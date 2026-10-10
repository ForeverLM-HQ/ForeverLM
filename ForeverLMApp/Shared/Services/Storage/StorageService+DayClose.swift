import Foundation

extension StorageService {

    // MARK: - State

    func dayCloseState() throws -> KnowledgeStore.DayCloseState? {
        try cohortKnowledgeStore().dayCloseState()
    }

    func recordDayCloseRun(watermark: Date, now: Date = Date()) throws {
        try cohortKnowledgeStore().recordDayCloseRun(watermark: watermark, now: now)
    }

    // MARK: - Chats

    func dayCloseChatSubjects(since: Date, now: Date) throws -> [KnowledgeStore.DayCloseChatSubject] {
        try cohortKnowledgeStore().dayCloseChatSubjects(since: since, now: now)
    }

    func dayCloseDiscussedSourceIDs(for subject: KnowledgeStore.DayCloseChatSubject) throws -> [String] {
        try cohortKnowledgeStore().dayCloseDiscussedSourceIDs(for: subject)
    }

    /// The chat as the closer reads it: the title, then every turn in order.
    func dayCloseTranscript(sessionID: String, title: String) throws -> String {
        let exchanges = try cohortKnowledgeStore().loadReviewExchanges(sessionID: sessionID).map {
            ReviewableChat.Exchange(
                sequenceNumber: $0.sequenceNumber,
                question: $0.question,
                userAnswer: $0.userAnswer,
                evaluation: $0.evaluation,
                score: $0.score,
                ideaCoverage: $0.ideaCoverage,
                answeredAt: $0.answeredAt
            )
        }
        return ReviewableChat.transcript(title: title, exchanges: exchanges)
    }

    func recordChatConsolidation(sessionID: String, throughSequence: Int, sourceCount: Int, now: Date = Date()) throws {
        try cohortKnowledgeStore().recordChatConsolidation(
            sessionID: sessionID, throughSequence: throughSequence, sourceCount: sourceCount, now: now
        )
    }

    func chatConsolidationThroughSequence(sessionID: String) throws -> Int? {
        try cohortKnowledgeStore().chatConsolidationThroughSequence(sessionID: sessionID)
    }

    func setReviewSessionSummary(sessionID: String, summary: String) throws {
        try cohortKnowledgeStore().setReviewSessionSummary(sessionID: sessionID, summary: summary)
        scheduleImmediateCloudKitSyncForReviewSessions()
    }

    // MARK: - Reading

    /// Sources the learner took in far enough in (`since`, `now`] to be
    /// reviewed: reached in the window, and at the confidence a review of
    /// their own needs. What the day close warms ideas for.
    func sourceIDsConsumed(since: Date, now: Date) throws -> [String] {
        let store = try cohortKnowledgeStore()
        let reached = Set(try store.sourceIDsReached(since: since, now: now))
        guard !reached.isEmpty else { return [] }
        return try store.cohortCandidates(
            now: now,
            minimumConfidence: CohortSelector.selectableConfidence,
            restrictToSourceIDs: reached
        )
        .map(\.sourceID)
        .sorted()
    }
}
