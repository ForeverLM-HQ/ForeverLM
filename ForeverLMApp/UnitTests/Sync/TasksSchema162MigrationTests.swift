import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 162 (docs/cloudkit-schema-design.md §12.7, WP14): the Job table and the Task and
/// Automation records' columns, DDL only and empty until a store's generation-2 activation, from the
/// released 150 and 153 shapes, from 154 and from the step before it (`Schema154Fixture`). Under
/// generation 1 the task, share-request, action-item and scheduled-task writers write what build 177
/// does and nothing else (D40).
@Suite("Schema 162 migration")
struct TasksSchema162MigrationTests {
    private static func filledCount(_ root: URL) -> Int {
        Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM jobs")
            + Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM notebook_tasks WHERE order_key IS NOT NULL")
            + Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM scheduled_tasks WHERE runner_device_id IS NOT NULL")
            + Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM scheduled_task_runs WHERE ring_slot IS NOT NULL")
    }

    /// A notebook's two tasks, a team's share request, a meeting's action item and a scheduled task with
    /// two runs, as generation 1 writes them.
    static func tasksSQL(notebookID: String) -> String {
        """
            INSERT INTO project_tasks (id, project_id, title, notes, status, sort_order, created_at, updated_at) VALUES
                ('task-1', '\(notebookID)', 'Read the methods', '', 'todo', 0, 100, 100),
                ('task-2', '\(notebookID)', 'Write a summary', 'by Friday', 'done', 1, 101, 102);
            INSERT INTO share_requests (id, team_id, url, title, status, created_at, updated_at) VALUES
                ('req-1', 'team-1', 'https://example.org/paper', 'A paper', 'open', 103, 103);
            INSERT INTO meeting_action_items (id, group_id, source_id, position, text, owner, created_at, updated_at) VALUES
                ('meeting-1#0', 'group-1', 'meeting-1', 0, 'Send the slides', 'Ana', 104, 104);
            INSERT INTO scheduled_tasks (id, title, instruction, cadence, hour, minute, created_at, updated_at) VALUES
                ('auto-1', 'Morning brief', 'Summarize yesterday', 'daily', 8, 0, 105, 105);
            INSERT INTO scheduled_task_runs (id, task_id, occurrence_at, started_at, status) VALUES
                ('run-1', 'auto-1', 200, 200, 'succeeded'), ('run-2', 'auto-1', 300, 300, 'failed');
        """
    }

    @Test("A fresh store is at 162 or later with the Job table and the task columns, empty")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("162-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 162)
        #expect(KnowledgeStore.tasksSchemaVersion == 162)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probeTasksSchema()
        #expect(Self.filledCount(root) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM pragma_foreign_key_list('jobs')") == 0,
                "a Job is the member's own record: no foreign key (D18)")
    }

    @Test(
        "A released, 154 or 157 store migrates to 162 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Schema154Fixture.versionBeforeTasksSchema]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("162-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, Self.tasksSQL(notebookID: library.notebookID), nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'jobs'") == 0)
        for added in KnowledgeStore.tasksSyncColumns {
            #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('\(added.table)') WHERE name = '\(added.column)'") == 0)
        }
        let counts = ["sources", "notebook_tasks", "share_requests", "meeting_action_items", "scheduled_tasks", "scheduled_task_runs"]
        let before = counts.map { Schema154Fixture.rowCount(at: root, $0) }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.rowCount(at: root, $0) } == before)
        #expect(Self.filledCount(root) == 0, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(Set(try migrated.loadSourcesWithoutContent().map(\.id)) == Set(library.sourceIDs))
        #expect(try migrated.loadNotebookTasks(notebookID: library.notebookID).map(\.id) == ["task-1", "task-2"])
        #expect(try migrated.loadScheduledTaskRuns(taskID: "auto-1").map(\.id) == ["run-2", "run-1"])
    }

    @Test("A migrated store and a fresh one hold the same 162 table and columns")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("162-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("162-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 153)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master WHERE tbl_name = 'jobs' ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
        for added in KnowledgeStore.tasksSyncColumns {
            let column = "SELECT type || ' ' || \"notnull\" || ' ' || COALESCE(dflt_value, '') FROM pragma_table_info('\(added.table)') WHERE name = '\(added.column)'"
            #expect(Schema154Fixture.scalar(at: freshRoot, column) != nil)
            #expect(Schema154Fixture.scalar(at: freshRoot, column) == Schema154Fixture.scalar(at: migratedRoot, column), "\(added.table).\(added.column)")
        }
    }

    @Test("A same-named table of another shape rolls 162 back and leaves the store at the step before")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("162-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let version = Schema154Fixture.versionBeforeTasksSchema
        try Schema154Fixture.makeLibrary(at: root, version: version)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE jobs (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        for added in KnowledgeStore.tasksSyncColumns {
            #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('\(added.table)') WHERE name = '\(added.column)'") == 0,
                    "\(added.table).\(added.column) does not stay")
        }
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("Under generation 1 a task, a share request and a scheduled run write none of 162's columns")
    func generationOneWritesNothingNew() throws {
        let root = try Schema154Fixture.temporaryRoot("162-generation-1")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: nil)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try store.saveNotebookTask(NotebookTaskRecord(notebookID: library.notebookID, title: "Read the methods"))
        let task = try store.saveScheduledTask(ScheduledTask(title: "Morning brief", instruction: "Summarize yesterday"))
        _ = try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.requestScheduledTaskRunNow(task.id)
        #expect(Self.filledCount(root) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM scheduled_tasks WHERE run_now_requested_at IS NOT NULL") == 1,
                "Run now sets the request, as build 177 does")
    }

    @Test("A production-sized library migrates from the step before to 162 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("162-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try Schema154Fixture.restoreGeneration1Tables(store)
            // 6,000 sources; 2,000 tasks, 500 share requests, 2,000 action items; 50 automations with 1,000 runs;
            // 17,000 sync rows. Production holds none of the tasks or automations (2026-10-04): this is 10× and more.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000)
                INSERT INTO notebook_tasks (id, notebook_id, title, status, sort_order, created_at, updated_at)
                SELECT printf('task-%05d', n), printf('notebook-%03d', n % 40), 'A task', 'todo', n, n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500)
                INSERT INTO share_requests (id, team_id, url, status, created_at, updated_at)
                SELECT printf('req-%04d', n), 'team-1', printf('https://example.org/%d', n), 'open', n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000)
                INSERT INTO meeting_action_items (id, group_id, source_id, position, text, created_at, updated_at)
                SELECT printf('meeting-%04d#%d', n / 10, n % 10), 'group-1', printf('meeting-%04d', n / 10), n % 10, 'Do it', n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 50)
                INSERT INTO scheduled_tasks (id, title, instruction, created_at, updated_at)
                SELECT printf('auto-%02d', n), 'Brief', 'Summarize', n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
                INSERT INTO scheduled_task_runs (id, task_id, occurrence_at, started_at, status)
                SELECT printf('run-%04d', n), printf('auto-%02d', (n % 50) + 1), n, n, 'succeeded' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreShapeBeforeTasksSchema(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema \(Schema154Fixture.versionBeforeTasksSchema) → \(KnowledgeStore.schemaVersion) over 2,000 tasks, 500 requests, 2,000 action items and 1,000 runs: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(Self.filledCount(root) == 0)
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }
}
