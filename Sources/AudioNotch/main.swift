import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            let controller = NotchController()
            controller.install()
            self.controller = controller
        }
    }
}

// `AudioNotch --dump` prints what CoreAudio reports, then exits.
if CommandLine.arguments.contains("--dump") {
    let snapshot = AudioMonitor().snapshot()
    print("volume: \(Int((snapshot.volume * 100).rounded()))%  muted: \(snapshot.muted)")
    print("output: \(snapshot.currentDevice?.name ?? "none")")
    for device in snapshot.devices {
        print("  device \(device.isDefault ? "*" : " ") \(device.name)")
    }
    for source in snapshot.sources {
        let state = source.isRecording ? "recording" : (source.isPlaying ? "playing" : "idle")
        print("  source \(source.name) [\(source.ownerBundleID ?? "?")] \(state) transport=\(source.transport?.appName ?? "none")")
    }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let dir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "./docs"
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { RenderHarness.run(outputDirectory: dir) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
