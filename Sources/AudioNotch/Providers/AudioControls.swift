import AppKit
import CoreAudio
import AudioToolbox

/// The things macOS actually lets you change.
///
/// Output volume, mute and the default device are public CoreAudio properties.
/// Per-application volume is not: apps like SoundSource achieve it by installing a
/// virtual audio driver, which is a different kind of product. So per-app control
/// here is transport (for apps that script) and focus (for everything else).
enum AudioControls {
    static var defaultOutputDevice: AudioObjectID {
        CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }

    // MARK: - Output device

    static func volume(of device: AudioObjectID) -> Float? {
        guard CA.has(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                     scope: kAudioObjectPropertyScopeOutput) else { return nil }
        return CA.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                        scope: kAudioObjectPropertyScopeOutput, default: Float32(0))
    }

    @discardableResult
    static func setVolume(_ value: Float, on device: AudioObjectID = defaultOutputDevice) -> Bool {
        let clamped = Float32(min(max(value, 0), 1))
        return CA.set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                      scope: kAudioObjectPropertyScopeOutput, value: clamped)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        CA.value(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
                 default: UInt32(0)) != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on device: AudioObjectID = defaultOutputDevice) -> Bool {
        CA.set(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
               value: UInt32(muted ? 1 : 0))
    }

    @discardableResult
    static func selectOutput(_ device: AudioObjectID) -> Bool {
        CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, value: device)
    }

    // MARK: - Per app

    /// Play/pause for the handful of apps that expose it to scripting.
    static func togglePlayback(_ transport: Transport) {
        run(script: "tell application \"\(transport.appName)\" to playpause")
    }

    static func isPlaying(_ transport: Transport) -> Bool? {
        guard let out = run(script: "tell application \"\(transport.appName)\" to player state as string")
        else { return nil }
        return out.contains("playing")
    }

    /// Everything else gets brought to the front so you can deal with it yourself.
    static func focus(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    @discardableResult
    private static func run(script: String) -> String? {
        var error: NSDictionary?
        let value = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { debugLog("applescript failed: \(error)") ; return nil }
        return value?.stringValue
    }
}

/// Set AUDIONOTCH_DEBUG=1 to trace on stderr.
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AUDIONOTCH_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[audio-notch] " + message() + "\n").utf8))
}
