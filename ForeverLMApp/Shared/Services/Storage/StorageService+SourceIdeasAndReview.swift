// StorageService: source ideas and memory review.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Source ideas and memory review

    func loadSourceIdeas(sourceIDs: [String], includeRetired: Bool = false) throws -> [String: [SourceIdea]] {
        try knowledgeStore().loadSourceIdeas(sourceIDs: sourceIDs, includeRetired: includeRetired)
    }

    /// One source's row without its text, for callers that need its title and
    /// type and nothing else.
    func loadSourceWithoutContent(_ id: String) throws -> StudioArticle? {
        try knowledgeStore().loadSourceForSync(id)
    }

    func sourceIdeaContentHash(sourceID: String) throws -> String? {
        try knowledgeStore().sourceIdeaContentHash(sourceID: sourceID)
    }

    func replaceSourceIdeas(sourceID: String, contentHash: String, ideas: [SourceIdea]) throws {
        try knowledgeStore().replaceSourceIdeas(sourceID: sourceID, contentHash: contentHash, ideas: ideas)
        scheduleCloudKitSync(.coalesced)
    }

    func setSourceIdeaStatus(id: String, status: SourceIdeaStatus) throws {
        try knowledgeStore().setSourceIdeaStatus(id: id, status: status)
        scheduleCloudKitSync(.coalesced)
    }

    func loadSourceReviewDepths(sourceIDs: [String]) throws -> [String: MemoryReviewDepth] {
        try knowledgeStore().loadSourceReviewDepths(sourceIDs: sourceIDs)
    }

    func setSourceReviewDepth(sourceID: String, depth: MemoryReviewDepth?) throws {
        try knowledgeStore().setSourceReviewDepth(sourceID: sourceID, depth: depth)
        scheduleCloudKitSync(.coalesced)
    }

    func setReviewSessionBriefing(sessionID: String, briefing: String?) throws {
        try knowledgeStore().setReviewSessionBriefing(sessionID: sessionID, briefing: briefing)
        scheduleCloudKitSync(.coalesced)
    }

    func loadReviewSessionBriefing(sessionID: String) throws -> String? {
        try knowledgeStore().loadReviewSessionBriefing(sessionID: sessionID)
    }

    func loadCourseQuizSittingRows() throws -> [(sessionID: String, startedAt: Date, briefing: String?)] {
        try knowledgeStore().loadCourseQuizSittingRows()
    }

    func recordMemoryContourGrade(sessionID: String, sequence: Int, grade: MemoryContourGrade) throws {
        try knowledgeStore().recordMemoryContourGrade(sessionID: sessionID, sequence: sequence, grade: grade)
        scheduleCloudKitSync(.coalesced)
    }

    @discardableResult
    func recordMemoryReviewSteer(sessionID: String, steer: MemoryReviewSteer) throws -> [MemoryIdeaCoverage]? {
        let coverage = try knowledgeStore().recordMemoryReviewSteer(sessionID: sessionID, steer: steer)
        scheduleCloudKitSync(.coalesced)
        return coverage
    }

    func memoryReviewSteers(sessionID: String) throws -> [(sourceID: String, steer: MemoryReviewSteer)] {
        try knowledgeStore().memoryReviewSteers(sessionID: sessionID)
    }

    func forkReviewSession(
        sessionID: String,
        throughExchangeID: String,
        field: ReviewExchangeMessageField
    ) throws -> ReviewSessionRecord {
        let session = try knowledgeStore().forkReviewSession(
            sessionID: sessionID,
            throughExchangeID: throughExchangeID,
            field: field
        )
        scheduleCloudKitSync(.immediate)
        return session
    }

    func loadReviewSessionCardIDs(sessionID: String) throws -> [String] {
        try knowledgeStore().loadReviewSessionCardIDs(sessionID: sessionID)
    }

    func updateReviewSessionModel(
        sessionID: String,
        modelProvider: String,
        modelID: String,
        modelEffort: String?,
        modelSpeed: String?
    ) throws {
        try knowledgeStore().updateReviewSessionModel(
            sessionID: sessionID,
            modelProvider: modelProvider,
            modelID: modelID,
            modelEffort: modelEffort,
            modelSpeed: modelSpeed
        )
        scheduleCloudKitSync(.soon)
    }

    func loadReviewSessionModelRoute(sessionID: String) throws -> ReviewSessionModelRoute? {
        try knowledgeStore().loadReviewSessionModelRoute(sessionID: sessionID)
    }

    func updateReviewSessionTitle(sessionID: String, title: String) throws {
        try knowledgeStore().updateReviewSessionTitle(sessionID: sessionID, title: title)
        scheduleCloudKitSync(.soon)
    }

    /// Swap in the AI-suggested title only if the learner has not renamed the
    /// chat since it was opened. Returns false when the rename won.
    func replaceProvisionalReviewSessionTitle(
        sessionID: String,
        provisionalTitle: String,
        title: String
    ) throws -> Bool {
        let replaced = try knowledgeStore().replaceProvisionalReviewSessionTitle(
            sessionID: sessionID,
            provisionalTitle: provisionalTitle,
            title: title
        )
        if replaced {
            scheduleCloudKitSync(.soon)
        }
        return replaced
    }

    func updateReviewSessionGoal(sessionID: String, goalID: String?) throws {
        try knowledgeStore().updateReviewSessionGoal(sessionID: sessionID, goalID: goalID)
        scheduleCloudKitSync(.soon)
    }

    /// Hides a chat from the sidebar on every Mac signed into this account, or
    /// shows it again. Not a change to the chat: its record is not republished
    /// and no team copy follows, because hiding is the learner's view of the
    /// chat, not a fact about it (the same rule as `setArtifactHidden`); the
    /// view syncs as its own private-zone record. Returns the resulting
    /// `hiddenAt`.
    @discardableResult
    func setReviewSessionHidden(sessionID: String, hidden: Bool) throws -> Date? {
        let hiddenAt = try knowledgeStore().setReviewSessionHidden(sessionID, hidden: hidden)
        scheduleCloudKitSync(.soon)
        return hiddenAt
    }

    // What a chat had loaded describes this Mac's prompt, not the
    // conversation, so like the history digest below it never schedules a
    // CloudKit pass.
    func updateReviewSessionLoadedSources(sessionID: String, sourceIDs: [String]) throws {
        try knowledgeStore().updateReviewSessionLoadedSources(sessionID: sessionID, sourceIDs: sourceIDs)
    }

    func loadReviewSessionLoadedSourceIDs(sessionID: String) throws -> [String]? {
        try knowledgeStore().loadReviewSessionLoadedSourceIDs(sessionID: sessionID)
    }

    func chatDiscussedSourceIDs(sessionID: String) throws -> [String] {
        try knowledgeStore().chatDiscussedSourceIDs(sessionID: sessionID)
    }

    func loadReviewSessionGoalID(sessionID: String) throws -> String? {
        try knowledgeStore().loadReviewSessionGoalID(sessionID: sessionID)
    }

    // The history digest is a local cache of the synced exchanges, so neither
    // accessor schedules a CloudKit pass.
    func loadReviewSessionHistoryDigest(sessionID: String) throws -> ReviewSessionHistoryDigest? {
        try knowledgeStore().loadReviewSessionHistoryDigest(sessionID: sessionID)
    }

    func saveReviewSessionHistoryDigest(_ digest: ReviewSessionHistoryDigest) throws {
        try knowledgeStore().saveReviewSessionHistoryDigest(digest)
    }

    @discardableResult
    func addReviewExchange(
        sessionID: String,
        question: String,
        answer: String,
        evaluation: String,
        score: Double? = nil,
        knowledgeNote: String? = nil,
        sourceRefs: [String],
        answeredAt: Date = Date()
    ) throws -> Int {
        let sequence = try knowledgeStore().addReviewExchange(
            sessionID: sessionID,
            question: question,
            answer: answer,
            evaluation: evaluation,
            score: score,
            knowledgeNote: knowledgeNote,
            sourceRefs: sourceRefs,
            answeredAt: answeredAt
        )
        scheduleCloudKitSync(.soon)
        return sequence
    }

    @discardableResult
    func addReviewPrompt(
        sessionID: String,
        question: String,
        sourceRefs: [String]
    ) throws -> Int {
        let sequence = try knowledgeStore().addReviewPrompt(
            sessionID: sessionID,
            question: question,
            sourceRefs: sourceRefs
        )
        scheduleCloudKitSync(.soon)
        return sequence
    }

    @discardableResult
    func recordPendingReviewUserMessage(
        sessionID: String,
        answer: String,
        sourceRefs: [String],
        contextContent: String? = nil
    ) throws -> Int {
        let sequence = try knowledgeStore().recordPendingReviewUserMessage(
            sessionID: sessionID,
            answer: answer,
            sourceRefs: sourceRefs,
            contextContent: contextContent
        )
        scheduleCloudKitSync(.soon)
        return sequence
    }

    @discardableResult
    func answerPendingReviewExchange(
        sessionID: String,
        sequence: Int? = nil,
        answer: String,
        evaluation: String,
        score: Double? = nil,
        knowledgeNote: String? = nil,
        sourceRefs: [String],
        answeredAt: Date = Date()
    ) throws -> Int? {
        let answered = try knowledgeStore().answerPendingReviewExchange(
            sessionID: sessionID,
            sequence: sequence,
            answer: answer,
            evaluation: evaluation,
            score: score,
            knowledgeNote: knowledgeNote,
            sourceRefs: sourceRefs,
            answeredAt: answeredAt
        )
        if answered != nil {
            scheduleCloudKitSync(.soon)
        }
        return answered
    }

    func completeReviewSession(sessionID: String, overallScore: Double? = nil, summary: String, endedAt: Date = Date()) throws {
        try knowledgeStore().completeReviewSession(
            sessionID: sessionID,
            overallScore: overallScore,
            summary: summary,
            endedAt: endedAt
        )
        scheduleCloudKitSync(.immediate)
    }

    func reopenReviewSession(sessionID: String) throws {
        try knowledgeStore().reopenReviewSession(sessionID: sessionID)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func saveReviewSessionLink(title: String, url: String, sourceIDs: [String] = []) throws -> ReviewSessionRecord {
        let link = try knowledgeStore().saveReviewSessionLink(title: title, url: url, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
        return link
    }

    /// What `saveImportedChat` did.
    struct ImportedChatOutcome: Equatable, Sendable {
        let sessionID: String
        let created: Bool
        let appended: Int
        let replaced: Int
    }

    /// A chat read from another app's own record of it — a Gemini Notebook
    /// conversation — kept under an id that record gives it. The first import
    /// writes it; a later one brings the stored chat level with the record, as
    /// `import_review_chat` does for a Claude Code session file, so reading a
    /// notebook again adds what was said since without a second copy. It is a
    /// chat and not a review (`kind` chat), so its sources are not marked
    /// reviewed, and it is drawn on the day's log (the Activity pane) at the
    /// hours the record's own stamps say it ran.
    @discardableResult
    func saveImportedChat(
        id: String,
        title: String,
        messages: [ReviewTranscriptMessage],
        sourceIDs: [String],
        notebookID: String?,
        modelProvider: String
    ) throws -> ImportedChatOutcome {
        let store = try knowledgeStore()
        let turns = ReviewTranscriptParser.turns(from: messages)
        guard !turns.isEmpty else {
            throw KnowledgeStoreError.invalidData("The chat “\(title)” had no readable messages.")
        }
        let stamps = messages.compactMap(\.timestamp)
        let outcome: ImportedChatOutcome
        if try store.loadReviewSessionForSync(id) != nil {
            let reconciled = try store.reconcileReviewChatExchanges(
                sessionID: id,
                turns: turns,
                sourceIDs: sourceIDs,
                summary: nil,
                overallScore: nil,
                modelProvider: modelProvider,
                modelID: nil,
                endedAt: stamps.max()
            )
            outcome = ImportedChatOutcome(sessionID: id, created: false, appended: reconciled.appended, replaced: reconciled.replaced)
        } else {
            try store.importReviewChatSession(
                id: id,
                title: title,
                turns: turns,
                sourceIDs: sourceIDs,
                goalID: notebookID,
                summary: nil,
                overallScore: nil,
                modelProvider: modelProvider,
                modelID: nil,
                createdAt: stamps.min() ?? Date(),
                endedAt: stamps.max(),
                kind: .chat,
                chatKind: .chat,
                marksReviewed: false
            )
            outcome = ImportedChatOutcome(sessionID: id, created: true, appended: turns.count, replaced: 0)
        }
        if !stamps.isEmpty {
            do {
                _ = try store.recordDayActivityObservations(kind: .chat, targetID: id, title: title, at: stamps)
            } catch {
                // The chat is saved either way; only its place on the clock is lost.
                perfLogger.error("Imported chat \(id, privacy: .public) could not be put on the day's log: \(error.localizedDescription, privacy: .public)")
            }
        }
        scheduleCloudKitSync(.immediate)
        return outcome
    }

    func loadReviewSessionLinks() throws -> [ReviewSessionRecord] {
        try knowledgeStore().loadReviewSessionLinks()
    }

    func loadReviewSessionExchanges(sessionID: String) throws -> [ReviewExchangeRecord] {
        try knowledgeStore().loadReviewSessionExchanges(sessionID: sessionID)
    }

    func searchReviewSessionIDs(matching query: String) throws -> Set<String> {
        try knowledgeStore().searchReviewSessionIDs(matching: query)
    }

    func deleteReviewExchangeMessage(
        sessionID: String,
        exchangeID: String,
        field: ReviewExchangeMessageField
    ) throws {
        try knowledgeStore().deleteReviewExchangeMessage(
            sessionID: sessionID,
            exchangeID: exchangeID,
            field: field
        )
        scheduleCloudKitSync(.immediate)
    }

    func deleteReviewSession(_ sessionId: String) throws {
        try knowledgeStore().deleteReviewSession(sessionId)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func deleteReviewSessionIfNoRecordedConversation(_ sessionID: String) throws -> Bool {
        let deleted = try knowledgeStore().deleteReviewSessionIfNoRecordedConversation(sessionID)
        if deleted {
            scheduleCloudKitSync(.immediate)
        }
        return deleted
    }

    func updateReviewSessionSources(sessionID: String, sourceIDs: [String]) throws {
        try knowledgeStore().updateReviewSessionSources(sessionID: sessionID, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
    }

    func loadLearningGoals() throws -> [LearningGoalRecord] {
        try knowledgeStore().loadLearningGoals()
    }

    func loadLearningGoal(_ id: String) throws -> LearningGoalRecord? {
        try knowledgeStore().loadLearningGoal(id)
    }

}
