extension URLNormalizer {
    /// URL normalization v1 as the Mac computes it: a local file path normalizes against this
    /// Mac's content roots (`StorageService.relativeSourcePath`), so the same file on two Macs
    /// keeps one key. Every source id the Mac mints goes through here (`SourceIdentity`,
    /// `TeamContentIdentity`, the `url:` work key).
    ///
    /// Answers are remembered for the life of the process. The rules are frozen and the content
    /// roots are fixed at launch, so a URL always gets the same key; what changes is only how often
    /// it is asked. The main actor asks for the whole library at once (the liked-videos and
    /// playlist refreshes collect every source's key on each pass), and working each one out again,
    /// with path splitting and pattern matches for the local files, cost 150 ms of main thread per
    /// pass on build 292 and over a second under load. A remembered key is one dictionary read.
    static func normalize(_ urlString: String) -> String {
        if let key = MacNormalizedKeys.shared.key(for: urlString) { return key }
        let key = normalize(urlString, localPath: StorageService.relativeSourcePath)
        MacNormalizedKeys.shared.remember(key, for: urlString)
        return key
    }
}

/// The keys `URLNormalizer.normalize(_:)` has worked out in this process. Bounded: a library holds a
/// few thousand sources, and feeds and searches pass many more URLs through once, so when it is full
/// it starts over rather than growing without end. Very long strings are not kept.
final class MacNormalizedKeys: @unchecked Sendable {
    static let shared = MacNormalizedKeys()

    static let capacity = 20_000
    static let longestKeptInput = 2_048

    private let lock = AppLock()
    private var keys: [String: String] = [:]

    func key(for urlString: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[urlString]
    }

    func remember(_ key: String, for urlString: String) {
        guard urlString.utf8.count <= Self.longestKeptInput else { return }
        lock.lock()
        defer { lock.unlock() }
        if keys.count >= Self.capacity {
            keys.removeAll(keepingCapacity: true)
        }
        keys[urlString] = key
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.count
    }
}

extension WorkKey {
    /// A work key as the Mac computes it: a `url:` key naming a local file normalizes against this
    /// Mac's content roots, as `URLNormalizer.normalize(_:)` does. Clients without local files call
    /// `normalizeRemote(_:)`.
    static func normalize(_ key: String) -> String? {
        normalize(key, localPath: StorageService.relativeSourcePath)
    }
}
