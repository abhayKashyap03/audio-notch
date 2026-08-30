import AppKit
import CoreAudio
import AudioToolbox

/// Watches which applications are using the audio hardware.
///
/// macOS 14.4 made the per-process audio objects public, so "who is making sound"
/// is a real query rather than a guess. CoreAudio also pushes changes, so the panel
/// updates the instant something starts or stops instead of polling for it.
final class AudioMonitor: @unchecked Sendable {
    /// Apps stay listed briefly after they go quiet — otherwise rows flicker away
    /// during the gap between tracks.
    private static let lingerAfterQuiet: TimeInterval = 12

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var quietSince: [pid_t: Date] = [:]
    /// Only apps we have actually heard get to linger; the rest never appear at all.
    private var everPlayed: Set<pid_t> = []
    private let queue = DispatchQueue(label: "com.abhaykashyap.audionotch.coreaudio")
    var onChange: (() -> Void)?

    // MARK: - Snapshot

    func snapshot(now: Date = Date()) -> AudioSnapshot {
        var snap = AudioSnapshot()
        snap.sources = sources(now: now)
        snap.devices = outputDevices()
        let device = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        snap.volume = AudioControls.volume(of: device) ?? 0
        snap.muted = AudioControls.isMuted(device)
        return snap
    }

    private func sources(now: Date) -> [AudioSource] {
        var byOwner: [String: AudioSource] = [:]
        var loose: [AudioSource] = []

        for process in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = CA.value(process, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { continue }
            let bundle = CA.string(process, kAudioProcessPropertyBundleID)
            let playing = CA.value(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            let recording = CA.value(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0

            // Track when something fell silent so it can linger, then disappear.
            // Apps merely *capable* of audio are legion — most of the list is idle
            // helpers — so nothing appears until it has actually made a sound.
            if playing || recording {
                everPlayed.insert(pid)
                quietSince[pid] = nil
            } else if everPlayed.contains(pid), quietSince[pid] == nil {
                quietSince[pid] = now
            }
            let quiet = quietSince[pid]
            if !playing && !recording {
                guard everPlayed.contains(pid), let quiet,
                      now.timeIntervalSince(quiet) < Self.lingerAfterQuiet else { continue }
            }

            guard let owner = resolveOwner(pid: pid, bundle: bundle) else { continue }
            let source = AudioSource(id: owner.pid, name: owner.name, bundleID: bundle,
                                     ownerBundleID: owner.bundle, isPlaying: playing,
                                     isRecording: recording, wentQuietAt: quiet)

            // Browsers and Electron apps show up as several helpers; merge them so the
            // panel says "Arc", not three anonymous renderer processes.
            if let key = owner.bundle {
                if var existing = byOwner[key] {
                    existing.isPlaying = existing.isPlaying || playing
                    existing.isRecording = existing.isRecording || recording
                    byOwner[key] = existing
                } else {
                    byOwner[key] = source
                }
            } else {
                loose.append(source)
            }
        }

        let all = Array(byOwner.values) + loose
        return all.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            if lhs.isRecording != rhs.isRecording { return lhs.isRecording }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Maps an audio process to the app a person would recognise, walking up from
    /// helper processes and skipping system daemons nobody can act on.
    private func resolveOwner(pid: pid_t, bundle: String?) -> (pid: pid_t, name: String, bundle: String?)? {
        // `.regular` means it has a Dock icon: something the user recognises and can
        // switch to. Helpers and daemons are walked up to their parent instead.
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName,
           app.activationPolicy == .regular {
            return (pid, name, app.bundleIdentifier ?? bundle)
        }
        // Helpers are not NSRunningApplications; their parent usually is.
        var walker = pid
        for _ in 0..<4 {
            guard let parent = CA.parentPID(of: walker), parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent), let name = app.localizedName,
               app.activationPolicy == .regular {
                return (parent, name, app.bundleIdentifier)
            }
            walker = parent
        }
        // Fall back to matching the helper's bundle id against a running app.
        if let bundle, let app = NSWorkspace.shared.runningApplications.first(where: {
            guard let id = $0.bundleIdentifier else { return false }
            return bundle.lowercased().hasPrefix(id.lowercased()) && $0.activationPolicy == .regular
        }), let name = app.localizedName {
            return (app.processIdentifier, name, app.bundleIdentifier)
        }
        return nil    // a system daemon: not something the user can act on
    }

    private func outputDevices() -> [OutputDevice] {
        let current = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        return CA.objects(CA.system, kAudioHardwarePropertyDevices).compactMap { device in
            guard CA.outputChannels(device) > 0, let name = CA.string(device, kAudioObjectPropertyName) else { return nil }
            return OutputDevice(id: device, name: name,
                                uid: CA.string(device, kAudioDevicePropertyDeviceUID) ?? "\(device)",
                                isDefault: device == current)
        }
    }

    // MARK: - Live updates

    /// CoreAudio notifies us on change, which is what keeps the pill in sync with a
    /// track starting rather than up to a poll interval behind it.
    func start() {
        observe(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refreshProcessListeners()
            self?.onChange?()
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            observe(CA.system, selector) { [weak self] in self?.onChange?() }
        }
        refreshProcessListeners()
    }

    private func refreshProcessListeners() {
        // Drop the per-process listeners and re-add for the current set.
        let systemSelectors: Set<AudioObjectPropertySelector> = [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ]
        for (object, address, block) in listeners where !systemSelectors.contains(address.mSelector) {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        }
        listeners.removeAll { !systemSelectors.contains($0.1.mSelector) }

        for process in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            for selector in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput] {
                observe(process, selector) { [weak self] in self?.onChange?() }
            }
        }
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = CA.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        listeners.append((object, address, block))
    }
}
