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
    ///
    /// Returns false when macOS refuses the Apple event — the app needs Automation
    /// permission for that target, which the caller surfaces rather than swallowing.
    @discardableResult
    static func togglePlayback(_ transport: Transport) -> Bool {
        // `playpause` returns nothing, so a nil result means "no value", not
        // "failed". Only an actual error justifies the fallback — otherwise the key
        // press lands as a second toggle and playback resumes immediately.
        if execute("tell application \"\(transport.appName)\" to playpause").ok { return true }
        // Fall back to the media key: no permission needed, but it only reaches
        // whichever app currently owns Now Playing.
        return pressPlayPauseKey()
    }

    /// Synthesises the keyboard's play/pause key.
    @discardableResult
    static func pressPlayPauseKey() -> Bool {
        let playKey: Int = 16   // NX_KEYTYPE_PLAY
        for isDown in [true, false] {
            let data1 = (playKey << 16) | ((isDown ? 0x0A : 0x0B) << 8)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: data1, data2: -1),
                  let cg = event.cgEvent else { return false }
            cg.post(tap: .cghidEventTap)
        }
        return true
    }

    static func isPlaying(_ transport: Transport) -> Bool? {
        let result = execute("tell application \"\(transport.appName)\" to player state as string")
        guard result.ok, let value = result.value else { return nil }
        return value.contains("playing")
    }

    /// Playback state and the current track in a single Apple event, since asking
    /// twice doubles the cost of something polled every second.
    static func nowPlaying(_ transport: Transport) -> (playing: Bool, track: TrackInfo?)? {
        let script = """
        tell application "\(transport.appName)"
            set s to player state as string
            if s is "playing" or s is "paused" then
                set t to current track
                return s & "\t" & (name of t) & "\t" & (artist of t) & "\t" & (artwork url of t)
            end if
            return s
        end tell
        """
        let result = execute(script)
        guard result.ok, let value = result.value else { return nil }
        let parts = value.components(separatedBy: "\t")
        let playing = parts.first?.contains("playing") ?? false
        guard parts.count >= 3 else { return (playing, nil) }
        let track = TrackInfo(title: parts[1], artist: parts[2],
                              artworkURL: parts.count > 3 ? parts[3] : nil)
        return (playing, track.title.isEmpty ? nil : track)
    }

    /// Everything else gets brought to the front so you can deal with it yourself.
    static func focus(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    /// True once macOS has refused an Apple event, so the UI can explain itself once.
    private(set) static var automationDenied = false

    /// Success is reported separately from the returned value: commands like
    /// `playpause` succeed while returning nothing at all.
    @discardableResult
    private static func execute(_ source: String) -> (ok: Bool, value: String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised": the user must allow this app under
            // Privacy & Security > Automation.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { automationDenied = true }
            debugLog("applescript failed: \(error)")
            return (false, nil)
        }
        return (true, descriptor.stringValue)
    }
}

/// Set AUDIONOTCH_DEBUG=1 to trace on stderr.
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AUDIONOTCH_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[audio-notch] " + message() + "\n").utf8))
}
