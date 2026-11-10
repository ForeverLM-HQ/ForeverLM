// StorageService: shared Schedule placements.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Shared Schedule placements

    func loadScheduledSources(goalID: String? = nil) throws -> [ScheduledSourceEntry] {
        try knowledgeStore().loadScheduledSources(goalID: goalID)
    }

    func addSourceToGoal(sourceID: String, goalID: String, plannedAt: Date? = nil) throws {
        try knowledgeStore().addSourceToGoal(sourceID: sourceID, goalID: goalID, plannedAt: plannedAt)
        scheduleCloudKitSync(.immediate)
    }

    func removeSourceFromGoal(sourceID: String, goalID: String) throws {
        try knowledgeStore().removeSourceFromGoal(sourceID: sourceID, goalID: goalID)
        scheduleCloudKitSync(.immediate)
    }

    func removeScheduledSource(sourceID: String) throws {
        try knowledgeStore().removeScheduledSource(sourceID: sourceID)
        scheduleCloudKitSync(.immediate)
    }

    /// Batch schedule removal for day and week clears. Goal-scoped clears
    /// remove only that goal's tag; unified Schedule clears delete the placements.
    /// KnowledgeStore records CloudKit metadata for each mutation, then the batch
    /// schedules one outbound sync (including any changes made before an error).
    func removeSourcesFromSchedule(goalID: String?, sourceIDs: [String]) throws {
        guard !sourceIDs.isEmpty else { return }
        defer { scheduleCloudKitSync(.immediate) }
        try knowledgeStore().removeSourcesFromSchedule(goalID: goalID, sourceIDs: sourceIDs)
    }

    func setScheduledSourcePlannedDate(
        sourceID: String,
        plannedAt: Date,
        beforeSourceID: String? = nil
    ) throws {
        try knowledgeStore().setScheduledSourcePlannedDate(
            sourceID: sourceID,
            plannedAt: plannedAt,
            beforeSourceID: beforeSourceID
        )
        scheduleCloudKitSync(.immediate)
    }

    /// Read-only: the History pane's day-by-day record of what was consumed.
    func loadSourceConsumptionHistory(limit: Int = 500, since: Date? = nil) throws -> [SourceConsumptionEntry] {
        try knowledgeStore().loadSourceConsumptionHistory(limit: limit, since: since)
    }

    func setScheduledSourceCompletion(sourceID: String, isCompleted: Bool) throws {
        try knowledgeStore().setScheduledSourceCompletion(sourceID: sourceID, isCompleted: isCompleted)
        scheduleCloudKitSync(.immediate)
    }

    func recordScheduledSourceReview(sourceID: String, on day: Date) throws {
        try knowledgeStore().recordScheduledSourceReview(sourceID: sourceID, on: day)
        scheduleCloudKitSync(.immediate)
    }

    func recordScheduledSourceCompletion(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        try knowledgeStore().recordScheduledSourceCompletion(
            sourceID: sourceID,
            on: day,
            kind: kind
        )
        scheduleCloudKitSync(.immediate)
    }

    func recordScheduledSourceCompletions(
        sourceIDs: [String],
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        try knowledgeStore().recordScheduledSourceCompletions(
            sourceIDs: sourceIDs,
            on: day,
            kind: kind
        )
        scheduleCloudKitSync(.immediate)
    }

    /// Record automatic learning activity and make sure the source has a
    /// Schedule anchor. Explicit goal-backed plans remain independent.
    @discardableResult
    func recordScheduledSourceActivity(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let inserted = try knowledgeStore().recordScheduledSourceActivity(
            sourceID: sourceID,
            on: day,
            kind: kind,
            fraction: fraction,
            engagedSeconds: engagedSeconds
        )
        scheduleCloudKitSync(.immediate)
        return inserted
    }

    /// Plays Apple Podcasts saw, recorded as listening on the day of each play.
    /// See `KnowledgeStore.recordExternalListening`. A sync pass can record a
    /// month of plays at once, so the push is coalesced; the day's log is told
    /// only when something landed on it.
    @discardableResult
    func recordExternalListening(_ listens: [ExternalListen]) throws -> [String] {
        guard !listens.isEmpty else { return [] }
        let recorded = try knowledgeStore().recordExternalListening(listens)
        if !recorded.isEmpty {
            scheduleCloudKitSync(.coalesced)
            NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        }
        return recorded
    }

    /// Time spent with one source across its activity days.
    func sourceEngagedSeconds(sourceID: String) throws -> Double {
        try knowledgeStore().sourceEngagedSeconds(sourceID: sourceID)
    }

    func setCompanionItemReviewState(goalID: String, sourceIDs: [String], state: LearningGoalItemReviewState) throws {
        try knowledgeStore().setCompanionItemReviewState(goalID: goalID, sourceIDs: sourceIDs, state: state)
        scheduleCloudKitSync(.immediate)
    }

    func removeCompanionSources(goalID: String, sourceIDs: [String]) throws {
        try knowledgeStore().removeCompanionSources(goalID: goalID, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
    }

    func reorderCompanionSources(goalID: String, orderedSourceIDs: [String]) throws {
        try knowledgeStore().reorderCompanionSources(goalID: goalID, orderedSourceIDs: orderedSourceIDs)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func createCompanionGoal(
        title: String,
        description: String? = nil,
        summary: String? = nil,
        topic: String,
        startAt: Date,
        endAt: Date,
        dailyTarget: Int,
        discoveryEnabled: Bool,
        seedSourceIDs: [String],
        parentNotebookID: String? = nil,
        teamID: String? = nil,
        artifactID: String? = nil
    ) throws -> LearningGoalRecord {
        let goal = try knowledgeStore().createCompanionGoal(
            title: title,
            description: description,
            summary: summary,
            topic: topic,
            startAt: startAt,
            endAt: endAt,
            dailyTarget: dailyTarget,
            discoveryEnabled: discoveryEnabled,
            seedSourceIDs: seedSourceIDs,
            parentNotebookID: parentNotebookID,
            teamID: teamID,
            artifactID: artifactID
        )
        scheduleCloudKitSync(.immediate)
        return goal
    }

    /// The Board's Notebook (`KnowledgeStore.ensureBoardNotebook`), made on
    /// first use and synced when it is.
    func ensureBoardNotebook() throws -> LearningGoalRecord {
        let result = try knowledgeStore().ensureBoardNotebook()
        if result.created { scheduleCloudKitSync(.immediate) }
        return result.notebook
    }

    func companionRecentSessions(goalID: String, limit: Int) throws -> [CompanionSessionSummary] {
        try knowledgeStore().companionRecentSessions(goalID: goalID, limit: limit)
    }

    func deleteLearningGoal(
        _ goalID: String,
        cascadeChildGoals: Bool = false,
        deleteLinkedChats: Bool = false
    ) throws {
        // Resolved before the row goes: the workspace path is derived from a
        // Notebook that still has to load. `notebook_files` cascades on the FK,
        // but those rows are only an index — the folder on disk is the file.
        let workspaceURL = try? notebookWorkspaceURL(notebookID: goalID, createIfNeeded: false)
        try knowledgeStore().deleteLearningGoal(
            goalID,
            cascadeChildGoals: cascadeChildGoals,
            deleteLinkedChats: deleteLinkedChats
        )
        if let workspaceURL {
            discardNotebookWorkspace(at: workspaceURL)
        }
        scheduleCloudKitSync(.immediate)
    }

    func splitCompanionGoal(
        sourceGoalID: String,
        splits: [CompanionGoalSplitSpec],
        keepParent: Bool = true
    ) throws -> CompanionGoalSplitResult {
        let store = try knowledgeStore()
        // Resolved while the parent still exists, as a merge does: a split
        // that removes the parent hands its folder to the heir.
        let parent = try store.loadLearningGoal(sourceGoalID)
        let parentWorkspace = parent?.isNotebook == true
            ? try notebookWorkspaceURL(notebookID: sourceGoalID, createIfNeeded: false)
            : nil
        let result = try store.splitCompanionGoal(
            sourceGoalID: sourceGoalID,
            splits: splits,
            keepParent: keepParent
        )
        if let heirID = result.heirGoalID, let parent, let parentWorkspace,
           FileManager.default.fileExists(atPath: parentWorkspace.path) {
            let heirWorkspace = try notebookWorkspaceURL(notebookID: heirID, createIfNeeded: true)
            _ = Self.adoptNotebookWorkspace(from: parentWorkspace, into: heirWorkspace, mergedNotebookTitle: parent.title)
            _ = try? loadNotebookFiles(notebookID: heirID)
        }
        scheduleCloudKitSync(.immediate)
        // The split job handed the member's NotebookState sets to the heir
        // in the store (schema v2 §5.2); the surfaces read them again.
        if result.heirGoalID != nil { NotebookStateStore.reload() }
        return result
    }

    func mergeCompanionGoals(
        notebookIDs: [String],
        title: String? = nil,
        mergeNotes: Bool = true
    ) throws -> CompanionGoalMergeResult {
        let store = try knowledgeStore()
        // Workspace folders are resolved while every Notebook still exists: the
        // path is derived from a row the merge is about to delete, and the
        // folder — not the `notebook_files` index that cascades with the row —
        // is the learner's files.
        var mergeeWorkspaces: [(title: String, url: URL)] = []
        var seen = Set<String>()
        for id in notebookIDs.dropFirst() where seen.insert(id).inserted && id != notebookIDs.first {
            guard let goal = try store.loadLearningGoal(id), goal.isNotebook else { continue }
            let url = try notebookWorkspaceURL(notebookID: id, createIfNeeded: false)
            mergeeWorkspaces.append((goal.title, url))
        }
        var result = try store.mergeCompanionGoals(
            notebookIDs: notebookIDs,
            title: title,
            mergeNotes: mergeNotes
        )
        let occupied = mergeeWorkspaces.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if !occupied.isEmpty {
            let survivorWorkspace = try notebookWorkspaceURL(notebookID: result.survivorGoalID, createIfNeeded: true)
            for workspace in occupied {
                result.filesMoved += Self.adoptNotebookWorkspace(
                    from: workspace.url,
                    into: survivorWorkspace,
                    mergedNotebookTitle: workspace.title
                )
            }
            _ = try? loadNotebookFiles(notebookID: result.survivorGoalID)
        }
        scheduleCloudKitSync(.immediate)
        return result
    }

    func setLearningGoalDescription(goalID: String, description: String?) throws {
        try knowledgeStore().setLearningGoalDescription(goalID: goalID, description: description)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalTitle(goalID: String, title: String) throws {
        try knowledgeStore().setLearningGoalTitle(goalID: goalID, title: title)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalSummary(goalID: String, summary: String?) throws {
        try knowledgeStore().setLearningGoalSummary(goalID: goalID, summary: summary)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalNotes(goalID: String, notes: String) throws {
        try knowledgeStore().setLearningGoalNotes(goalID: goalID, notes: notes)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalResearchQuestions(goalID: String, questions: [String]) throws {
        try knowledgeStore().setLearningGoalResearchQuestions(goalID: goalID, questions: questions)
        scheduleCloudKitSync(.immediate)
    }

    func setRelatedNotebooks(notebookID: String, relatedNotebookIDs: [String]) throws {
        try knowledgeStore().setRelatedNotebooks(
            notebookID: notebookID,
            relatedNotebookIDs: relatedNotebookIDs
        )
        scheduleCloudKitSync(.immediate)
    }

    func setNotebookRepository(notebookID: String, repository: String?) throws {
        try knowledgeStore().setNotebookRepository(notebookID: notebookID, repository: repository)
        scheduleCloudKitSync(.immediate)
    }

    /// Link a Goal to the Doc, Site or animation it is for, or unlink it with nil.
    func setLearningGoalArtifact(goalID: String, artifactID: String?) throws {
        try knowledgeStore().setLearningGoalArtifact(goalID: goalID, artifactID: artifactID)
        scheduleCloudKitSync(.immediate)
    }

    /// Put the Goals in the learner's order: the listed ids first, the rest
    /// as they read; an empty list is deadline order again.
    @discardableResult
    func reorderLearningGoals(goalIDs: [String]) throws -> [String] {
        let order = try knowledgeStore().reorderLearningGoals(goalIDs: goalIDs)
        scheduleCloudKitSync(.immediate)
        return order
    }

    func loadLearningGoalGaps(goalID: String) throws -> [LearningGoalGap] {
        try knowledgeStore().loadLearningGoalGaps(goalID: goalID)
    }

}
