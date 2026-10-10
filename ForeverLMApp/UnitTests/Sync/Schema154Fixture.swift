import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Stores in the shapes released builds left, for the schema-154 suites: 150 (builds 176 to 178),
/// 149 (builds 168 to 175) and 148 (build 167), and 153, which no build has released but a bug-fix
/// release from `main` would leave. 150 and 153 share one shape: 151 to 153 changed no DDL, and on
/// 2026-10-03 the production store (150) and the Dev store (153) held byte-identical `sqlite_master`.
/// A library is made with today's code and then given that shape: the `ck_*` tables, the wire columns
/// and the notebook's v2 columns go, the per-member tables are rebuilt from their released definitions,
/// verbatim from the production store, foreign keys and all, and below 150 the columns 149 and 150
/// added go too, as `Schema150MigrationTests` takes them away.
enum Schema154Fixture {
    static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Schema154-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Room enough for any copy, for opens that are not about the disk.
    static let roomy: (URL) throws -> Int64? = { _ in 1_000_000_000_000 }

    /// The next launch for the store in `root`: its next open decides about the rollback copy afresh,
    /// as a new process would, instead of following this launch's decision (`KnowledgeStoreOpening`).
    static func newLaunch(_ root: URL) {
        KnowledgeStoreOpening.startNewLaunchForTesting(databaseAt: root.appendingPathComponent("knowledge.db").path)
    }

    /// One value through a connection of its own, read-only. A rollback copy is opened immutable, as
    /// the app reads one, so reading it creates no side file.
    static func scalar(at root: URL, _ sql: String, file: String = "knowledge.db") -> String? {
        var database: OpaquePointer?
        let path = root.appendingPathComponent(file).path
        let opened = file == "knowledge.db"
            ? sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
            : sqlite3_open_v2("file:\(path)?immutable=1", &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    static func count(at root: URL, _ sql: String, file: String = "knowledge.db") -> Int {
        Int(scalar(at: root, sql, file: file) ?? "") ?? -1
    }

    static func count(_ store: KnowledgeStore, _ sql: String) throws -> Int {
        Int(try store.scalarInteger(sql) ?? -1)
    }

    /// The per-member tables as builds up to 178 created them, verbatim from production's
    /// `sqlite_master`, each followed by its indexes.
    static let releasedPerMemberTables: [(name: String, statements: [String])] = [
        ("source_highlights", ["""
            CREATE TABLE source_highlights (
                    highlight_id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    page_index INTEGER NOT NULL CHECK(page_index >= 0),
                    quads_json TEXT NOT NULL,
                    text TEXT NOT NULL,
                    color TEXT NOT NULL,
                    note TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                , anchor_prefix TEXT, anchor_suffix TEXT, anchor_offset INTEGER, chat_session_id TEXT, references_json TEXT, publication_update TEXT, publication_update_at REAL)
            """, """
            CREATE INDEX idx_source_highlights_source_page
                ON source_highlights(source_id, page_index, created_at)
            """]),
        ("hidden_sources", ["""
            CREATE TABLE hidden_sources (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    hidden_at REAL NOT NULL
                )
            """]),
        ("hidden_podcast_episodes", ["""
            CREATE TABLE hidden_podcast_episodes (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    hidden_at REAL NOT NULL
                )
            """]),
        ("visible_podcast_episode_overrides", ["""
            CREATE TABLE visible_podcast_episode_overrides (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    visible_at REAL NOT NULL
                )
            """]),
        ("visible_youtube_video_overrides", ["""
            CREATE TABLE visible_youtube_video_overrides (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    visible_at REAL NOT NULL
                )
            """]),
        ("source_understanding", ["""
            CREATE TABLE source_understanding (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    relative_path TEXT NOT NULL,
                    derived_through_session_id TEXT,
                    generated_at REAL NOT NULL,
                    generator_version INTEGER NOT NULL,
                    body_sha256 TEXT NOT NULL,
                    open_thread_count INTEGER NOT NULL DEFAULT 0
                , discussed_idea_ids TEXT NOT NULL DEFAULT '[]')
            """]),
        ("notebook_files", ["""
            CREATE TABLE notebook_files (
                    id TEXT PRIMARY KEY,
                    notebook_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                    relative_path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content_type TEXT,
                    size_bytes INTEGER NOT NULL DEFAULT 0,
                    modified_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    UNIQUE(notebook_id, relative_path)
                )
            """,
            "CREATE INDEX idx_notebook_files_notebook ON notebook_files(notebook_id)",
            "CREATE INDEX idx_notebook_files_notebook_role ON notebook_files(notebook_id, role)",
        ]),
    ]

    struct UnsupportedVersion: Error {
        let version: Int32
    }

    /// Gives a store made by today's code the released shape of `version` (148 to 153) and stamps it.
    static func restoreReleasedShape(_ store: KnowledgeStore, version: Int32) throws {
        guard (148...153).contains(version) else { throw UnsupportedVersion(version: version) }
        try store.execForTesting("PRAGMA legacy_alter_table = ON")
        try restoreSchema154Shape(store)
        for table in KnowledgeStore.replicaTables {
            try store.execForTesting("DROP TABLE \(table.name)")
        }
        for table in KnowledgeStore.wireKeyedTables {
            try store.execForTesting("""
                DROP INDEX idx_\(table)_wire_key;
                ALTER TABLE \(table) DROP COLUMN wire_key;
                ALTER TABLE \(table) DROP COLUMN wire_id;
            """)
        }
        for column in ["moved_to", "moving_to", "fold_kind", "merged_into", "entity_kind"] {
            try store.execForTesting("ALTER TABLE learning_goals DROP COLUMN \(column)")
        }
        for table in releasedPerMemberTables {
            let columns = try store.tableColumnNames(table.name).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
            try store.execForTesting("ALTER TABLE \(table.name) RENAME TO \(table.name)__v154")
            try store.execForTesting(table.statements[0])
            try store.execForTesting("INSERT INTO \(table.name) (\(columns)) SELECT \(columns) FROM \(table.name)__v154")
            // Dropping the renamed table frees its index names for the released indexes.
            try store.execForTesting("DROP TABLE \(table.name)__v154")
            for index in table.statements.dropFirst() {
                try store.execForTesting(index)
            }
        }
        if version < 150 {
            // 150: a course's notebook, one column and its index.
            try store.execForTesting("""
                DROP INDEX idx_courses_home_notebook;
                ALTER TABLE courses DROP COLUMN home_notebook_id;
            """)
        }
        if version < 149 {
            // 149: a chat's effort and speed.
            try store.execForTesting("""
                ALTER TABLE review_sessions DROP COLUMN model_speed;
                ALTER TABLE review_sessions DROP COLUMN model_effort;
            """)
        }
        try store.execForTesting("PRAGMA user_version = \(version)")
    }

    /// Gives a store made by today's code schema 154's shape: 155's tables go (DDL only, so nothing
    /// else differs) and the store is stamped 154.
    static func restoreSchema154Shape(_ store: KnowledgeStore) throws {
        try restoreSchema155Shape(store)
        for table in KnowledgeStore.sourceSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        try store.execForTesting("PRAGMA user_version = 154")
    }

    /// Gives a store made by today's code schema 155's shape: 156's view, tables and order key go (DDL
    /// only, so nothing else differs) and the store is stamped 155.
    static func restoreSchema155Shape(_ store: KnowledgeStore) throws {
        try restoreSchema156Shape(store)
        try store.execForTesting("DROP VIEW IF EXISTS ck_notebook_children")
        for table in KnowledgeStore.notebookSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        if try store.tableColumnNames("learning_goal_items").contains("order_key") {
            try store.execForTesting("ALTER TABLE learning_goal_items DROP COLUMN order_key")
        }
        try store.execForTesting("PRAGMA user_version = 155")
    }

    /// Schema 156's back-pointer view as WP8 made it, a course listed under its home notebook (the home
    /// 2026-10-03 retired, which 157's view leaves out).
    static let released156ChildrenView = KnowledgeStore.notebookChildrenView.replacingOccurrences(
        // The literal in `notebookChildrenView` is indented 4 spaces once Swift strips its closing delimiter's indent.
        of: "\n    UNION ALL SELECT parent_notebook_id, 'Goal'",
        with: "\n    UNION ALL SELECT home_notebook_id, 'Course', 'courses', id FROM courses WHERE home_notebook_id IS NOT NULL\n    UNION ALL SELECT parent_notebook_id, 'Goal'"
    )

    /// Gives a store made by today's code schema 156's shape: 163's, 162's, 161's and 160's tables,
    /// 159's tables and column, 158's columns and 157's table and columns go, the view is WP8's again
    /// (DDL only, so nothing else differs), and the store is stamped 156.
    static func restoreSchema156Shape(_ store: KnowledgeStore) throws {
        try restoreShapeBeforeChatSchema(store)
        try store.execForTesting("DROP VIEW IF EXISTS ck_notebook_children")
        for table in KnowledgeStore.courseSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        for added in KnowledgeStore.courseSyncColumns.reversed() {
            guard try store.tableColumnNames(added.table).contains(added.column) else { continue }
            try store.execForTesting("ALTER TABLE \(added.table) DROP COLUMN \(added.column)")
        }
        try store.execForTesting(released156ChildrenView)
        try store.execForTesting("PRAGMA user_version = 156")
    }

    /// The version a store has just before schema 158 (WP10): 157, WP9's courses.
    static let versionBeforeChatSchema: Int32 = 157

    /// Gives a store made by today's code the shape it had before 158: 161's and 160's tables, 159's
    /// tables and column and the chat columns go (DDL only, so nothing else differs) and the store is
    /// stamped `versionBeforeChatSchema`.
    static func restoreShapeBeforeChatSchema(_ store: KnowledgeStore) throws {
        try restoreShapeBeforeArtifactSchema(store)
        for column in KnowledgeStore.chatSyncColumns.reversed() {
            guard try store.tableColumnNames(column.table).contains(column.name) else { continue }
            try store.execForTesting("ALTER TABLE \(column.table) DROP COLUMN \(column.name)")
        }
        try store.execForTesting("PRAGMA user_version = \(versionBeforeChatSchema)")
    }

    /// The version a store has just before schema 159 (WP11): 158, WP10's chats.
    static let versionBeforeArtifactSchema: Int32 = 158

    /// Gives a store made by today's code the shape it had before 159: 161's and 160's tables, 159's
    /// tables and `global_artifacts.body_ref` go (DDL only, so nothing else differs) and the store is
    /// stamped `versionBeforeArtifactSchema`.
    static func restoreShapeBeforeArtifactSchema(_ store: KnowledgeStore) throws {
        try restoreShapeBeforeReadingSchema(store)
        for table in KnowledgeStore.artifactSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        if try store.tableColumnNames("global_artifacts").contains("body_ref") {
            try store.execForTesting("ALTER TABLE global_artifacts DROP COLUMN body_ref")
        }
        try store.execForTesting("PRAGMA user_version = \(versionBeforeArtifactSchema)")
    }

    /// The version a store has just before schema 160 (WP12): 159, WP11's Artifacts.
    static let versionBeforeReadingSchema: Int32 = 159

    /// Gives a store made by today's code the shape it had before 160: 161's tables and 160's table go
    /// (DDL only, so nothing else differs) and the store is stamped `versionBeforeReadingSchema`.
    static func restoreShapeBeforeReadingSchema(_ store: KnowledgeStore) throws {
        // A generation-2 store's source view reads `reading_states`, and SQLite refuses every DROP COLUMN
        // below while a view names a table that is gone. The next open makes the view again.
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try restoreShapeBeforeMemorySchema(store)
        for table in KnowledgeStore.readingSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        // The view of a store from before 160, which reads the sources columns.
        try store.execForTesting(KnowledgeStore.sourceProjectionViewSQL(sourceColumnNames: try store.tableColumnNames("sources"), readingStates: false))
        try store.execForTesting("PRAGMA user_version = \(versionBeforeReadingSchema)")
    }

    /// The version a store has just before schema 161 (WP13): 160, WP12's reading state.
    static let versionBeforeMemorySchema: Int32 = 160

    /// Gives a store made by today's code the shape it had before 161: 162's table and columns and 161's
    /// tables go (DDL only, so nothing else differs) and the store is stamped `versionBeforeMemorySchema`.
    static func restoreShapeBeforeMemorySchema(_ store: KnowledgeStore) throws {
        try restoreShapeBeforeTasksSchema(store)
        for table in KnowledgeStore.memorySyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        try store.execForTesting("PRAGMA user_version = \(versionBeforeMemorySchema)")
    }

    /// The version a store has just before schema 162 (WP14): 161, WP13's memory records.
    static let versionBeforeTasksSchema: Int32 = 161

    /// Gives a store made by today's code the shape it had before 162: 163's tables and 162's table and
    /// columns go (DDL only, so nothing else differs) and the store is stamped `versionBeforeTasksSchema`.
    static func restoreShapeBeforeTasksSchema(_ store: KnowledgeStore) throws {
        try restoreShapeBeforePersonalStateSchema(store)
        for table in KnowledgeStore.tasksSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        for added in KnowledgeStore.tasksSyncColumns.reversed() {
            guard try store.tableColumnNames(added.table).contains(added.column) else { continue }
            try store.execForTesting("ALTER TABLE \(added.table) DROP COLUMN \(added.column)")
        }
        try store.execForTesting("PRAGMA user_version = \(versionBeforeTasksSchema)")
    }

    /// The version a store has just before schema 163 (WP12b): 162, WP14's tasks.
    static let versionBeforePersonalStateSchema: Int32 = 162

    /// Gives a store made by today's code the shape it had before 163: its Device and import-blocked
    /// tables go (DDL only, so nothing else differs) and the store is stamped
    /// `versionBeforePersonalStateSchema`.
    static func restoreShapeBeforePersonalStateSchema(_ store: KnowledgeStore) throws {
        for table in KnowledgeStore.personalStateSyncTables {
            try store.execForTesting("DROP TABLE IF EXISTS \(table.name)")
        }
        try store.execForTesting("PRAGMA user_version = \(versionBeforePersonalStateSchema)")
    }

    struct Library {
        let sourceIDs: [String]
        let notebookID: String
    }

    /// Writes a source's every kind of per-member row, as the Reader, the hide filters and the day
    /// close leave them.
    static func addPerMemberRows(_ store: KnowledgeStore, sourceID: String) throws {
        try store.execForTesting("""
            INSERT INTO source_highlights (highlight_id, source_id, page_index, quads_json, text, color, note,
                created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset, publication_update)
            VALUES ('hl-\(sourceID)', '\(sourceID)', 3, '[]', 'A passage, quoted', 'yellow', 'my note', 1, 2,
                'before', 'after', 120, 'since then');
            INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('\(sourceID)', 10);
            INSERT INTO hidden_podcast_episodes (source_id, hidden_at) VALUES ('\(sourceID)', 11);
            INSERT INTO visible_podcast_episode_overrides (source_id, visible_at) VALUES ('\(sourceID)', 12);
            INSERT INTO visible_youtube_video_overrides (source_id, visible_at) VALUES ('\(sourceID)', 13);
            INSERT INTO source_understanding (source_id, relative_path, derived_through_session_id, generated_at,
                generator_version, body_sha256, open_thread_count, discussed_idea_ids)
            VALUES ('\(sourceID)', 'Understanding/\(sourceID).md', 'chat-1', 3, 2, 'abc', 1, '["idea-1"]');
        """)
    }

    /// A library of `sourceCount` articles, the first two with every kind of per-member row, and a
    /// notebook holding the first source and one workspace file; at `version` in the released
    /// shape when given one (154 to 162 drop only the later steps' DDL), else at the current schema.
    @discardableResult
    static func makeLibrary(at root: URL, version: Int32?, sourceCount: Int = 3, generation: SyncGeneration = .one) throws -> Library {
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: generation, freeSpace: roomy)
        var sourceIDs: [String] = []
        for index in 0..<sourceCount {
            var article = StudioArticle(url: "https://example.org/schema154/\(index)", title: "Paper \(index)", sourceType: .article)
            try store.insertSourceIfNew(&article)
            sourceIDs.append(article.id)
        }
        for sourceID in sourceIDs.prefix(2) {
            try addPerMemberRows(store, sourceID: sourceID)
        }
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria", topic: "Mitochondria", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: Array(sourceIDs.prefix(1))
        )
        try store.execForTesting("""
            INSERT INTO notebook_files (id, notebook_id, relative_path, name, role, content_type, size_bytes, modified_at, created_at)
            VALUES ('file-1', '\(notebook.id)', 'Projects/\(notebook.id)/data.tsv', 'data.tsv', 'file', 'text/tab-separated-values', 42, 4, 5)
        """)
        try store.clearAllPendingSyncChanges()
        if version == versionBeforePersonalStateSchema {
            try restoreShapeBeforePersonalStateSchema(store)
        } else if version == versionBeforeTasksSchema {
            try restoreShapeBeforeTasksSchema(store)
        } else if version == versionBeforeMemorySchema {
            try restoreShapeBeforeMemorySchema(store)
        } else if version == versionBeforeReadingSchema {
            try restoreShapeBeforeReadingSchema(store)
        } else if version == versionBeforeArtifactSchema {
            try restoreShapeBeforeArtifactSchema(store)
        } else if version == versionBeforeChatSchema {
            try restoreShapeBeforeChatSchema(store)
        } else if version == 156 {
            try restoreSchema156Shape(store)
        } else if version == 155 {
            try restoreSchema155Shape(store)
        } else if version == 154 {
            try restoreSchema154Shape(store)
        } else if version == versionBeforeNotebookNames {
            try store.execForTesting("PRAGMA user_version = \(versionBeforeNotebookNames)")
        } else if let version {
            try restoreReleasedShape(store, version: version)
        }
        if version != nil {
            try restoreProjectStorageNames(store)
        }
        return Library(sourceIDs: sourceIDs, notebookID: notebook.id)
    }

    /// The name a table is stored under in the store at `root`: the released name while the store is
    /// before schema 164 (a table 164 renamed), else the name it has now. A read of a store that may be
    /// on either side of that step names the table once and lets this say which.
    static func storedName(at root: URL, _ table: String) -> String {
        guard let released = KnowledgeStore.projectStorageTableRenames.first(where: { $0.new == table })?.old,
              count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") != 1
        else { return table }
        return released
    }

    /// The name today's schema gives an object a released store holds under its old name: a table 164
    /// renamed, or an index or an automatic index on one, which says notebook where it said project.
    static func currentName(_ released: String) -> String {
        if let renamed = KnowledgeStore.projectStorageTableRenames.first(where: { $0.old == released })?.new {
            return renamed
        }
        let isIndex = released.hasPrefix("idx_") || released.hasPrefix("sqlite_autoindex_")
        guard isIndex, !released.contains("projection"), !released.contains("unprojected") else { return released }
        var name = released
        for (old, new) in KnowledgeStore.projectStorageTableRenames {
            name = name.replacingOccurrences(of: old, with: new)
        }
        return name.replacingOccurrences(of: "project", with: "notebook")
    }

    /// A table's row count, under whichever name the store at `root` holds it.
    static func rowCount(at root: URL, _ table: String) -> Int {
        count(at: root, "SELECT COUNT(*) FROM \(storedName(at: root, table))")
    }

    /// Every per-member row as text, for comparing two stores or two moments. A table is labelled
    /// by its current name and its columns ordered by the current names, so a store before
    /// schema 164 and one after it give the same text for the same rows.
    static func perMemberRows(at root: URL) -> [String] {
        var rows: [String] = []
        var database: OpaquePointer?
        let path = root.appendingPathComponent("knowledge.db").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return [] }
        defer { sqlite3_close(database) }
        for label in releasedPerMemberTables.map(\.name) {
            let table = storedName(at: root, label)
            var columns: [String] = []
            var statement: OpaquePointer?
            sqlite3_prepare_v2(database, "SELECT name FROM pragma_table_info('\(table)') ORDER BY replace(name, 'project', 'notebook')", -1, &statement, nil)
            while sqlite3_step(statement) == SQLITE_ROW { columns.append(String(cString: sqlite3_column_text(statement, 0))) }
            sqlite3_finalize(statement)
            let concat = columns.map { "quote(\"\($0)\")" }.joined(separator: " || '|' || ")
            sqlite3_prepare_v2(database, "SELECT '\(label)|' || \(concat) FROM \(table) ORDER BY 1", -1, &statement, nil)
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
            sqlite3_finalize(statement)
        }
        return rows
    }

    /// The foreign keys a table holds, under whichever name the store at `root` holds it.
    static func foreignKeyCount(at root: URL, _ table: String) -> Int {
        count(at: root, "SELECT COUNT(*) FROM pragma_foreign_key_list('\(storedName(at: root, table))')")
    }

    /// The version a store has just before schema 164, the notebook names: every released
    /// store before it holds the tables and columns that said project.
    static let versionBeforeNotebookNames: Int32 = 163

    /// Gives a store made by today's code the storage names every build before schema 164
    /// wrote: the tables and columns that said project, their indexes under the old names, the
    /// back-pointer view naming the old tables, and the kind values that said 'project'. The
    /// version stamp is the caller's. The per-member tables above come back under their released
    /// names this way.
    static func restoreProjectStorageNames(_ store: KnowledgeStore) throws {
        try store.execForTesting("PRAGMA legacy_alter_table = OFF")
        let viewSQL = try store.scalarText("SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'ck_notebook_children'")
        if viewSQL != nil {
            try store.execForTesting("DROP VIEW ck_notebook_children")
        }
        var oldTableByNew: [String: String] = [:]
        for (old, new) in KnowledgeStore.projectStorageTableRenames {
            oldTableByNew[new] = old
            guard try store.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(new)'") == 1 else { continue }
            try store.execForTesting("ALTER TABLE \(new) RENAME TO \(old)")
        }
        for (table, old, new) in KnowledgeStore.projectStorageColumnRenames {
            let current = oldTableByNew[table] ?? table
            guard try store.tableColumnNames(current).contains(new) else { continue }
            try store.execForTesting("ALTER TABLE \(current) RENAME COLUMN \(new) TO \(old)")
        }
        // The renames rewrote each index's columns; its name still says notebook.
        let touched = Set(KnowledgeStore.projectStorageTableRenames.map(\.old)
            + KnowledgeStore.projectStorageColumnRenames.map { oldTableByNew[$0.table] ?? $0.table })
        var indexes: [(name: String, sql: String)] = []
        try store.query("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL AND name LIKE '%notebook%'") { statement in
            guard let name = store.string(statement, 0), let table = store.string(statement, 1),
                  let sql = store.string(statement, 2), touched.contains(table) else { return }
            indexes.append((name, sql))
        }
        for index in indexes {
            let oldName = index.name.replacingOccurrences(of: "notebook", with: "project")
            try store.execForTesting("DROP INDEX \(index.name)")
            try store.execForTesting(index.sql.replacingOccurrences(of: index.name, with: oldName))
        }
        if let viewSQL {
            try store.execForTesting(projectStorageView(viewSQL))
        }
        try store.execForTesting("UPDATE idea_links SET kind = 'project' WHERE kind = 'notebook'")
        try store.execForTesting("UPDATE research_directions SET home_kind = 'project' WHERE home_kind = 'notebook'")
    }

    /// A back-pointer view's text as builds before schema 164 made it: the old table names,
    /// in its FROM clauses and in the table names its rows carry, and the old column names.
    static func projectStorageView(_ sql: String) -> String {
        var text = sql
        for (old, new) in KnowledgeStore.projectStorageTableRenames {
            text = text.replacingOccurrences(of: new, with: old)
        }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            for (table, old, new) in KnowledgeStore.projectStorageColumnRenames {
                let current = KnowledgeStore.projectStorageTableRenames.first { $0.new == table }?.old ?? table
                if line.contains("FROM \(current)") {
                    line = line.replacingOccurrences(of: new, with: old)
                }
            }
            return line
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "kind = 'notebook'", with: "kind = 'project'")
    }
}
