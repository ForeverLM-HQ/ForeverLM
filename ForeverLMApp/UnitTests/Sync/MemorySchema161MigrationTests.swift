import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 161 (docs/cloudkit-schema-design.md §12.7, WP13): the memory records' tables, DDL only and
/// empty until a store's generation-2 activation, from the released 150 and 153 shapes, from 154 and from
/// the step before it (`Schema154Fixture`). Under generation 1 every memory recorder writes what build 177
/// does and nothing else (D40).
@Suite("Schema 161 migration")
struct MemorySchema161MigrationTests {
    private static let tables = KnowledgeStore.memorySyncTables.map(\.name)

    private static func counts(_ store: KnowledgeStore) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in tables { counts[table] = try Schema154Fixture.count(store, "SELECT COUNT(*) FROM \(table)") }
        return counts
    }

    @Test("A fresh store is at 161 with the memory tables, empty")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("161-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 161)
        #expect(KnowledgeStore.memorySchemaVersion == 161)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        for table in KnowledgeStore.memorySyncTables {
            try store.query(table.probe) { _ in }
        }
        #expect(try Self.counts(store).values.allSatisfy { $0 == 0 })
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try Schema154Fixture.count(store, """
            SELECT COUNT(*) FROM pragma_foreign_key_list('memory_sittings') UNION ALL
            SELECT COUNT(*) FROM pragma_foreign_key_list('memory_sitting_answers')
        """) == 0, "per-member history has no foreign key to content (D18)")
    }

    @Test(
        "A released, 154 or 160 store migrates to 161 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Schema154Fixture.versionBeforeMemorySchema]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("161-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'memory_sittings'") == 0)
        let counts = ["sources", "memory_items", "memory_attempts", "source_activity_days", "memory_review_activity", "sync_metadata"]
        let before = counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") } == before)
        #expect(try Self.counts(migrated).values.allSatisfy { $0 == 0 }, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try migrated.pendingSyncChanges().isEmpty, "a schema-only migration republishes nothing")
        #expect(Set(try migrated.loadSourcesWithoutContent().map(\.id)) == Set(library.sourceIDs))
    }

    @Test("A migrated store and a fresh one hold the same 161 tables")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("161-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("161-parity-migrated")
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

    @Test("A same-named table of another shape rolls 161 back and leaves the store where it was")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("161-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: Schema154Fixture.versionBeforeMemorySchema)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE practices (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(Schema154Fixture.versionBeforeMemorySchema))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'memory_sittings'") == 0, "nothing of 161 stays")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("A production-sized memory history migrates to 161 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("161-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            // Ten times production's memory history (55 items, 59 attempts, 2,451 activity days, 17
            // review device-days): 6,000 sources, 600 items, 6,000 attempts, 25,000 activity days.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 600)
                INSERT INTO memory_items (id, kind, target, rubric_json, status, created_at, updated_at)
                SELECT printf('item-%04d', n), 'concept', 'A target', '{}', 'active', n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO memory_attempts (id, memory_item_id, attempt_type, prompt, learner_answer, grade_state, attempted_at)
                SELECT printf('attempt-%05d', n), printf('item-%04d', n % 600 + 1), 'review', 'Q?', 'A.', 'graded', n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 25000)
                INSERT INTO source_activity_days (id, scheduled_source_id, source_id, day_start, first_activity_at,
                    last_activity_at, kinds, completed_kinds)
                SELECT printf('day-%05d', n), 'placement', printf('source-%05d', n % 6000 + 1), (n / 6000) * 86400.0 + n,
                    n, n, 1, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreShapeBeforeMemorySchema(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema \(Schema154Fixture.versionBeforeMemorySchema) → \(KnowledgeStore.schemaVersion) over 6,000 sources and 6,000 attempts: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
        #expect(try Self.counts(migrated).values.allSatisfy { $0 == 0 })
    }

    @Test("Under generation 1 attempts, activity and a bout land where build 177 puts them, and the 161 tables stay empty")
    func generation1RecordsAsBefore() throws {
        let root = try Schema154Fixture.temporaryRoot("161-generation1")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        var article = StudioArticle(url: "https://example.org/memory/1", title: "A paper", sourceType: .article)
        #expect(try store.insertSourceIfNew(&article))

        let now = Date()
        try store.recordScheduledSourceActivity(sourceID: article.id, on: now, kind: .reading, fraction: 0.4, engagedSeconds: 90)
        try store.recordMemoryReviewActivity(MemoryReviewActivity(
            day: DayPlan.dateString(for: now), deviceID: "device-a", activeSeconds: 120, goalSeconds: 600, updatedAt: now
        ))
        let item = MemoryItem(
            id: "item-1", kind: .concept, target: "Complex I pumps four protons", rubricJSON: "{}",
            sources: [MemoryItemSource(id: "anchor-1", memoryItemID: "item-1", sourceID: article.id, excerpt: "pumps", sourceSHA256: "abc", sortIndex: 0)],
            createdAt: now.addingTimeInterval(-3 * 86_400), updatedAt: now.addingTimeInterval(-3 * 86_400)
        )
        try store.saveMemoryItem(item)
        _ = try store.recordMemoryAttempt(MemoryAttempt(
            id: "attempt-1", memoryItemID: item.id, prompt: "How many?", learnerAnswer: "Four",
            score: 1, scheduleRating: .good, gradeState: .graded, attemptedAt: now
        ))
        let bout = try store.startLearningBout(LearningBout(dayPlanID: DayPlan.dateString(for: now), title: "Complex I"), now: now)

        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_activity_days WHERE source_id = '\(article.id)'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM memory_review_activity WHERE device_id = 'device-a'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM memory_attempts WHERE id = 'attempt-1'") == 1)
        #expect(try store.scalarText("SELECT day_plan_id FROM learning_bouts WHERE id = ?", [.text(bout.id)]) == DayPlan.dateString(for: now),
                "the bout in its day plan")
        let memoryRows = try Self.counts(store)
        #expect(memoryRows.values.allSatisfy { $0 == 0 }, "\(memoryRows)")
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }
}
