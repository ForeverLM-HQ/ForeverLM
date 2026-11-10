// MARK: - Schema 163, the personal records: Device and the import-blocked shows (§12.7)

extension KnowledgeStore {
    /// The tables schema 163 adds for the Device record and the `importBlocked` Mark (docs/cloudkit-schema-design.md
    /// §3.5.2, §3.5.19), created empty: DDL only, like every step from 154 on. Generation 1 never reads or
    /// writes them (its `connectorHealth.*` and `podcasts.blockedShows` preference rows stay its truth); the
    /// generation-2 activation fills them from those rows, and from then on the Device and Mark projections
    /// and the generation-2 writers keep them.
    static let personalStateSyncTables: [ReplicaSchemaTable] = [
        // One row per Device record (§3.5.2): this Mac's own, which only this Mac writes, and every other
        // device's as its record arrives. `roles_json` is the set as a sorted JSON array,
        // `connector_health_json` the map `{connector: {state, lastSeenAt, lastSuccessfulSyncAt}}` (ms).
        // Times are Cocoa seconds; `last_seen_day` a `YYYY-MM-DD` day.
        ReplicaSchemaTable("devices", [
            ("device_id", "TEXT PRIMARY KEY"),
            ("platform", "TEXT"),
            ("app_version", "TEXT"),
            ("app_build", "TEXT"),
            ("schema_revision", "INTEGER"),
            ("display_name", "TEXT"),
            ("first_seen_at", "REAL"),
            ("last_seen_day", "TEXT"),
            ("roles_json", "TEXT"),
            ("connector_health_json", "TEXT"),
        ]),
        // The podcast shows whose episodes are never imported, one row per `Mark(importBlocked, col:)`
        // the learner holds on, keyed by the show's name as the importer compares it (NOCASE, like
        // `hidden_youtube_channels`). Generation 1 keeps the list in the `podcasts.blockedShows` row.
        ReplicaSchemaTable("blocked_podcast_shows", [
            ("show_name", "TEXT PRIMARY KEY COLLATE NOCASE"),
            ("blocked_at", "REAL NOT NULL"),
        ]),
    ]

    /// Creates schema 163's personal tables where missing: empty, DDL only.
    func createPersonalStateSyncTables() throws {
        for table in Self.personalStateSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

}
