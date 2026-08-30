import Combine
import SwiftUI

/// Owns the monitor and republishes its snapshots on the main actor.
@MainActor
final class AudioStore: ObservableObject {
    @Published private(set) var snapshot = AudioSnapshot()

    private let monitor = AudioMonitor()
    private var ticker: Timer?

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
    }

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
                            ownerBundleID: "com.spotify.client", isPlaying: true, isRecording: false),
                AudioSource(id: 502, name: "Arc", bundleID: "company.thebrowser.Browser",
                            ownerBundleID: "company.thebrowser.Browser", isPlaying: true, isRecording: false),
                AudioSource(id: 503, name: "Zoom", bundleID: "us.zoom.xos",
                            ownerBundleID: "us.zoom.xos", isPlaying: false, isRecording: true),
            ],
            devices: [
                OutputDevice(id: 1, name: "AirPods Pro", uid: "airpods", isDefault: true),
                OutputDevice(id: 2, name: "MacBook Air Speakers", uid: "builtin", isDefault: false),
            ],
            volume: 0.62, muted: false)
    }

    // MARK: - Actions

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
        if let transport = source.transport {
            AudioControls.togglePlayback(transport)
        } else {
            AudioControls.focus(pid: source.id)
        }
        reload()
    }
}
