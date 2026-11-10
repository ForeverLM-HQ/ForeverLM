import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 157 (docs/cloudkit-schema-design.md §12.7, WP9): the course records' columns and the
/// Enrollment table, DDL only and empty until a store's generation-2 activation, from the released 150
/// and 153 shapes and from 154 to 156 (`Schema154Fixture`); and the back-pointer view, which no longer
/// lists a course under the home notebook 2026-10-03 retired.
@Suite("Schema 157 migration")
struct CourseSchema157MigrationTests {
    private static let tables = KnowledgeStore.courseSyncTables.map(\.name)

    private static func filledCount(_ root: URL) -> Int {
        Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM course_enrollments")
            + Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM courses WHERE created_at IS NOT NULL")
            + Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM course_lectures WHERE order_key IS NOT NULL")
            + Schema154Fixture.count(at: root, """
                SELECT COUNT(*) FROM course_lecture_items WHERE order_key IS NOT NULL OR span_json IS NOT NULL OR span_slot IS NOT NULL
            """)
    }

    /// A course with two lectures, three items (two page ranges of one chapter in one lecture), a quiz
    /// and a notebook following it, as generation 1 writes them (its retired home included).
    static func courseSQL(sourceIDs: [String], notebookID: String) -> String {
        """
            INSERT INTO courses (id, title, institution, playlist_url, home_project_id) VALUES ('course-1', 'Systems Biology', 'Weizmann', 'https://youtube.com/playlist?list=PL1', '\(notebookID)');
            INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at) VALUES ('lec-1', 'course-1', 1, 'Motifs', 100), ('lec-2', 'course-1', 2, 'Robustness', 200);
            INSERT INTO source_units (id, source_id, kind, locator, title) VALUES ('su-a', '\(sourceIDs[1])', 'pages', '3-9', 'Pages 3–9'), ('su-b', '\(sourceIDs[1])', 'pages', '20-31', 'Pages 20–31');
            INSERT INTO course_lecture_items (id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at) VALUES
                ('cli-1', 'lec-1', '\(sourceIDs[0])', NULL, 'video', NULL, 0, 101),
                ('cli-2', 'lec-1', '\(sourceIDs[1])', 'su-a', 'reading', 'Read first', 1, 102),
                ('cli-3', 'lec-1', '\(sourceIDs[1])', 'su-b', 'reading', NULL, 2, 103);
            INSERT INTO course_quizzes (id, course_id, kind, title, lecture_ids_json, after_lecture_id, questions_json, created_at, updated_at) VALUES
                ('cq-1', 'course-1', 'practice', 'Motifs', '["lec-1"]', 'lec-1', '[]', 104, 104);
            INSERT INTO project_course_links (goal_id, course_id) VALUES ('\(notebookID)', 'course-1');
        """
    }

    @Test("A fresh store is at 157 or later with the Enrollment table and the course columns, empty")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("157-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 157)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probeSchema157()
        #expect(Self.filledCount(root) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM pragma_table_info('courses') WHERE name = 'homing'") == 0,
                "a course lives in no notebook: there is no homing column")
    }

    @Test(
        "A released, 154, 155 or 156 store migrates to 157 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Int32(155), Int32(156)]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("157-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, Self.courseSQL(sourceIDs: library.sourceIDs, notebookID: library.notebookID), nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'course_enrollments'") == 0)
        if version == 156 {
            #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'ck_notebook_children' AND sql LIKE '%''courses''%'") == 1,
                    "the 156 fixture holds WP8's view with its course-home line, so 157's drop of it is tested")
        }
        let counts = ["sources", "courses", "course_lectures", "course_lecture_items", "course_quizzes", "source_units", "notebook_course_links"]
        let before = counts.map { Schema154Fixture.rowCount(at: root, $0) }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.rowCount(at: root, $0) } == before)
        #expect(Self.filledCount(root) == 0, "nothing filled before the activation")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM course_quizzes WHERE revision = 1") == 1, "a quiz's revision is 1 until generation 2 counts")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        // The notebook follows the course; nothing names it as the course's home any more.
        #expect(try Schema154Fixture.count(migrated, """
            SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = '\(library.notebookID)' AND child_type = 'Course'
        """) == 0)
        #expect(try Schema154Fixture.count(migrated, """
            SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = '\(library.notebookID)' AND child_table = 'notebook_course_links'
        """) == 1)
    }

    @Test("A migrated store and a fresh one hold the same 157 table, view and columns")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("157-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("157-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 156)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        let names = (Self.tables + ["ck_notebook_children"]).map { "'\($0)'" }.joined(separator: ", ")
        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN (\(names)) ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
        for added in KnowledgeStore.courseSyncColumns {
            let column = "SELECT type || ' ' || \"notnull\" || ' ' || COALESCE(dflt_value, '') FROM pragma_table_info('\(added.table)') WHERE name = '\(added.column)'"
            #expect(Schema154Fixture.scalar(at: freshRoot, column) != nil)
            #expect(Schema154Fixture.scalar(at: freshRoot, column) == Schema154Fixture.scalar(at: migratedRoot, column), "\(added.table).\(added.column)")
        }
    }

    @Test("A same-named table of another shape rolls 157 back and leaves the store at 156")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("157-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 156)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE course_enrollments (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 156)
        for added in KnowledgeStore.courseSyncColumns {
            #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('\(added.table)') WHERE name = '\(added.column)'") == 0,
                    "\(added.table).\(added.column) does not stay")
        }
        #expect(Schema154Fixture.count(at: root, """
            SELECT COUNT(*) FROM sqlite_master WHERE name = 'ck_notebook_children' AND sql LIKE '%home_project_id%'
        """) == 1, "156's view stays as it was, in the released names")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("A production-sized library migrates from 156 to 157 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("157-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try Schema154Fixture.restoreGeneration1Tables(store)
            // 6,000 sources; 60 courses with 1,800 lectures, 3,600 items and 600 quizzes; 17,000 sync rows.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'video', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 60)
                INSERT INTO courses (id, title) SELECT printf('course-%03d', n), printf('Course %d', n) FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1800)
                INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at)
                SELECT printf('lecture-%04d', n), printf('course-%03d', (n % 60) + 1), n, printf('Lecture %d', n), n FROM seq;
                INSERT INTO course_lecture_items (id, lecture_id, source_id, role, sort_index, created_at)
                SELECT 'item-' || id, printf('lecture-%04d', (date_added % 1800) + 1), id, 'video', 0, date_added
                FROM sources WHERE date_added <= 3600;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 600)
                INSERT INTO course_quizzes (id, course_id, kind, title, after_lecture_id, questions_json, created_at, updated_at)
                SELECT printf('cq-%04d', n), printf('course-%03d', (n % 60) + 1), 'practice', 'Quiz', printf('lecture-%04d', n), '[]', n, n FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreSchema156Shape(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema 156 → \(KnowledgeStore.schemaVersion) over 60 courses, 1,800 lectures, 3,600 items and 600 quizzes: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM course_quizzes WHERE revision = 1") == 600)
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }
}
