// Source persistence tests: review dates, CloudKit round trips, goals and content paths.

import Testing
import CloudKit
import Foundation
import SQLite3
@testable import ForeverLM

/// Helper: create a StudioArticle with sensible defaults for testing.
private func makeArticle(url: String, title: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

extension SourcePersistenceTests {
    @Test("source review dates come from completed reviews and Schedule items")
    func testSourceReviewDates() throws {
        let store = try TestStores.inMemory()
        var article = StudioArticle(
            url: "https://example.com/review-me",
            title: "Review Me",
            sourceType: .article,
            id: "source-review-1"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.insertSourceIfNew(&article)
        var scheduledArticle = StudioArticle(
            url: "https://example.com/schedule-reviewed",
            title: "Schedule Reviewed",
            sourceType: .article,
            id: "source-schedule-reviewed"
        )
        scheduledArticle.normalizedURL = URLNormalizer.normalize(scheduledArticle.url)
        try store.insertSourceIfNew(&scheduledArticle)

        try store.createReviewSession(
            id: "session-active",
            topic: "Draft review",
            sourceIDs: [article.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        #expect((try store.sourceReviewDates())[article.id] == nil)

        try store.completeReviewSession(
            sessionID: "session-active",
            overallScore: 0.8,
            summary: "Covered the main points.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        #expect((try store.sourceReviewDates())[article.id] == Date(timeIntervalSinceReferenceDate: 200))

        _ = try store.saveReviewSessionLink(
            title: "Claude follow-up review",
            url: "https://claude.ai/share/reviewed",
            sourceIDs: [article.id],
            createdAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        #expect((try store.sourceReviewDates())[article.id] == Date(timeIntervalSinceReferenceDate: 300))

        let scheduleReviewedAt = Date(timeIntervalSinceReferenceDate: 400)
        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: LearningGoalRecord(
                    id: "goal-reviewed",
                    title: "Reviewed Plan",
                    startAt: Date(timeIntervalSinceReferenceDate: 0),
                    endAt: Date(timeIntervalSinceReferenceDate: 7 * 24 * 60 * 60),
                    createdAt: Date(timeIntervalSinceReferenceDate: 0),
                    updatedAt: scheduleReviewedAt,
                    status: "active",
                    items: [
                        LearningGoalItem(
                            id: "item-reviewed",
                            goalID: "goal-reviewed",
                            sourceID: scheduledArticle.id,
                            addedAt: Date(timeIntervalSinceReferenceDate: 0),
                            completedAt: scheduleReviewedAt
                        )
                    ]
                ),
                sourceIdentities: []
            )
        )
        #expect((try store.sourceReviewDates())[scheduledArticle.id] == scheduleReviewedAt)
    }

    @Test("review eligibility follows equivalent paper DOI records")
    func reviewEligibilityFollowsEquivalentPaperDOIRecords() throws {
        let store = try TestStores.inMemory()
        let doi = "10.1101/2026.01.02.123456"
        var detectedPaper = StudioArticle(
            url: "https://doi.org/\(doi)",
            title: "Detected Paper",
            sourceType: .paper,
            id: "detected-paper"
        )
        detectedPaper.doi = doi
        var scheduledPaper = StudioArticle(
            url: "Papers/detected-paper.pdf",
            title: "Scheduled Paper",
            sourceType: .paper,
            id: "scheduled-paper"
        )
        scheduledPaper.doi = doi.uppercased()
        try store.saveSource(detectedPaper)
        try store.saveSource(scheduledPaper)

        try store.createReviewSession(
            id: "session-paper-review",
            topic: "Detected paper review",
            sourceIDs: [detectedPaper.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.completeReviewSession(
            sessionID: "session-paper-review",
            overallScore: nil,
            summary: "Reviewed the detected paper.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        #expect(try store.sourceIdsWithLinkedChatSession().contains(scheduledPaper.id))
        #expect(try store.sourceHasLinkedChatSession(scheduledPaper.id))
        #expect((try store.sourceReviewDates())[scheduledPaper.id] == Date(timeIntervalSinceReferenceDate: 200))
    }

    @Test("review sessions store the last in-app model used")
    func reviewSessionsStoreLastModelUsed() throws {
        let store = try TestStores.inMemory()

        try store.createReviewSession(
            id: "session-model",
            topic: "Model review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            modelProvider: AIProvider.openai.rawValue,
            modelID: "gpt-5.4"
        )

        var session = try #require(try store.loadReviewSessionLinks().first { $0.id == "session-model" })
        #expect(session.modelProvider == AIProvider.openai.rawValue)
        #expect(session.modelID == "gpt-5.4")

        try store.updateReviewSessionModel(
            sessionID: "session-model",
            modelProvider: AIProvider.anthropic.rawValue,
            modelID: "claude-sonnet-4-6",
            modelEffort: AIEffort.high.rawValue,
            modelSpeed: nil
        )

        session = try #require(try store.loadReviewSessionLinks().first { $0.id == "session-model" })
        #expect(session.modelProvider == AIProvider.anthropic.rawValue)
        #expect(session.modelID == "claude-sonnet-4-6")
        #expect(try store.loadReviewSessionModelRoute(sessionID: "session-model")?.modelEffort == "high")
    }

    @Test("CloudKit review sessions remap linked sources by identity")
    func cloudKitReviewSessionsRemapLinkedSourcesByIdentity() throws {
        let store = try TestStores.inMemory()
        let localSourceID = "local-review-source"
        let remoteSourceID = "remote-review-source"
        let url = "https://example.com/same-review-source"
        var article = StudioArticle(
            url: url,
            title: "Same Review Source",
            sourceType: .article,
            id: localSourceID
        )
        article.normalizedURL = URLNormalizer.normalize(url)
        try store.saveSource(article)

        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: "remote-session",
                topic: "Remote review",
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: "completed",
                overallScore: 0.9,
                summary: "Reviewed remotely.",
                sourceIDs: [remoteSourceID],
                cardIDs: [],
                exchangeCount: 1,
                modelProvider: AIProvider.gemini.rawValue,
                modelID: "gemini-2.5-pro",
                goalID: "remote-goal",
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "exchange-1",
                        sessionID: "remote-session",
                        sequenceNumber: 1,
                        question: "Explain it.",
                        userAnswer: "Answer.",
                        evaluation: "Good.",
                        score: 0.9,
                        sourceRefs: [remoteSourceID],
                        knowledgeNote: nil,
                        answeredAt: Date(timeIntervalSinceReferenceDate: 150)
                    )
                ],
                sourceIdentities: [
                    CloudKitSourceIdentityPayload(
                        sourceID: remoteSourceID,
                        url: url,
                        normalizedURL: URLNormalizer.normalize(url),
                        doi: nil,
                        publishedDOI: nil
                    )
                ]
            )
        )

        let session = try #require(try store.loadReviewSessionLinks().first { $0.id == "remote-session" })
        #expect(session.sourceIDs == [localSourceID])
        #expect(session.modelProvider == AIProvider.gemini.rawValue)
        #expect(session.modelID == "gemini-2.5-pro")
        #expect(session.goalID == "remote-goal")
        #expect(try store.sourceIdsWithLinkedChatSession().contains(localSourceID))
        #expect((try store.sourceReviewDates())[localSourceID] == Date(timeIntervalSinceReferenceDate: 200))
    }

    @Test("CloudKit review sessions defer missing Source links until the Source arrives")
    func cloudKitReviewSessionsDeferMissingSourceLinks() throws {
        let store = try TestStores.inMemory()
        let sourceID = "later-source"
        let sessionID = "session-before-source-order"

        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: sessionID,
                topic: "Out-of-order review",
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: "completed",
                overallScore: 0.8,
                summary: "The session arrived first.",
                sourceIDs: [sourceID],
                cardIDs: [],
                exchangeCount: 0,
                modelProvider: nil,
                modelID: nil,
                goalID: nil,
                exchanges: []
            )
        )

        var linkCount = -1
        try store.query("SELECT COUNT(*) FROM review_session_sources") { statement in
            linkCount = Int(sqlite3_column_int64(statement, 0))
        }
        #expect(linkCount == 0)
        #expect(try store.loadReviewSessionForSync(sessionID)?.sourceIDs == [sourceID])

        try store.saveSource(StudioArticle(
            url: "https://example.com/later-source",
            title: "Later Source",
            sourceType: .article,
            id: sourceID
        ))

        try store.query("SELECT COUNT(*) FROM review_session_sources") { statement in
            linkCount = Int(sqlite3_column_int64(statement, 0))
        }
        #expect(linkCount == 1)
        #expect(try store.sourceHasLinkedChatSession(sourceID))
    }

    @Test("CloudKit review goal presence keeps the link when the field is absent and explicit null clears")
    func cloudKitReviewGoalPresenceIsLossless() throws {
        let store = try TestStores.inMemory()

        func payload(goalID: String?) -> CloudKitReviewSessionPayload {
            CloudKitReviewSessionPayload(
                id: "goal-presence-session",
                topic: "Goal relationship parity",
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: "completed",
                overallScore: 0.8,
                summary: "Reviewed relationship parity.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 0,
                goalID: goalID,
                exchanges: []
            )
        }

        try store.saveReviewSessionRecord(payload(goalID: "goal-linked"))
        #expect(try store.loadReviewSessionLinks().first {
            $0.id == "goal-presence-session"
        }?.goalID == "goal-linked")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let explicitNullData = try encoder.encode(payload(goalID: nil))
        var absentFieldObject = try #require(
            JSONSerialization.jsonObject(with: explicitNullData) as? [String: Any]
        )
        #expect(absentFieldObject.keys.contains("goalID"))
        #expect(absentFieldObject["goalID"] is NSNull)

        // A pre-goalID client omitted the field. Updating other session content
        // must not silently detach an existing Notebook relationship.
        absentFieldObject.removeValue(forKey: "goalID")
        let absentFieldData = try JSONSerialization.data(withJSONObject: absentFieldObject)
        let absentFieldPayload = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self,
            from: absentFieldData
        )
        #expect(!absentFieldPayload.goalIDFieldIsPresent)
        try store.saveReviewSessionRecord(absentFieldPayload)
        #expect(try store.loadReviewSessionLinks().first {
            $0.id == "goal-presence-session"
        }?.goalID == "goal-linked")

        // Current clients encode nil as an explicit null, which intentionally
        // clears the relationship and survives a decode/apply round trip.
        let clearingPayload = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self,
            from: explicitNullData
        )
        #expect(clearingPayload.goalIDFieldIsPresent)
        #expect(clearingPayload.goalID == nil)
        try store.saveReviewSessionRecord(clearingPayload)
        #expect(try store.loadReviewSessionLinks().first {
            $0.id == "goal-presence-session"
        }?.goalID == nil)
    }

    @Test("CloudKit preserves and updates a source-less mobile chat")
    func cloudKitPreservesAndUpdatesSourceLessMobileChat() throws {
        let store = try TestStores.inMemory()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let endedAt = Date(timeIntervalSinceReferenceDate: 200)

        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: "ios-live-source-less",
                topic: "Voice session",
                startedAt: startedAt,
                endedAt: endedAt,
                status: "completed",
                overallScore: nil,
                summary: "General CarPlay conversation.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 1,
                modelProvider: AIProvider.gemini.rawValue,
                modelID: "gemini-live",
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "ios-live-source-less::exchange::0000",
                        sessionID: "ios-live-source-less",
                        sequenceNumber: 0,
                        question: "What would you like to review?",
                        userAnswer: "Help me plan today's study session.",
                        evaluation: nil,
                        score: nil,
                        sourceRefs: [],
                        knowledgeNote: "Recorded from an iOS realtime voice session.",
                        answeredAt: endedAt
                    )
                ]
            )
        )

        let session = try #require(
            try store.loadReviewSessionLinks().first { $0.id == "ios-live-source-less" }
        )
        #expect(session.status == "completed")
        #expect(session.sourceIDs.isEmpty)
        #expect(session.exchangeCount == 1)

        let exchanges = try store.loadReviewSessionExchanges(sessionID: session.id)
        #expect(exchanges.count == 1)
        #expect(exchanges[0].sourceRefs.isEmpty)
        #expect(exchanges[0].userAnswer == "Help me plan today's study session.")

        let updatedEndedAt = Date(timeIntervalSinceReferenceDate: 300)
        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: session.id,
                topic: "Voice session",
                startedAt: startedAt,
                endedAt: updatedEndedAt,
                status: "completed",
                overallScore: nil,
                summary: "General CarPlay conversation with two turns.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 2,
                modelProvider: AIProvider.gemini.rawValue,
                modelID: "gemini-live",
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "ios-live-source-less::exchange::0000",
                        sessionID: session.id,
                        sequenceNumber: 0,
                        question: "What would you like to review?",
                        userAnswer: "Help me plan today's study session.",
                        evaluation: "Let's start with your scheduled sources.",
                        score: nil,
                        sourceRefs: [],
                        knowledgeNote: "Recorded from an iOS realtime voice session.",
                        answeredAt: endedAt
                    ),
                    CloudKitReviewExchangePayload(
                        id: "ios-live-source-less::exchange::0001",
                        sessionID: session.id,
                        sequenceNumber: 1,
                        question: "Which source should we discuss first?",
                        userAnswer: "The first one on today's Schedule.",
                        evaluation: "I'll open that source now.",
                        score: nil,
                        sourceRefs: [],
                        knowledgeNote: "Recorded from an iOS realtime voice session.",
                        answeredAt: updatedEndedAt
                    )
                ]
            )
        )

        let roundTrip = try #require(try store.loadReviewSessionForSync(session.id))
        #expect(roundTrip.sourceIDs.isEmpty)
        #expect(roundTrip.exchangeCount == 2)
        #expect(roundTrip.exchanges.count == 2)
        #expect(roundTrip.exchanges[0].evaluation == "Let's start with your scheduled sources.")
        #expect(roundTrip.exchanges[1].userAnswer == "The first one on today's Schedule.")
        #expect(roundTrip.sourceIdentities.isEmpty)
    }

    @Test("CloudKit review session payload preserves its Goal link")
    func cloudKitReviewSessionPayloadPreservesGoalLink() throws {
        let store = try TestStores.inMemory()
        try store.createReviewSession(
            id: "goal-linked-session",
            topic: "Goal review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            goalID: "goal-123"
        )

        let payload = try #require(try store.loadReviewSessionForSync("goal-linked-session"))
        #expect(payload.goalID == "goal-123")
    }

    @Test("CloudKit learning goals remap item sources by identity")
    func cloudKitLearningGoalsRemapItemSourcesByIdentity() throws {
        let store = try TestStores.inMemory()
        let localSourceID = "local-scheduled-source"
        let remoteSourceID = "remote-scheduled-source"
        let url = "https://example.com/same-scheduled-source"
        var article = StudioArticle(
            url: url,
            title: "Same Scheduled Source",
            sourceType: .article,
            id: localSourceID
        )
        article.normalizedURL = URLNormalizer.normalize(url)
        try store.saveSource(article)

        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end = Date(timeIntervalSinceReferenceDate: 100 + 7 * 24 * 60 * 60)
        let completedAt = Date(timeIntervalSinceReferenceDate: 300)
        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: LearningGoalRecord(
                    id: "remote-goal",
                    title: "Remote Plan",
                    startAt: start,
                    endAt: end,
                    createdAt: start,
                    updatedAt: completedAt,
                    status: "active",
                    items: [
                        LearningGoalItem(
                            id: "remote-item",
                            goalID: "remote-goal",
                            sourceID: remoteSourceID,
                            addedAt: start,
                            completedAt: completedAt
                        )
                    ]
                ),
                sourceIdentities: [
                    CloudKitSourceIdentityPayload(
                        sourceID: remoteSourceID,
                        url: url,
                        normalizedURL: URLNormalizer.normalize(url),
                        doi: nil,
                        publishedDOI: nil
                    )
                ]
            )
        )

        let goal = try #require(try store.loadLearningGoal("remote-goal"))
        #expect(goal.items.map(\.sourceID) == [localSourceID])
        #expect(goal.items.first?.completedAt == completedAt)
    }

    /// A Goal arriving from another Mac must stay a Goal. When `parentNotebookID`
    /// was dropped from the inbound mapping it was written NULL, so the receiving
    /// device presented the Goal as a top-level Notebook and then propagated the
    /// nulled parent back on its next edit.
    /// A Goal that syncs in without its `parent_notebook_id` is a sync bug, not a
    /// partial success — it arrives stripped of the relationship that makes it a
    /// Goal rather than a Notebook.
    @Test("CloudKit learning goals keep their parent Notebook")
    func cloudKitLearningGoalsKeepParent() throws {
        let store = try TestStores.inMemory()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end = Date(timeIntervalSinceReferenceDate: 100 + 7 * 24 * 60 * 60)

        let notebook = try store.createCompanionGoal(
            title: "Mitochondrial biology",
            description: nil,
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: nil
        )

        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: LearningGoalRecord(
                    id: "remote-nested-goal",
                    title: "Write article about mitochondrial transplantation",
                    startAt: start,
                    endAt: end,
                    createdAt: start,
                    updatedAt: end,
                    status: LearningGoalStatus.active.rawValue,
                    items: [],
                    kind: LearningGoalRecord.companionKind,
                    parentNotebookID: notebook.id
                ),
                sourceIdentities: []
            )
        )

        let received = try #require(try store.loadLearningGoal("remote-nested-goal"))
        #expect(received.parentNotebookID == notebook.id)
        #expect(received.isNotebookGoal)
        #expect(!received.isNotebook)
    }

    /// `researchQuestions` is the same inbound-mapping trap `parentNotebookID` fell
    /// into: `LearningGoalRecord.init` defaults it to nil, so leaving it out of the
    /// payload mapping compiles clean and silently nulls the field. The upsert's
    /// COALESCE guard then always keeps the local value, and a Notebook's defining
    /// questions never reach the other Mac.
    @Test("CloudKit learning goals carry their research questions")
    func cloudKitLearningGoalsCarryResearchQuestions() throws {
        let store = try TestStores.inMemory()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end = Date(timeIntervalSinceReferenceDate: 100 + 7 * 24 * 60 * 60)
        let questions = [
            "Why might mitochondrial transplantation work mechanistically?",
            "Are mtDNA mutations primarily responsible for mitochondrial dysfunction as we age?",
        ]

        func receive(_ researchQuestions: [String]?) throws {
            try store.saveLearningGoalRecord(
                CloudKitLearningGoalPayload(
                    goal: LearningGoalRecord(
                        id: "remote-notebook",
                        title: "Mitochondrial Transplantation",
                        startAt: start,
                        endAt: end,
                        createdAt: start,
                        updatedAt: end,
                        status: LearningGoalStatus.active.rawValue,
                        items: [],
                        kind: LearningGoalRecord.companionKind,
                        researchQuestions: researchQuestions
                    ),
                    sourceIdentities: []
                )
            )
        }

        try receive(questions)
        #expect(try store.loadLearningGoal("remote-notebook")?.researchQuestions == questions)

        // nil is "never set" — an older device with no opinion must not wipe the list.
        try receive(nil)
        #expect(try store.loadLearningGoal("remote-notebook")?.researchQuestions == questions)

        // An explicit clear travels as [] and wins.
        try receive([])
        #expect(try store.loadLearningGoal("remote-notebook")?.researchQuestions == [])
    }

    @Test("Goal lifecycle status is explicit, not inferred from the deadline")
    func goalLifecycleStatusIsExplicit() throws {
        let store = try TestStores.inMemory()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let passed = Date(timeIntervalSinceReferenceDate: 1000)

        let notebook = try store.createCompanionGoal(
            title: "Parent",
            description: nil,
            topic: "parent",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: nil
        )
        let goal = try store.createCompanionGoal(
            title: "Ship the article",
            description: nil,
            topic: "article",
            startAt: start,
            endAt: passed,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )

        // Deadline long past, but the work was never marked finished.
        let overdue = try #require(try store.loadLearningGoal(goal.id))
        #expect(overdue.lifecycleStatus == .active)
        #expect(overdue.isOverdue())
        #expect(!overdue.isDone)

        try store.setLearningGoalStatus(goalID: goal.id, status: .done)
        let done = try #require(try store.loadLearningGoal(goal.id))
        #expect(done.isDone)
        // Finished work is never also overdue.
        #expect(!done.isOverdue())

        // An open-ended Notebook can never be overdue.
        let parent = try #require(try store.loadLearningGoal(notebook.id))
        #expect(!parent.isOverdue())
    }

    /// The Schedule reads `scheduled_sources` but `LearningGoalRecord.completedCount`
    /// reads `learning_goal_items`. Only the placement was ever written by the review
    /// path, so every companion goal reported 0% done regardless of work finished.
    @Test("Completing a scheduled source marks it complete on the goal too")
    func completionMirrorsOntoGoalItems() throws {
        let store = try TestStores.inMemory()
        var article = StudioArticle(
            url: "https://example.com/mito-transfer",
            title: "Mitochondrial transfer",
            sourceType: .article,
            id: "src-mito"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.saveSource(article)

        let goal = try store.createCompanionGoal(
            title: "Write the article",
            description: nil,
            topic: "mitochondrial transplantation",
            startAt: Date(timeIntervalSinceReferenceDate: 0),
            endAt: Date(timeIntervalSinceReferenceDate: 10 * 86_400),
            dailyTarget: 2,
            discoveryEnabled: false,
            seedSourceIDs: [article.id],
            parentNotebookID: nil
        )
        try store.addSourceToGoal(
            sourceID: article.id,
            goalID: goal.id,
            plannedAt: Date(timeIntervalSinceReferenceDate: 86_400)
        )

        #expect(try #require(try store.loadLearningGoal(goal.id)).completedCount == 0)

        try store.markScheduledSourceDone(sourceID: article.id)

        let done = try #require(try store.loadLearningGoal(goal.id))
        #expect(done.completedCount == 1)
        #expect(done.items.first { $0.sourceID == article.id }?.isCompleted == true)

        // Reopening puts the source back on the calendar without erasing the
        // durable record that it was completed for this Notebook. A NULL item
        // completion would not converge through CloudKit's max-date merge.
        try store.reopenScheduledSource(sourceID: article.id)
        let reopened = try #require(try store.loadLearningGoal(goal.id))
        #expect(reopened.completedCount == 1)
        #expect(reopened.items.first { $0.sourceID == article.id }?.isCompleted == true)
    }

    @Test("Source activity creates one pending calendar entry and preserves existing plans")
    func sourceActivityCreatesIdempotentCalendarEntry() throws {
        let store = try TestStores.inMemory()
        var active = StudioArticle(
            url: "https://example.com/active-reading",
            title: "Active reading",
            sourceType: .article,
            id: "source-active-reading"
        )
        active.normalizedURL = URLNormalizer.normalize(active.url)
        try store.saveSource(active)

        let activityDay = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(try store.recordScheduledSourceActivity(sourceID: active.id, on: activityDay, kind: .reading))
        #expect(!(try store.recordScheduledSourceActivity(sourceID: active.id, on: activityDay, kind: .reading)))
        #expect(try store.recordScheduledSourceActivity(
            sourceID: active.id,
            on: activityDay.addingTimeInterval(86_400),
            kind: .chat
        ))

        let activeEntry = try #require(
            try store.loadScheduledSources().first { $0.placement.sourceID == active.id }
        )
        let activePlacement = activeEntry.placement
        #expect(Calendar.current.isDate(
            activePlacement.plannedAt,
            inSameDayAs: activityDay.addingTimeInterval(86_400)
        ))
        #expect(!activePlacement.isCompleted)
        #expect(activeEntry.activityDays.count == 2)
        #expect(activeEntry.isAutomatic)
        #expect(activeEntry.activityDays[0].kinds == [.reading])
        #expect(activeEntry.activityDays[1].kinds == [.chat])

        var planned = StudioArticle(
            url: "https://example.com/planned-reading",
            title: "Planned reading",
            sourceType: .article,
            id: "source-planned-reading"
        )
        planned.normalizedURL = URLNormalizer.normalize(planned.url)
        try store.saveSource(planned)
        let futureDay = activityDay.addingTimeInterval(5 * 86_400)
        try store.setScheduledSourcePlannedDate(sourceID: planned.id, plannedAt: futureDay)

        #expect(try store.recordScheduledSourceActivity(sourceID: planned.id, on: activityDay, kind: .listening))
        let plannedEntry = try #require(
            try store.loadScheduledSources().first { $0.placement.sourceID == planned.id }
        )
        let plannedPlacement = plannedEntry.placement
        #expect(Calendar.current.isDate(plannedPlacement.plannedAt, inSameDayAs: futureDay))
        #expect(!plannedEntry.isAutomatic)
        #expect(plannedEntry.activityDays.map(\.kinds) == [Set([.listening])])
    }

    @Test("Consumption history reports each day's activity without claiming completion")
    func consumptionHistoryReportsActivityDays() throws {
        let store = try TestStores.inMemory()
        var read = StudioArticle(
            url: "https://example.com/history-read",
            title: "History read",
            sourceType: .article,
            id: "source-history-read"
        )
        read.normalizedURL = URLNormalizer.normalize(read.url)
        try store.saveSource(read)

        var listened = StudioArticle(
            url: "https://example.com/history-listened",
            title: "History listened",
            sourceType: .podcast,
            id: "source-history-listened"
        )
        listened.normalizedURL = URLNormalizer.normalize(listened.url)
        try store.saveSource(listened)

        let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let later = earlier.addingTimeInterval(86_400)
        _ = try store.recordScheduledSourceActivity(sourceID: read.id, on: earlier, kind: .reading)
        _ = try store.recordScheduledSourceActivity(sourceID: listened.id, on: later, kind: .listening)
        // An explicit "I finished this" log is the only thing that marks a kind
        // complete; merely opening never does.
        try store.recordScheduledSourceCompletion(sourceID: listened.id, on: later, kind: .listening)

        let history = try store.loadSourceConsumptionHistory()
        #expect(history.count == 2)

        // Newest day first.
        let newest = try #require(history.first)
        #expect(newest.sourceID == listened.id)
        #expect(newest.title == "History listened")
        #expect(newest.kinds == [.listening])
        #expect(newest.completedKinds == [.listening])
        #expect(newest.isConsumption)

        let older = try #require(history.last)
        #expect(older.sourceID == read.id)
        #expect(older.kinds == [.reading])
        #expect(older.completedKinds.isEmpty)
        #expect(Calendar.current.isDate(older.dayStart, inSameDayAs: earlier))
    }

    @Test("Starting a review atomically adds its sources to the calendar")
    func reviewStartAddsCalendarEntries() throws {
        let store = try TestStores.inMemory()
        var article = StudioArticle(
            url: "https://example.com/review-start",
            title: "Review start",
            sourceType: .article,
            id: "source-review-start"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.saveSource(article)
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_100_000)

        try store.createReviewSession(
            id: "review-start-session",
            topic: "Review start",
            sourceIDs: [article.id],
            startedAt: startedAt,
            scheduleActivityAt: startedAt
        )

        let entry = try #require(try store.loadScheduledSources().first)
        let placement = entry.placement
        #expect(placement.sourceID == article.id)
        #expect(Calendar.current.isDate(placement.plannedAt, inSameDayAs: startedAt))
        #expect(!placement.isCompleted)
        #expect(entry.activityDays.first?.kinds == [.review])
    }

    @Test("Re-parenting validates the target is a top-level Notebook")
    func reparentingValidatesTarget() throws {
        let store = try TestStores.inMemory()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = Date(timeIntervalSinceReferenceDate: 10_000)

        let notebook = try store.createCompanionGoal(
            title: "Parent", description: nil, topic: "p",
            startAt: start, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let goalA = try store.createCompanionGoal(
            title: "Goal A", description: nil, topic: "a",
            startAt: start, endAt: end,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let goalB = try store.createCompanionGoal(
            title: "Goal B", description: nil, topic: "b",
            startAt: start, endAt: end,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let otherNotebook = try store.createCompanionGoal(
            title: "Other Parent", description: nil, topic: "other",
            startAt: start, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        // Goals cannot nest under other Goals.
        #expect(throws: (any Error).self) {
            try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: goalB.id)
        }
        // Nor under themselves.
        #expect(throws: (any Error).self) {
            try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: goalA.id)
        }
        // A Notebook that already holds Goals cannot become a nested Goal.
        #expect(throws: (any Error).self) {
            try store.setLearningGoalParentNotebook(goalID: notebook.id, parentNotebookID: goalA.id)
        }

        // Untagging is an ordinary state since schema 120: the Goal keeps its
        // deadline and everything it holds, and stands on its own. It never
        // becomes a Notebook — the deadline, not the parent, says which it is.
        try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: nil)
        let untagged = try #require(try store.loadLearningGoal(goalA.id))
        #expect(untagged.parentNotebookID == nil)
        #expect(untagged.isGoal && untagged.isStandaloneGoal)
        #expect(!untagged.isNotebook && !untagged.isNotebookGoal)
        #expect(untagged.endAt == end)

        try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: otherNotebook.id)
        let reparented = try #require(try store.loadLearningGoal(goalA.id))
        #expect(reparented.parentNotebookID == otherNotebook.id)
        #expect(reparented.isNotebookGoal)
    }

    @Test("active review sessions are linked but not reviewed")
    func activeReviewSessionIsLinkedButNotReviewed() throws {
        let store = try TestStores.inMemory()
        var article = StudioArticle(
            url: "https://example.com/active-review",
            title: "Active Review",
            sourceType: .article,
            id: "source-active-review"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.insertSourceIfNew(&article)

        try store.createReviewSession(
            id: "session-active",
            topic: "Active review",
            sourceIDs: [article.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        #expect(try store.sourceIdsWithReviewSession().contains(article.id))
        #expect(!(try store.sourceIdsWithLinkedChatSession().contains(article.id)))
        #expect((try store.sourceReviewDates())[article.id] == nil)
    }

    @Test("reopen review session only writes completed sessions")
    func reopenReviewSessionOnlyWritesCompletedSessions() throws {
        let store = try TestStores.inMemory()

        try store.createReviewSession(
            id: "session-active",
            topic: "Active review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-active" }?.overallScore == nil)

        try store.reopenReviewSession(sessionID: "session-active")
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-active" }?.status == "active")

        try store.completeReviewSession(
            sessionID: "session-active",
            overallScore: nil,
            summary: "Completed once.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        try store.reopenReviewSession(sessionID: "session-active")
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-active" }?.status == "active")
    }

    @Test("relative file path round-trips")
    func testRelativeFilePathRoundTrips() throws {
        let store = try TestStores.inMemory()
        var article = makeArticle(url: "https://example.com/paper.pdf", title: "Paper")
        article.localFilePath = "Documents/papers/paper.pdf"
        try store.insertSourceIfNew(&article)

        let loaded = try store.loadSources()
        #expect(loaded.count == 1)
        // The relative path should survive the round-trip (it may be resolved to absolute by
        // StorageService.absoluteSourcePath, but since it doesn't start with / and isn't http,
        // it gets the library root prepended — the important thing is it doesn't lose the value)
        #expect(loaded[0].localFilePath != nil)
        #expect(loaded[0].localFilePath!.contains("paper.pdf"))
    }

    /// Regression: the macOS 27 upgrade made iCloud fork the whole KB into
    /// `Documents/ForeverLM 2`, stranding ~370 paper PDFs. Resolving a file
    /// inside a fork depends on the fork's absolute path mapping back to the
    /// same relative path as the canonical folder — that equivalence is what
    /// lets `locateLocalPath` find the file and stops the Papers tab from
    /// reporting hundreds of papers as having lost their PDFs.
    @Test("iCloud conflict-fork paths map to the canonical relative path")
    func testConflictForkPathsMapToCanonicalRelativePath() {
        let home = NSHomeDirectory()
        let forkPaths = [
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM 2/Papers/x.pdf",
            "\(home)/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM 3/Papers/x.pdf",
            "\(home)/Documents/ForeverLM 2/Papers/x.pdf",
        ]
        for path in forkPaths {
            #expect(StorageService.relativeSourcePath(path) == "Papers/x.pdf")
        }

        // The canonical folder maps the same way, so a fork and the real folder
        // are interchangeable as far as source identity is concerned.
        let canonical = "\(home)/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/x.pdf"
        #expect(StorageService.relativeSourcePath(canonical) == "Papers/x.pdf")

        // A path outside any content root must stay untouched, so the fork
        // lookup in `locateLocalPath` never fires for unrelated files.
        let external = "/tmp/somewhere-else/x.pdf"
        #expect(StorageService.relativeSourcePath(external) == external)
    }

    /// Regression: a paper published by the other Mac reported "PDF needed"
    /// forever, with its own bytes sitting in the CloudKit record being applied.
    ///
    /// Builds before commit 3c62e0d put the *publishing* Mac's absolute path on
    /// the wire, and once content moved out of `Documents/ForeverLM` those paths
    /// had no marker component to key on — so the receiving Mac could only match
    /// its own `/Users/<name>` prefix, which never matches. The path reduced to
    /// nothing, and `materializeInboundSourcePDFIfNeeded` reads that as "a layout
    /// this device knows nothing about" and declines to install the PDF.
    ///
    /// `normalizedSourceKey` has always documented the opposite: paths from
    /// different machines map to the same key. This pins that promise to the
    /// local content root, which is the root that broke it.
    @Test("another Mac's content path reduces to the same relative key")
    func testForeignHomeContentPathsReduceToRelativeKey() {
        let foreignHome = "/Users/some-other-account"
        let localSuffix = (StorageService.localContentRootPath as NSString)
            .abbreviatingWithTildeInPath
        // Only run the home-relative half when this device's roots really do sit
        // under its home; a CI account with a relocated home has nothing to pin.
        guard localSuffix.hasPrefix("~/") else { return }
        let suffix = String(localSuffix.dropFirst(2))

        let foreignLocalRoot = "\(foreignHome)/\(suffix)/Papers/x.pdf"
        #expect(StorageService.relativeSourcePath(foreignLocalRoot) == "Papers/x.pdf")

        // The same holds for every historical root, so a second Mac that never
        // left the ubiquity container is read the same way.
        let foreignRoots = [
            "\(foreignHome)/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/x.pdf",
            "\(foreignHome)/Documents/ForeverLM/Papers/x.pdf",
        ]
        for path in foreignRoots {
            #expect(StorageService.relativeSourcePath(path) == "Papers/x.pdf")
        }

        // The documented contract: the foreign absolute form and the stored
        // relative form are one source, not two.
        #expect(
            StorageService.normalizedSourceKey(foreignLocalRoot)
                == StorageService.normalizedSourceKey("Papers/x.pdf")
        )

        // Reducing makes the path app-managed, which is what stops startup
        // reconciliation from reading a not-yet-arrived file as a deletion.
        #expect(StorageService.isAppManagedSourcePath(foreignLocalRoot))

        // And it makes the file findable here: the inbound PDF lands under this
        // Mac's own root rather than being refused.
        let candidates = StorageService.sourceFileCandidatePaths(for: foreignLocalRoot)
        #expect(
            candidates.contains(
                (StorageService.libraryRootPath as NSString).appendingPathComponent("Papers/x.pdf")
            )
        )

        // Another account's unrelated file is still none of our business — the
        // reduction is keyed on a content root, not on `/Users/<name>` alone.
        let unrelated = "\(foreignHome)/Downloads/x.pdf"
        #expect(StorageService.relativeSourcePath(unrelated) == unrelated)
        #expect(!StorageService.isAppManagedSourcePath(unrelated))
    }

    /// The app used to answer "where is this file" in three places that each
    /// knew rules the others didn't, so it could open a file it simultaneously
    /// reported as missing. They now share
    /// `StorageService.sourceFileCandidatePaths`; this pins them together, since
    /// the cost of them drifting apart again is a library that looks half-empty.
    @Test("every file resolver agrees on where a source file is")
    func testFileResolversAgree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-agreement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = dir.appendingPathComponent("present.pdf")
        try Data("%PDF-1.4".utf8).write(to: present)
        let absent = dir.appendingPathComponent("absent.pdf").path

        for path in [present.path, absent] {
            let viaStorage = StorageService.locateSourceFile(path)
            let viaSourceService = SourceService.resolveLocalFileURL(path)?.path
            var article = makeArticle(url: "https://example.com/x", title: "X")
            article.localFilePath = path
            let viaArticle = article.resolvedLocalPath

            #expect(viaStorage == viaSourceService)
            // `resolvedLocalPath` reports the path it would use even on a miss,
            // so compare it only where a file was actually located.
            if let viaStorage {
                #expect(viaArticle == viaStorage)
            }
        }

        // `file://` inputs reach the resolver only through SourceService — a
        // stored `localFilePath` is always a plain or relative path, and
        // `resolvedLocalPath` screens out anything containing "://" before
        // resolving. Both file-URL-aware entry points must still agree.
        let fileURLForm = "file://" + present.path
        #expect(StorageService.locateSourceFile(fileURLForm) == present.path)
        #expect(SourceService.resolveLocalFileURL(fileURLForm)?.path == present.path)

        // A not-yet-downloaded iCloud file leaves a `.name.icloud` placeholder
        // beside it. Reading it as absent is what makes the app offer to
        // re-download a paper it already has.
        let evicted = dir.appendingPathComponent("evicted.pdf")
        let placeholder = dir.appendingPathComponent(".evicted.pdf.icloud")
        try Data().write(to: placeholder)
        #expect(StorageService.locateSourceFile(evicted.path) == evicted.path)
        #expect(SourceService.resolveLocalFileURL(evicted.path)?.path == evicted.path)
    }

    /// The offline fallback must not live in `~/Documents`: with "Desktop &
    /// Documents Folders" syncing on (the macOS default) that folder IS iCloud
    /// Drive, so the fallback became a second synced root that could fork
    /// against the private container — which is exactly what happened.
    @Test("the offline content root is local, not a second synced root")
    func testLocalContentRootIsNotSynced() {
        let local = StorageService.localContentRootPath
        #expect(local.contains("Application Support"))
        #expect(!local.contains("Mobile Documents"))
        #expect(!local.hasPrefix(NSHomeDirectory() + "/Documents"))

        // knowledge.db survives these events because Application Support is never
        // synced; content now shares that property when iCloud is unavailable.
        #expect(local.hasPrefix(NSHomeDirectory()) || local.hasPrefix("/"))
    }

    /// A stored relative path has to resolve against every live root, so moving
    /// between the private container and local storage never strands a file.
    @Test("stored relative paths are searched against every known content root")
    func testRelativePathsSearchAllKnownRoots() {
        let roots = StorageService.knownContentRoots
        // The roots carry the running build's product folder: `ForeverLM` in a
        // release build, `ForeverLM Dev` in the Dev build these tests run in.
        let folder = ForeverLMRuntimeIdentity.productFolderName
        #expect(roots.contains(StorageService.libraryRootPath))
        #expect(roots.contains(StorageService.localContentRootPath))
        #expect(roots.contains { $0.hasSuffix("iCloud~com~foreverlm/Documents/\(folder)") })
        // The retired container is deliberately absent: it is drained and its
        // `Documents` is empty, so searching it can only ever miss.
        #expect(!roots.contains { $0.contains("iCloud~com~feynmanlm") })
        // iCloud Drive proper is not searched either: nothing lives there.
        #expect(!roots.contains { $0.contains("com~apple~CloudDocs") })
        // The real `~/Documents` is not searched: touching it raises the
        // Documents-folder TCC prompt.
        let realDocuments = (NSHomeDirectory() as NSString).appendingPathComponent("Documents") + "/"
        #expect(!roots.contains { $0.hasPrefix(realDocuments) })

        // Each root contributes a candidate for the same stored path...
        let candidates = StorageService.sourceFileCandidatePaths(for: "Papers/x.pdf")
        for root in Set(roots) {
            #expect(candidates.contains((root as NSString).appendingPathComponent("Papers/x.pdf")))
        }
        // ...with no duplicates, since roots overlap by configuration.
        #expect(candidates.count == Set(candidates).count)

        // A file under the local root still reduces to its relative form even
        // while iCloud is available, or the same file would be stored absolute on
        // one launch and relative on the next.
        let localFile = (StorageService.localContentRootPath as NSString)
            .appendingPathComponent("Papers/x.pdf")
        #expect(StorageService.relativeSourcePath(localFile) == "Papers/x.pdf")
    }

    /// Content is written locally, not into the ubiquity container. CloudDocs
    /// resolves a *directory* conflict in document scope by bouncing one side to
    /// a numbered name, and this library forked that way repeatedly — the app
    /// re-creating a root iCloud had not yet delivered was the other half of it.
    ///
    /// The move needed no migration precisely because resolution is root-agnostic,
    /// so the invariant worth pinning is that nothing already written became
    /// unreachable: the container stays searchable, and only new writes land
    /// locally.
    @Test("content is written locally while the container root stays readable")
    func testContentRootIsLocalAndContainerRootStaysReadable() {
        #expect(StorageService.libraryRootPath == StorageService.localContentRootPath)
        #expect(!StorageService.libraryRootPath.contains("Mobile Documents"))

        // The container is still a known root: that is where most of this
        // library's files are, and they were not moved.
        #expect(StorageService.ubiquityContentRootPath.contains("iCloud~com~foreverlm"))
        #expect(StorageService.knownContentRoots.contains(StorageService.ubiquityContentRootPath))

        // A stored relative path resolves against the local root first and the
        // container after it, so a new write and an older file both land.
        let candidates = StorageService.sourceFileCandidatePaths(for: "Papers/x.pdf")
        let localCandidate = (StorageService.localContentRootPath as NSString)
            .appendingPathComponent("Papers/x.pdf")
        let containerCandidate = (StorageService.ubiquityContentRootPath as NSString)
            .appendingPathComponent("Papers/x.pdf")
        #expect(candidates.first == localCandidate)
        #expect(candidates.contains(containerCandidate))
    }

    /// Synced audio is the deliberate exception under generation 1: it has no
    /// CloudKit entity there, and the iPhone reads these files straight out of
    /// the container, so CloudDocs is its only transport. If this ever follows
    /// `libraryRootPath`, Mac narration silently stops reaching the phone.
    /// Generation 2 moves a device's narration to its own working folder
    /// (`MacNarrationLibrary.install`, covered by `MacNarrationTests`), and the
    /// test host installs that answer from its own library's generation, so
    /// this reads the generation-1 tree itself rather than `audioRootURL()`.
    @Test("synced audio's generation-1 tree still resolves inside the ubiquity container")
    func testSyncedAudioStaysInTheUbiquityContainer() {
        let audioRoot = SyncedArticleAudioStore.ubiquityAudioRootURL().path
        #expect(audioRoot.hasPrefix(StorageService.ubiquityContentRootPath))
        #expect(!audioRoot.hasPrefix(StorageService.localContentRootPath))
        #expect(audioRoot.hasSuffix("/Audio"))
    }
}
