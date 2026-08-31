import AppKit
import Combine
import SwiftUI

/// Owns the monitor and republishes its snapshots on the main actor.
@MainActor
final class AudioStore: ObservableObject {
    @Published private(set) var snapshot = AudioSnapshot()

    private let monitor = AudioMonitor()
    private var ticker: Timer?
    private var meterTicker: Timer?
    private var hasExplainedAutomation = false

    func start() {
        monitor.onChange = { [weak self] in self?.reload() }
        monitor.start()
        reload()
        // CoreAudio pushes state changes; this only catches the linger timers
        // expiring and the volume being changed by the keyboard.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        // Meters need to move like meters; the rest of the snapshot does not.
        let meters = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLevels() }
        }
        RunLoop.main.add(meters, forMode: .common)
        meterTicker = meters
    }

    /// Cheap: only the level numbers, at meter rate.
    private func refreshLevels() {
        guard snapshot.anyPlaying else { return }
        let levels = monitor.levels()
        guard !levels.isEmpty else { return }
        var updated = snapshot
        updated.sources = snapshot.sources.map { source in
            var copy = source
            copy.level = levels[source.id] ?? 0
            return copy
        }
        if updated != snapshot { snapshot = updated }
    }

    /// Album art for a track, once it has been fetched.
    func artwork(for url: String?) -> NSImage? { monitor.artwork(for: url) }

    func reload() {
        let fresh = monitor.snapshot()
        guard fresh != snapshot else { return }
        snapshot = fresh
    }

    /// Stand-in state for the README screenshots.
    func loadDemoData() {
        snapshot = AudioSnapshot(
            sources: [
                AudioSource(id: 501, name: "Spotify", bundleID: "com.spotify.client",
                            ownerBundleID: "com.spotify.client", isPlaying: true, isRecording: false,
                            transportPlaying: true,
                            track: TrackInfo(title: "we never dated", artist: "sombr", artworkURL: nil)),
                AudioSource(id: 502, name: "Arc", bundleID: "company.thebrowser.Browser",
                            ownerBundleID: "company.thebrowser.Browser", isPlaying: true, isRecording: false),
                AudioSource(id: 503, name: "Zoom", bundleID: "us.zoom.xos",
                            ownerBundleID: "us.zoom.xos", isPlaying: false, isRecording: true),
            ],
            devices: [
                OutputDevice(id: 1, name: "AirPods Pro", uid: "airpods", isDefault: true),
                OutputDevice(id: 2, name: "MacBook Air Speakers", uid: "builtin", isDefault: false),
            ],
            recent: [
                AudioEvent(app: "Slack", kind: .started, at: Date().addingTimeInterval(-42)),
                AudioEvent(app: "Arc", kind: .started, at: Date().addingTimeInterval(-160)),
                AudioEvent(app: "AirPods Pro", kind: .becameOutput, at: Date().addingTimeInterval(-320)),
            ],
            volume: 0.62, muted: false, cameraActive: false)
    }

    // MARK: - Actions

    /// Shown once: without Automation permission, pausing a named app cannot work.
    private func explainAutomation() {
        guard !hasExplainedAutomation else { return }
        hasExplainedAutomation = true
        let alert = NSAlert()
        alert.messageText = "Allow Audio Notch to control media apps"
        alert.informativeText =
            "macOS blocked the request to pause this app. Open System Settings > Privacy & "
            + "Security > Automation and enable Audio Notch for Spotify and Music.\n\n"
            + "Until then, pause falls back to the media key, which only reaches whichever "
            + "app currently owns Now Playing."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func setVolume(_ value: Float) {
        AudioControls.setVolume(value)
        snapshot.volume = value
    }

    func toggleMute() {
        AudioControls.setMuted(!snapshot.muted)
        reload()
    }

    func select(device: OutputDevice) {
        AudioControls.selectOutput(device.id)
        reload()
    }

    func act(on source: AudioSource) {
        guard let transport = source.transport else {
            AudioControls.focus(pid: source.id)
            reload()
            return
        }

        let willBePlaying = !source.reallyPlaying
        AudioControls.togglePlayback(transport)
        if AudioControls.automationDenied { explainAutomation() }

        // Reflect the click immediately. Waiting for the next poll to confirm what we
        // just asked for is the difference between a button and a suggestion.
        if let index = snapshot.sources.firstIndex(where: { $0.id == source.id }) {
            snapshot.sources[index].transportPlaying = willBePlaying
        }
        monitor.invalidateTransport()
        // Then confirm, in case the app disagreed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reload() }
    }
}
