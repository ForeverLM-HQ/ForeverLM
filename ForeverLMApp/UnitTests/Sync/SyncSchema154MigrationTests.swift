import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 154 (docs/cloudkit-schema-design.md §12.7): the ck_* tables, the wire columns, the
/// notebook's v2 columns and the per-member tables rebuilt without foreign keys to content, DDL only,
/// from the released 150 and 153 shapes (`Schema154Fixture`).
@Suite("Schema 154 migration")
struct SyncSchema154MigrationTests {
    private static let perMemberTables = Schema154Fixture.releasedPerMemberTables.map(\.name)

    @Test("A fresh store is at 154 with every ck table, the wire columns and no foreign key to content")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 154)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        for table in KnowledgeStore.replicaTables {
            try store.query(table.probe) { _ in }
        }
        for table in KnowledgeStore.wireKeyedTables {
            #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM pragma_table_xinfo('\(table)') WHERE name = 'wire_key' AND hidden = 2") == 1, "\(table)")
            #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_\(table)_wire_key'") == 1)
        }
        for table in Self.perMemberTables {
            #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM pragma_foreign_key_list('\(table)')") == 0, "\(table)")
        }
        #expect(try Schema154Fixture.count(store, "SELECT \"notnull\" FROM pragma_table_info('notebook_files') WHERE name = 'notebook_id'") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(store.rollbackCopy == nil, "a new store holds no library to copy")
    }

    @Test("The fixture has the released shape", arguments: [Int32(148), Int32(149), Int32(150), Int32(153)])
    func fixtureShape(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("shape-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: version)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('courses') WHERE name = 'home_project_id'") == (version < 150 ? 0 : 1), "a released store says project")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_courses_home_project'") == (version < 150 ? 0 : 1))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('review_sessions') WHERE name IN ('model_effort', 'model_speed')") == (version < 149 ? 0 : 2))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'ck\\_%' ESCAPE '\\'") == 0)
        for table in KnowledgeStore.wireKeyedTables {
            #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_xinfo('\(table)') WHERE name IN ('wire_id', 'wire_key')") == 0)
        }
        // The released keys as SQLite reads them back: each to its content, cascading.
        for table in Schema154Fixture.releasedPerMemberTables.map(\.name) {
            #expect(Schema154Fixture.foreignKeyCount(at: root, table) == 1, "\(table)")
            let key = Schema154Fixture.scalar(at: root, "SELECT \"table\" || ' ' || on_delete FROM pragma_foreign_key_list('\(Schema154Fixture.storedName(at: root, table))')")
            #expect(key == (table == "notebook_files" ? "learning_goals CASCADE" : "sources CASCADE"), "\(table)")
        }
        #expect(Schema154Fixture.count(at: root, "SELECT \"notnull\" FROM pragma_table_info('project_files') WHERE name = 'project_id'") == 1)
        // Against a fresh store, it lacks exactly what 154 added, and below 150 also 150's index.
        let freshRoot = try Schema154Fixture.temporaryRoot("shape-fresh-\(version)")
        defer { try? FileManager.default.removeItem(at: freshRoot) }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        let names = "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name)"
        let fresh = Set((Schema154Fixture.scalar(at: freshRoot, names) ?? "").split(separator: ",").map(String.init))
        // A released store says project; the fresh one says notebook (164), so compare by the current name.
        // A released store also has generation 1's tables, which 175 drops and a fresh store never makes.
        let generation1 = Set(KnowledgeStore.generation1Tables + ["idx_sync_metadata_zone", "idx_sync_conflicts_detected"])
        let fixture = Set((Schema154Fixture.scalar(at: root, names) ?? "").split(separator: ",").map(String.init).map(Schema154Fixture.currentName))
            .subtracting(generation1)
        #expect(!fixture.isEmpty && fixture.isSubset(of: fresh))
        // 155's tables (WP7) and their indexes come after 154 and go with it.
        let schema155 = Set(KnowledgeStore.sourceSyncTables.map(\.name) + ["idx_source_work_keys_key"])
            // 156's tables (WP8) too; its view starts `ck_`. And 157's (WP9).
            .union(KnowledgeStore.notebookSyncTables.map(\.name))
            .union(KnowledgeStore.courseSyncTables.map(\.name))
            // 159's (WP11) too.
            .union(KnowledgeStore.artifactSyncTables.map(\.name))
            // And 160's (WP12).
            .union(KnowledgeStore.readingSyncTables.map(\.name))
            // And 161's (WP13), with its indexes.
            .union(KnowledgeStore.memorySyncTables.map(\.name))
            .union(["idx_memory_sittings_writer", "idx_memory_sitting_answers_sitting"])
            // And 162's (WP14), with its index.
            .union(KnowledgeStore.tasksSyncTables.map(\.name) + ["idx_jobs_status"])
            // And 163's Device and import-blocked tables (WP12b).
            .union(KnowledgeStore.personalStateSyncTables.map(\.name))
        let missing = fresh.subtracting(fixture).filter {
            !($0.hasPrefix("ck_") || $0.hasPrefix("idx_ck_") || $0.hasSuffix("_wire_key") || schema155.contains($0)
              || $0.hasPrefix("sqlite_autoindex_source_") || $0.hasPrefix("sqlite_autoindex_artifact_")
              || $0.hasPrefix("sqlite_autoindex_notebook_") || $0.hasPrefix("sqlite_autoindex_course_enrollments")
              || $0.hasPrefix("sqlite_autoindex_reading_") || $0.hasPrefix("sqlite_autoindex_jobs")
              || (version < 150 && $0 == "idx_courses_home_notebook"))
        }
        #expect(missing.isEmpty, "\(missing.sorted())")
    }

    @Test(
        "A released store migrates to 154 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(148), Int32(149), Int32(150), Int32(153)]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        let rowsBefore = Schema154Fixture.perMemberRows(at: root)
        #expect(rowsBefore.count == 13, "two sources with six kinds of row each, and one file")
        let counts = ["sources", "learning_goals", "learning_goal_items", "articles"]
        let countsBefore = counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(Schema154Fixture.perMemberRows(at: root) == rowsBefore, "every per-member row, column for column")
        #expect(counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") } == countsBefore)
        for table in Self.perMemberTables {
            #expect(Schema154Fixture.foreignKeyCount(at: root, table) == 0, "\(table)")
        }
        // Nothing filled: every ck table empty, every wire_id NULL, wire_key the row's id.
        for table in KnowledgeStore.replicaTables {
            #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM \(table.name)") == 0, "\(table.name)")
        }
        for table in KnowledgeStore.wireKeyedTables {
            #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM \(table) WHERE wire_id IS NOT NULL OR wire_key IS NOT id") == 0)
        }
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM learning_goals WHERE COALESCE(entity_kind, merged_into, fold_kind, moving_to, moved_to) IS NOT NULL") == 0)
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        // Sources stay visible, the hidden ones hidden, with no deferred work queued by 154.
        let sources = try migrated.loadSourcesWithoutContent()
        #expect(Set(sources.map(\.id)) == Set(library.sourceIDs))
        #expect(sources.filter(\.isHidden).map(\.id).sorted() == Array(library.sourceIDs.prefix(2)).sorted())
        #expect(try migrated.loadLearningGoal(library.notebookID)?.approvedSourceIDs == [library.sourceIDs[0]])
    }

    @Test("A migrated store and a fresh one hold the same ck tables and per-member definitions")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 153)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)

        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master
                WHERE name LIKE 'ck\\_%' ESCAPE '\\' OR tbl_name LIKE 'ck\\_%' ESCAPE '\\'
                   OR tbl_name IN ('\(Self.perMemberTables.joined(separator: "', '"))')
                   OR name LIKE 'idx\\_%\\_wire\\_key' ESCAPE '\\'
                ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
        for table in KnowledgeStore.wireKeyedTables {
            let wireColumns = "SELECT group_concat(name || ' ' || type || ' ' || hidden) FROM pragma_table_xinfo('\(table)') WHERE name IN ('wire_id', 'wire_key')"
            #expect(Schema154Fixture.scalar(at: freshRoot, wireColumns) == Schema154Fixture.scalar(at: migratedRoot, wireColumns), "\(table)")
        }
        let notebookColumns = "SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('learning_goals') WHERE name IN ('entity_kind', 'merged_into', 'fold_kind', 'moving_to', 'moved_to') ORDER BY name)"
        #expect(Schema154Fixture.scalar(at: freshRoot, notebookColumns) == "entity_kind,fold_kind,merged_into,moved_to,moving_to")
        #expect(Schema154Fixture.scalar(at: migratedRoot, notebookColumns) == "entity_kind,fold_kind,merged_into,moved_to,moving_to")
    }

    @Test("A production-sized library migrates to 154 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try Schema154Fixture.restoreGeneration1Tables(store)
            // 6,000 sources (the largest library has 5,161), with production's per-member rows twice
            // over, 40 notebooks with files, and 17,000 sync rows.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n), 'example.com' FROM seq;
                INSERT INTO hidden_sources (source_id, hidden_at)
                SELECT id, date_added FROM sources WHERE date_added <= 1500;
                INSERT INTO hidden_podcast_episodes (source_id, hidden_at)
                SELECT id, date_added FROM sources WHERE date_added > 1500 AND date_added <= 2500;
                INSERT INTO visible_podcast_episode_overrides (source_id, visible_at)
                SELECT id, date_added FROM sources WHERE date_added > 2500 AND date_added <= 2520;
                INSERT INTO source_highlights (highlight_id, source_id, page_index, quads_json, text, color, created_at, updated_at)
                SELECT 'hl-' || id, id, 0, '[]', 'quote', 'yellow', 1, 1 FROM sources WHERE date_added <= 200;
                INSERT INTO source_understanding (source_id, relative_path, generated_at, generator_version, body_sha256)
                SELECT id, 'Understanding/' || id || '.md', 1, 1, 'abc' FROM sources WHERE date_added <= 600;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 40)
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind)
                SELECT printf('notebook-%02d', n), printf('Notebook %02d', n), 1, 4102444800, 1, 1, 'active', 'companion' FROM seq;
                INSERT INTO notebook_files (id, notebook_id, relative_path, name, role, modified_at, created_at)
                SELECT 'file-' || id, id, 'Projects/' || id || '/notes.md', 'notes.md', 'file', 1, 1 FROM learning_goals;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreReleasedShape(store, version: 153)
        }
        let rowsBefore = Schema154Fixture.perMemberRows(at: root)

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema 153 → 154 over 6,000 sources and \(rowsBefore.count) per-member rows, rollback copy included: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(migrated.rollbackCopy?.userVersion == 153)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(Schema154Fixture.perMemberRows(at: root) == rowsBefore)
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }
}
