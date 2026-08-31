import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// Hosting view for the pill: routes clicks and drags in AppKit.
///
/// SwiftUI's gesture recognisers never fire here — the panel does not become key —
/// so mouse handling lives at this level. A press that moves more than a few points
/// is a reposition; anything shorter is a click, dispatched to whichever control
/// reported that rect.
final class NotchHostingView: NSHostingView<AudioRootView> {
    /// Content rect in SwiftUI coordinates (origin top-left), updated on every change.
    var interactiveRect: CGRect = .zero
    /// Controls published by the SwiftUI tree, in the same coordinate space.
    var hitTargets: [HitTarget] = []
    /// Those controls only exist while the panel is open.
    var targetsEnabled = false

    var onDebug: ((String) -> Void)?
    var onPrimaryClick: (() -> Void)?
    var onTargetClick: ((String, CGPoint) -> Void)?
    var onSecondaryClick: ((NSPoint) -> Void)?
    var onTargetDrag: ((String, CGPoint) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint, CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private static let dragThreshold: CGFloat = 4

    private var pressOrigin: NSPoint?
    private var isDragging = false
    /// The control the press started on, if any. Dragging inside a slider should
    /// move the slider, not the whole pill.
    private var pressedTarget: HitTarget?

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        isDragging = false
        let point = contentPoint(inWindow: event.locationInWindow)
        pressedTarget = targetsEnabled ? hitTargets.first { $0.rect.contains(point) } : nil
    }

    override func mouseDragged(with event: NSEvent) {
        // A drag that began on the volume bar adjusts it, continuously.
        if let target = pressedTarget, target.id == "volume" {
            let point = contentPoint(inWindow: event.locationInWindow)
            isDraggingSlider = true
            onTargetDrag?(target.id, CGPoint(x: point.x - target.rect.minX, y: point.y - target.rect.minY))
            return
        }
        guard let start = pressOrigin else { return }
        let current = NSEvent.mouseLocation
        let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
        if !isDragging {
            guard hypot(delta.x, delta.y) > Self.dragThreshold else { return }
            isDragging = true
            onDragBegan?()
        }
        onDragMoved?(current, delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil; isDragging = false; pressedTarget = nil }
        // A slider drag has already applied itself; do not also treat it as a click.
        if let target = pressedTarget, target.id == "volume", isDraggingSlider {
            isDraggingSlider = false
            return
        }
        if isDragging {
            onDragEnded?()
            return
        }
        let point = contentPoint(inWindow: event.locationInWindow)
        onDebug?("click at \(point) flipped=\(isFlipped) rect=\(interactiveRect) targets=\(hitTargets.map(\.id))")
        if targetsEnabled, let hit = hitTargets.first(where: { $0.rect.contains(point) }) {
            onTargetClick?(hit.id, CGPoint(x: point.x - hit.rect.minX, y: point.y - hit.rect.minY))
        } else {
            onPrimaryClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSecondaryClick?(NSEvent.mouseLocation)
    }

    private var isDraggingSlider = false

    /// Panels that never activate still need to accept the very first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI reports rects with the origin at the top-left; AppKit hands us
    /// bottom-left window coordinates. Convert once, in one place.
    private func contentPoint(inWindow point: NSPoint) -> CGPoint {
        // NSHostingView is flipped, so converting from window coordinates already
        // yields SwiftUI's top-left origin. Flipping again is a bug that pushed every
        // click to the mirrored half of the panel.
        let local = convert(point, from: nil)
        return isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }

    @MainActor required init(rootView: AudioRootView) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Wires the panel, the SwiftUI tree, the status-bar menu and the refresh loop together.
@MainActor
final class NotchController: NSObject, NSMenuDelegate {
    private let store = AudioStore()
    private let state = NotchState()
    private var panel: NotchPanel!
    private var hosting: NotchHostingView!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var geometry = NotchGeometry.current()

    /// Slack around the content so the drop shadow is not clipped by the window.
    private static let shadowMargin: CGFloat = 36
    /// How close to an edge the cursor must get, while dragging, to snap to it.
    private static let snapBand: CGFloat = 90

    private var monitors: [Any] = []
    private var mouseTimer: Timer?
    private var claimTimer: Timer?
    private var mouseInside = false

    private struct DragOrigin {
        var cursor: NSPoint
        var topOffset: Double
        var sideOffset: Double
    }
    private var drag: DragOrigin?

    func install() {
        buildPanel()
        buildStatusItem()
        installMouseTracking()

        state.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.updateHitRegion(for: mode)
                self?.debugLog("mode=\(mode)")
            }
            .store(in: &bag)

        // The pill resizes when what is playing changes, so follow the snapshot.
        store.$snapshot
            .map { "\($0.sources.count):\($0.devices.count):\($0.playing.first?.name ?? "")" }
            .removeDuplicates()
            .sink { [weak self] _ in self?.positionPanel() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildLayout() }
            .store(in: &bag)

        // Keep our claim fresh so other widgets know we are still here, and drop it
        // when we quit so they can reclaim the space.
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.publishClaim(for: self.panel.frame)
            }
        }
        heartbeat.tolerance = 5
        RunLoop.main.add(heartbeat, forMode: .common)
        claimTimer = heartbeat

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in NotchClaims.withdraw() }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refresh(spin: false) }
            .store(in: &bag)

        state.placement = currentPlacement()
        state.mode = state.restingMode
        updateHitRegion(for: state.mode)
        store.start()
        debugLog("panel=\(panel.frame) screen=\(geometry.screen.localizedName) notch=\(geometry.anchorRect) hasNotch=\(geometry.hasNotch)")
    }

    /// Set AUDIONOTCH_DEBUG=1 to trace placement and interaction on stderr.
    private func debugLog(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["AUDIONOTCH_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data(("[audio-notch] " + message() + "\n").utf8))
    }

    // MARK: - Panel

    private func buildPanel() {
        panel = NotchPanel(contentRect: windowFrame())
        hosting = NotchHostingView(rootView: makeRootView())
        hosting.onDebug = { [weak self] message in self?.debugLog(message) }
        hosting.onPrimaryClick = { [weak self] in self?.refresh(spin: true) }
        hosting.onTargetClick = { [weak self] id, point in self?.handleTarget(id, at: point) }
        hosting.onTargetDrag = { [weak self] id, point in self?.handleTarget(id, at: point) }
        hosting.onSecondaryClick = { [weak self] location in self?.showContextMenu(at: location) }
        hosting.onDragBegan = { [weak self] in self?.dragBegan() }
        hosting.onDragMoved = { [weak self] cursor, delta in self?.dragMoved(cursor: cursor, delta: delta) }
        hosting.onDragEnded = { [weak self] in self?.dragEnded() }
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
        // Transparent until the cursor is actually over the pill — see mouseMoved().
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    private func makeRootView() -> AudioRootView {
        AudioRootView(
            store: store,
            state: state,
            onHitTargets: { [weak self] targets in
                self?.hosting?.hitTargets = targets
                self?.debugLog("targets=" + targets.map { "\($0.id)@\(Int($0.rect.minY))-\(Int($0.rect.maxY))" }.sorted().joined(separator: " "))
            },
            onPanelHeight: { [weak self] height in
                self?.debugLog("panel measured \(height)")
                self?.positionPanel()
            }
        )
    }

    private func layout() -> Layout {
        let snap = store.snapshot
        return Layout(placement: currentPlacement(),
                      rows: snap.sources.count + snap.devices.count,
                      active: snap.anyPlaying,
                      leadName: snap.playing.first?.name ?? snap.sources.first?.name ?? "",
                      leadSubtitle: snap.currentDevice?.name ?? "",
                      measuredBody: state.panelBodyHeight,
                      trailLabel: "\(Int((snap.volume * 100).rounded()))%")
    }

    private func currentPlacement() -> Placement {
        Placement.current(notch: geometry.islandSize)
    }

    /// Big enough for the largest state, so the window never resizes mid-animation.
    private func windowSize() -> CGSize {
        let l = layout()
        let expanded = l.size(for: .expanded)
        let pill = l.size(for: .pill)
        return CGSize(width: max(expanded.width, pill.width) + Self.shadowMargin,
                      height: max(expanded.height, pill.height) + Self.shadowMargin)
    }

    /// Base placement plus the user's drag offset, clamped so the pill stays on screen.
    private func windowFrame() -> CGRect {
        let placement = currentPlacement()
        let size = windowSize()
        var frame = geometry.frame(for: size, placement: placement)
        switch placement.edge {
        case .top: frame.origin.x += CGFloat(Settings.shared.topOffset)
        case .left, .right: frame.origin.y += CGFloat(Settings.shared.sideOffset)
        case .island: break   // island mode is pinned to the notch by definition
        }

        // Keep the pill itself (not the padded window) fully on screen. Top and island
        // placements are meant to occupy the menu-bar strip, so they clamp against the
        // full screen; side placements stay clear of the menu bar.
        let content = placement.contentRect(window: size, content: currentContentSize())
        let screen = geometry.screen.frame
        let ceiling = placement.edge.isSide ? geometry.screen.visibleFrame.maxY : screen.maxY
        let minX = screen.minX - content.minX
        let maxX = screen.maxX - content.maxX
        let minY = screen.minY + (size.height - content.maxY)
        let maxY = ceiling - (size.height - content.minY)
        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = min(max(frame.origin.y, minY), maxY)

        // Step around any other notch widget that already claimed this strip.
        let obstacles = NotchClaims.obstacles(screen: geometry.screen.localizedName)
        if !obstacles.isEmpty {
            let contentScreen = CGRect(x: frame.minX + content.minX,
                                       y: frame.maxY - content.maxY,
                                       width: content.width, height: content.height)
            let resolved = NotchClaims.resolve(rect: contentScreen, edge: placement.edge,
                                               screen: geometry.screen, obstacles: obstacles)
            frame.origin.x += resolved.minX - contentScreen.minX
            frame.origin.y += resolved.minY - contentScreen.minY
        }

        return CGRect(x: frame.origin.x.rounded(), y: frame.origin.y.rounded(),
                      width: size.width, height: size.height)
    }

    private func currentContentSize(for mode: NotchMode? = nil) -> CGSize {
        layout().size(for: mode ?? state.mode)
    }

    private func positionPanel() {
        let frame = windowFrame()
        panel.setFrame(frame, display: true)
        publishClaim(for: frame)
        updateHitRegion(for: state.mode)
        panel.orderFrontRegardless()
    }

    /// Tell other notch widgets which strip of screen this one occupies.
    private func publishClaim(for frame: CGRect) {
        let content = currentPlacement().contentRect(window: frame.size, content: currentContentSize())
        let screenRect = CGRect(x: frame.minX + content.minX,
                                y: frame.maxY - content.maxY,
                                width: content.width, height: content.height)
        NotchClaims.publish(rect: screenRect, screen: geometry.screen.localizedName,
                            edge: Settings.shared.edge)
    }

    private func rebuildLayout() {
        geometry = NotchGeometry.current()
        state.placement = currentPlacement()
        positionPanel()
    }

    /// Clicks only count where the pill is drawn; the rest of the (deliberately
    /// oversized) window is transparent to whatever is underneath.
    private func updateHitRegion(for mode: NotchMode) {
        let content = currentContentSize(for: mode)
        hosting.interactiveRect = currentPlacement().contentRect(window: panel.frame.size, content: content)
        hosting.targetsEnabled = mode == .expanded
    }

    // MARK: - Mouse tracking
    //
    // A window swallows every click inside its frame, whatever its views' hit tests
    // say — view-level hit testing cannot hand a click to another application. So the
    // panel stays mouse-transparent and only opens up while the cursor is genuinely
    // over the pill, which also gives us hover without a tracking area.

    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]) { event in handler(event); return event } {
            monitors.append(local)
        }
        // Safety net for movement the monitors miss (space switches, warps).
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.mouseMoved() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    /// Screen rect of the drawn pill, in bottom-left coordinates.
    private func contentScreenRect() -> CGRect {
        let window = panel.frame
        let rect = currentPlacement().contentRect(window: window.size, content: currentContentSize())
        return CGRect(x: window.minX + rect.minX,
                      y: window.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func mouseMoved() {
        guard drag == nil else { return }   // keep events while repositioning
        let inside = contentScreenRect().insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
        guard inside != mouseInside else { return }
        mouseInside = inside
        panel.ignoresMouseEvents = !inside
        debugLog("mouse \(inside ? "entered" : "left") pill; ignoresMouseEvents=\(!inside)")
        state.hoverChanged(inside)
        if inside { store.reload() }
    }

    // MARK: - Dragging

    private func dragBegan() {
        drag = DragOrigin(cursor: NSEvent.mouseLocation,
                          topOffset: Settings.shared.topOffset,
                          sideOffset: Settings.shared.sideOffset)
        panel.ignoresMouseEvents = false
    }

    private func dragMoved(cursor: NSPoint, delta: CGPoint) {
        guard var origin = drag else { return }

        // Dragging into an edge band re-attaches the pill to that edge.
        let screen = geometry.screen.frame
        var edge = Settings.shared.edge
        if cursor.y > screen.maxY - Self.snapBand { edge = .top }
        else if cursor.x < screen.minX + Self.snapBand { edge = .left }
        else if cursor.x > screen.maxX - Self.snapBand { edge = .right }

        if edge == .island { edge = .top }
        if edge != Settings.shared.edge {
            Settings.shared.edge = edge
            state.placement = .current
            centreOnCursor(cursor, edge: edge)
            origin = DragOrigin(cursor: cursor,
                                topOffset: Settings.shared.topOffset,
                                sideOffset: Settings.shared.sideOffset)
            drag = origin
            debugLog("drag snapped to \(edge.rawValue)")
        } else {
            switch edge {
            case .top: Settings.shared.topOffset = origin.topOffset + Double(cursor.x - origin.cursor.x)
            case .left, .right: Settings.shared.sideOffset = origin.sideOffset + Double(cursor.y - origin.cursor.y)
            case .island: break
            }
        }
        positionPanel()
    }

    private func dragEnded() {
        drag = nil
        positionPanel()
        mouseMoved()
    }

    /// Places the pill under the cursor along its new edge, so a snap does not make
    /// it jump to the middle of the screen.
    private func centreOnCursor(_ cursor: NSPoint, edge: NotchEdge) {
        Settings.shared.topOffset = 0
        Settings.shared.sideOffset = 0
        let size = windowSize()
        let base = geometry.frame(for: size, placement: currentPlacement())
        let content = currentPlacement().contentRect(window: size, content: currentContentSize())
        switch edge {
        case .top:
            Settings.shared.topOffset = Double(cursor.x - (base.minX + content.midX))
        case .left, .right:
            Settings.shared.sideOffset = Double(cursor.y - (base.maxY - content.midY))
        case .island:
            break
        }
    }

    // MARK: - Actions

    private func refresh(spin: Bool) {
        if spin { state.kickRefreshSpin() }
        store.reload()
    }

    /// Rows report their own rects, so a click is routed by id here.
    private func handleTarget(_ id: String, at point: CGPoint) {
        let snapshot = store.snapshot
        switch true {
        case id == "mute":
            store.toggleMute()
        case id == "volume":
            let width = hosting.hitTargets.first { $0.id == "volume" }?.rect.width ?? 1
            store.setVolume(Float(min(max(point.x / width, 0), 1)))
        case id == "settings":
            let rect = contentScreenRect()
            showContextMenu(at: NSPoint(x: rect.midX, y: rect.minY))
        case id.hasPrefix("source:"):
            let pid = pid_t(id.dropFirst("source:".count)) ?? -1
            if let source = snapshot.sources.first(where: { $0.id == pid }) { store.act(on: source) }
        case id.hasPrefix("device:"):
            let deviceID = UInt32(id.dropFirst("device:".count)) ?? 0
            if let device = snapshot.devices.first(where: { $0.id == deviceID }) { store.select(device: device) }
        default:
            break
        }
        debugLog("target \(id) at \(point)")
    }

    private func toggleMiniMode() {
        Settings.shared.miniMode.toggle()
        debugLog("work mode -> \(Settings.shared.miniMode)")
        state.settleToResting()
    }

    /// Right-clicking the pill opens the same menu the status item carries.
    private func showContextMenu(at location: NSPoint) {
        guard let menu = statusItem.menu, let view = panel.contentView else { return }
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: panel.convertPoint(fromScreen: location), in: view)
    }

    @objc private func menuRefresh() { refresh(spin: true) }
    @objc private func menuToggleMini() { toggleMiniMode() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuResetPosition() {
        Settings.shared.resetOffsets()
        rebuildLayout()
    }

    @objc private func menuSetEdge(_ sender: NSMenuItem) {
        guard let edge = NotchEdge(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.shared.edge = edge
        Settings.shared.resetOffsets()
        rebuildLayout()
    }

    @objc private func menuSetAnchor(_ sender: NSMenuItem) {
        guard let anchor = NotchAnchor(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.shared.anchor = anchor
        Settings.shared.topOffset = 0
        rebuildLayout()
    }

    @objc private func menuSetScreen(_ sender: NSMenuItem) {
        Settings.shared.preferredScreen = sender.representedObject as? String
        Settings.shared.resetOffsets()
        rebuildLayout()
    }

    @objc private func menuToggleFollow() {
        Settings.shared.followNewDevices.toggle()
    }

    @objc private func menuToggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                           accessibilityDescription: "Usage Notch")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        if let device = store.snapshot.currentDevice {
            let item = NSMenuItem(title: "Output: \(device.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for source in store.snapshot.playing.prefix(3) {
            let item = NSMenuItem(title: "\(source.name) — playing", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(item("Refresh", #selector(menuRefresh), key: "r"))
        menu.addItem(item(s.miniMode ? "Leave work mode" : "Work mode (hide pill)", #selector(menuToggleMini), key: "h"))

        let displays = NSMenu()
        let auto = item("Automatic (notched screen)", #selector(menuSetScreen(_:)))
        auto.representedObject = nil
        auto.state = s.preferredScreen == nil ? .on : .off
        displays.addItem(auto)
        displays.addItem(.separator())
        for screen in NSScreen.screens {
            let name = screen.localizedName
            let suffix = screen.safeAreaInsets.top > 0 ? " (notch)" : ""
            let mi = item(name + suffix, #selector(menuSetScreen(_:)))
            mi.representedObject = name
            mi.state = s.preferredScreen == name ? .on : .off
            displays.addItem(mi)
        }
        menu.addItem(submenu("Display", displays))

        let edges = NSMenu()
        for edge in NotchEdge.allCases {
            let mi = item(edge.title, #selector(menuSetEdge(_:)))
            mi.representedObject = edge.rawValue
            mi.state = s.edge == edge ? .on : .off
            edges.addItem(mi)
        }
        menu.addItem(submenu("Attach to", edges))

        let position = NSMenu()
        for anchor in NotchAnchor.allCases {
            let mi = item(anchor.title(hasNotch: geometry.hasNotch), #selector(menuSetAnchor(_:)))
            mi.representedObject = anchor.rawValue
            mi.state = s.anchor == anchor ? .on : .off
            mi.isEnabled = s.edge == .top
            position.addItem(mi)
        }
        position.addItem(.separator())
        position.addItem(item("Reset to default spot", #selector(menuResetPosition)))
        menu.addItem(submenu(s.edge == .top ? "Position" : "Position (drag to move)", position))


        let follow = item("Follow newly connected devices", #selector(menuToggleFollow))
        follow.state = s.followNewDevices ? .on : .off
        menu.addItem(follow)

        let login = item("Open at login", #selector(menuToggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Usage Notch", #selector(menuQuit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }
}
