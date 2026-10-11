import Foundation

// MARK: - Ideas (docs/ideas-design.md)
//
// The Ideas tab over MCP. An Idea is a sentence the learner wrote with no
// deadline and no commitment, plus the things it draws on. Nothing here asks
// a model anything: every tool is a read or a row write, the same one the tab
// makes, so the learner driving ForeverLM from a chat beside the app can jot,
// link and revisit exactly what the tab offers (settings-need-mcp-parity).

extension MCPDataStore {

    // MARK: list_ideas

    /// Every Idea, newest first, with each link resolved to the title of what
    /// it points at. A link whose target has left the library keeps its id and
    /// reads `"title": null`; a source the learner keeps from AI is named the
    /// same way, so the boundary holds without the link disappearing.
    func listIdeas(includeArchived: Bool, notebookID: String? = nil) throws -> String {
        let store = try knowledgeStore()
        // notebook_id: only the Ideas filed in that notebook — linked to the
        // Notebook or to one of its Goals (`NotebookMembership`).
        let notebook = try notebookMembershipForListing(notebookID: notebookID, store: store)
        // Screen record mode (admin only): an Idea jotted during the take, or
        // one linked to the recording Notebook or one of its Goals. Nil scope
        // lists every Idea, as before.
        let screenScope = screenRecordScope()
        let parents: [String: String] = try screenScope == nil ? [:] : screenRecordParentNotebookIDs()
        let ideas = try store.loadIdeas(includeArchived: includeArchived).filter { idea in
            if let notebook, !notebook.contains(idea) { return false }
            guard let screenScope else { return true }
            return screenScope.allowsItem(
                createdAt: idea.createdAt,
                notebookIDs: screenRecordNotebookIDs(linkedTo: NotebookMembership.filingNotebookIDs(of: idea), parents: parents)
            )
        }
        let excludedSourceIDs = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let formatter = ISO8601DateFormatter()

        let rows: [[String: Any]] = try ideas.map { idea in
            var payload: [String: Any] = [
                "idea_id": idea.id,
                "title": idea.title,
                "status": idea.status.rawValue,
                "created_at": formatter.string(from: idea.createdAt),
                "updated_at": formatter.string(from: idea.updatedAt),
                "links": try idea.links.map { try ideaLinkPayload($0, store: store, excludedSourceIDs: excludedSourceIDs, formatter: formatter) },
            ]
            if let notes = idea.notes { payload["notes"] = notes }
            return payload
        }

        var payload: [String: Any] = [
            "ideas": rows,
            "count": rows.count,
            "guidance": "An Idea is the learner's own thought with no deadline. When one earns a date it becomes a Goal: create_learning_goal with the Idea's title, then link_idea with kind \"goal\" so the row reads where the thought went.",
            "generated_at": formatter.string(from: Date()),
        ]
        if let notebook { payload["notebook_id"] = notebook.notebookID }
        return try jsonString(payload)
    }

    // MARK: create_idea

    /// Jot one down. The words are stored as given, collapsed to one line;
    /// anything longer belongs in `notes`.
    func createIdea(title rawTitle: String, notes rawNotes: String?, links rawLinks: [[String: Any]]) throws -> String {
        let title = IdeaRecord.normalizedTitle(rawTitle)
        guard !title.isEmpty else {
            throw MCPError.invalidInput("title is required: the sentence the learner wants kept.")
        }
        let store = try knowledgeStore()
        let links = try parsedIdeaLinks(rawLinks)
        let idea: IdeaRecord
        do {
            idea = try store.createIdea(title: title, notes: rawNotes, links: links)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "created",
            "idea_id": idea.id,
            "title": idea.title,
            "linked": idea.links.count,
            "guidance": "It is saved among the learner's Ideas, newest first. Link research or explorations to it with link_idea.",
        ] as [String: Any])
    }

    // MARK: update_idea

    /// Reword an Idea, write or clear its note, archive it or bring it back.
    /// Every field is optional and an omitted one is left alone; `notes: ""`
    /// clears the note.
    func updateIdea(ideaID rawIdeaID: String, title: String?, notes: String?, statusString: String?) throws -> String {
        let ideaID = rawIdeaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ideaID.isEmpty else {
            throw MCPError.invalidInput("idea_id is required. Use list_ideas to find it.")
        }
        let store = try knowledgeStore()
        guard try store.hasIdea(ideaID) else {
            throw MCPError.notFound("Idea \(ideaID) was not found. Use list_ideas.")
        }
        if let title, IdeaRecord.normalizedTitle(title).isEmpty {
            throw MCPError.invalidInput("An Idea cannot be left without words. Pass a title with something in it, or delete_idea.")
        }
        var status: IdeaStatus?
        if let statusString {
            let trimmed = statusString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let parsed = IdeaStatus(rawValue: trimmed) else {
                throw MCPError.invalidInput("status must be \"open\" or \"archived\".")
            }
            status = parsed
        }

        var idea: IdeaRecord
        do {
            idea = try store.updateIdea(ideaID, title: title, notes: notes)
            if let status, status != idea.status {
                idea = try store.setIdeaStatus(ideaID, status: status)
            }
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "updated",
            "idea_id": idea.id,
            "title": idea.title,
            "idea_status": idea.status.rawValue,
            "has_notes": idea.notes != nil,
        ] as [String: Any])
    }

    // MARK: link_idea

    /// Link research or an exploration to an Idea — the drop of sources on
    /// its row, or a pick in its Link sheet. Targets already linked are
    /// skipped and said so; an id no record holds is refused and nothing is
    /// written.
    func linkIdea(ideaID rawIdeaID: String, kindString: String, targetIDs: [String]) throws -> String {
        let (ideaID, kind, ids, store) = try resolvedIdeaLinkRequest(rawIdeaID, kindString, targetIDs)
        let result: (idea: IdeaRecord, added: Int)
        do {
            result = try store.linkIdea(ideaID, kind: kind, targetIDs: ids)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "linked",
            "idea_id": result.idea.id,
            "title": result.idea.title,
            "kind": kind.rawValue,
            "added": result.added,
            "already_linked": ids.count - result.added,
            "links": result.idea.links.count,
        ] as [String: Any])
    }

    // MARK: unlink_idea

    /// Take a link off an Idea. What it pointed at is untouched.
    func unlinkIdea(ideaID rawIdeaID: String, kindString: String, targetIDs: [String]) throws -> String {
        let (ideaID, kind, ids, store) = try resolvedIdeaLinkRequest(rawIdeaID, kindString, targetIDs, validateTargets: false)
        let result: (idea: IdeaRecord, removed: Int)
        do {
            result = try store.unlinkIdea(ideaID, kind: kind, targetIDs: ids)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "unlinked",
            "idea_id": result.idea.id,
            "title": result.idea.title,
            "kind": kind.rawValue,
            "removed": result.removed,
            "links": result.idea.links.count,
        ] as [String: Any])
    }

    // MARK: delete_idea

    /// Forget an Idea. Its links go with it; every record they pointed at
    /// stays exactly where it was.
    func deleteIdea(ideaID rawIdeaID: String) throws -> String {
        let ideaID = rawIdeaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ideaID.isEmpty else {
            throw MCPError.invalidInput("idea_id is required. Use list_ideas to find it.")
        }
        let store = try knowledgeStore()
        guard let idea = try store.loadIdea(ideaID) else {
            throw MCPError.notFound("Idea \(ideaID) was not found. Use list_ideas.")
        }
        do {
            try store.deleteIdea(idea.id)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "deleted",
            "idea_id": idea.id,
            "title": idea.title,
            "links_dropped": idea.links.count,
            "guidance": "Nothing it linked to was touched. To put an Idea away and keep it, update_idea with status \"archived\" instead.",
        ] as [String: Any])
    }

    // MARK: - Shared

    /// The pieces every link write needs, with the Idea, the kind and the ids
    /// all checked before a row is touched.
    private func resolvedIdeaLinkRequest(
        _ rawIdeaID: String,
        _ kindString: String,
        _ rawTargetIDs: [String],
        validateTargets: Bool = true
    ) throws -> (ideaID: String, kind: IdeaLinkKind, targetIDs: [String], store: KnowledgeStore) {
        let ideaID = rawIdeaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ideaID.isEmpty else {
            throw MCPError.invalidInput("idea_id is required. Use list_ideas to find it.")
        }
        guard let kind = IdeaLinkKind(rawValue: kindString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw MCPError.invalidInput("kind must be one of: \(IdeaLinkKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let ids = rawTargetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            throw MCPError.invalidInput("target_ids is required: at least one \(kind.noun) id.")
        }
        let store = try knowledgeStore()
        guard try store.hasIdea(ideaID) else {
            throw MCPError.notFound("Idea \(ideaID) was not found. Use list_ideas.")
        }
        if validateTargets {
            for id in ids {
                do {
                    try store.validateIdeaLinkTarget(IdeaLink(kind: kind, targetID: id))
                } catch let error as KnowledgeStoreError {
                    throw MCPError.invalidInput(error.localizedDescription)
                }
            }
        }
        return (ideaID, kind, ids, store)
    }

    /// The `links` argument of create_idea, checked the same way link_idea
    /// checks its own.
    private func parsedIdeaLinks(_ raw: [[String: Any]]) throws -> [IdeaLink] {
        guard !raw.isEmpty else { return [] }
        let store = try knowledgeStore()
        var links: [IdeaLink] = []
        for entry in raw {
            let kindString = (entry["kind"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let kind = IdeaLinkKind(rawValue: kindString) else {
                throw MCPError.invalidInput("Each link needs a kind, one of: \(IdeaLinkKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let targetID = (entry["target_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetID.isEmpty else {
                throw MCPError.invalidInput("Each link needs a target_id: the id of the \(kind.noun) to link.")
            }
            let link = IdeaLink(kind: kind, targetID: targetID)
            do {
                try store.validateIdeaLinkTarget(link)
            } catch let error as KnowledgeStoreError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            links.append(link)
        }
        return links
    }

    /// One link as the listing reports it: its kind, what it points at, and
    /// that record's title when this library still holds it and the learner
    /// has not kept it from AI.
    private func ideaLinkPayload(
        _ link: IdeaLink,
        store: KnowledgeStore,
        excludedSourceIDs: Set<String>,
        formatter: ISO8601DateFormatter
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "kind": link.kind.rawValue,
            "target_id": link.targetID,
            "added_at": formatter.string(from: link.addedAt),
        ]
        switch link.kind {
        case .source:
            if excludedSourceIDs.contains(link.targetID) {
                payload["withheld_from_ai"] = true
            } else if let source = try store.loadSourceForSync(link.targetID) {
                payload["title"] = source.title
                payload["source_type"] = source.sourceType.rawValue
            }
        case .artifact:
            if let artifact = try store.loadArtifact(link.targetID) {
                payload["title"] = artifact.title
            }
        case .chat:
            payload["title"] = try store.loadReviewSessionLinks()
                .first(where: { $0.id == link.targetID })?.title as Any
        case .goal, .notebook:
            if let goal = try store.loadLearningGoal(link.targetID) {
                payload["title"] = goal.title
            }
        }
        return payload
    }
}
