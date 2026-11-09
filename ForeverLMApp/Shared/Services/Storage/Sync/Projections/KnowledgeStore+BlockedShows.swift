import Foundation
import OSLog

// MARK: - The import-blocked shows under generation 2 (docs/cloudkit-schema-design.md §3.5.19, §10)

extension KnowledgeStore {
    /// The shows whose episodes are never imported, as `blocked_podcast_shows` holds them.
    func blockedPodcastShowNames() throws -> [String] {
        var names: [String] = []
        try query("SELECT show_name FROM blocked_podcast_shows ORDER BY show_name COLLATE NOCASE", []) { row in
            if let name = row.text(0) { names.append(name) }
        }
        return names
    }

    /// Makes `blocked_podcast_shows` hold exactly `names` (matched as the importer matches them,
    /// `SourceDiscovery.podcastShowKey`): a show newly blocked is a row, a show unblocked loses its row,
    /// and a show still blocked keeps its row and its time. Generation 2 only.
    func setBlockedPodcastShows(_ names: [String], at date: Date = Date()) throws {
        try inDerivationTransaction { store in
            let held = try store.blockedPodcastShowNames()
            let wanted = Dictionary(names.map { (SourceDiscovery.podcastShowKey($0), $0) }, uniquingKeysWith: { first, _ in first })
            let heldKeys = Set(held.map(SourceDiscovery.podcastShowKey))
            for name in held where wanted[SourceDiscovery.podcastShowKey(name)] == nil {
                try store.execute("DELETE FROM blocked_podcast_shows WHERE show_name = ?", [.text(name)])
            }
            for (key, name) in wanted where !key.isEmpty && !heldKeys.contains(key) {
                try store.execute("""
                    INSERT INTO blocked_podcast_shows (show_name, blocked_at) VALUES (?, ?)
                    ON CONFLICT(show_name) DO UPDATE SET blocked_at = excluded.blocked_at
                """, [.text(name), .real(date.timeIntervalSinceReferenceDate)])
            }
        }
    }
}

/// Generation 2's keeper of the import-blocked shows: the list stays in this Mac's `UserDefaults`
/// (`SourceDiscovery.blockedPodcastShowNames`, read synchronously by the importer), and each change is
/// written to `blocked_podcast_shows`, the table of `Mark(importBlocked)`, off the main actor and in call
/// order. `reload()` takes the table back into `UserDefaults` after an inbound Mark (WP16 calls it after
/// an apply).
enum BlockedShowsSync {
    private static let storage = StorageService()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tail: Task<Void, Never>?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "BlockedShowsSync")

    static func mirror(_ names: Set<String>) {
        let list = names.sorted()
        enqueue { try $0.setBlockedPodcastShows(list) }
    }

    static func reload() {
        enqueue { store in
            let names = try store.blockedPodcastShowNames()
            let defaults = UserDefaults.standard
            let key = SourceDiscovery.blockedPodcastShowsPreferenceKey
            guard Set(defaults.stringArray(forKey: key) ?? []) != Set(names) else { return }
            if names.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(names, forKey: key) }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PreferenceStore.didChangeRemotely, object: nil, userInfo: [PreferenceStore.changedKeysKey: Set([key])])
            }
        }
    }

    private static func enqueue(_ work: @escaping @Sendable (KnowledgeStore) throws -> Void) {
        lock.lock()
        let predecessor = tail
        tail = Task.detached(priority: .utility) {
            await predecessor?.value
            do {
                try await storage.performSync(work)
            } catch {
                logger.error("Could not keep the import-blocked shows: \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.unlock()
    }
}
