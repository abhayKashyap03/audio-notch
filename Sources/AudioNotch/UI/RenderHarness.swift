import AppKit
import SwiftUI

/// `AudioNotch --render <dir>` snapshots each notch state to PNG. Screen Recording
/// permission is not always available, so this is how the UI gets eyeballed and how
/// the README screenshots are produced.
@MainActor
enum RenderHarness {
    static func run(outputDirectory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let store = AudioStore()
        let state = NotchState()
        if CommandLine.arguments.contains("--demo") {
            store.loadDemoData()
        } else {
            store.reload()
        }

        let edge = Settings.shared.edge
        // Screenshots of island mode need notch metrics even on a screen without one.
        let notch = NotchGeometry.current().islandSize
        for (mode, name) in [(NotchMode.mini, "mini"), (.pill, "pill"), (.expanded, "expanded")] {
            state.mode = mode
            state.placement = Placement(edge: edge, anchor: .rightOfNotch, notch: notch)
            let root = AudioRootView(store: store, state: state,
                                     onHitTargets: { _ in }, onPanelHeight: { _ in })
            let snap = store.snapshot
            let layout = Layout(placement: state.placement,
                                rows: snap.sources.count + snap.devices.count,
                                active: snap.anyPlaying,
                                leadName: snap.playing.first?.name ?? "",
                                leadSubtitle: snap.currentDevice?.name ?? "",
                                measuredBody: state.panelBodyHeight,
                                trailLabel: "\(Int((snap.volume * 100).rounded()))%")
            let size = layout.size(for: mode)
            snapshot(root, size: size, to: outputDirectory + "/\(name).png")
            print("rendered \(name).png  \(Int(size.width))x\(Int(size.height))")
        }
        exit(0)
    }

    /// Pumps the main run loop until `done()` or the deadline passes.
    private static func spin(until deadline: Date, done: () -> Bool) {
        while Date() < deadline && !done() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            usleep(10_000)
        }
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        // SwiftUI needs a window to run a layout pass; keep it offscreen.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        spin(until: Date().addingTimeInterval(0.4)) { false }

        // The panel sizes itself now, so trust its fitting size over the estimate.
        let fitting = hosting.fittingSize
        if fitting.height > hosting.frame.height + 0.5 {
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: hosting.frame.width, height: ceil(fitting.height)))
            window.setContentSize(hosting.frame.size)
            hosting.layoutSubtreeIfNeeded()
            spin(until: Date().addingTimeInterval(0.25)) { false }
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
