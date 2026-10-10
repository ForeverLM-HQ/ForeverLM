import Foundation

/// Off-main access to the Ideas tab's records (docs/ideas-design.md).
///
/// Thin pass-throughs to `KnowledgeStore` plus the sync urgency: an Idea is
/// jotted down in the moment, and the other Mac should have it before the
/// learner looks for it there, so every write pushes at once.
extension StorageService {

    func loadIdeas(includeArchived: Bool = true) throws -> [IdeaRecord] {
        try notebookFilesKnowledgeStore().loadIdeas(includeArchived: includeArchived)
    }

    func loadIdea(_ ideaID: String) throws -> IdeaRecord? {
        try notebookFilesKnowledgeStore().loadIdea(ideaID)
    }

    @discardableResult
    func createIdea(title: String, notes: String? = nil, links: [IdeaLink] = []) throws -> IdeaRecord {
        let idea = try notebookFilesKnowledgeStore().createIdea(title: title, notes: notes, links: links)
        ideasDidChange()
        return idea
    }

    @discardableResult
    func updateIdea(_ ideaID: String, title: String? = nil, notes: String? = nil) throws -> IdeaRecord {
        let idea = try notebookFilesKnowledgeStore().updateIdea(ideaID, title: title, notes: notes)
        ideasDidChange()
        return idea
    }

    @discardableResult
    func setIdeaStatus(_ ideaID: String, status: IdeaStatus) throws -> IdeaRecord {
        let idea = try notebookFilesKnowledgeStore().setIdeaStatus(ideaID, status: status)
        ideasDidChange()
        return idea
    }

    @discardableResult
    func linkIdea(_ ideaID: String, kind: IdeaLinkKind, targetIDs: [String]) throws -> (idea: IdeaRecord, added: Int) {
        let result = try notebookFilesKnowledgeStore().linkIdea(ideaID, kind: kind, targetIDs: targetIDs)
        if result.added > 0 { ideasDidChange() }
        return result
    }

    @discardableResult
    func unlinkIdea(_ ideaID: String, kind: IdeaLinkKind, targetIDs: [String]) throws -> (idea: IdeaRecord, removed: Int) {
        let result = try notebookFilesKnowledgeStore().unlinkIdea(ideaID, kind: kind, targetIDs: targetIDs)
        if result.removed > 0 { ideasDidChange() }
        return result
    }

    func deleteIdea(_ ideaID: String) throws {
        try notebookFilesKnowledgeStore().deleteIdea(ideaID)
        ideasDidChange()
    }

    private func ideasDidChange() {
        scheduleImmediateCloudKitSyncForDayPlans()
        NotificationCenter.default.post(name: .ideasDidChange, object: nil)
    }
}

extension Notification.Name {
    /// An Idea was written on this Mac: the tab reads the list again.
    static let ideasDidChange = Notification.Name("foreverlm.ideasDidChange")
}
