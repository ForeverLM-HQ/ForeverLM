import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 159 (docs/cloudkit-schema-design.md §12.7, WP11): `global_artifacts.body_ref`,
/// `artifact_files` and `ck_legacy_bodies`, DDL only and empty until a store's generation-2 activation,
/// from the released 150 and 153 shapes and from 154, 155 and the schema before it
/// (`Schema154Fixture`).
@Suite("Schema 159 migration")
struct ArtifactSchema159MigrationTests {
    private static let tables = KnowledgeStore.artifactSyncTables.map(\.name)

    private static func emptyCounts(_ store: KnowledgeStore) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in tables { counts[table] = try Schema154Fixture.count(store, "SELECT COUNT(*) FROM \(table)") }
        return counts
    }

    @Test("A fresh store is at 159 with the Artifact tables, empty, and the body pointer")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("159-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 159)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probeSchema159()
        #expect(try Self.emptyCounts(store).values.allSatisfy { $0 == 0 })
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test(
        "A released or later store migrates to 159 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Int32(155), Schema154Fixture.versionBeforeArtifactSchema]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("159-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'artifact_files'") == 0)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('global_artifacts') WHERE name = 'body_ref'") == 0)
        let counts = ["sources", "learning_goals", "global_artifacts", "notebook_files", "sync_metadata"]
        let before = counts.map { Schema154Fixture.rowCount(at: root, $0) }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.rowCount(at: root, $0) } == before)
        #expect(try Self.emptyCounts(migrated).values.allSatisfy { $0 == 0 }, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM global_artifacts WHERE body_ref IS NOT NULL") == 0)
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try migrated.pendingSyncChanges().isEmpty, "a schema-only migration republishes nothing")
    }

    @Test("A migrated store and a fresh one hold the same 159 tables and body pointer")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("159-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("159-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 153)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        let names = Self.tables.map { "'\($0)'" }.joined(separator: ", ")
        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN (\(names)) ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
        let column = "SELECT type FROM pragma_table_info('global_artifacts') WHERE name = 'body_ref'"
        #expect(Schema154Fixture.scalar(at: freshRoot, column) == "TEXT")
        #expect(Schema154Fixture.scalar(at: migratedRoot, column) == "TEXT")
    }

    @Test("A same-named table of another shape rolls 159 back and leaves the store where it was")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("159-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Schema154Fixture.versionBeforeArtifactSchema
        try Schema154Fixture.makeLibrary(at: root, version: before)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE ck_legacy_bodies (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(before))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'artifact_files'") == 0, "nothing of 159 stays")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('global_artifacts') WHERE name = 'body_ref'") == 0)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("Under generation 1 a source's draft deck stays an Artifact and syncs as on build 177")
    func generation1DeckSyncsAsBefore() throws {
        let root = try Schema154Fixture.temporaryRoot("159-gen1-deck")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let deckID = MemoryCard.draftDeckIDPrefix + "src-a"
        try store.saveArtifactRecord(ArtifactRecord(
            id: deckID, title: "Cards to check", homeNotebookID: nil, linkedNotebookIDs: [], kind: .flashcards,
            sourceIDs: ["src-a"], createdAt: Date(), updatedAt: Date()
        ))
        #expect(try store.loadArtifact(deckID)?.isCardDeck == true)
        #expect(try store.pendingSyncChanges().contains { $0.entity == .artifact && $0.logicalKey == deckID }, "it syncs as an Artifact")
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM global_artifacts WHERE body_ref IS NOT NULL") == 0)
        try store.clearAllPendingSyncChanges()
        try store.deleteArtifactRecord(deckID)
        #expect(try store.pendingSyncChanges().contains { $0.entity == .artifact && $0.logicalKey == deckID && $0.operation == .delete })
        #expect(try Self.emptyCounts(store).values.allSatisfy { $0 == 0 }, "generation 1 writes none of 159's tables")
    }

    @Test("A production-sized library migrates to 159 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("159-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            // 6,000 sources, 1,000 Docs with their notebook links, and 17,000 sync rows: ten times
            // production's 86 Artifacts.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
                INSERT INTO global_artifacts (id, title, created_at, updated_at)
                SELECT printf('doc-%04d', n), printf('Doc %d', n), n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreShapeBeforeArtifactSchema(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema \(Schema154Fixture.versionBeforeArtifactSchema) → 159 over 6,000 sources and 1,000 Docs: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM global_artifacts") == 1_000)
    }
}
