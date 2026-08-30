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

    var icon: NSImage? {
        guard let bundle = ownerBundleID ?? bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else { return NSRunningApplication(processIdentifier: id)?.icon }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Apps we can actually drive, rather than only focus.
    var transport: Transport? { Transport.forBundle(ownerBundleID ?? bundleID ?? "") }

    static func == (a: AudioSource, b: AudioSource) -> Bool {
        a.id == b.id && a.isPlaying == b.isPlaying && a.isRecording == b.isRecording && a.name == b.name
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
struct AudioSnapshot: Equatable {
    var sources: [AudioSource] = []
    var devices: [OutputDevice] = []
    var volume: Float = 0
    var muted: Bool = false

    var playing: [AudioSource] { sources.filter(\.isPlaying) }
    var recording: [AudioSource] { sources.filter(\.isRecording) }
    var anyPlaying: Bool { !playing.isEmpty }
    var currentDevice: OutputDevice? { devices.first(where: \.isDefault) }
}
