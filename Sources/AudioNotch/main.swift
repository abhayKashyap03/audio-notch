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
// `AudioNotch --test-pause` exercises the transport path with the app's own
// identity, which is what Automation permission is granted against.
if CommandLine.arguments.contains("--test-pause") {
    let ok = AudioControls.togglePlayback(.spotify)
    print("togglePlayback -> \(ok), automationDenied=\(AudioControls.automationDenied)")
    exit(0)
}

// `AudioNotch --levels` prints live per-app levels for a few seconds.
if CommandLine.arguments.contains("--levels") {
    let monitor = AudioMonitor()
    for tick in 0..<24 {
        let snapshot = monitor.snapshot()
        if tick % 4 == 0 {
            let line = snapshot.sources.filter(\.isPlaying)
                .map { "\($0.name)=\(String(format: "%.2f", $0.level))" }
                .joined(separator: "  ")
            print(line.isEmpty ? "(nothing playing)" : line)
        }
        usleep(250_000)
    }
    print("metering unavailable: \(monitor.meteringUnavailable)  \(monitor.meterDiagnostics)")
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    let monitor = AudioMonitor()
    _ = monitor.snapshot()          // priming pass: the transport probe answers async
    usleep(2_500_000)
    let snapshot = monitor.snapshot()
    print("volume: \(Int((snapshot.volume * 100).rounded()))%  muted: \(snapshot.muted)")
    print("output: \(snapshot.currentDevice?.name ?? "none")")
    for device in snapshot.devices {
        print("  device \(device.isDefault ? "*" : " ") \(device.name)")
    }
    print("camera active: \(snapshot.cameraActive)   metering: \(snapshot.meteringUnavailable ? "unavailable" : "ok")")
    for event in snapshot.recent.prefix(6) {
        print("  event \(event.app) \(event.kind.verb) \(event.ago()) ago")
    }
    for source in snapshot.sources {
        let state = source.isRecording ? "recording" : (source.isPlaying ? "playing" : "idle")
        let says = source.transportPlaying.map { $0 ? "says playing" : "says paused" } ?? "no answer"
        print("  source \(source.name) [\(source.ownerBundleID ?? "?")] \(state) transport=\(source.transport?.appName ?? "none") \(says) chip=\(source.actionLabel)")
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
