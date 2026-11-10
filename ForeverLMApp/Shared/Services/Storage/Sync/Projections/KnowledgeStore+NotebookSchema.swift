import Foundation

// MARK: - Schema 156: what the Notebook, Goal, Entry and NotebookState records need (§12.7)

extension KnowledgeStore {
    /// The tables schema 156 adds (docs/cloudkit-schema-design.md §12.7), created empty: DDL only, like
    /// every step from 154 on. Generation 1 never reads or writes them; the generation-2 activation
    /// fills them from generation-1 truth (`notebookActivationDerivations`), and from then on the
    /// notebook projections and the generation-2 writers keep them.
    static let notebookSyncTables: [ReplicaSchemaTable] = [
        // The member's own state for one notebook (`NotebookState`, §3.5.20), keyed by the notebook's
        // wire id with no foreign key: per-member state outlives the notebook it is about (D18).
        // `excluded_json` maps a source id to the Entry stamp pair its untick named (§5.6); the
        // two sets are sorted JSON arrays of their members; `course_order_json` maps a course id to
        // its fractional key.
        ReplicaSchemaTable("notebook_states", [
            ("notebook_id", "TEXT PRIMARY KEY"),
            ("excluded_json", "TEXT"),
            ("context_notebooks_json", "TEXT"),
            ("collections_json", "TEXT"),
            ("sidebar_key", "TEXT"),
            ("pinned", "INTEGER"),
            ("expanded", "INTEGER"),
            ("layout_override", "TEXT"),
            ("course_id", "TEXT"),
            ("course_order_json", "TEXT"),
        ]),
        // Where each notebook id leads after merges, emptying splits and moves (`resolveNotebook()`,
        // §5.2), refreshed on every Notebook apply: the last live notebook and its zone.
        ReplicaSchemaTable("notebook_resolution", [
            ("id", "TEXT PRIMARY KEY"),
            ("resolved_id", "TEXT NOT NULL"),
            ("resolved_zone", "TEXT NOT NULL"),
        ]),
        // A notebook's research questions, one row per element of `Notebook.researchQuestions`
        // (was the JSON array in `learning_goals.research_questions`, which generation-1 readers keep
        // reading). A question's id is deterministic from its notebook and text
        // (`NotebookResearchQuestions.questionID`), so two Macs deriving one list mint one map.
        ReplicaSchemaTable("notebook_research_questions", [
            ("notebook_id", "TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE"),
            ("id", "TEXT NOT NULL"),
            ("text", "TEXT NOT NULL"),
            ("status", "TEXT NOT NULL DEFAULT 'open'"),
            ("order_key", "TEXT NOT NULL"),
            ("created_at", "REAL"),
        ], constraints: ["PRIMARY KEY (notebook_id, id)"]),
    ]

    /// The back-pointer index (§5.2): every row that files something into a notebook, by the
    /// notebook's local id. What a delete unfiles, a merge re-points (WP8b) and a move into a space
    /// copies (WP15b) is found here, so nothing belongs to a notebook by living inside it (D17). A course
    /// is in no notebook (2026-10-03): a notebook only follows one, which its Entry row says (schema 157
    /// dropped the retired `courses.home_notebook_id` line).
    static let notebookChildrenView = """
        CREATE VIEW IF NOT EXISTS ck_notebook_children (notebook_id, child_type, child_table, child_id) AS
            SELECT goal_id, 'Entry', 'learning_goal_items', id FROM learning_goal_items
            UNION ALL SELECT goal_id, 'Entry', 'notebook_course_links', course_id FROM notebook_course_links
            UNION ALL SELECT goal_id, 'Chat', 'review_sessions', id FROM review_sessions WHERE goal_id IS NOT NULL
            UNION ALL SELECT home_notebook_id, 'Artifact', 'global_artifacts', id FROM global_artifacts WHERE home_notebook_id IS NOT NULL
            UNION ALL SELECT notebook_id, 'Artifact', 'global_artifact_notebook_links', artifact_id FROM global_artifact_notebook_links
            UNION ALL SELECT notebook_id, 'Artifact', 'notebook_files', id FROM notebook_files WHERE notebook_id IS NOT NULL
            UNION ALL SELECT parent_notebook_id, 'Goal', 'learning_goals', id FROM learning_goals WHERE parent_notebook_id IS NOT NULL
            UNION ALL SELECT notebook_id, 'Task', 'notebook_tasks', id FROM notebook_tasks
            UNION ALL SELECT notebook_id, 'Automation', 'scheduled_tasks', id FROM scheduled_tasks WHERE notebook_id IS NOT NULL
            UNION ALL SELECT target_id, 'Idea', 'idea_links', idea_id FROM idea_links WHERE kind = 'notebook'
            UNION ALL SELECT home_id, 'Idea', 'research_directions', id FROM research_directions WHERE home_kind = 'notebook'
            UNION ALL SELECT goal_id, 'Card', 'memory_items', id FROM memory_items WHERE goal_id IS NOT NULL
            UNION ALL SELECT notebook_id, 'Sitting', 'learning_bouts', id FROM learning_bouts WHERE notebook_id IS NOT NULL
            UNION ALL SELECT notebook_id, 'NotebookState', 'notebook_states', notebook_id FROM notebook_states
        """

    /// Creates schema 156's tables where missing: empty, DDL only.
    func createNotebookSyncTables() throws {
        for table in Self.notebookSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

    /// The back-pointer view, made after the migration steps: an `ALTER TABLE` of a table it reads
    /// (154's rebuild of `notebook_files`) runs before it exists.
    func createNotebookChildrenView() throws {
        try exec(Self.notebookChildrenView)
    }

}

// MARK: - The activation's derivations for notebooks (§13.3 step 3c)

extension KnowledgeStore {
    /// WP8's derivations, in order, after WP7's wire ids: each row's kind, the Entries' order keys, the
    /// research questions' rows, the member's NotebookStates from the preference rows, and where each
    /// notebook id leads. Each is idempotent, bounded by the library's notebooks and their items, in its
    /// own transaction, and reads generation-1 truth only. None writes a notes base: a Notes Doc's base
    /// is the old record's notes the catch-up's walk returns (WP16a, WP16b2, into `ck_legacy_bodies`),
    /// never the local text (§13.6, R8-1).
    static let notebookActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "notebookEntityKinds") { store in
            try store.inDerivationTransaction { try LearningGoalEntityKind.classifyUnclassified($0) }
        },
        ActivationDerivation(id: "entryOrderKeys") { store in try store.inDerivationTransaction { try $0.deriveEntryOrderKeys() } },
        ActivationDerivation(id: "notebookResearchQuestions") { store in try store.inDerivationTransaction { try $0.deriveResearchQuestions() } },
        ActivationDerivation(id: "notebookStates") { store in try store.inDerivationTransaction { try $0.deriveNotebookStates() } },
        ActivationDerivation(id: "notebookResolution") { store in try store.inDerivationTransaction { try NotebookResolutionTable.refresh($0) } },
    ]

    /// Every pool's order keys from its study order (`sequence`, then `added_at`): the same order gives
    /// the same keys on every Mac, and a second run changes nothing.
    func deriveEntryOrderKeys() throws {
        var goals: [String] = []
        try query("SELECT DISTINCT goal_id FROM learning_goal_items ORDER BY goal_id", []) { row in
            if let id = row.text(0) { goals.append(id) }
        }
        for goal in goals { try EntryOrderKeys.replan(goalID: goal, connection: self) }
    }

    /// Each notebook's research questions as rows, from its JSON array, dated by the notebook's creation
    /// so two Macs derive the same map.
    func deriveResearchQuestions() throws {
        var notebooks: [(id: String, json: String, createdAt: Double)] = []
        try query(
            "SELECT id, research_questions, created_at FROM learning_goals WHERE entity_kind = ? AND research_questions IS NOT NULL",
            [.text(LearningGoalEntityKind.notebook)]
        ) { row in
            if let id = row.text(0), let json = row.text(1) { notebooks.append((id, json, row.real(2) ?? 0)) }
        }
        for notebook in notebooks {
            guard let questions = Self.decodeResearchQuestions(notebook.json) else { continue }
            try NotebookResearchQuestions.syncRows(notebookID: notebook.id, questions: questions, at: notebook.createdAt, connection: self)
        }
    }

    /// The member's NotebookStates from generation 1's preference rows (§10, §13.3 step 3c): the chat
    /// unticks (`notebook.chatExcluded.*`), the context notebooks ticked (`notebook.chatContextNotebooks.*`;
    /// a link with no row stays unticked, D52), the collections (`notebook.collections.*`), the sidebar
    /// order (`studio.projectOrder`), the pins (`studio.pinnedNotebooks.v1`: listed true, every other
    /// notebook false) and the expanded rows (`studio.navigation.expandedProjectIDs.v1`). An untick has
    /// no Entry stamp to name before the seed: it is stored waiting (`~pending`) and named by
    /// `resolvePendingUnticks` once its Entry has a stamp. Each derived field is exactly what the rows
    /// say, so a run after generation-1 edits reflects them and a second run changes nothing.
    func deriveNotebookStates() throws {
        var preferences: [String: Any] = [:]
        try query("""
            SELECT key, value FROM user_preferences
            WHERE key LIKE 'notebook.chatExcluded.%' OR key LIKE 'notebook.chatContextNotebooks.%' OR key LIKE 'notebook.collections.%'
               OR key IN ('studio.projectOrder', 'studio.pinnedNotebooks.v1', 'studio.navigation.expandedProjectIDs.v1')
        """, []) { row in
            if let key = row.text(0), let value = row.text(1).flatMap(PreferenceStore.decodePlist) { preferences[key] = value }
        }
        func ids(_ key: String) -> [String] { (preferences[key] as? [String]) ?? [] }
        func rows(_ prefix: String) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for (key, value) in preferences where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                if !id.isEmpty, let list = value as? [String], !list.isEmpty { result[id] = list }
            }
            return result
        }
        let excluded = rows(NotebookChatSelection.preferenceKeyPrefix)
        let contexts = rows(NotebookChatContext.preferenceKeyPrefix)
        let collections = rows(NotebookCollections.membershipPreferenceKeyPrefix)
        var notebooks: [String] = []
        try query("SELECT id FROM learning_goals WHERE entity_kind = ? ORDER BY id", [.text(LearningGoalEntityKind.notebook)]) { row in
            if let id = row.text(0) { notebooks.append(id) }
        }
        let order = ids("studio.projectOrder")
        let pinned = preferences["studio.pinnedNotebooks.v1"].map { _ in Set(ids("studio.pinnedNotebooks.v1")) }
        let expanded = preferences["studio.navigation.expandedProjectIDs.v1"].map { _ in Set(ids("studio.navigation.expandedProjectIDs.v1")) }
        let sidebarKeys = (try? FractionalIndex.keys(between: nil, and: nil, count: order.count)) ?? []

        var touched = Set(excluded.keys).union(contexts.keys).union(collections.keys).union(order)
        if pinned != nil || expanded != nil { touched.formUnion(notebooks) }
        let held = try Set(notebookStateIDs())
        for id in touched.union(held).sorted() {
            var row = try NotebookStateRow.load(id, connection: self) ?? NotebookStateRow(notebookID: id)
            row.excluded = Dictionary((excluded[id] ?? []).map { ($0, row.excluded[$0] ?? NotebookStateRow.pendingPair) }, uniquingKeysWith: { first, _ in first })
            row.contextNotebooks = Set(contexts[id] ?? [])
            row.collections = Set(collections[id] ?? [])
            row.sidebarKey = order.firstIndex(of: id).flatMap { $0 < sidebarKeys.count ? sidebarKeys[$0] : nil }
            if let pinned { row.pinned = pinned.contains(id) }
            if let expanded { row.expanded = expanded.contains(id) }
            guard row != NotebookStateRow(notebookID: id) || held.contains(id) else { continue }
            try row.save(self)
        }
    }

    private func notebookStateIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT notebook_id FROM notebook_states", []) { row in if let id = row.text(0) { ids.append(id) } }
        return ids
    }
}
