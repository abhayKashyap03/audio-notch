import AppKit

/// Tracks what scriptable media apps say about themselves.
///
/// CoreAudio reports whether a process is *producing output*, which is not the same
/// question as "is it playing": Spotify holds its stream open for a while after you
/// pause, so the hardware still sees it as running. For apps that can be asked
/// directly, ask them — otherwise the button offers to pause something already paused.
///
/// The query is an Apple event, so it runs on a background queue and the UI only ever
/// reads a cached answer.
final class TransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Transport: Bool] = [:]
    private var lastPoll = Date.distantPast
    private let queue = DispatchQueue(label: "com.abhaykashyap.audionotch.transport", qos: .utility)
    private var polling = false

    private static let interval: TimeInterval = 1

    /// Last known playback state, or nil when the app cannot be asked.
    func isPlaying(_ transport: Transport) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return states[transport]
    }

    /// Forces the next poll to run, used right after we change playback ourselves.
    func invalidate() {
        lock.lock(); lastPoll = .distantPast; lock.unlock()
    }

    /// Refreshes in the background if the cache is stale. Never blocks the caller.
    func poll(running: [Transport], now: Date = Date()) {
        lock.lock()
        let due = !polling && now.timeIntervalSince(lastPoll) > Self.interval && !running.isEmpty
        if due { polling = true }
        lock.unlock()
        guard due else { return }

        queue.async { [weak self] in
            guard let self else { return }
            var fresh: [Transport: Bool] = [:]
            for transport in running {
                if let playing = AudioControls.isPlaying(transport) { fresh[transport] = playing }
            }
            self.lock.lock()
            self.states = fresh
            self.lastPoll = Date()
            self.polling = false
            self.lock.unlock()
        }
    }
}
