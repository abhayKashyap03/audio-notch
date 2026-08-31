import AppKit
import SwiftUI

/// An application that CoreAudio says is using the audio hardware.
struct AudioSource: Identifiable, Equatable {
    var id: pid_t
    var name: String
    var bundleID: String?
    /// The app the user thinks of — helper processes are folded into their parent.
    var ownerBundleID: String?
    var isPlaying: Bool
    var isRecording: Bool
    /// Set while the app has stopped but is worth keeping on screen briefly.
    var wentQuietAt: Date?
    /// Live output level, 0...1, when process tapping is available.
    var level: Float = 0
    /// What a scriptable app says about itself, which beats the hardware's view.
    var transportPlaying: Bool?
    /// The track a media app is playing, when it will say.
    var track: TrackInfo?

    var icon: NSImage? {
        guard let bundle = ownerBundleID ?? bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else { return NSRunningApplication(processIdentifier: id)?.icon }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Apps we can actually drive, rather than only focus.
    var transport: Transport? { Transport.forBundle(ownerBundleID ?? bundleID ?? "") }

    /// True when the app is really playing, preferring its own answer over the
    /// hardware's, which stays "running" for a while after a pause.
    var reallyPlaying: Bool { transportPlaying ?? isPlaying }

    /// What clicking the row will do, so the chip never lies.
    var actionLabel: String {
        guard transport != nil else { return "focus" }
        return reallyPlaying ? "pause" : "play"
    }

    static func == (a: AudioSource, b: AudioSource) -> Bool {
        a.id == b.id && a.isPlaying == b.isPlaying && a.isRecording == b.isRecording
            && a.name == b.name && a.transportPlaying == b.transportPlaying
            && a.track == b.track && abs(a.level - b.level) < 0.02
    }
}

/// Apps with a scripting interface for play/pause. macOS has no general per-app
/// transport control, so this is an explicit list rather than a guess.
enum Transport: String {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"
    case podcasts = "com.apple.podcasts"
    case tv = "com.apple.TV"

    static func forBundle(_ bundle: String) -> Transport? {
        Transport(rawValue: bundle) ?? (bundle.hasPrefix("com.spotify.") ? .spotify : nil)
    }

    var appName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        case .podcasts: return "Podcasts"
        case .tv: return "TV"
        }
    }
}

struct OutputDevice: Identifiable, Equatable {
    var id: UInt32
    var name: String
    var uid: String
    var isDefault: Bool

    /// Rough guess at the right symbol, from the device name.
    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpod") { return "airpodspro" }
        if n.contains("headphone") || n.contains("beats") { return "headphones" }
        if n.contains("display") || n.contains("monitor") || n.contains("tv") { return "display" }
        if n.contains("speaker") || n.contains("macbook") || n.contains("imac") { return "laptopcomputer" }
        return "hifispeaker"
    }
}

/// Everything the panel draws.
/// Something an app did with the audio hardware, kept so you can answer "what was
/// that sound?" after the app has already gone quiet.
struct AudioEvent: Identifiable, Equatable {
    enum Kind: String {
        case started, stopped, startedRecording, becameOutput

        var verb: String {
            switch self {
            case .started: return "started"
            case .stopped: return "stopped"
            case .startedRecording: return "opened the mic"
            case .becameOutput: return "became the output"
            }
        }
    }

    var id: String { "\(app)-\(kind.rawValue)-\(at.timeIntervalSince1970)" }
    var app: String
    var kind: Kind
    var at: Date

    func ago(from now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(at))
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

struct AudioSnapshot: Equatable {
    var sources: [AudioSource] = []
    var devices: [OutputDevice] = []
    var recent: [AudioEvent] = []
    var volume: Float = 0
    var muted: Bool = false
    /// True when the camera is on, whoever is using it.
    var cameraActive = false
    /// True when levels cannot be read (no audio-recording permission).
    var meteringUnavailable = false

    var playing: [AudioSource] { sources.filter(\.isPlaying) }
    var recording: [AudioSource] { sources.filter(\.isRecording) }
    var anyPlaying: Bool { !playing.isEmpty }
    var currentDevice: OutputDevice? { devices.first(where: \.isDefault) }
}
