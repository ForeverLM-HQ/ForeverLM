import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Schema 164 drops the retired word from storage: six tables and thirteen columns that
/// said project say notebook, the indexes that carried the word are made again under the new
/// names, the back-pointer view and the generation-2 outbox follow, and the stored kind values
/// that said 'project' read 'notebook'. What has to hold: a store in every released shape
/// (`Schema154Fixture`, which gives each one the old names) comes up at the current schema with
/// every row under the new names; a store held at 153 for want of room for its rollback copy
/// still gets the new names, since this build's queries use them; a store that already has the
/// new names is left alone; and a table already named like a rename's target rolls the whole
/// migration back.
@Suite("Notebook schema migration", .serialized)
struct NotebookSchemaMigrationTests {

    private static let path = "knowledge.db"

    /// Rows under the old names, written the way a build before schema 164 wrote them.
    private static func seedOldNames(at root: URL, notebookID: String, withOutbox: Bool) throws {
        try SQLiteHandle(path: root.appendingPathComponent(path).path).executeScript("""
            INSERT INTO ideas (id, title, created_at, updated_at) VALUES ('idea-1', 'a thought', 1.0, 1.0);
            INSERT INTO idea_links (idea_id, kind, target_id, added_at) VALUES ('idea-1', 'project', '\(notebookID)', 1.0);
            INSERT INTO project_tasks (id, project_id, title, created_at, updated_at)
            VALUES ('task-1', '\(notebookID)', 'Read the methods', 1.0, 1.0);
            INSERT INTO project_related_project_links (project_id, related_project_id, linked_at) VALUES ('\(notebookID)', 'nb-2', 1.0);
            INSERT INTO journal_watch_excluded_projects (project_id, excluded_at) VALUES ('\(notebookID)', 1.0);
        """)
        guard withOutbox else { return }
        try SQLiteHandle(path: root.appendingPathComponent(path).path).executeScript("""
            INSERT INTO ck_outbox (source_table, local_key, record_key_json, op, dirty_at)
            VALUES ('project_tasks', 'task-1', '{}', 'upsert', 1.0);
            INSERT INTO ck_outbox_fields (source_table, local_key, "column", dirty_at)
            VALUES ('project_tasks', 'task-1', 'project_id', 1.0);
        """)
    }

    private static func count(_ root: URL, _ sql: String) -> Int {
        Schema154Fixture.count(at: root, sql)
    }

    private static func tableExists(_ root: URL, _ name: String) -> Bool {
        count(root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") == 1
    }

    private static func columnExists(_ root: URL, table: String, _ column: String) -> Bool {
        count(root, "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)'") == 1
    }

    /// Every table and column under its new name and none under its old one.
    private static func expectNewNames(_ root: URL) {
        for (old, new) in KnowledgeStore.projectStorageTableRenames {
            #expect(tableExists(root, new), "\(new) exists")
            #expect(!tableExists(root, old), "\(old) is gone")
        }
        for (table, old, new) in KnowledgeStore.projectStorageColumnRenames {
            #expect(columnExists(root, table: table, new), "\(table).\(new) exists")
            #expect(!columnExists(root, table: table, old), "\(table).\(old) is gone")
        }
    }

    @Test(
        "A store in a released shape comes up at the current schema with its notebook rows under the new names",
        arguments: [Int32(148), Int32(150), Int32(153), Int32(154), Int32(156), Schema154Fixture.versionBeforeNotebookNames]
    )
    func forwardMigration(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("notebook-names-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version)
        try Self.seedOldNames(at: root, notebookID: library.notebookID, withOutbox: version >= 154)
        #expect(Self.count(root, "PRAGMA user_version") == Int(version))
        #expect(Self.tableExists(root, "project_tasks"))
        #expect(Self.tableExists(root, "project_files"))
        #expect(!Self.tableExists(root, "notebook_tasks"))
        #expect(Self.count(root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_project_files_project'") == 1)

        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)

        #expect(Self.count(root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        Self.expectNewNames(root)
        for index in ["idx_courses_home_notebook", "idx_notebook_tasks_notebook", "idx_notebook_tasks_team", "idx_notebook_files_notebook"] {
            #expect(Self.count(root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = '\(index)'") == 1, "\(index) exists")
        }
        // Nothing in the schema still says project (projection and unprojected are other words).
        #expect(Self.count(root, """
            SELECT COUNT(*) FROM sqlite_master
            WHERE (name LIKE '%project%' OR sql LIKE '%project%')
              AND name NOT LIKE '%projection%' AND name NOT LIKE '%unprojected%'
              AND COALESCE(sql, '') NOT LIKE '%source_projection%' AND COALESCE(sql, '') NOT LIKE '%ck_unprojected%'
        """) == 0)
        // Rows survived, and the stored kind values read as the app reads them.
        #expect(Self.count(root, "SELECT COUNT(*) FROM notebook_tasks WHERE notebook_id = '\(library.notebookID)'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM notebook_files WHERE notebook_id = '\(library.notebookID)'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM notebook_related_notebook_links WHERE notebook_id = '\(library.notebookID)' AND related_notebook_id = 'nb-2'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM journal_watch_excluded_notebooks WHERE notebook_id = '\(library.notebookID)'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM idea_links WHERE kind = 'notebook' AND target_id = '\(library.notebookID)'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM idea_links WHERE kind = 'project'") == 0)
        #expect(try store.loadNotebookTasks(notebookID: library.notebookID).map(\.id) == ["task-1"])
        // The back-pointer view names the new tables in its rows.
        #expect(Self.count(root, "SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = '\(library.notebookID)' AND child_table = 'notebook_tasks'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = '\(library.notebookID)' AND child_table = 'notebook_files'") == 1)
        #expect(Self.count(root, "SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = '\(library.notebookID)' AND child_type = 'Idea'") == 1)
        if version >= 154 {
            #expect(Self.count(root, "SELECT COUNT(*) FROM ck_outbox WHERE source_table = 'notebook_tasks' AND local_key = 'task-1'") == 1)
            #expect(Self.count(root, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'notebook_tasks' AND \"column\" = 'notebook_id'") == 1)
            #expect(Self.count(root, "SELECT COUNT(*) FROM ck_outbox WHERE source_table LIKE 'project%'") == 0)
        }
    }

    @Test(
        "A store held at 153 for want of room still gets the notebook names, and its later launch with room finishes the indexes",
        arguments: [Int32(150), Int32(153)]
    )
    func heldBelow154(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("notebook-names-held-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { LibraryUpgradeSpace.record(nil) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version)
        try Self.seedOldNames(at: root, notebookID: library.notebookID, withOutbox: false)

        Schema154Fixture.newLaunch(root)
        let waiting = try KnowledgeStore(storeDirectory: root, freeSpace: { _ in 1_500_000_000 })
        #expect(waiting.upgradeWaitingForSpace != nil)
        #expect(Self.count(root, "PRAGMA user_version") == 153)
        Self.expectNewNames(root)
        #expect(try waiting.loadNotebookTasks(notebookID: library.notebookID).map(\.id) == ["task-1"])
        #expect(Self.count(root, "SELECT COUNT(*) FROM idea_links WHERE kind = 'notebook'") == 1)

        // A second launch, still short of room, has nothing left to rename.
        Schema154Fixture.newLaunch(root)
        _ = try KnowledgeStore(storeDirectory: root, freeSpace: { _ in 1_500_000_000 })
        #expect(Self.count(root, "PRAGMA user_version") == 153)

        Schema154Fixture.newLaunch(root)
        let later = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Self.count(root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        Self.expectNewNames(root)
        #expect(Self.count(root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx\\_%project%' ESCAPE '\\' AND name NOT LIKE '%unprojected%'") == 0)
        #expect(Self.count(root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_notebook_tasks_notebook'") == 1)
        #expect(try later.loadNotebookTasks(notebookID: library.notebookID).map(\.id) == ["task-1"])
    }

    @Test("A current store is left as it is, and opens again without a second rename")
    func currentStoreIsUntouched() throws {
        let root = try Schema154Fixture.temporaryRoot("notebook-names-current")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: nil)
        try SQLiteHandle(path: root.appendingPathComponent(Self.path).path).executeScript("""
            INSERT INTO notebook_tasks (id, notebook_id, title, created_at, updated_at)
            VALUES ('task-1', '\(library.notebookID)', 'Read the methods', 1.0, 1.0);
        """)
        Schema154Fixture.newLaunch(root)
        _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Self.count(root, "SELECT COUNT(*) FROM notebook_tasks") == 1)
        #expect(Self.count(root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        Self.expectNewNames(root)
    }

    @Test("A table already named like a rename's target rolls the whole migration back")
    func foreignTableRollsBack() throws {
        let root = try Schema154Fixture.temporaryRoot("notebook-names-clash")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: Schema154Fixture.versionBeforeNotebookNames)
        try Self.seedOldNames(at: root, notebookID: library.notebookID, withOutbox: false)
        try SQLiteHandle(path: root.appendingPathComponent(Self.path).path).executeScript(
            "CREATE TABLE notebook_tasks (id TEXT PRIMARY KEY);"
        )
        Schema154Fixture.newLaunch(root)
        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Self.count(root, "PRAGMA user_version") == Int(Schema154Fixture.versionBeforeNotebookNames))
        #expect(Self.tableExists(root, "project_tasks"))
        #expect(Self.tableExists(root, "project_files"))
        #expect(Self.count(root, "SELECT COUNT(*) FROM idea_links WHERE kind = 'project'") == 1)
    }

    @Test("Device-local preference keys that said project move once, and the choice survives")
    func preferenceKeysAdopted() throws {
        let suiteName = "foreverlm.notebook-keys.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for (old, _) in LegacyIdentityAdoption.retiredNotebookPreferenceKeys {
            defaults.set("nb-\(old.count)", forKey: old)
        }
        let moves = LegacyIdentityAdoption.retiredNotebookPreferenceKeys
        #expect(LegacyIdentityAdoption.adoptRetiredNotebookPreferenceKeysIfNeeded(defaults: defaults) == moves.count)
        for (old, new) in moves {
            #expect(defaults.string(forKey: new) == "nb-\(old.count)", "\(new)")
            #expect(defaults.object(forKey: old) == nil, "\(old)")
        }
        // Once: a later launch moves nothing, and never overwrites a newer choice.
        defaults.set("nb-3", forKey: "studio.activeMCPNotebookID")
        defaults.set("nb-9", forKey: "studio.activeMCPProjectID")
        #expect(LegacyIdentityAdoption.adoptRetiredNotebookPreferenceKeysIfNeeded(defaults: defaults) == 0)
        #expect(defaults.string(forKey: "studio.activeMCPNotebookID") == "nb-3")
    }

    @Test("A window snapshot written before the rename still reopens its notebook, and a saved Projects tab shows the Space")
    func savedLayoutsStillRead() throws {
        let old = Data(#"{"projectID":"nb-7","showsChat":true,"sourcesCollapsed":false}"#.utf8)
        let workspace = try JSONDecoder().decode(NotebookWorkspace.self, from: old)
        #expect(workspace.notebookID == "nb-7")
        let reencoded = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
        #expect(reencoded.contains("\"notebookID\":\"nb-7\""))
        #expect(!reencoded.contains("projectID"))

        let groups = try #require(StudioCenterTabGroups.fromPersisted(["chat|projects*|reader"]))
        let tabs = groups.groups.flatMap(\.tabs)
        #expect(tabs.contains(.artifacts))
        #expect(groups.groups[0].activeTab == .artifacts, "the retired tab was the active one")
    }

    @Test("A payload saved in iCloud before the rename reads with this build's keys, and nothing else in it changes")
    func retiredPayloadKeys() throws {
        let saved = Data(#"{"goal":{"id":"nb-1","parentProjectID":"nb-0","relatedProjectIDs":["nb-2"],"title":"My project notes","projection":"kept"},"artifact":{"homeProjectID":"nb-1","homeNotebookID":"nb-9"},"byID":{"project-1":1}}"#.utf8)
        let current = RetiredNotebookWording.currentPayload(saved)
        let object = try #require(try JSONSerialization.jsonObject(with: current) as? [String: Any])
        let goal = try #require(object["goal"] as? [String: Any])
        #expect(goal["parentNotebookID"] as? String == "nb-0")
        #expect(goal["relatedNotebookIDs"] as? [String] == ["nb-2"])
        #expect(goal["parentProjectID"] == nil)
        #expect(goal["title"] as? String == "My project notes", "values never change")
        #expect(goal["projection"] as? String == "kept")
        // A key already under its current name wins over its retired twin.
        let artifact = try #require(object["artifact"] as? [String: Any])
        #expect(artifact["homeNotebookID"] as? String == "nb-9")
        #expect(artifact.count == 1)
        #expect((object["byID"] as? [String: Any])?["project-1"] as? Int == 1, "a key that is not an identifier is data")
        let fresh = Data(#"{"goal":{"parentNotebookID":"nb-0"}}"#.utf8)
        #expect(RetiredNotebookWording.currentPayload(fresh) == fresh, "a current payload is returned byte for byte")

        // The kind values an Idea's links and a Direction's home were saved under.
        let kinds = try JSONDecoder().decode([IdeaLinkKind].self, from: Data(#"["project","notebook","goal"]"#.utf8))
        #expect(kinds == [.notebook, .notebook, .goal])
        #expect(try JSONDecoder().decode(DirectionHomeKind.self, from: Data(#""project""#.utf8)) == .notebook)
        #expect(String(decoding: try JSONEncoder().encode([IdeaLinkKind.notebook]), as: UTF8.self) == #"["notebook"]"#)
    }
}
