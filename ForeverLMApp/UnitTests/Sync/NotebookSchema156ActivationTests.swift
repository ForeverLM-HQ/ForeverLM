import Foundation
import Testing
@testable import ForeverLM

/// Schema 156's activation steps (docs/cloudkit-schema-design.md §13.3 step 3c, WP8): each row's kind,
/// the Entries' order keys, the research questions' rows, the member's NotebookStates from the
/// preference rows and `notebook_resolution`, run twice and after generation-1 edits; and no notes base
/// from the local text (R8-1).
@Suite("Schema 156 activation")
struct NotebookSchema156ActivationTests {
    typealias F = NotebookSyncFixture

    /// A preference row as `PreferenceStore` mirrors one into `user_preferences`.
    static func setPreference(_ store: KnowledgeStore, _ key: String, _ value: Any?) throws {
        guard let value else {
            try store.execute("DELETE FROM user_preferences WHERE key = ?", [.text(key)])
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: ["v": value], format: .xml, options: 0)
        try store.execute("""
            INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, 1)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [.text(key), .text(String(decoding: data, as: UTF8.self))])
    }

    static func runDerivations(_ store: KnowledgeStore) throws {
        for derivation in KnowledgeStore.notebookActivationDerivations { try derivation.run(store) }
    }

    /// What the derivations wrote, as text, to compare two runs.
    static func derived(_ store: KnowledgeStore) throws -> String {
        var lines: [String] = []
        for sql in [
            "SELECT id || '=' || COALESCE(entity_kind, '-') FROM learning_goals ORDER BY id",
            "SELECT goal_id || '/' || source_id || '=' || COALESCE(order_key, '-') FROM learning_goal_items ORDER BY goal_id, source_id",
            "SELECT notebook_id || '/' || id || '=' || text || ',' || status || ',' || order_key || ',' || created_at FROM notebook_research_questions ORDER BY notebook_id, id",
            "SELECT notebook_id || '=' || COALESCE(excluded_json, '') || ',' || COALESCE(context_notebooks_json, '') || ',' || COALESCE(collections_json, '') || ',' || COALESCE(sidebar_key, '') || ',' || COALESCE(pinned, '') || ',' || COALESCE(expanded, '') FROM notebook_states ORDER BY notebook_id",
            "SELECT id || '=' || resolved_id || '@' || resolved_zone FROM notebook_resolution ORDER BY id",
        ] {
            try store.query(sql, []) { row in lines.append(row.text(0) ?? "") }
        }
        return lines.joined(separator: "\n")
    }

    /// A library as generation 1 leaves one: kinds, keys and states not derived yet.
    static func generation1Library(_ store: KnowledgeStore) throws {
        try F.addNotebook(store, "nb-a", title: "A", classify: false)
        try F.addNotebook(store, "nb-b", title: "B", classify: false)
        try store.execute("""
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, parent_notebook_id)
            VALUES ('goal-1', 'Exam', 1, 800000000, 1, 1, 'active', 'companion', 'nb-a')
        """)
        try store.execute("UPDATE learning_goals SET research_questions = ?, created_at = 500 WHERE id = 'nb-a'",
                          [.text(KnowledgeStore.encodeResearchQuestions(["Why?", "How?"]))])
        for (index, source) in ["src-1", "src-2", "src-3"].enumerated() {
            try F.addSource(store, source)
            try store.execute("""
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, review_state, sequence)
                VALUES (?, 'nb-a', ?, ?, 'approved', ?)
            """, [.text("item-\(source)"), .text(source), .real(Double(10 + index)), .real(Double(2 - index))])
        }
        try store.execute("INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at) VALUES ('nb-a', 'nb-b', 1)")
        try store.execute("INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at) VALUES ('nb-b', 'nb-a', 1)")
        try setPreference(store, "notebook.chatExcluded.nb-a", ["src-2"])
        try setPreference(store, "notebook.chatContextNotebooks.nb-a", ["nb-b"])
        try setPreference(store, "notebook.collections.nb-b", ["nbc-1", "nbc-2"])
        try setPreference(store, "studio.projectOrder", ["nb-b", "nb-a"])
        try setPreference(store, "studio.pinnedNotebooks.v1", ["nb-b"])
    }

    @Test("The activation derives kinds, keys, questions, states and resolution, the same twice, and no notes base")
    func activationDerives() throws {
        let (root, store) = try F.makeStore("156-derive", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.generation1Library(store)
        try Self.runDerivations(store)

        #expect(try F.text(store, "SELECT group_concat(id || ':' || entity_kind, ',') FROM (SELECT * FROM learning_goals ORDER BY id)") == "goal-1:goal,nb-a:notebook,nb-b:notebook")
        var studyOrder: [String] = []
        try store.query("SELECT source_id FROM learning_goal_items WHERE goal_id = 'nb-a' ORDER BY order_key", []) { studyOrder.append($0.text(0) ?? "") }
        #expect(studyOrder == ["src-3", "src-2", "src-1"], "keys follow the sequence")
        let questions = try NotebookResearchQuestions.rows(notebookID: "nb-a", connection: store)
        #expect(questions.map(\.text) == ["Why?", "How?"])
        #expect(questions.allSatisfy { $0.createdAt == 500 && $0.status == "open" })
        let a = try #require(try NotebookStateRow.load("nb-a", connection: store))
        #expect(a.excluded == ["src-2": NotebookStateRow.pendingPair], "an untick waits for its Entry's stamp")
        #expect(a.contextNotebooks == ["nb-b"])
        #expect(a.pinned == false)
        let b = try #require(try NotebookStateRow.load("nb-b", connection: store))
        #expect(b.contextNotebooks.isEmpty, "a link with no row starts unticked")
        #expect(b.collections == ["nbc-1", "nbc-2"])
        #expect(b.pinned == true)
        #expect((b.sidebarKey ?? "") < (a.sidebarKey ?? ""), "the sidebar order is kept")
        #expect(try NotebookResolutionTable.resolve("nb-a", connection: store) == SyncRecordLocation(zone: .library, id: "nb-a"))

        // R8-1: no notes base from the local text, in any table.
        try store.execute("UPDATE learning_goals SET notes = 'Local notes' WHERE id = 'nb-a'")
        let first = try Self.derived(store)
        try Self.runDerivations(store)
        #expect(try Self.derived(store) == first, "a second run changes nothing")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_text_bases") == 0)
        // The table exists since 159 (the catch-up's walk fills it); the activation puts no notes base in it.
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_body_sends WHERE record_type = 'Notebook' AND field = 'notes'") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0, "derivations queue nothing")
    }

    @Test("A duplicate id in a generation-1 list does not stop the activation")
    func duplicateIDsInPreferenceLists() throws {
        let (root, store) = try F.makeStore("156-duplicates", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.generation1Library(store)
        try Self.setPreference(store, "notebook.chatExcluded.nb-a", ["src-2", "src-2", "src-1"])
        try Self.runDerivations(store)
        let a = try #require(try NotebookStateRow.load("nb-a", connection: store))
        #expect(Set(a.excluded.keys) == ["src-1", "src-2"])
    }

    @Test("A run after generation-1 edits reflects them")
    func activationAfterGeneration1Edits() throws {
        let (root, store) = try F.makeStore("156-edits", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.generation1Library(store)
        try Self.runDerivations(store)
        let keyOf2 = try F.text(store, "SELECT order_key FROM learning_goal_items WHERE source_id = 'src-2'")

        // A generation-1 release moves src-1 to the front, asks a new question, unticks nothing more
        // and takes nb-b out of the chats, before the activation finishes.
        try store.execute("UPDATE learning_goal_items SET sequence = -1 WHERE source_id = 'src-1'")
        try store.execute("UPDATE learning_goals SET research_questions = ? WHERE id = 'nb-a'",
                          [.text(KnowledgeStore.encodeResearchQuestions(["Why?", "How?", "What next?"]))])
        try Self.setPreference(store, "notebook.chatExcluded.nb-a", nil)
        try Self.setPreference(store, "notebook.chatContextNotebooks.nb-a", nil)
        try Self.runDerivations(store)

        var studyOrder: [String] = []
        try store.query("SELECT source_id FROM learning_goal_items WHERE goal_id = 'nb-a' ORDER BY order_key", []) { studyOrder.append($0.text(0) ?? "") }
        #expect(studyOrder == ["src-1", "src-3", "src-2"])
        #expect(try F.text(store, "SELECT order_key FROM learning_goal_items WHERE source_id = 'src-2'") == keyOf2, "only the moved key changes")
        #expect(try NotebookResearchQuestions.rows(notebookID: "nb-a", connection: store).map(\.text) == ["Why?", "How?", "What next?"])
        let a = try #require(try NotebookStateRow.load("nb-a", connection: store))
        #expect(a.excluded.isEmpty && a.contextNotebooks.isEmpty)
    }

    @Test("A waiting untick is named once its Entry has a stamp, and the seed's Entries match it")
    func waitingUntickResolves() throws {
        let (root, store) = try F.makeStore("156-pending", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.generation1Library(store)
        try Self.runDerivations(store)
        // The triggers come after the derivations (§13.3 step 3d).
        try store.installOutboxTriggers(F.registry)
        try F.prepareReplica(store)
        // The seed sends the notebook's Entries; then the untick is named against what was sent.
        try store.execute("UPDATE learning_goal_items SET relevance = 0.5 WHERE goal_id = 'nb-a'")
        try F.sendAll(store)
        try store.resolvePendingUnticks()
        let pair = try #require(try NotebookStateRow.load("nb-a", connection: store)?.excluded["src-2"])
        #expect(pair != NotebookStateRow.pendingPair)
        #expect(try store.notebookStateSnapshot().excluded["nb-a"] == ["src-2"])
    }
}
