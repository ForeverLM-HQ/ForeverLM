import Foundation
import SQLite3

// MARK: - The replica on this store's connection (D32, §6.6 step 3)

extension KnowledgeStore: SQLiteConnection {
    func executeScript(_ sql: String) throws {
        try exec(sql)
    }

    func execute(_ sql: String, _ parameters: [SQLiteValue]) throws {
        try SQLiteStatements.run(db, sql, parameters)
    }

    func query(_ sql: String, _ parameters: [SQLiteValue], _ row: (SQLiteRow) throws -> Void) throws {
        try SQLiteStatements.run(db, sql, parameters, row)
    }

    var changedRowCount: Int { Int(sqlite3_changes(db)) }

    /// What a committed apply wrote goes to the owner's handler; a rolled-back one's is forgotten.
    func replicaApplyDidEnd(committed: Bool) {
        let changes = appliedRemoteChanges
        appliedRemoteChanges = AppliedRemoteChanges()
        guard committed, !changes.isEmpty else { return }
        appliedRemoteChangesHandler?(changes)
    }
}

extension KnowledgeStore {
    /// The replica of the server's records, on this store's own connection: an apply runs inside the
    /// storage actor's transaction on it and never on a handle of its own (§6.6 step 3).
    var replica: ReplicaStore { ReplicaStore(connection: self) }

    // MARK: - Schema 154: the replica tables (§12.7)

    /// The `ck_*` tables only the Mac holds; `ReplicaStore.sharedTables` are the iPhone's too. Times
    /// are Cocoa reference seconds and stamps the 27-character stamps of §3.2. Schema 154 creates them
    /// empty, and nothing fills them, or installs a trigger that would, before a store's
    /// generation-2 activation (§13.3 step 3).
    static let macReplicaTables: [ReplicaSchemaTable] = [
        // The diff-based outbox the generated triggers write (§6.6 step 1): one row per changed local
        // row, with the key columns that route it to its record even after the row is gone.
        ReplicaSchemaTable("ck_outbox", [
            ("source_table", "TEXT NOT NULL"),
            ("local_key", "TEXT NOT NULL"),
            ("record_key_json", "TEXT NOT NULL"),
            ("op", "TEXT NOT NULL"),
            ("dirty_at", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (source_table, local_key)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_outbox_dirty ON ck_outbox(dirty_at)",
        ]),
        // Each column's own change time (`__row` for an insert or delete), the stamp minted for it
        // once and pinned until sent, and the stamp it was minted against (`seen`, which the merge
        // takes as the change's provenance, `FieldMerge.merge(mintedAgainst:)`).
        ReplicaSchemaTable("ck_outbox_fields", [
            ("source_table", "TEXT NOT NULL"),
            ("local_key", "TEXT NOT NULL"),
            ("column", "TEXT NOT NULL"),
            ("dirty_at", "REAL NOT NULL"),
            ("stamp", "TEXT"),
            ("seen", "TEXT"),
        ], constraints: ["PRIMARY KEY (source_table, local_key, column)"]),
        // Which local row holds a record of a zone (§4.3): a personal row's local id is its wire id; a
        // space copy has its own.
        ReplicaSchemaTable("ck_identity", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("local_id", "TEXT NOT NULL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_type, wire_id)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_identity_local ON ck_identity(record_type, local_id)",
        ]),
        // The cutover seeder's priority cursor, one row per pass (§13.4).
        ReplicaSchemaTable("ck_seed_cursor", [
            ("pass", "TEXT PRIMARY KEY"),
            ("cursor", "TEXT"),
            ("completed_at", "REAL"),
            ("updated_at", "REAL NOT NULL"),
        ]),
        // Work the activation queues, drained off-main in bounded, resumable batches (§13.3 step 4).
        ReplicaSchemaTable("ck_backfill_queue", [
            ("id", "INTEGER PRIMARY KEY"),
            ("kind", "TEXT NOT NULL"),
            ("target", "TEXT NOT NULL"),
            ("payload_json", "TEXT"),
            ("enqueued_at", "REAL NOT NULL"),
            ("attempts", "INTEGER NOT NULL DEFAULT 0"),
            ("last_error", "TEXT"),
        ], constraints: ["UNIQUE (kind, target)"]),
        // This Mac's view of the old zones after its catch-up (§13.3, §13.4 step 0). `field_hashes` is
        // JSON: the old record's `waiting` flag and, per v2 record its mapping gives, the owner flag
        // and the field hashes, as `ZoneRoot.legacyBase`'s shards hold them.
        ReplicaSchemaTable("ck_legacy_snapshot", [
            ("old_zone", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("change_tag", "TEXT"),
            ("field_hashes", "TEXT NOT NULL"),
        ], constraints: ["PRIMARY KEY (old_zone, record_name)"]),
        // The generation-2 activation's one-row journal (D46, §13.3 step 3). `clone_path` is relative
        // to the store's folder.
        ReplicaSchemaTable("ck_activation", [
            ("id", "INTEGER PRIMARY KEY CHECK (id = 1)"),
            ("step", "TEXT"),
            ("mode", "TEXT"),
            ("fresh_reason", "TEXT"),
            ("account", "TEXT"),
            ("clone_path", "TEXT"),
            ("clone_user_version", "INTEGER"),
            ("rollback_build", "TEXT"),
            ("rollback_schema", "INTEGER"),
            ("started_at", "REAL"),
            ("derived_at", "REAL"),
            ("activated_at", "REAL"),
            ("catch_up_at", "REAL"),
            ("trigger_hash", "TEXT"),
        ]),
        // Creates a pass has queued and not yet listed in its manifest delta (§13.6).
        ReplicaSchemaTable("ck_manifest_pending", [
            ("pass_key", "TEXT NOT NULL"),
            ("zone_key", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
        ], constraints: ["PRIMARY KEY (pass_key, zone_key, record_type, wire_id)"]),
        // Late edits of a merged or moved notebook's stub, forwarded to the survivor once (§5.2).
        ReplicaSchemaTable("ck_forwarded", [
            ("record_name", "TEXT NOT NULL"),
            ("field", "TEXT NOT NULL"),
            ("stamp", "TEXT NOT NULL"),
        ], constraints: ["PRIMARY KEY (record_name, field, stamp)"]),
        // The move journal (§4.4, §5.3): a job, and one item per record it copies and then deletes.
        ReplicaSchemaTable("ck_move_jobs", [
            ("id", "TEXT PRIMARY KEY"),
            ("kind", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("from_zone", "TEXT NOT NULL"),
            ("to_zone", "TEXT NOT NULL"),
            ("state", "TEXT NOT NULL"),
            ("pass", "INTEGER NOT NULL DEFAULT 0"),
            ("created_at", "REAL NOT NULL"),
            ("updated_at", "REAL NOT NULL"),
            ("last_error", "TEXT"),
        ]),
        ReplicaSchemaTable("ck_move_items", [
            ("job_id", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("from_zone", "TEXT NOT NULL"),
            ("to_zone", "TEXT NOT NULL"),
            ("state", "TEXT NOT NULL"),
            ("copy_change_tag", "TEXT"),
            ("updated_at", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (job_id, record_type, wire_id)"]),
    ]

    /// `wire_key` on the five tables that can hold a space copy (§4.3): the logical id every v2 join
    /// reads, which is the row's own id while `wire_id` is NULL (every row before the generation-2
    /// activation, and every row generation-1 code inserts), so no row drops out of a join.
    static let wireKeyDefinition = "TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL"

    /// The tables that carry `wire_id` and the indexed `wire_key`.
    static let wireKeyedTables = ["sources", "learning_goals", "review_sessions", "global_artifacts", "courses"]

    /// Creates the `ck_*` tables and their indexes where missing: empty, DDL only.
    func createReplicaTables() throws {
        try replica.installSharedSchema()
        for table in Self.macReplicaTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

    /// Indexes each `wire_key`, the column every v2 join reads, once the wire columns are there.
    func createWireKeyIndexes() throws {
        for table in Self.wireKeyedTables {
            try exec("CREATE INDEX IF NOT EXISTS idx_\(table)_wire_key ON \(table)(wire_key)")
        }
    }

    // MARK: - Schema 154: per-member tables without foreign keys to content (D18, §5.7)

    /// A per-member table as a fresh store creates it from schema 154 on: no foreign key to the
    /// content it is about, so deleting a source or a notebook never deletes the learner's own state
    /// with it (a record of it lives on in the member's `Library`). `createSchema` and the rebuild
    /// both run this exact text, so a migrated store and a fresh one hold the same definition.
    struct PerMemberTable: Sendable {
        let name: String
        let createStatement: String
        let indexes: [String]
    }

    static let sourceHighlightsTable = PerMemberTable(name: "source_highlights", createStatement: """
        CREATE TABLE IF NOT EXISTS source_highlights (
            highlight_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            quads_json TEXT NOT NULL,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            note TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            anchor_prefix TEXT,
            anchor_suffix TEXT,
            anchor_offset INTEGER,
            chat_session_id TEXT,
            references_json TEXT,
            publication_update TEXT,
            publication_update_at REAL
        )
        """, indexes: [
        """
        CREATE INDEX IF NOT EXISTS idx_source_highlights_source_page
        ON source_highlights(source_id, page_index, created_at)
        """,
    ])

    static let hiddenSourcesTable = PerMemberTable(name: "hidden_sources", createStatement: """
        CREATE TABLE IF NOT EXISTS hidden_sources (
            source_id TEXT PRIMARY KEY,
            hidden_at REAL NOT NULL
        )
        """, indexes: [])

    static let hiddenPodcastEpisodesTable = PerMemberTable(name: "hidden_podcast_episodes", createStatement: """
        CREATE TABLE IF NOT EXISTS hidden_podcast_episodes (
            source_id TEXT PRIMARY KEY,
            hidden_at REAL NOT NULL
        )
        """, indexes: [])

    static let visiblePodcastEpisodeOverridesTable = PerMemberTable(name: "visible_podcast_episode_overrides", createStatement: """
        CREATE TABLE IF NOT EXISTS visible_podcast_episode_overrides (
            source_id TEXT PRIMARY KEY,
            visible_at REAL NOT NULL
        )
        """, indexes: [])

    static let visibleYouTubeVideoOverridesTable = PerMemberTable(name: "visible_youtube_video_overrides", createStatement: """
        CREATE TABLE IF NOT EXISTS visible_youtube_video_overrides (
            source_id TEXT PRIMARY KEY,
            visible_at REAL NOT NULL
        )
        """, indexes: [])

    static let sourceUnderstandingTable = PerMemberTable(name: "source_understanding", createStatement: """
        CREATE TABLE IF NOT EXISTS source_understanding (
            source_id TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL,
            derived_through_session_id TEXT,
            generated_at REAL NOT NULL,
            generator_version INTEGER NOT NULL,
            body_sha256 TEXT NOT NULL,
            open_thread_count INTEGER NOT NULL DEFAULT 0,
            discussed_idea_ids TEXT NOT NULL DEFAULT '[]'
        )
        """, indexes: [])

    /// A notebook's files: under generation 2 a deleted notebook's files become unfiled like its
    /// Docs (§5.2), so `notebook_id` may be NULL.
    static let notebookFilesTable = PerMemberTable(name: "notebook_files", createStatement: """
        CREATE TABLE IF NOT EXISTS notebook_files (
            id TEXT PRIMARY KEY,
            notebook_id TEXT,
            relative_path TEXT NOT NULL,
            name TEXT NOT NULL,
            role TEXT NOT NULL,
            content_type TEXT,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            modified_at REAL NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(notebook_id, relative_path)
        )
        """, indexes: [
        "CREATE INDEX IF NOT EXISTS idx_notebook_files_notebook ON notebook_files(notebook_id)",
        "CREATE INDEX IF NOT EXISTS idx_notebook_files_notebook_role ON notebook_files(notebook_id, role)",
    ])

    func createPerMemberTable(_ table: PerMemberTable) throws {
        try exec(table.createStatement)
        for index in table.indexes {
            try exec(index)
        }
    }

    private func rowCount(_ table: String) throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM \(table)") { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    // MARK: - A deleted notebook's files

    /// A deleted notebook's files stay, unfiled, as its Docs do (§5.2).
    func releaseFilesOfDeletedNotebook(_ notebookID: String) throws {
        try execBind("UPDATE notebook_files SET notebook_id = NULL WHERE notebook_id = ?") { statement in
            bind(statement, 1, notebookID)
        }
        // The notebook's Notes Doc is deleted with it (§5.2): its body pointer goes, and the record
        // with it (WP11).
        try execBind("DELETE FROM artifact_files WHERE artifact_id = ?") { statement in
            bind(statement, 1, NotesDoc.id(notebookID: notebookID))
        }
    }

    // MARK: - ck_identity (§4.3)

    /// Records which local row holds a record of a zone.
    func recordIdentity(zoneKey: String, recordType: String, wireID: String, localID: String) throws {
        try execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(zoneKey), .text(recordType), .text(wireID), .text(localID)])
    }

    func forgetIdentity(zoneKey: String, recordType: String, wireID: String) throws {
        try execute(
            "DELETE FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(zoneKey), .text(recordType), .text(wireID)]
        )
    }

    /// The local id of a record in one zone, if this store has recorded one.
    func localID(zoneKey: String, recordType: String, wireID: String) throws -> String? {
        try scalarText(
            "SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(zoneKey), .text(recordType), .text(wireID)]
        )
    }

    /// A wire id resolved to a local row for a cross-zone link (§4.3): first in the zones the caller
    /// prefers, in order (the zone `zoneFor` or `resolveNotebook()` names, then the personal library),
    /// then in any other zone, by zone key.
    func localID(forWire wireID: String, recordType: String, preferring zoneKeys: [String]) throws -> String? {
        for zoneKey in zoneKeys {
            if let local = try localID(zoneKey: zoneKey, recordType: recordType, wireID: wireID) {
                return local
            }
        }
        return try scalarText(
            "SELECT local_id FROM ck_identity WHERE record_type = ? AND wire_id = ? ORDER BY zone_key LIMIT 1",
            [.text(recordType), .text(wireID)]
        )
    }
}
