import AudioToolbox
import CoreAudio
import Foundation

/// Real per-application levels, using the process taps macOS 14.4 made public.
///
/// One tap per playing process, all gathered into a single private aggregate device
/// whose IO block hands us the audio each app is producing. We only ever compute an
/// RMS from it: nothing is recorded, buffered, or written anywhere.
///
/// Taps need the user's audio-capture consent. If that is refused — or the API fails
/// for any other reason — `levels` simply stays empty and the UI falls back to
/// showing playing/idle without a meter.
final class AudioTapEngine: @unchecked Sendable {
    private struct Tap {
        var pid: pid_t
        var tapID: AudioObjectID
        var uid: String
    }

    private let lock = NSLock()
    private var taps: [Tap] = []
    private var aggregate: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var meters: [pid_t: Float] = [:]
    private var trackedPIDs: Set<pid_t> = []
    private let queue = DispatchQueue(label: "com.abhaykashyap.audionotch.taps", qos: .userInitiated)

    /// Set once a tap attempt has failed, so the UI can stop pretending it has meters.
    private(set) var unavailable = false
    /// macOS hands out silent buffers until the user allows audio recording, so a
    /// long run of callbacks carrying nothing but zeroes means "not permitted"
    /// rather than "nothing is playing".
    var permissionLikelyMissing: Bool { callbackCount > 200 && peakSeen == 0 }

    /// Smoothed 0...1 level per process id.
    func levels() -> [pid_t: Float] {
        lock.lock(); defer { lock.unlock() }
        return meters
    }

    /// Rebuilds the tap set when the playing processes change.
    func track(processes: [(pid: pid_t, object: AudioObjectID)]) {
        let wanted = Set(processes.map(\.pid))
        lock.lock()
        let changed = wanted != trackedPIDs
        lock.unlock()
        guard changed else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.lock.lock(); self.trackedPIDs = wanted; self.lock.unlock()
            guard !processes.isEmpty else { return }
            self.build(processes)
        }
    }

    func stop() {
        queue.async { [weak self] in self?.teardown() }
    }

    // MARK: - Building

    private func build(_ processes: [(pid: pid_t, object: AudioObjectID)]) {
        var created: [Tap] = []
        for process in processes {
            let description = CATapDescription(stereoMixdownOfProcesses: [process.object])
            description.name = "AudioNotch \(process.pid)"
            description.isPrivate = true
            description.muteBehavior = .unmuted        // never change what the user hears
            var tapID = AudioObjectID(0)
            guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else {
                unavailable = true
                continue
            }
            created.append(Tap(pid: process.pid, tapID: tapID, uid: description.uuid.uuidString))
        }
        guard !created.isEmpty else { return }

        // A private aggregate device is the only way to receive tap audio.
        let outputUID = CA.string(AudioControls.defaultOutputDevice, kAudioDevicePropertyDeviceUID) ?? ""
        let aggregateUID = "com.abhaykashyap.audionotch.meter." + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Notch Meter",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: created.map {
                [kAudioSubTapUIDKey: $0.uid, kAudioSubTapDriftCompensationKey: true]
            },
        ]

        var device = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr, device != 0 else {
            unavailable = true
            created.forEach { AudioHardwareDestroyProcessTap($0.tapID) }
            return
        }

        let order = created.map(\.pid)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.measure(input, order: order)
        }
        guard status == noErr, let proc else {
            unavailable = true
            AudioHardwareDestroyAggregateDevice(device)
            created.forEach { AudioHardwareDestroyProcessTap($0.tapID) }
            return
        }

        guard AudioDeviceStart(device, proc) == noErr else {
            unavailable = true
            AudioDeviceDestroyIOProcID(device, proc)
            AudioHardwareDestroyAggregateDevice(device)
            created.forEach { AudioHardwareDestroyProcessTap($0.tapID) }
            return
        }

        lock.lock()
        taps = created
        aggregate = device
        procID = proc
        lock.unlock()
    }

    /// Buffers arrive in tap-list order, so buffer N belongs to process N.
    private(set) var callbackCount = 0
    private(set) var bytesSeen = 0
    private(set) var peakSeen: Float = 0

    private func measure(_ input: UnsafePointer<AudioBufferList>, order: [pid_t]) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbackCount += 1
        bytesSeen += buffers.reduce(0) { $0 + Int($1.mDataByteSize) }
        var fresh: [pid_t: Float] = [:]
        for (slot, buffer) in buffers.enumerated() where slot < order.count {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            var read = 0
            // Every fourth sample is plenty for a meter and keeps this cheap.
            while read < count {
                let value = samples[read]
                sum += value * value
                read += 4
            }
            let rms = (sum / Float(max(count / 4, 1))).squareRoot()
            peakSeen = max(peakSeen, rms)
            // Raw RMS spends most of its life near zero, so lift it for display.
            // Several taps can belong to one app (browser helpers); loudest wins.
            fresh[order[slot]] = max(fresh[order[slot]] ?? 0, min(rms * 3.2, 1))
        }

        lock.lock()
        for (pid, value) in fresh {
            let previous = meters[pid] ?? 0
            // Fast attack, slow release, so the bars look like a meter, not a strobe.
            meters[pid] = value > previous ? value : previous * 0.82 + value * 0.18
        }
        for pid in meters.keys where fresh[pid] == nil {
            meters[pid] = (meters[pid] ?? 0) * 0.7
        }
        lock.unlock()
    }

    private func teardown() {
        lock.lock()
        let device = aggregate, proc = procID, existing = taps
        aggregate = 0; procID = nil; taps = []; meters = [:]
        lock.unlock()

        if device != 0, let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
        existing.forEach { AudioHardwareDestroyProcessTap($0.tapID) }
    }

    deinit { teardown() }
}
