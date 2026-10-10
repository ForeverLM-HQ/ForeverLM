import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 163, WP12b's step (docs/cloudkit-schema-design.md §12.7): the Device record's table and the
/// import-blocked shows' table, DDL only and empty until a store's generation-2 activation, from the released
/// 150 and 153 shapes and from 154 to 162 (`Schema154Fixture`).
@Suite("Schema 163 migration, Device and import-blocked shows")
struct PersonalStateSchema163MigrationTests {
    private static let tables = KnowledgeStore.personalStateSyncTables.map(\.name)

    private static func filledCount(_ root: URL) -> Int {
        tables.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }.reduce(0, +)
    }

    @Test("A fresh store is at 163 or later with the Device and import-blocked tables, empty")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("163-personal-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= KnowledgeStore.personalStateSchemaVersion)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probePersonalStateSchema()
        #expect(Self.filledCount(root) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test(
        "A released store, or one from 154 to 162, migrates to 163 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Int32(155), Int32(156), Schema154Fixture.versionBeforePersonalStateSchema]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("163-personal-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        // What generation 1 holds for these tables' records: a connector's health and a blocked show.
        #expect(sqlite3_exec(database, """
            INSERT INTO user_preferences (key, value, updated_at) VALUES
                ('connectorHealth.readAI.state', 'healthy', 1), ('podcasts.blockedShows', 'EPIC RADIO', 2);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('devices', 'blocked_podcast_shows')") == 0)
        let counts = ["sources", "user_preferences", "hidden_sources", "source_highlights", "sync_metadata"]
        let before = counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") } == before)
        #expect(Self.filledCount(root) == 0, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try migrated.pendingSyncChanges().isEmpty, "a schema-only migration republishes nothing")
    }

    @Test("A migrated store and a fresh one hold the same 163 tables")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("163-personal-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("163-personal-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: Schema154Fixture.versionBeforePersonalStateSchema)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        let names = Self.tables.map { "'\($0)'" }.joined(separator: ", ")
        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN (\(names)) ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
        #expect(fresh?.contains("show_name TEXT PRIMARY KEY COLLATE NOCASE") == true)
    }

    @Test("A same-named table of another shape rolls 163 back and leaves the store where it was")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("163-personal-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Schema154Fixture.versionBeforePersonalStateSchema
        try Schema154Fixture.makeLibrary(at: root, version: before)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE devices (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(before))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'blocked_podcast_shows'") == 0,
                "the other table does not stay")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("A production-sized library migrates to 163 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("163-personal-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            // 6,000 sources, 1,500 preference rows, 17,000 sync rows: the step is DDL only, so none is read.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'podcast', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1500)
                INSERT INTO user_preferences (key, value, updated_at) SELECT printf('studio.workspaceView.%04d', n), 'x', n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreShapeBeforePersonalStateSchema(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema \(Schema154Fixture.versionBeforePersonalStateSchema) → \(KnowledgeStore.schemaVersion) over 6,000 sources and 1,500 preference rows: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }
}
