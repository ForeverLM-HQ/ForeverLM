import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 160 (docs/cloudkit-schema-design.md §12.7, WP12): the member's reading state, DDL only
/// and empty until a store's generation-2 activation, from the released 150 and 153 shapes and from 154
/// on (`Schema154Fixture`). Under generation 1 the `sources` columns stay the reading state's only truth.
@Suite("Schema 160 migration")
struct PersonalSchema160MigrationTests {
    private static let tables = KnowledgeStore.readingSyncTables.map(\.name)

    @Test("A fresh store is at 160 with reading_states, empty, and no trigger")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("160-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 160)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probeReadingSchema()
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM reading_states") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test(
        "A released or later store migrates to 160 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Int32(155), Schema154Fixture.versionBeforeReadingSchema]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("160-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'reading_states'") == 0)
        // A position, a read mark, a review depth and a consumed mark, as generation 1 holds them.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, """
            UPDATE sources SET reading_position_page = 7, read_at = 1000, review_depth = 'deep', is_consumed = 1
            WHERE id = '\(library.sourceIDs[0])'
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let reading = "SELECT reading_position_page || '|' || read_at || '|' || review_depth || '|' || is_consumed FROM sources WHERE id = '\(library.sourceIDs[0])'"
        let before = Schema154Fixture.scalar(at: root, reading)
        let counts = ["sources", "learning_goals", "learning_goal_items", "walkthrough_progress", "source_understanding"]
        let countsBefore = counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") } == countsBefore)
        #expect(before == "7|1000.0|deep|1" && Schema154Fixture.scalar(at: root, reading) == before, "the sources columns stay as they were")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM reading_states") == 0, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        // Generation 1's Reader still reads the position from the sources columns.
        var page: Int32 = -1
        try migrated.query("SELECT reading_position_page FROM source_projection WHERE id = '\(library.sourceIDs[0])'") { page = sqlite3_column_int($0, 0) }
        #expect(page == 7)
    }

    @Test("A migrated store and a fresh one hold the same 160 table")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("160-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("160-parity-migrated")
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
    }

    @Test("A same-named table of another shape rolls 160 back and leaves the store where it was")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("160-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: Schema154Fixture.versionBeforeReadingSchema)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE reading_states (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(Schema154Fixture.versionBeforeReadingSchema))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('reading_states') WHERE name = 'wire_id'") == 0, "nothing of 160 stays")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("Under generation 1 the source view reads the sources columns, never reading_states")
    func generation1ViewIsUnchanged() throws {
        let root = try Schema154Fixture.temporaryRoot("160-view")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let stored = try store.scalarText("SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'source_projection'")
        let expected = KnowledgeStore.sourceProjectionViewSQL(sourceColumnNames: try store.tableColumnNames("sources"))
        #expect(stored?.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(stored?.contains("reading_states") == false)
        #expect(!SyncedPreferenceKeys.liveSyncedPrefixes.contains(ListeningPositionSync.preferenceKeyPrefix), "a ReadingState field under generation 2")
    }

    @Test("A production-sized library migrates from 159 to 160 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("160-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try Schema154Fixture.restoreGeneration1Tables(store)
            // 6,000 sources, a third of them with a position and a read mark, and 17,000 sync rows.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status, reading_position_page, read_at)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active',
                       CASE WHEN n % 3 = 0 THEN n % 40 END, CASE WHEN n % 3 = 0 THEN n END FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreShapeBeforeReadingSchema(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema \(Schema154Fixture.versionBeforeReadingSchema) → \(KnowledgeStore.schemaVersion) over 6,000 sources: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }

    // MARK: The activation's steps (§13.3 step 3c)

    typealias F = NotebookSyncFixture

    /// What the reading derivations wrote, as text, to compare two runs.
    static func derived(_ store: KnowledgeStore) throws -> String {
        var lines: [String] = []
        try store.query("""
            SELECT wire_id || '=' || COALESCE(locator_json, '-') || ',' || COALESCE(position, '-') || ',' || COALESCE(read_at, '-') || ','
                || COALESCE(review_depth, '-') || ',' || COALESCE(furthest, '-') || ',' || COALESCE(completed_at, '-') || ','
                || COALESCE(consumed_at, '-') FROM reading_states ORDER BY wire_id
        """, []) { row in lines.append(row.text(0) ?? "") }
        try store.query("SELECT kind || '/' || target FROM ck_backfill_queue ORDER BY kind, target", []) { row in lines.append(row.text(0) ?? "") }
        return lines.joined(separator: "\n")
    }

    static func runDerivations(_ store: KnowledgeStore) throws {
        try KnowledgeStore.$listenFileProbeOverride.withValue({ _ in [:] }) {
            for derivation in KnowledgeStore.readingActivationDerivations { try derivation.run(store) }
        }
    }

    @Test("The activation's steps give the same rows twice, and reflect generation-1 edits made before them")
    func activationStepsRunTwiceAndAfterEdits() throws {
        let (root, store) = try F.makeStore("160-derive", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["src-1", "src-2", "src-3"] { try F.addSource(store, id) }
        try store.executeScript("""
            UPDATE sources SET reading_position_page = 4, read_at = 100, review_depth = 'quick' WHERE id = 'src-1';
            UPDATE sources SET reading_position_locator = '{"webScrollFraction":0.5}', is_consumed = 1, read_at = 50 WHERE id = 'src-2';
            INSERT INTO source_understanding (source_id, relative_path, generated_at, generator_version, body_sha256)
            VALUES ('src-3', 'Understanding/src-3.md', 7, 1, 'abc');
        """)
        try Self.runDerivations(store)
        let first = try Self.derived(store)
        #expect(first.contains("src-1={\"page\":4,\"t\":\"pdf\"}") == false, "a page is the position column, not a locator")
        #expect(first.contains("src-1=-,4,100.0,quick,-,-,-"))
        #expect(first.contains("src-2=") && first.contains(",0.5,-,50.0"), "the furthest fraction, and consumed when it was read")
        #expect(first.contains("understanding/src-3"))
        try Self.runDerivations(store)
        #expect(try Self.derived(store) == first, "a second run changes nothing")

        // Generation-1 writes made before the activation: a new read mark, a cleared depth, a cleared place.
        try store.executeScript("""
            UPDATE sources SET read_at = 300, review_depth = NULL WHERE id = 'src-1';
            UPDATE sources SET reading_position_locator = NULL, is_consumed = NULL, read_at = NULL WHERE id = 'src-2';
        """)
        try Self.runDerivations(store)
        let after = try Self.derived(store)
        #expect(after.contains("src-1=-,4,300.0,-,-,-,-"))
        #expect(after.contains("src-2=-,-,-,-,-,-,-"), "cleared, as the columns now say")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0, "derivations send nothing")
    }
}
