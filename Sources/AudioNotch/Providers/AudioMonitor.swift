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
    private var wasPlaying: Set<pid_t> = []
    private var history: [AudioEvent] = []
    private var knownDeviceUIDs: Set<String> = []
    /// Only apps we have actually heard get to linger; the rest never appear at all.
    private var everPlayed: Set<pid_t> = []
    private let queue = DispatchQueue(label: "com.abhaykashyap.audionotch.coreaudio")
    private let tapEngine = AudioTapEngine()
    private let transportProbe = TransportProbe()

    /// Drops the cached playback answer so the next snapshot re-asks immediately.
    func invalidateTransport() { transportProbe.invalidate() }

    /// Live 0...1 levels per app, empty when tapping is unavailable.
    func levels() -> [pid_t: Float] { tapEngine.levels() }
    var meteringUnavailable: Bool { tapEngine.unavailable || tapEngine.permissionLikelyMissing }
    var meterDiagnostics: String {
        "callbacks=\(tapEngine.callbackCount) bytes=\(tapEngine.bytesSeen) peak=\(tapEngine.peakSeen)"
    }
    var onChange: (() -> Void)?

    // MARK: - Snapshot

    func snapshot(now: Date = Date()) -> AudioSnapshot {
        var snap = AudioSnapshot()
        snap.sources = sources(now: now)
        snap.devices = outputDevices()
        snap.recent = history
        snap.cameraActive = CameraWatch.isActive()
        snap.meteringUnavailable = meteringUnavailable
        let device = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        snap.volume = AudioControls.volume(of: device) ?? 0
        snap.muted = AudioControls.isMuted(device)
        return snap
    }

    private func sources(now: Date) -> [AudioSource] {
        var byOwner: [String: AudioSource] = [:]
        var loose: [AudioSource] = []
        // (owner pid, audio process object) pairs to meter.
        var metered: [(pid: pid_t, object: AudioObjectID)] = []

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
            if playing { metered.append((owner.pid, process)) }

            // Log the moment something starts or stops, which is the only record of
            // "what made that noise" once the app has gone quiet again.
            let wasOn = wasPlaying.contains(pid)
            if playing && !wasOn {
                wasPlaying.insert(pid)
                record(AudioEvent(app: owner.name, kind: recording ? .startedRecording : .started, at: now))
            } else if !playing && wasOn {
                wasPlaying.remove(pid)
                record(AudioEvent(app: owner.name, kind: .stopped, at: now))
            }
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

        // Anything we can actually drive stays on the list even when silent —
        // disappearing on pause defeats the point of having transport controls.
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, Transport.forBundle(bundle) != nil,
                  byOwner[bundle] == nil, app.activationPolicy == .regular else { continue }
            byOwner[bundle] = AudioSource(id: app.processIdentifier,
                                          name: app.localizedName ?? bundle,
                                          bundleID: bundle, ownerBundleID: bundle,
                                          isPlaying: false, isRecording: false)
        }

        // Ask scriptable apps what they think they are doing; the hardware's idea of
        // "running" lingers after a pause.
        let transports = byOwner.values.compactMap(\.transport)
        transportProbe.poll(running: Array(Set(transports)))

        tapEngine.track(processes: metered)
        let levels = tapEngine.levels()
        let all = (Array(byOwner.values) + loose).map { source -> AudioSource in
            var copy = source
            copy.level = levels[source.id] ?? 0
            if let transport = source.transport { copy.transportPlaying = transportProbe.isPlaying(transport) }
            return copy
        }
        return all.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            if lhs.isRecording != rhs.isRecording { return lhs.isRecording }
            // Controllable apps outrank passive ones when both are quiet.
            if (lhs.transport != nil) != (rhs.transport != nil) { return lhs.transport != nil }
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

    /// When a device appears that was not there a moment ago, that is almost always
    /// the one you just connected.
    private func adoptNewDevice() {
        let devices = outputDevices()
        let uids = Set(devices.map(\.uid))
        defer { knownDeviceUIDs = uids }
        guard Settings.shared.followNewDevices, !knownDeviceUIDs.isEmpty else { return }
        let appeared = uids.subtracting(knownDeviceUIDs)
        guard let new = devices.first(where: { appeared.contains($0.uid) }) else { return }
        debugLog("new output device \(new.name); switching")
        AudioControls.selectOutput(new.id)
        record(AudioEvent(app: new.name, kind: .becameOutput, at: Date()))
    }

    private func record(_ event: AudioEvent) {
        history.insert(event, at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
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
        observePlaybackBroadcasts()
        observe(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refreshProcessListeners()
            self?.onChange?()
        }
        observe(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.onChange?() }
        observe(CA.system, kAudioHardwarePropertyDevices) { [weak self] in
            self?.adoptNewDevice()
            self?.onChange?()
        }
        knownDeviceUIDs = Set(outputDevices().map(\.uid))
        refreshProcessListeners()
    }

    /// Media apps broadcast their own state changes, which is how the panel keeps up
    /// with the keyboard's play/pause key. Polling could never be both fast and cheap.
    private func observePlaybackBroadcasts() {
        let center = DistributedNotificationCenter.default()
        let feeds: [(name: String, transport: Transport)] = [
            ("com.spotify.client.PlaybackStateChanged", .spotify),
            ("com.apple.iTunes.playerInfo", .music),
        ]
        for feed in feeds {
            center.addObserver(forName: Notification.Name(feed.name), object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let state = (note.userInfo?["Player State"] as? String)?.lowercased()
                if let state { self.transportProbe.set(feed.transport, playing: state == "playing") }
                debugLog("broadcast: \(feed.transport.appName) \(state ?? "?")")
                self.onChange?()
            }
        }
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
