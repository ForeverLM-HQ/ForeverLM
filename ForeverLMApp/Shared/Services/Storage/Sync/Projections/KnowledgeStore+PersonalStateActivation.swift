import Foundation

// MARK: - The activation's derivations for the personal records (§13.3 step 3c)

extension KnowledgeStore {
    /// The derivations for the personal records: the member's highlights and Schedule placements on
    /// their sources' wire ids, the hides still waiting for their source as hides, the import-blocked
    /// shows from their preference row, and this Mac's Device row. Each is idempotent, bounded by the
    /// library, in its own transaction, and reads generation-1 truth only, so a run after generation-1
    /// edits reflects them. Marks need nothing more: they project from the tables generation 1 keeps
    /// (a like, a follow and a discovery origin from their columns), so every one is there to send.
    static let personalStateActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "personalStateWireKeys") { store in try store.inDerivationTransaction { try $0.rekeyPersonalStateRows() } },
        ActivationDerivation(id: "blockedPodcastShows") { store in try store.inDerivationTransaction { try $0.deriveBlockedPodcastShows() } },
        ActivationDerivation(id: "thisDevice") { store in try store.inDerivationTransaction { _ = try $0.ensureThisDeviceRow() } },
    ]

    /// Team copies' highlights and placements re-keyed to the personal copy's wire id (§12.7 v160), every
    /// placement keyed by its record id `pl:<wire id>` (two that meet on one id keep the one placed first,
    /// with both's goals), and a hide waiting for its source (`pending_hidden_sources`) made a hide: a
    /// Mark needs no source (§10).
    func rekeyPersonalStateRows() throws {
        try execute("""
            UPDATE source_highlights SET source_id = (SELECT wire_id FROM sources WHERE id = source_highlights.source_id)
            WHERE source_id IN (SELECT id FROM sources WHERE wire_id IS NOT NULL AND wire_id <> id)
        """, [])

        struct Placement { let id: String; let sourceID: String; let wireKey: String; let addedAt: Double }
        var placements: [Placement] = []
        try query("""
            SELECT ss.id, ss.source_id, COALESCE(s.wire_key, ss.source_id), ss.added_at
            FROM scheduled_sources ss LEFT JOIN sources s ON s.id = ss.source_id
            ORDER BY ss.added_at, ss.id
        """, []) { row in
            if let id = row.text(0), let source = row.text(1) {
                placements.append(Placement(id: id, sourceID: source, wireKey: row.text(2) ?? source, addedAt: row.real(3) ?? 0))
            }
        }
        for (wireKey, group) in Dictionary(grouping: placements, by: \.wireKey).sorted(by: { $0.key < $1.key }) {
            let recordID = SyncIdentity.placementID(sourceID: wireKey)
            let survivor = group.first { $0.id == recordID } ?? group[0]
            for loser in group where loser.id != survivor.id {
                try execute("""
                    INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
                    SELECT ?, goal_id, added_at FROM scheduled_source_goals WHERE scheduled_source_id = ?
                    ON CONFLICT(scheduled_source_id, goal_id) DO NOTHING
                """, [.text(survivor.id), .text(loser.id)])
                try execute("UPDATE source_activity_days SET scheduled_source_id = ? WHERE scheduled_source_id = ?", [.text(survivor.id), .text(loser.id)])
                try execute("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?", [.text(loser.id)])
                try execute("DELETE FROM scheduled_sources WHERE id = ?", [.text(loser.id)])
            }
            if survivor.sourceID != wireKey {
                try execute("UPDATE scheduled_sources SET source_id = ? WHERE id = ?", [.text(wireKey), .text(survivor.id)])
            }
            if survivor.id != recordID {
                try Self.rekeyPlacement(from: survivor.id, to: recordID, connection: self)
            }
        }

        try execute("""
            INSERT INTO hidden_sources (source_id, hidden_at)
            SELECT source_id, hidden_at FROM pending_hidden_sources WHERE true
            ON CONFLICT(source_id) DO UPDATE SET hidden_at = MAX(hidden_sources.hidden_at, excluded.hidden_at)
        """, [])
        try execute("DELETE FROM pending_hidden_sources", [])
    }

    /// The import-blocked shows from generation 1's `podcasts.blockedShows` row (§10): exactly the shows
    /// it lists, each blocked at the row's time; none when there is no row.
    func deriveBlockedPodcastShows() throws {
        var names: [String] = []
        var at = Date().timeIntervalSinceReferenceDate
        try query("SELECT value, updated_at FROM user_preferences WHERE key = ?", [.text(SourceDiscovery.blockedPodcastShowsPreferenceKey)]) { row in
            names = (row.text(0).flatMap(PreferenceStore.decodePlist) as? [String]) ?? []
            at = row.real(1) ?? at
        }
        let wanted = Dictionary(names.map { (SourceDiscovery.podcastShowKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        for held in try blockedPodcastShowNames() where wanted[SourceDiscovery.podcastShowKey(held)] == nil {
            try execute("DELETE FROM blocked_podcast_shows WHERE show_name = ?", [.text(held)])
        }
        for (key, name) in wanted.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            try execute("""
                INSERT INTO blocked_podcast_shows (show_name, blocked_at) VALUES (?, ?)
                ON CONFLICT(show_name) DO UPDATE SET blocked_at = excluded.blocked_at
            """, [.text(name), .real(at)])
        }
    }
}
