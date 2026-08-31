import AppKit

/// What a media app is playing right now.
struct TrackInfo: Equatable {
    var title: String
    var artist: String
    var artworkURL: String?

    var oneLine: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

/// Fetches track details and album art for the apps that expose them.
///
/// Spotify hands over the name, artist and an artwork URL in one Apple event, so a
/// single call per poll covers everything. Artwork is downloaded once per URL and
/// kept in memory — album art changes far less often than anything else on screen.
final class NowPlaying: @unchecked Sendable {
    private let lock = NSLock()
    private var artwork: [String: NSImage] = [:]
    private var pending: Set<String> = []

    /// Cached album art, kicking off a download the first time a URL is seen.
    func image(for url: String?) -> NSImage? {
        guard let url, !url.isEmpty else { return nil }
        lock.lock()
        if let cached = artwork[url] { lock.unlock(); return cached }
        let alreadyFetching = pending.contains(url)
        if !alreadyFetching { pending.insert(url) }
        lock.unlock()
        guard !alreadyFetching else { return nil }

        URLSession.shared.dataTask(with: URL(string: url)!) { [weak self] data, _, _ in
            guard let self else { return }
            let image = data.flatMap(NSImage.init(data:))
            self.lock.lock()
            if let image { self.artwork[url] = image }
            self.pending.remove(url)
            // Album art is small, but a long session should not accumulate forever.
            if self.artwork.count > 40 { self.artwork.removeAll() }
            self.lock.unlock()
        }.resume()
        return nil
    }
}
