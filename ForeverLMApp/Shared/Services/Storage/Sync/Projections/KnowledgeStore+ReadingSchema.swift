// MARK: - Schema 160: the member's reading state (docs/cloudkit-schema-design.md §12.7, §3.5.18)

extension KnowledgeStore {
    /// The table schema 160 adds, created empty: DDL only, like every step from 154 on. Generation 1
    /// never reads or writes it (the `sources` columns stay its truth); the generation-2 activation fills
    /// it from generation-1 truth (`readingActivationDerivations`), and from then on the Reader's
    /// accessors and the ReadingState projection keep it.
    static let readingSyncTables: [ReplicaSchemaTable] = [
        // One row per ReadingState record (§3.5.18), keyed by the source's wire id with no foreign key:
        // a team copy and the personal copy share it, and it outlives the source it is about (D18).
        // `locator_json` is the record's Locator (§3.3), the Mac reader's own encoding kept beside it
        // under `mac`; `position` the PDF page index the Mac's reader keeps. Times are Cocoa seconds.
        // `furthest_epoch` and `furthest` are the record's `furthest` pair. `walk_variants_json` holds
        // the walk variants other than `main`, which no local table holds (`main` is
        // `walkthrough_progress`'s row); `discussed_json` the discussed idea keys of a source with no
        // Understanding row on this Mac; `understanding_json` and `understanding_path` the
        // Understanding document's FileRef and the file it was laid out from.
        ReplicaSchemaTable("reading_states", [
            ("wire_id", "TEXT PRIMARY KEY"),
            ("locator_json", "TEXT"),
            ("position", "INTEGER"),
            ("read_at", "REAL"),
            ("review_depth", "TEXT"),
            ("furthest_epoch", "INTEGER"),
            ("furthest", "REAL"),
            ("completed_at", "REAL"),
            ("consumed_at", "REAL"),
            ("last_read_at", "REAL"),
            ("listen_json", "TEXT"),
            ("media_json", "TEXT"),
            ("watched_seconds", "REAL"),
            ("last_context_json", "TEXT"),
            ("walk_variants_json", "TEXT"),
            ("discussed_json", "TEXT"),
            ("understanding_json", "TEXT"),
            ("understanding_path", "TEXT"),
        ]),
    ]

    /// Creates schema 160's table where missing: empty, DDL only.
    func createReadingSyncTables() throws {
        for table in Self.readingSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

}
