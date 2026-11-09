import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 156 (docs/cloudkit-schema-design.md §12.7, WP8): the notebook records' tables, the
/// Entry's order key and the back-pointer view, DDL only and empty until a store's generation-2
/// activation, from the released 150 and 153 shapes and from 154 and 155 (`Schema154Fixture`).
@Suite("Schema 156 migration")
struct NotebookSchema156MigrationTests {
    private static let tables = KnowledgeStore.notebookSyncTables.map(\.name)

    private static func emptyCounts(_ store: KnowledgeStore) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in tables { counts[table] = try Schema154Fixture.count(store, "SELECT COUNT(*) FROM \(table)") }
        return counts
    }

    @Test("A fresh store is at 156 or later with the notebook tables, empty, and the back-pointer view")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("156-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 156)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probeSchema156()
        #expect(try Self.emptyCounts(store).values.allSatisfy { $0 == 0 })
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'view' AND name = 'ck_notebook_children'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test(
        "A released, 154 or 155 store migrates past 156 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Int32(155)]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("156-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'notebook_states'") == 0)
        let counts = ["sources", "learning_goals", "learning_goal_items", "notebook_files", "sync_metadata"]
        let before = counts.map { Schema154Fixture.rowCount(at: root, $0) }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.rowCount(at: root, $0) } == before)
        #expect(try Self.emptyCounts(migrated).values.allSatisfy { $0 == 0 }, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM learning_goal_items WHERE order_key IS NOT NULL") == 0)
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try migrated.pendingSyncChanges().isEmpty, "a schema-only migration republishes nothing")
        // The view reads the library as it is: the fixture's notebook holds a source and a file.
        #expect(try Schema154Fixture.count(migrated, """
            SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = '\(library.notebookID)'
        """) == 2)
    }

    @Test("A migrated store and a fresh one hold the same 156 tables and view")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("156-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("156-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 153)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        let names = (Self.tables + ["ck_notebook_children"]).map { "'\($0)'" }.joined(separator: ", ")
        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN (\(names)) ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
        let column = "SELECT COUNT(*) FROM pragma_table_info('learning_goal_items') WHERE name = 'order_key'"
        #expect(Schema154Fixture.count(at: freshRoot, column) == 1)
        #expect(Schema154Fixture.count(at: migratedRoot, column) == 1)
    }

    @Test("A same-named table of another shape rolls 156 back and leaves the store at 155")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("156-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 155)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE notebook_resolution (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 155)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('notebook_states', 'ck_notebook_children')") == 0, "nothing of 156 stays")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('learning_goal_items') WHERE name = 'order_key'") == 0)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("Chat ticks and collections are NotebookState fields, so their prefixes are not synced preferences")
    func notebookStatePrefixesAreNotSynced() {
        for prefix in SyncedPreferenceKeys.notebookStatePrefixes {
            #expect(!SyncedPreferenceKeys.liveSyncedPrefixes.contains(prefix), "\(prefix) is a NotebookState field")
        }
    }

    @Test("A production-sized library migrates from 155 to the current schema in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("156-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            // 6,000 sources, 60 notebooks holding 4,000 items between them, and 17,000 sync rows.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 60)
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, kind)
                SELECT printf('notebook-%03d', n), printf('Notebook %d', n), 0, 0, n, n, 'companion' FROM seq;
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, sequence)
                SELECT 'item-' || id, printf('notebook-%03d', (date_added % 60) + 1), id, date_added, NULL
                FROM sources WHERE date_added <= 4000;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreSchema155Shape(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema 155 → \(KnowledgeStore.schemaVersion) over 6,000 sources and 4,000 notebook items: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }
}
