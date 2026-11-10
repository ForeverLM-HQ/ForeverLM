// StorageService: memory cards.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - AI-native memory tutor

    func saveMemoryItem(_ item: MemoryItem) throws {
        try knowledgeStore().saveMemoryItem(item)
        scheduleCloudKitSync(.soon)
    }

    func loadMemoryItem(_ id: String) throws -> MemoryItem? {
        try knowledgeStore().loadMemoryItem(id)
    }

    func loadMemoryItems(
        status: MemoryItemStatus? = nil,
        goalID: String? = nil
    ) throws -> [MemoryItem] {
        try knowledgeStore().loadMemoryItems(status: status, goalID: goalID)
    }

    func loadMemoryItemsForSession(_ sessionID: String) throws -> [MemoryItem] {
        try knowledgeStore().loadMemoryItemsForSession(sessionID)
    }

    func setMemoryItemStatus(
        id: String,
        status: MemoryItemStatus,
        updatedAt: Date = Date()
    ) throws {
        try knowledgeStore().setMemoryItemStatus(id: id, status: status, updatedAt: updatedAt)
        scheduleCloudKitSync(.soon)
    }

    func deleteMemoryItem(_ id: String) throws {
        try knowledgeStore().deleteMemoryItem(id)
        scheduleCloudKitSync(.soon)
    }

    @discardableResult
    func recordMemoryAttempt(_ attempt: MemoryAttempt) throws -> Bool {
        let inserted = try knowledgeStore().recordMemoryAttempt(attempt)
        if inserted {
            scheduleCloudKitSync(.soon)
        }
        return inserted
    }

    func loadMemoryAttempt(_ id: String) throws -> MemoryAttempt? {
        try knowledgeStore().loadMemoryAttempt(id)
    }

    func loadMemoryAttempts(
        memoryItemID: String? = nil,
        sessionID: String? = nil
    ) throws -> [MemoryAttempt] {
        try knowledgeStore().loadMemoryAttempts(memoryItemID: memoryItemID, sessionID: sessionID)
    }

    func reviewedMemorySourceIDs(sessionID: String) throws -> [String] {
        try knowledgeStore().reviewedMemorySourceIDs(sessionID: sessionID)
    }

    func memoryStruggleProjection(
        memoryItemID: String,
        limit: Int = 3
    ) throws -> MemoryStruggleProjection? {
        try knowledgeStore().memoryStruggleProjection(
            memoryItemID: memoryItemID,
            limit: limit
        )
    }

    func deleteMemoryAttempt(_ id: String) throws {
        try knowledgeStore().deleteMemoryAttempt(id)
        scheduleCloudKitSync(.soon)
    }

    func loadMemorySchedule(memoryItemID: String) throws -> MemorySchedule? {
        try knowledgeStore().loadMemorySchedule(memoryItemID: memoryItemID)
    }

    @discardableResult
    func rebuildMemorySchedule(memoryItemID: String) throws -> MemorySchedule? {
        try knowledgeStore().rebuildMemorySchedule(memoryItemID: memoryItemID)
    }

    // MARK: Memory cards (KnowledgeStore+MemoryCards.swift)

    /// Keeps a drafted card as its Memory item, once
    /// (`KnowledgeStore.keepMemoryCard`).
    @discardableResult
    func keepMemoryCard(
        _ card: MemoryCard,
        sourceID: String,
        quote: String,
        alsoFrom: [CardSourceLink] = [],
        ideaID: String? = nil,
        at now: Date = Date()
    ) throws -> MemoryItem {
        let item = try knowledgeStore().keepMemoryCard(
            card,
            sourceID: sourceID,
            quote: quote,
            alsoFrom: alsoFrom,
            ideaID: ideaID,
            at: now
        )
        scheduleCloudKitSync(.soon)
        return item
    }

    /// Retires a card's item (`KnowledgeStore.retireMemoryCard`).
    func retireMemoryCard(memoryItemID: String, at now: Date = Date()) throws {
        try knowledgeStore().retireMemoryCard(memoryItemID: memoryItemID, at: now)
        scheduleCloudKitSync(.soon)
    }

    /// Retires a card's item and keeps its revision under a new card id
    /// (`KnowledgeStore.startMemoryCardOver`).
    @discardableResult
    func startMemoryCardOver(
        memoryItemID: String,
        as revision: MemoryCard,
        at now: Date = Date()
    ) throws -> MemoryItem {
        let item = try knowledgeStore().startMemoryCardOver(memoryItemID: memoryItemID, as: revision, at: now)
        scheduleCloudKitSync(.soon)
        return item
    }

    /// A card the learner graded themselves, written only when it counts
    /// (`KnowledgeStore.recordSelfGradedMemoryCardAttempt`).
    @discardableResult
    func recordSelfGradedMemoryCardAttempt(
        memoryItemID: String,
        prompt: String,
        remembered: Bool,
        sessionKey: String,
        practice: Bool = false,
        at now: Date = Date()
    ) throws -> MemoryCardAnswerOutcome {
        let outcome = try knowledgeStore().recordSelfGradedMemoryCardAttempt(
            memoryItemID: memoryItemID,
            prompt: prompt,
            remembered: remembered,
            sessionKey: sessionKey,
            practice: practice,
            at: now
        )
        if outcome == .recorded {
            scheduleCloudKitSync(.soon)
        }
        return outcome
    }

    /// "This asks something else" on a card's variant, written once a
    /// sitting (`KnowledgeStore.recordMemoryCardAskedSomethingElse`). Under
    /// generation 2 the rewording is also taken out on the card's Card (its
    /// variant `retired`), as the phone takes it out, so every device leaves
    /// it out whatever answers it holds.
    @discardableResult
    func recordMemoryCardAskedSomethingElse(
        memoryItemID: String,
        prompt: String,
        variantIndex: Int,
        sessionKey: String,
        at now: Date = Date()
    ) throws -> Bool {
        let store = try knowledgeStore()
        let inserted = try store.recordMemoryCardAskedSomethingElse(
            memoryItemID: memoryItemID,
            prompt: prompt,
            variantIndex: variantIndex,
            sessionKey: sessionKey,
            at: now
        )
        if inserted, try store.recordsMemoryForGeneration2() {
            try store.retireCardRecordVariant(cardID: memoryItemID, text: prompt, at: now)
            MemoryCardStateStore.reload()
        }
        if inserted {
            scheduleCloudKitSync(.soon)
        }
        return inserted
    }

    /// One batch of the schedule rows an older scheduler wrote, after
    /// `afterID`. See `KnowledgeStore.rebuildStaleMemorySchedules`.
    @discardableResult
    func rebuildStaleMemorySchedules(
        after afterID: String? = nil,
        limit: Int
    ) throws -> KnowledgeStore.MemoryScheduleRebuildBatch {
        try knowledgeStore().rebuildStaleMemorySchedules(after: afterID, limit: limit)
    }

    /// Today's cards in a scope, the new cards practice would take, the
    /// scope's kept cards and its cards to check, in one read
    /// (`KnowledgeStore.memoryCardReviewSnapshot`). With `includesToCheck`
    /// the sources' draft decks (`loadCardDrafts`) and their states
    /// (`cardDeckStates`: the Card rows under generation 2, the rows in
    /// `stateDefaults` under generation 1) are read; a sitting, which deals
    /// kept cards only, leaves them out.
    func memoryCardReviewSnapshot(
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        scope: MemoryCardScope?,
        includesListings: Bool = true,
        includesToCheck: Bool = true,
        stateDefaults: UserDefaults = .standard
    ) throws -> MemoryCardReviewSnapshot {
        let drafts: [MemoryCardDraftDeck]? = try includesToCheck ? loadCardDrafts() : nil
        let deckStates = try includesToCheck ? cardDeckStates(stateDefaults: stateDefaults) : { _ in MemoryCardDeckState() }
        return try knowledgeStore().memoryCardReviewSnapshot(
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: deadlines,
            scope: scope,
            includesListings: includesListings,
            toCheckFrom: drafts,
            deckState: { deckStates($0) }
        )
    }

    /// What a notebook's Practice deals: its kept cards and its undecided
    /// drafts (`KnowledgeStore.memoryCardNotebookPractice`), the draft decks
    /// and their states read as `memoryCardReviewSnapshot` reads them.
    func memoryCardNotebookPractice(
        scope: MemoryCardScope,
        now: Date,
        stateDefaults: UserDefaults = .standard
    ) throws -> MemoryCardNotebookPractice {
        let drafts = try loadCardDrafts()
        let deckStates = try cardDeckStates(stateDefaults: stateDefaults)
        return try knowledgeStore().memoryCardNotebookPractice(
            scope: scope,
            now: now,
            toCheckFrom: drafts,
            deckState: { deckStates($0) }
        )
    }

    /// What the cards a chat chose deal (`KnowledgeStore.memoryCardChosenPractice`).
    func memoryCardChosenPractice(cardIDs: [String], now: Date) throws -> MemoryCardChosenPractice {
        try knowledgeStore().memoryCardChosenPractice(cardIDs: cardIDs, now: now)
    }

    /// Today's cards, in the order they are asked (`MemoryCardQueue.today` over
    /// every item the library may ask).
    func memoryCardQueueToday(
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> MemoryCardQueue.Today {
        try knowledgeStore().memoryCardQueueToday(
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: deadlines,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    func dueMemoryItems(
        now: Date,
        limit: Int,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [DueMemoryItem] {
        try knowledgeStore().dueMemoryItems(
            now: now,
            limit: limit,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    func dueMemoryItems(
        now: Date,
        limit: Int,
        goalID: String?,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [DueMemoryItem] {
        try knowledgeStore().dueMemoryItems(
            now: now,
            limit: limit,
            goalID: goalID,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    func canonicalMemorySourceSnapshot(sourceID: String) throws -> MemorySourceSnapshot {
        try knowledgeStore().canonicalMemorySourceSnapshot(sourceID: sourceID)
    }

    func portableMemorySourceKey(sourceID: String) throws -> String {
        try knowledgeStore().portableMemorySourceKey(sourceID: sourceID)
    }

    func resolveMemorySourceID(
        portableSourceKey: String,
        restrictToSourceIDs sourceIDs: [String]
    ) throws -> String? {
        try knowledgeStore().resolveMemorySourceID(
            portableSourceKey: portableSourceKey,
            restrictToSourceIDs: sourceIDs
        )
    }

    func validatedMemorySourceAnchor(
        sourceID: String,
        excerpt: String
    ) throws -> MemorySourceAnchorValidation {
        try knowledgeStore().validatedMemorySourceAnchor(sourceID: sourceID, excerpt: excerpt)
    }

    @discardableResult
    func completePendingReviewExchangeAndRecordMemoryAttempt(
        sessionID: String,
        sequence: Int? = nil,
        answer: String,
        evaluation: String,
        knowledgeNote: String?,
        sourceRefs: [String],
        item: MemoryItem? = nil,
        expectedExistingItem: MemoryItem? = nil,
        attempt: MemoryAttempt,
        answeredAt: Date = Date()
    ) throws -> MemoryAttempt {
        let linkedAttempt = try knowledgeStore().completePendingReviewExchangeAndRecordMemoryAttempt(
            sessionID: sessionID,
            sequence: sequence,
            answer: answer,
            evaluation: evaluation,
            knowledgeNote: knowledgeNote,
            sourceRefs: sourceRefs,
            item: item,
            expectedExistingItem: expectedExistingItem,
            attempt: attempt,
            answeredAt: answeredAt
        )
        scheduleCloudKitSync(.soon)
        return linkedAttempt
    }

    func completeReviewSessionAndRecordMemoryAttempts(
        sessionID: String,
        overallScore: Double?,
        summary: String,
        endedAt: Date = Date(),
        exportedTranscript: String? = nil,
        transcriptKnowledgeNote: String? = nil,
        sessionSourceIDs: [String] = [],
        reviewedSourceIDs: [String]? = nil,
        scheduleReviewDate: Date? = nil,
        companionGoalID: String? = nil,
        companionQuizDate: String? = nil,
        companionGaps: [LearningGoalGap] = [],
        createIfMissing: ReviewSessionRecoverySeed? = nil,
        items: [MemoryItem] = [],
        expectedCurriculumFingerprints: [String: String] = [:],
        attempts: [MemoryAttempt]
    ) throws {
        try knowledgeStore().completeReviewSessionAndRecordMemoryAttempts(
            sessionID: sessionID,
            overallScore: overallScore,
            summary: summary,
            endedAt: endedAt,
            exportedTranscript: exportedTranscript,
            transcriptKnowledgeNote: transcriptKnowledgeNote,
            sessionSourceIDs: sessionSourceIDs,
            reviewedSourceIDs: reviewedSourceIDs,
            scheduleReviewDate: scheduleReviewDate,
            companionGoalID: companionGoalID,
            companionQuizDate: companionQuizDate,
            companionGaps: companionGaps,
            createIfMissing: createIfMissing,
            items: items,
            expectedCurriculumFingerprints: expectedCurriculumFingerprints,
            attempts: attempts
        )
        scheduleCloudKitSync(.soon)
    }

    @discardableResult
    func recordMemoryAttemptCreatingReviewExchange(
        sessionID: String,
        sourceRefs: [String],
        item: MemoryItem? = nil,
        expectedExistingItem: MemoryItem? = nil,
        attempt: MemoryAttempt
    ) throws -> MemoryAttempt {
        let linkedAttempt = try knowledgeStore().recordMemoryAttemptCreatingReviewExchange(
            sessionID: sessionID,
            sourceRefs: sourceRefs,
            item: item,
            expectedExistingItem: expectedExistingItem,
            attempt: attempt
        )
        scheduleCloudKitSync(.soon)
        return linkedAttempt
    }

    /// Returns the set of source IDs that have been reviewed.
    func sourceIdsWithCompletedReviewSession() throws -> Set<String> {
        try knowledgeStore().sourceIdsWithCompletedReviewSession()
    }

    func sourceIdsWithReviewSession() throws -> Set<String> {
        try knowledgeStore().sourceIdsWithReviewSession()
    }

    func sourceIdsWithLinkedChatSession() throws -> Set<String> {
        try knowledgeStore().sourceIdsWithLinkedChatSession()
    }

    func createReviewSession(
        id: String,
        topic: String,
        sourceIDs: [String],
        cardIDs: [String] = [],
        startedAt: Date = Date(),
        modelProvider: String? = nil,
        modelID: String? = nil,
        modelEffort: String? = nil,
        modelSpeed: String? = nil,
        goalID: String? = nil,
        scheduleActivityAt: Date? = nil,
        scheduleActivityKind: SourceActivityKind = .review,
        kind: ReviewSessionKind? = nil,
        briefing: String? = nil,
        chatKind: ChatKind? = nil
    ) throws {
        try knowledgeStore().createReviewSession(
            id: id,
            topic: topic,
            sourceIDs: sourceIDs,
            cardIDs: cardIDs,
            startedAt: startedAt,
            modelProvider: modelProvider,
            modelID: modelID,
            modelEffort: modelEffort,
            modelSpeed: modelSpeed,
            goalID: goalID,
            scheduleActivityAt: scheduleActivityAt,
            scheduleActivityKind: scheduleActivityKind,
            kind: kind,
            briefing: briefing,
            chatKind: chatKind
        )
        scheduleCloudKitSync(.soon)
    }

}
