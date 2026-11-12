import Foundation

// MARK: - Collections of notebooks over MCP
//
// `list_notebook_collections` and `update_notebook_collection`: the
// learner's collections (docs/notebooks-design.md, "Collections"), which the
// tools call collections of Notebooks. They are the learner's own synced
// preference rows (`NotebookCollections`), written through `PreferenceStore`
// as the Space's Add to Collection writes them, never a Notebook write; the
// open window picks them up through the `foreverLMDataDidChange` reload.
// The Space groups All by them, and these tools reach every collection.

extension MCPDataStore {

    /// Every collection, by name, with the Notebooks in it. In Screen record
    /// mode only the Notebooks on screen, and only the collections holding
    /// one, as the Space shows them.
    func listNotebookCollections() throws -> String {
        let store = try knowledgeStore()
        let collections = NotebookCollectionRows.read()
        let screenScope = screenRecordScope()
        let notebooks = try store.loadLearningGoals().filter { goal in
            goal.isNotebook && (screenScope.map { screenRecordAllowsGoal(goal, scope: $0) } ?? true)
        }
        let notebookIDs = notebooks
            .sorted(by: NotebooksHomeSort.titleOrder)
            .map(\.id)
        let rows: [[String: Any]] = collections.ordered.compactMap { collection in
            let members = collections.notebookIDs(notebookIDs, in: collection.id)
            if screenScope != nil, members.isEmpty { return nil }
            return Self.collectionRow(collection, notebookIDs: members)
        }
        return try jsonString([
            "collections": rows,
            "guidance": "A collection is the learner's own grouping of Notebooks, shown as headings in the Space's All and on the iPhone's Home. A Notebook can be in any number of collections, or none, and a collection changes nothing about the Notebooks in it. update_notebook_collection makes, renames and deletes collections and puts Notebooks in or out.",
        ] as [String: Any])
    }

    /// Makes, renames or deletes a collection, or puts Notebooks in it or
    /// takes them out, as a notebook's Add to Collection ▸ and a collection's
    /// heading menu do.
    func updateNotebookCollection(
        action rawAction: String,
        collectionID rawCollectionID: String?,
        name: String?,
        notebookIDs rawNotebookIDs: [String]?
    ) async throws -> String {
        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = ["create", "rename", "delete", "add_notebooks", "remove_notebooks"]
        guard actions.contains(action) else {
            throw MCPError.invalidInput("action must be create, rename, delete, add_notebooks, or remove_notebooks.")
        }
        let store = try knowledgeStore()
        var state = NotebookCollectionRows.read()
        let notebookIDs = try validatedCollectionNotebookIDs(rawNotebookIDs ?? [], store: store)

        func existing() throws -> NotebookCollection {
            let id = rawCollectionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else {
                throw MCPError.invalidInput("collection_id is required for action \(action). Use list_notebook_collections to find it.")
            }
            guard let collection = state.collection(id) else {
                throw MCPError.invalidInput("Collection not found: \(id). Use list_notebook_collections to see the learner's collections.")
            }
            return collection
        }
        func cleanedName() throws -> String {
            guard let cleaned = NotebookCollections.cleanedName(name ?? "") else {
                throw MCPError.invalidInput("name is required for action \(action) and cannot be blank.")
            }
            return cleaned
        }
        func setMembership(_ collectionID: String, isMember: Bool) {
            for notebookID in notebookIDs where state.contains(notebookID, in: collectionID) != isMember {
                let row = state.membershipRow(notebookID: notebookID, setting: collectionID, isMember: isMember)
                NotebookCollectionRows.writeMembership(row, notebookID: notebookID)
                state = state.settingMembership(row, for: notebookID)
            }
        }

        let collection: NotebookCollection
        var deleted = false
        switch action {
        case "create":
            let cleaned = try cleanedName()
            let id = NotebookCollections.newCollectionID()
            NotebookCollectionRows.writeName(cleaned, collectionID: id)
            state = state.settingName(cleaned, for: id)
            collection = NotebookCollection(id: id, name: cleaned)
            setMembership(id, isMember: true)
        case "rename":
            let current = try existing()
            let cleaned = try cleanedName()
            NotebookCollectionRows.writeName(cleaned, collectionID: current.id)
            state = state.settingName(cleaned, for: current.id)
            collection = NotebookCollection(id: current.id, name: cleaned)
        case "delete":
            collection = try existing()
            for (notebookID, row) in state.membershipRowsAfterDeleting(collection.id) {
                NotebookCollectionRows.writeMembership(row, notebookID: notebookID)
                state = state.settingMembership(row, for: notebookID)
            }
            NotebookCollectionRows.writeName(nil, collectionID: collection.id)
            state = state.settingName(nil, for: collection.id)
            deleted = true
        default:
            collection = try existing()
            guard !notebookIDs.isEmpty else {
                throw MCPError.invalidInput("notebook_ids is required for action \(action). Use list_notebooks to find them.")
            }
            setMembership(collection.id, isMember: action == "add_notebooks")
        }
        await PreferenceStore.flushPendingWrites()

        if deleted {
            return try jsonString([
                "deleted": true,
                "collection_id": collection.id,
                "name": collection.name,
                "guidance": "The collection is gone; the Notebooks that were in it are unchanged.",
            ] as [String: Any])
        }
        let allNotebookIDs = try store.loadLearningGoals()
            .filter(\.isNotebook)
            .sorted(by: NotebooksHomeSort.titleOrder)
            .map(\.id)
        return try jsonString([
            "collection": Self.collectionRow(collection, notebookIDs: state.notebookIDs(allNotebookIDs, in: collection.id)),
        ] as [String: Any])
    }

    private static func collectionRow(_ collection: NotebookCollection, notebookIDs: [String]) -> [String: Any] {
        [
            "id": collection.id,
            "name": collection.name,
            "notebook_ids": notebookIDs,
            "notebook_count": notebookIDs.count,
        ]
    }

    /// The Notebooks named, trimmed and each once, every one a Notebook of the
    /// library; the first that is not is refused before anything is written.
    private func validatedCollectionNotebookIDs(_ raw: [String], store: KnowledgeStore) throws -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for value in raw {
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            guard let goal = try store.loadLearningGoal(id), goal.isNotebook else {
                throw MCPError.invalidInput("Notebook not found: \(id). Use list_notebooks to see available Notebooks.")
            }
            ids.append(goal.id)
        }
        return ids
    }
}
