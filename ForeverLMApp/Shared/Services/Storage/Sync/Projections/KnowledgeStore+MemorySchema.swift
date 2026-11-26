// MARK: - Schema 161: the memory records' local tables (docs/cloudkit-schema-design.md §12.7)

extension KnowledgeStore {
    /// The tables schema 161 adds, created empty: DDL only, like every step from 154 on. Generation 1
    /// never reads or writes them; the generation-2 activation fills them from generation-1 truth
    /// (`memoryActivationDerivations`), and from then on the memory projections and the generation-2
    /// recorders keep them. None has a foreign key: every row is per-member history or state, kept
    /// whatever arrives first and whatever content goes (D18, §5.7).
    static let memorySyncTables: [ReplicaSchemaTable] = [
        // One row per Sitting record (§3.5.23), a continuation part `<firstID>#<n>` its own row. Times
        // are Cocoa seconds. `device_id` is the one writer; '' marks a sitting this Mac began before it
        // knew its sync device id, claimed when the clock is made (`claimOwnMemoryRows`). A learning bout
        // is the Sitting of kind `bout` and keeps its row in `learning_bouts`.
        ReplicaSchemaTable("memory_sittings", [
            ("id", "TEXT PRIMARY KEY"),
            ("device_id", "TEXT NOT NULL DEFAULT ''"),
            ("kind", "TEXT NOT NULL"),
            ("scope_json", "TEXT"),
            ("started_at", "REAL NOT NULL"),
            ("ended_at", "REAL"),
            ("chat_id", "TEXT"),
            ("part", "INTEGER NOT NULL DEFAULT 1"),
            ("result_json", "TEXT"),
            ("write_up_json", "TEXT"),
            ("break_minutes", "INTEGER"),
            ("break_ends_at", "REAL"),
            ("abandoned_at", "REAL"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_memory_sittings_writer ON memory_sittings(device_id, kind, chat_id)",
        ]),
        // A Sitting's answers, one row per answer, written once (S per element): the wire `Answer`
        // whole in `answer_json`, so answers about quiz questions, walk steps and exchanges, and those
        // that did not count, survive as they came. An answer about a card that counts (or carries a
        // grade state) is also that card's `memory_attempts` row, which every scheduler reads.
        ReplicaSchemaTable("memory_sitting_answers", [
            ("answer_id", "TEXT PRIMARY KEY"),
            ("sitting_id", "TEXT NOT NULL"),
            ("subject", "TEXT NOT NULL"),
            ("at", "REAL NOT NULL"),
            ("counted", "INTEGER NOT NULL DEFAULT 1"),
            ("practice", "INTEGER NOT NULL DEFAULT 0"),
            ("answer_json", "TEXT NOT NULL"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_memory_sitting_answers_sitting ON memory_sitting_answers(sitting_id, at)",
        ]),
        // A card's state outside its kept wording (§3.5.22), one row per Card record: whether it was
        // skipped or retired, its seed, variants and "always ask it this way", and a draft's wording.
        // A kept card's wording is its `memory_items` row and anchors, written once at Keep; `kept_json`
        // holds the kept wording as another device wrote it, sent back as it came (S, never rewritten).
        ReplicaSchemaTable("memory_card_states", [
            ("card_id", "TEXT PRIMARY KEY"),
            ("status", "TEXT NOT NULL"),
            ("deck_source_id", "TEXT"),
            ("origin", "TEXT"),
            ("seed_key", "TEXT"),
            ("draft_json", "TEXT"),
            ("kept_json", "TEXT"),
            ("variants_json", "TEXT NOT NULL DEFAULT '{}'"),
            ("always_ask", "INTEGER NOT NULL DEFAULT 0"),
            ("made_by_json", "TEXT"),
            ("drafted_at", "REAL"),
            ("skipped_at", "REAL"),
            ("retired_at", "REAL"),
            ("supersedes", "TEXT"),
            ("split_from", "TEXT"),
        ]),
        // A card's details (`Card.details`, schema 181): one row per card that takes one point of an
        // overview card's answer further, such as a step of an argument. `parent_id` is the overview's
        // Card id, `child_id` the detail's; `point` is the overview's line the detail elaborates, as
        // written, and `sort_index` its place among the details. No foreign key either way, so
        // deleting, retiring or starting over either card never touches the other (a link whose card
        // is gone is simply not drawn). Rows feed the overview's record, one map element each.
        ReplicaSchemaTable("memory_card_links", [
            ("parent_id", "TEXT NOT NULL"),
            ("child_id", "TEXT NOT NULL"),
            ("point", "TEXT NOT NULL DEFAULT ''"),
            ("sort_index", "INTEGER NOT NULL DEFAULT 0"),
            ("linked_at", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (parent_id, child_id)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_memory_card_links_child ON memory_card_links(child_id)",
        ]),
        // This Mac's own activity log for a day (§3.5.24), the one `al:<day>:<deviceID>` record it
        // writes: `sources_json` is the `sources` map, `review_json` the goal clock. '' as the device
        // is this Mac before it knew its sync device id.
        ReplicaSchemaTable("device_activity_days", [
            ("day", "TEXT NOT NULL"),
            ("device_id", "TEXT NOT NULL DEFAULT ''"),
            ("sources_json", "TEXT NOT NULL DEFAULT '{}'"),
            ("review_json", "TEXT"),
        ], constraints: ["PRIMARY KEY (day, device_id)"]),
        // Every other device's activity logs and the migrated `legacy22` ones, as they arrived or as
        // the activation built them. `source_activity_days` and `memory_review_activity` are their
        // fold under generation 2, recomputed per day.
        ReplicaSchemaTable("activity_logs", [
            ("day", "TEXT NOT NULL"),
            ("device_id", "TEXT NOT NULL"),
            ("sources_json", "TEXT NOT NULL DEFAULT '{}'"),
            ("review_json", "TEXT"),
            ("review_by_device_json", "TEXT NOT NULL DEFAULT '{}'"),
        ], constraints: ["PRIMARY KEY (day, device_id)"]),
        // Proposed and adopted study practices (§3.5.25). Times are Cocoa seconds.
        ReplicaSchemaTable("practices", [
            ("id", "TEXT PRIMARY KEY"),
            ("rule_id", "TEXT"),
            ("scope", "TEXT"),
            ("period", "TEXT"),
            ("origin", "TEXT NOT NULL"),
            ("status", "TEXT NOT NULL"),
            ("title", "TEXT NOT NULL"),
            ("body", "TEXT"),
            ("evidence_json", "TEXT"),
            ("min_sample_met", "INTEGER"),
            ("rule_json", "TEXT"),
            ("setting_change_json", "TEXT"),
            ("made_by_json", "TEXT"),
            ("decided_at", "REAL"),
            ("applied_at", "REAL"),
            ("valid_until", "REAL"),
            ("created_at", "REAL NOT NULL"),
        ]),
    ]

    /// Creates schema 161's tables where missing: empty, DDL only.
    func createMemorySyncTables() throws {
        for table in Self.memorySyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

}
