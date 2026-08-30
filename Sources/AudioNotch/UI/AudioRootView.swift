import AppKit
import SwiftUI

struct AudioRootView: View {
    @ObservedObject var store: AudioStore
    @ObservedObject var state: NotchState
    var onHitTargets: ([HitTarget]) -> Void
    var onPanelHeight: (CGFloat) -> Void

    private var placement: Placement { state.placement }
    private var alignment: Alignment { placement.alignment }
    private var snapshot: AudioSnapshot { store.snapshot }

    private var layout: Layout {
        Layout(placement: placement,
               rows: snapshot.sources.count + snapshot.devices.count,
               active: snapshot.anyPlaying,
               leadName: snapshot.playing.first?.name ?? snapshot.sources.first?.name ?? "",
               leadSubtitle: subtitle,
               measuredBody: state.panelBodyHeight,
               trailLabel: "\(Int((snapshot.volume * 100).rounded()))%")
    }

    private var subtitle: String {
        if snapshot.playing.count > 1 { return "+\(snapshot.playing.count - 1) more" }
        if let device = snapshot.currentDevice { return device.name }
        return "no output"
    }

    private var currentSize: CGSize { layout.size(for: state.mode) }
    private var radius: CGFloat { state.mode == .mini ? 4 : 12 }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            shell
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var shell: some View {
        ZStack(alignment: alignment) {
            layer(MiniNub(layout: layout, active: snapshot.anyPlaying), visible: state.mode == .mini)
            layer(PillContent(snapshot: snapshot, layout: layout), visible: state.mode == .pill)
            layer(Panel(store: store, layout: layout, onHitTargets: onHitTargets,
                        onHeight: reportHeight),
                  visible: state.mode == .expanded)
        }
        .frame(width: currentSize.width, height: currentSize.height, alignment: alignment)
        .background(Color.black)
        .clipShape(NotchShape(radius: radius, edge: placement.edge))
        .overlay(
            NotchShape(radius: radius, edge: placement.edge)
                .stroke(Color.white.opacity(state.mode == .expanded ? 0.10 : 0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(state.mode == .expanded ? 0.5 : 0.22),
                radius: state.mode == .expanded ? 20 : 8, y: 6)
        .animation(Anim.morph, value: currentSize)
        .animation(Anim.morph, value: radius)
        .animation(Anim.morph, value: placement)
    }

    /// The panel measures itself; the shell, the window and the hit region follow it.
    private func reportHeight(_ height: CGFloat) {
        let rounded = ceil(height)
        guard abs((state.panelBodyHeight ?? 0) - rounded) > 0.5 else { return }
        state.panelBodyHeight = rounded
        onPanelHeight(rounded)
    }

    private func layer<V: View>(_ view: V, visible: Bool) -> some View {
        view
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 3)
            .allowsHitTesting(visible)
            .animation(Anim.fade, value: visible)
    }
}

/// Bars that bounce while audio is playing.
struct LevelBars: View {
    var tint: Color
    var animating: Bool
    /// Real 0...1 level when the app can read one; zero falls back to the animation.
    var level: Float = 0
    var height: CGFloat = 12

    @State private var phase = false
    private let scales: [CGFloat] = [0.5, 1.0, 0.68, 0.85]

    private var metered: Bool { level > 0.001 }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(scales.enumerated()), id: \.offset) { index, scale in
                Capsule()
                    .fill(tint)
                    .frame(width: 2, height: barHeight(index: index, scale: scale))
                    .animation(
                        metered
                            ? .linear(duration: 0.07)
                            : (animating
                                ? .easeInOut(duration: 0.38 + Double(index) * 0.07).repeatForever(autoreverses: true)
                                : .easeOut(duration: 0.2)),
                        value: metered ? CGFloat(level) : (phase ? 1 : 0)
                    )
            }
        }
        .frame(height: height)
        .onAppear { phase = animating }
        .onChange(of: animating) { _, now in phase = now }
    }

    private func barHeight(index: Int, scale: CGFloat) -> CGFloat {
        if metered {
            // Bars lag each other slightly so the meter reads as movement, not a block.
            let lag: CGFloat = [1.0, 0.88, 0.74, 0.62][index % 4]
            return max(3, height * min(CGFloat(level) * lag * scale * 1.6, 1))
        }
        guard animating else { return 3 }
        return phase ? height * scale : max(height * 0.28 * scale, 3)
    }
}

private struct AppIcon: View {
    var source: AudioSource
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = source.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .frame(width: size, height: size)
    }
}

private struct MiniNub: View {
    var layout: Layout
    var active: Bool

    var body: some View {
        let size = layout.size(for: .mini)
        let colour = active ? Color(red: 0.45, green: 0.85, blue: 0.62) : Color.white.opacity(0.22)
        Group {
            if layout.placement.edge.isSide {
                VStack(spacing: 3) {
                    Capsule().fill(colour).frame(width: 3, height: 16)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 3, height: 8)
                }
            } else {
                HStack(spacing: 3) {
                    Capsule().fill(colour).frame(width: 16, height: 3)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 8, height: 3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Resting state: what is making sound, and where it is going.
private struct PillContent: View {
    var snapshot: AudioSnapshot
    var layout: Layout

    private var lead: AudioSource? { snapshot.playing.first ?? snapshot.sources.first }

    var body: some View {
        let size = layout.size(for: .pill)
        Group {
            switch layout.placement.edge {
            case .island: island(size)
            case .left, .right: vertical(size)
            case .top: horizontal(size)
            }
        }
    }

    private var leading: some View {
        HStack(spacing: 6) {
            if let lead {
                AppIcon(source: lead)
                VStack(alignment: .leading, spacing: 0) {
                    Text(lead.name)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(snapshot.playing.count > 1 ? "+\(snapshot.playing.count - 1) more" : (lead.isPlaying ? "playing" : "idle"))
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                LevelBars(tint: .green.opacity(0.85), animating: lead.isPlaying,
                          level: lead.level, height: 10)
            } else {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                Text("silent")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            Image(systemName: snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(snapshot.muted ? 0.45 : 0.7))
            Text("\(Int((snapshot.volume * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
        }
    }

    private func island(_ size: CGSize) -> some View {
        let wing = (size.width - layout.notchGap) / 2
        return HStack(spacing: 0) {
            leading.fixedSize().padding(.horizontal, Style.wingInset).frame(width: wing)
            Color.clear.frame(width: layout.notchGap)
            trailing.fixedSize().padding(.horizontal, Style.wingInset).frame(width: wing)
        }
        .frame(width: size.width, height: size.height)
    }

    private func horizontal(_ size: CGSize) -> some View {
        HStack(spacing: 9) {
            leading
            if snapshot.anyPlaying {
                Divider().frame(height: 12).overlay(Color.white.opacity(0.12))
            }
            trailing
        }
        .fixedSize()
        .padding(.horizontal, Style.pillInset)
        .frame(width: size.width, height: size.height)
    }

    private func vertical(_ size: CGSize) -> some View {
        VStack(spacing: 7) {
            if let lead {
                AppIcon(source: lead, size: 14)
                LevelBars(tint: .green.opacity(0.85), animating: lead.isPlaying,
                          level: lead.level, height: 9)
            } else {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text("\(Int((snapshot.volume * 100).rounded()))")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.vertical, 8)
        .frame(width: size.width, height: size.height)
    }
}

/// The opened panel: sources, volume, output devices.
private struct Panel: View {
    @ObservedObject var store: AudioStore
    var layout: Layout
    var onHitTargets: ([HitTarget]) -> Void
    var onHeight: (CGFloat) -> Void

    @State private var targets: [String: CGRect] = [:]

    private var snapshot: AudioSnapshot { store.snapshot }

    var body: some View {
        let size = layout.size(for: .expanded)
        VStack(spacing: 0) {
            if layout.placement.edge.isIsland {
                band.frame(height: layout.placement.notch.height)
            }
            // No fixed height: the content lays out naturally and reports what it
            // needed, which is what everything else is then sized from.
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(RectReader { onHeight($0.height) })
        }
        .frame(width: size.width, alignment: .top)
        .onChange(of: targets) { _, new in
            onHitTargets(new.map { HitTarget(id: $0.key, rect: $0.value) })
        }
    }

    private var band: some View {
        let wing = (layout.size(for: .expanded).width - layout.notchGap) / 2
        return HStack(spacing: 0) {
            Text("AUDIO")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize()
                .frame(width: wing)
            Color.clear.frame(width: layout.notchGap)
            Text(snapshot.currentDevice?.name ?? "—")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .fixedSize()
                .frame(width: wing)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !layout.placement.edge.isIsland {
                HStack {
                    Text("AUDIO")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(snapshot.currentDevice?.name ?? "—")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            volumeRow

            if snapshot.cameraActive || !snapshot.recording.isEmpty {
                watchdogRow
            }

            if snapshot.sources.isEmpty {
                Text("Nothing is playing")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                section("SOURCES")
                ForEach(snapshot.sources) { source in
                    sourceRow(source)
                }
            }

            if !snapshot.recent.isEmpty {
                section("RECENT")
                ForEach(snapshot.recent.prefix(3)) { event in
                    HStack(spacing: 6) {
                        Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                        Text(event.app)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        Text(event.kind.verb)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer(minLength: 4)
                        Text(event.ago())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .frame(height: 16)
                }
            }

            if snapshot.meteringUnavailable && snapshot.anyPlaying {
                Text("levels need audio-recording permission")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
            }

            if snapshot.devices.count > 1 {
                section("OUTPUT")
                ForEach(snapshot.devices) { device in
                    deviceRow(device)
                }
            }

        }
        .padding(.horizontal, Style.panelInset)
        .padding(.top, layout.placement.edge.isIsland ? 8 : 12)
        .padding(.bottom, 12)
    }

    /// Who is watching or listening to you right now — the question the green dot
    /// refuses to answer.
    private var watchdogRow: some View {
        HStack(spacing: 7) {
            Image(systemName: snapshot.cameraActive ? "video.fill" : "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red.opacity(0.85))
            Text(watchdogText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var watchdogText: String {
        let who = snapshot.recording.first?.name
        switch (snapshot.cameraActive, who) {
        case (true, let name?): return "\(name) — camera and mic"
        case (true, nil): return "camera in use"
        case (false, let name?): return "\(name) — using the mic"
        default: return "in use"
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(.white.opacity(0.3))
    }

    private var volumeRow: some View {
        HStack(spacing: 9) {
            Image(systemName: snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(snapshot.muted ? 0.4 : 0.75))
                .frame(width: 16)
                .measured("mute", into: $targets)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(snapshot.muted ? Color.white.opacity(0.25) : Color.green.opacity(0.85))
                        .frame(width: proxy.size.width * CGFloat(snapshot.muted ? 0 : snapshot.volume))
                        .animation(.easeOut(duration: 0.15), value: snapshot.volume)
                }
            }
            .frame(height: 5)
            .measured("volume", into: $targets)

            Text("\(Int((snapshot.volume * 100).rounded()))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, alignment: .trailing)
        }
        .frame(height: 20)
    }

    private func sourceRow(_ source: AudioSource) -> some View {
        HStack(spacing: 9) {
            AppIcon(source: source, size: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(source.isRecording ? "using the mic" : (source.isPlaying ? "playing" : "idle"))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(source.isRecording ? .red.opacity(0.8) : .white.opacity(0.35))
            }
            Spacer(minLength: 4)
            LevelBars(tint: source.isRecording ? .red.opacity(0.8) : .green.opacity(0.85),
                      animating: source.isPlaying || source.isRecording,
                      level: source.level, height: 11)
            Text(source.actionLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .frame(height: 26)
        .measured("source:\(source.id)", into: $targets)
    }

    private func deviceRow(_ device: OutputDevice) -> some View {
        HStack(spacing: 9) {
            Image(systemName: device.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(device.isDefault ? 0.85 : 0.4))
                .frame(width: 17)
            Text(device.name)
                .font(.system(size: 10.5, weight: device.isDefault ? .semibold : .medium, design: .rounded))
                .foregroundStyle(.white.opacity(device.isDefault ? 0.9 : 0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            if device.isDefault {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green.opacity(0.8))
            }
        }
        .frame(height: 24)
        .measured("device:\(device.id)", into: $targets)
    }
}

private extension View {
    /// Records this row's rect so the AppKit layer can route clicks to it.
    func measured(_ id: String, into targets: Binding<[String: CGRect]>) -> some View {
        background(
            RectReader { rect in
                if targets.wrappedValue[id] != rect { targets.wrappedValue[id] = rect }
            }
        )
    }
}
