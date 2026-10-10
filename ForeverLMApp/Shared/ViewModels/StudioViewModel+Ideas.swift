import Foundation

// MARK: - Ideas (docs/ideas-design.md)
//
// The Ideas tab's writes. Every one is a local write followed by a reload
// of the list; nothing here asks a model anything. The row resolves each
// link against the loaded library — a source's title, a Doc's, a chat's, a
// Goal's — and opens it the way that record opens from anywhere else.

extension StudioViewModel {

    /// Open Ideas newest first, then the archived ones, newest first.
    func ideaBands() -> (open: [IdeaRecord], archived: [IdeaRecord]) {
        var open: [IdeaRecord] = []
        var archived: [IdeaRecord] = []
        for idea in ideas.sorted(by: IdeaRecord.listOrder) where isVisibleInRecordingMode(idea) {
            if idea.isArchived {
                archived.append(idea)
            } else {
                open.append(idea)
            }
        }
        archived.sort { $0.updatedAt > $1.updatedAt }
        return (open, archived)
    }

    func loadIdeas() async {
        do {
            let loaded = try await storage.loadIdeas()
            if loaded != ideas { ideas = loaded }
            hasLoadedIdeasOnce = true
        } catch {
            logger.error("Failed to load ideas: \(error.localizedDescription)")
        }
    }

    /// Jot an Idea down: the words as typed, nothing else asked.
    @discardableResult
    func createIdea(title: String, notes: String? = nil, links: [IdeaLink] = []) async -> IdeaRecord? {
        guard !IdeaRecord.normalizedTitle(title).isEmpty else { return nil }
        do {
            let idea = try await storage.createIdea(title: title, notes: notes, links: links)
            await loadIdeas()
            return ideas.first(where: { $0.id == idea.id }) ?? idea
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to create Idea: \(error.localizedDescription)")
            showToast("Could not save the idea")
            return nil
        }
    }

    /// Reword an Idea or write its note; nil leaves a field alone.
    func updateIdea(ideaID: String, title: String? = nil, notes: String? = nil) async {
        do {
            try await storage.updateIdea(ideaID, title: title, notes: notes)
            await loadIdeas()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update Idea: \(error.localizedDescription)")
            showToast("Could not save the idea")
        }
    }

    func setIdeaStatus(ideaID: String, status: IdeaStatus) async {
        do {
            try await storage.setIdeaStatus(ideaID, status: status)
            await loadIdeas()
            showToast(status == .archived ? "Archived" : "Back on the list")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to change an Idea's status: \(error.localizedDescription)")
            showToast("Could not change the idea")
        }
    }

    /// Link research or an exploration to an Idea: the drop of sources on
    /// its row, a pick in its Link sheet, or the Goal it just became. Targets
    /// already linked are skipped and said so.
    func linkIdea(ideaID: String, kind: IdeaLinkKind, targetIDs: [String]) async {
        let ids = targetIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        do {
            let result = try await storage.linkIdea(ideaID, kind: kind, targetIDs: ids)
            await loadIdeas()
            let skipped = ids.count - result.added
            if result.added == 0 {
                showToast("Already linked")
            } else if skipped > 0 {
                showToast("Linked \(result.added), \(skipped) already there")
            } else {
                showToast(result.added == 1 ? "Linked" : "Linked \(result.added) \(kind == .notebook ? "notebooks" : kind.plural)")
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to link an Idea: \(error.localizedDescription)")
            showToast("Could not link the idea")
        }
    }

    func unlinkIdea(ideaID: String, kind: IdeaLinkKind, targetIDs: [String]) async {
        do {
            try await storage.unlinkIdea(ideaID, kind: kind, targetIDs: targetIDs)
            await loadIdeas()
            showToast("Unlinked")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to unlink an Idea: \(error.localizedDescription)")
            showToast("Could not unlink")
        }
    }

    /// Forget an Idea. What it was linked to stays.
    func deleteIdea(ideaID: String) async {
        do {
            try await storage.deleteIdea(ideaID)
            ideas.removeAll { $0.id == ideaID }
            showToast("Deleted the idea")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to delete an Idea: \(error.localizedDescription)")
            showToast("Could not delete the idea")
        }
    }

    /// An Idea becomes a Goal (product owner, 2026-09-20: a corollary to goals):
    /// the Goal is set with the Idea's words and the deadline chosen, and the
    /// Idea keeps a link to it so the row reads where the thought went. The
    /// Idea stays open; archiving it is the learner's call.
    @discardableResult
    func makeGoal(from idea: IdeaRecord, deadline: Date, notebookID: String?, artifactID: String?) async -> LearningGoalRecord? {
        guard let goal = await createGoal(title: idea.title, deadline: deadline, notebookID: notebookID, artifactID: artifactID) else {
            return nil
        }
        do {
            try await storage.linkIdea(idea.id, kind: .goal, targetIDs: [goal.id])
            await loadIdeas()
        } catch {
            logger.error("The Goal was set but could not be linked to its Idea: \(error.localizedDescription)")
        }
        return goal
    }

    // MARK: Resolving links

    /// The title of what a link points at, from the loaded library; nil when
    /// the record is gone or not loaded yet, which the row draws as no chip.
    func ideaLinkTitle(_ link: IdeaLink) -> String? {
        switch link.kind {
        case .source:
            return articlesById[link.targetID].map { displayTitle(for: $0) }
        case .artifact:
            return artifacts.first(where: { $0.id == link.targetID })?.title
        case .chat:
            return reviewSessionLinks.first(where: { $0.id == link.targetID })?.title
        case .goal, .notebook:
            return learningGoals.first(where: { $0.id == link.targetID })?.title
        }
    }

    /// The glyph for a link's chip: a source's type, a Doc's kind, or the
    /// kind's own symbol.
    func ideaLinkSymbolName(_ link: IdeaLink) -> String {
        switch link.kind {
        case .artifact:
            return artifacts.first(where: { $0.id == link.targetID })?.goalRowSymbolName ?? link.kind.symbolName
        default:
            return link.kind.symbolName
        }
    }

    /// Open what a link points at, beside the Ideas tab where that applies:
    /// a source in the Reader, a Doc or Site as itself, a chat in the chat
    /// pane, a Goal on the Goals tab, a Notebook in its workbench.
    func openIdeaLink(_ link: IdeaLink) async {
        switch link.kind {
        case .source:
            await openLinkedSourceInReader(link.targetID, beside: .ideas)
        case .artifact:
            if !hasLoadedArtifactsOnce { await loadArtifacts() }
            guard artifacts.contains(where: { $0.id == link.targetID }) else {
                showToast("That page or site is no longer in your library")
                return
            }
            await openTeamArtifact(link.targetID)
        case .chat:
            requestResumeReviewSession(link.targetID)
        case .goal:
            openGoalsInReader()
        case .notebook:
            openNotebookInReader(link.targetID)
        }
    }
}
