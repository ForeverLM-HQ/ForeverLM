import Foundation

// MARK: - Spaces of pages over MCP
//
// `list_spaces` and `update_space`: the Space sidebar's spaces
// (docs/docs-design.md, "The Space"), ChatGPT's spaces in ForeverLM. They are
// the learner's own synced preference rows (`PageSpaces`), written through
// `PageSpaceRows` as the sidebar and Move to Space ▸ write them, never an
// Artifact write; the open window picks them up through the
// `foreverLMDataDidChange` reload (`reloadSyncedPreferences` reseeds
// `pageSpaces`). Modelled on the Notebook collections pair
// (MCPTools+NotebookCollections.swift).

extension MCPDataStore {

    /// Every space, by name, with the pages in it by title. Pages in the
    /// Trash are left out, as the space's list leaves them out. In Screen
    /// record mode only the pages on screen, and only the spaces holding one,
    /// as the sidebar shows them.
    func listPageSpaces() async throws -> String {
        let spaces = PageSpaceRows.read()
        let artifacts = try await pageSpaceListedArtifacts()
        let screenScope = screenRecordScope()
        let rows: [[String: Any]] = spaces.ordered.compactMap { space in
            let members = artifacts.filter { spaces.spaceID(ofPage: $0.id) == space.id }
            if screenScope != nil, members.isEmpty { return nil }
            return pageSpaceRow(space, docs: members)
        }
        // The spaces in the Space's Trash: their pages are in no space until
        // update_space restore brings them back. Left out in Screen record mode.
        let trashed: [[String: Any]] = screenScope != nil ? [] : spaces.trashed.map { space in
            [
                "id": space.id,
                "name": space.name,
                "trashed_at": spaces.trashedDate(space.id).map { KnowledgeStore.iso8601Formatter.string(from: $0) } ?? "",
            ] as [String: Any]
        }
        return try jsonString([
            "spaces": rows,
            "in_trash": trashed,
            "guidance": "A space is the learner's own grouping of pages in the Space sidebar, as ChatGPT's spaces are. A page, linked Google Doc, site or reading is in one space at most, or in none, and a space changes nothing about the pages in it; a team's record, an animation and an audio overview cannot join one. update_space makes, renames, trashes, restores and deletes spaces and moves pages in or out; in_trash lists the spaces in the Space's Trash, whose pages are in no space until restored; list_docs names each Doc's space in space_id.",
        ] as [String: Any])
    }

    /// Makes, renames or deletes a space, or moves pages into it or out of
    /// their space, as the Space sidebar's Spaces + and right-click and a
    /// page's Move to Space ▸ do.
    func updatePageSpace(
        action rawAction: String,
        spaceID rawSpaceID: String?,
        name: String?,
        docIDs rawDocIDs: [String]?
    ) async throws -> String {
        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = ["create", "rename", "trash", "restore", "delete", "move_docs", "remove_docs"]
        guard actions.contains(action) else {
            throw MCPError.invalidInput("action must be create, rename, trash, restore, delete, move_docs, or remove_docs.")
        }
        var state = PageSpaceRows.read()
        let docs = try await validatedPageSpaceDocs(rawDocIDs ?? [], joining: action == "create" || action == "move_docs")

        func existing() throws -> PageSpace {
            let id = rawSpaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else {
                throw MCPError.invalidInput("space_id is required for action \(action). Use list_spaces to find it.")
            }
            guard let space = state.space(id) else {
                throw MCPError.invalidInput("Space not found: \(id). Use list_spaces to see the learner's spaces.")
            }
            // A space in Trash takes no pages and keeps its name until it is
            // restored; delete still removes it.
            if state.isTrashed(id), action != "delete", action != "restore" {
                throw MCPError.invalidInput("Space \(space.name) is in the Space's Trash. update_space restore brings it back first.")
            }
            if action == "restore", !state.isTrashed(id) {
                throw MCPError.invalidInput("Space \(space.name) is not in the Space's Trash.")
            }
            return space
        }
        func cleanedName() throws -> String {
            guard let cleaned = PageSpaces.cleanedName(name ?? "") else {
                throw MCPError.invalidInput("name is required for action \(action) and cannot be blank.")
            }
            return cleaned
        }
        /// Writes each row a move changes, as `filePages` does, and answers
        /// the pages that moved.
        func move(to spaceID: String?) -> [String] {
            let rows = state.membershipRowsAfterMoving(docs.map(\.id), to: spaceID)
            for row in rows {
                PageSpaceRows.writeMembership(row.spaceID, pageID: row.pageID)
            }
            state = state.applying(rows)
            return rows.map(\.pageID)
        }

        let space: PageSpace
        var moved: [String] = []
        switch action {
        case "create":
            let cleaned = try cleanedName()
            let id = PageSpaces.newSpaceID()
            PageSpaceRows.writeName(cleaned, spaceID: id)
            state = state.settingName(cleaned, for: id)
            space = PageSpace(id: id, name: cleaned)
            moved = move(to: id)
        case "rename":
            let current = try existing()
            let cleaned = try cleanedName()
            PageSpaceRows.writeName(cleaned, spaceID: current.id)
            state = state.settingName(cleaned, for: current.id)
            space = PageSpace(id: current.id, name: cleaned)
        case "trash", "restore":
            // Codex's Trash holds spaces as pages: in Trash a space leaves
            // the sidebar and its pages are in no space, keeping their rows,
            // so restore brings it back as it was.
            let current = try existing()
            let trashing = action == "trash"
            let value = trashing ? PageSpaces.trashRowValue(at: Date()) : nil
            PageSpaceRows.writeTrash(value, spaceID: current.id)
            state = state.settingTrash(value.flatMap { Int($0) }, for: current.id)
            await PreferenceStore.flushPendingWrites()
            return try jsonString([
                "space_id": current.id,
                "name": current.name,
                "in_trash": trashing,
                "guidance": trashing
                    ? "The space is in the Space's Trash; its pages stay in All, in no space, until update_space restore brings it back with them. delete removes it for good."
                    : "The space is back in the Space's sidebar with its pages.",
            ] as [String: Any])
        case "delete":
            let current = try existing()
            let rows = state.membershipRowsAfterDeleting(current.id)
            for row in rows {
                PageSpaceRows.writeMembership(row.spaceID, pageID: row.pageID)
            }
            PageSpaceRows.writeName(nil, spaceID: current.id)
            if state.trashedAt[current.id] != nil { PageSpaceRows.writeTrash(nil, spaceID: current.id) }
            state = state.applying(rows).settingName(nil, for: current.id).settingTrash(nil, for: current.id)
            await PreferenceStore.flushPendingWrites()
            return try jsonString([
                "deleted": true,
                "space_id": current.id,
                "name": current.name,
                "guidance": "The space is gone; the pages that were in it are unchanged and listed in All.",
            ] as [String: Any])
        case "move_docs":
            let current = try existing()
            guard !docs.isEmpty else {
                throw MCPError.invalidInput("doc_ids is required for action move_docs. Use list_docs to find them.")
            }
            space = current
            moved = move(to: current.id)
        default:
            guard !docs.isEmpty else {
                throw MCPError.invalidInput("doc_ids is required for action remove_docs. Use list_spaces to see what each space holds.")
            }
            let leaving = docs.filter { state.spaceID(ofPage: $0.id) != nil }.map(\.id)
            _ = move(to: nil)
            await PreferenceStore.flushPendingWrites()
            return try jsonString([
                "removed_doc_ids": leaving,
                "guidance": leaving.isEmpty
                    ? "None of these pages was in a space, so nothing changed."
                    : "These pages are in no space now; they stay in All.",
            ] as [String: Any])
        }
        await PreferenceStore.flushPendingWrites()

        let members = try await pageSpaceListedArtifacts().filter { state.spaceID(ofPage: $0.id) == space.id }
        var payload: [String: Any] = ["space": pageSpaceRow(space, docs: members)]
        if action == "create" || action == "move_docs" {
            payload["moved_doc_ids"] = moved
        }
        return try jsonString(payload)
    }

    /// The records a space can list: the library's, Trash and the records a
    /// space never holds left out, by title, in Screen record mode only those
    /// on screen.
    private func pageSpaceListedArtifacts() async throws -> [ArtifactRecord] {
        let screenScope = screenRecordScope()
        return try await notebookFileStorage.loadArtifacts(notebookID: nil)
            .filter { artifact in
                !artifact.isArchived
                    && (screenScope.map { screenRecordAllowsArtifact(artifact, scope: $0) } ?? true)
            }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    private func pageSpaceRow(_ space: PageSpace, docs: [ArtifactRecord]) -> [String: Any] {
        [
            "id": space.id,
            "name": space.name,
            "doc_count": docs.count,
            "docs": docs.map { artifact -> [String: Any] in
                let payload = artifactPayload(artifact)
                return [
                    "id": artifact.id,
                    "title": artifact.title,
                    "kind": payload["kind"] ?? NSNull(),
                    "is_hidden": artifact.isHidden,
                    "updated_at": payload["updated_at"] ?? NSNull(),
                ]
            },
        ]
    }

    /// The Docs named, trimmed and each once, every one a record of the
    /// library; the first that is not is refused before anything is written.
    /// A Doc `joining` a space must be one the app files in a space
    /// (`StudioViewModel.canFileInPageSpace`): the learner's own page, linked
    /// Google Doc, site or reading in no notebook.
    private func validatedPageSpaceDocs(_ raw: [String], joining: Bool) async throws -> [ArtifactRecord] {
        var seen = Set<String>()
        var ids: [String] = []
        for value in raw {
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { return [] }
        let library = Dictionary(
            try await notebookFileStorage.loadArtifacts(notebookID: nil).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let store = try knowledgeStore()
        let goals = joining ? try store.loadLearningGoals() : []
        let notebookIDs = Set(goals.filter(\.isNotebook).map(\.id))
        let goalParents = Dictionary(
            goals.compactMap { goal in goal.parentNotebookID.map { (goal.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var docs: [ArtifactRecord] = []
        for id in ids {
            guard let artifact = library[id] else {
                throw MCPError.invalidInput("Doc not found: \(id). Use list_docs to see the learner's Docs.")
            }
            if joining, let reason = try pageSpaceRefusal(artifact, store: store, notebookIDs: notebookIDs, goalParents: goalParents) {
                throw MCPError.invalidInput("‘\(artifact.title)’ cannot be put in a space: \(reason) Nothing was moved.")
            }
            docs.append(artifact)
        }
        return docs
    }

    /// Why a record cannot join a space, as the app's Move to Space ▸ is
    /// offered only for the rest; nil when it can.
    private func pageSpaceRefusal(
        _ artifact: ArtifactRecord,
        store: KnowledgeStore,
        notebookIDs: Set<String>,
        goalParents: [String: String]
    ) throws -> String? {
        if artifact.teamID != nil || TeamContentIdentity.isDraftArtifactID(artifact.id) {
            return "it is a team's record, and spaces are the learner's own grouping of their own pages."
        }
        if artifact.section == .animations {
            return "it is an animation, which lives in its Notebook's Studio."
        }
        if artifact.isCardDeck {
            return "it is a source's cards to check, not a page."
        }
        if try store.isAudioOverview(artifact) {
            return "it is a Notebook's audio overview, which lives in its Notebook."
        }
        if artifact.isMnemonicReading {
            let held = NotebookMembership.filingNotebookIDs(of: artifact).contains { id in
                guard let id else { return false }
                return notebookIDs.contains(id) || goalParents[id].map(notebookIDs.contains) == true
            }
            if held { return "it is a mnemonic reading its Notebook holds, listed there alone." }
        }
        return nil
    }
}
