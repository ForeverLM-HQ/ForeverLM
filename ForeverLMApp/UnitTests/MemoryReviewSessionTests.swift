import Foundation
import Testing
@testable import ForeverLM

@Suite("Memory review session identity")
struct MemoryReviewSessionTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("The day's id names the local day, so two starts converge on one record")
    func sessionIDNamesTheDay() {
        // 2026-09-03 14:00 UTC.
        let date = Date(timeIntervalSince1970: 1_788_444_000)
        #expect(MemoryReviewSession.sessionID(for: date, calendar: utc) == "memory-2026-09-03")

        // Same instant, a day earlier in a zone far enough west: it is that
        // zone's review, not UTC's.
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        let early = Date(timeIntervalSince1970: 1_788_404_400) // 03:00 UTC on the 3rd
        #expect(MemoryReviewSession.sessionID(for: early, calendar: honolulu) == "memory-2026-09-02")
    }

    @Test("Memory chats are recognised by prefix, like iPhone and CarPlay chats")
    func prefixIdentifiesMemoryChats() {
        #expect(MemoryReviewSession.isMemorySession("memory-2026-09-03"))
        #expect(!MemoryReviewSession.isMemorySession("ios-abc"))
        #expect(!MemoryReviewSession.isMemorySession(UUID().uuidString))
        #expect(ReviewSessionOrigin.infer(from: "memory-2026-09-03") == .other)
    }

    @Test("The title is the full date and nothing else")
    func titleIsTheDate() {
        let date = Date(timeIntervalSince1970: 1_788_444_000)
        let title = MemoryReviewSession.title(for: date, calendar: utc)
        #expect(!title.hasPrefix("Memory"))
        #expect(title.contains("3"))
        #expect(title.contains("2026"))
        #expect(title.lowercased().contains("september"))
    }

    @Test("A session id names its day")
    func sessionIDNamesItsDay() throws {
        let date = try #require(MemoryReviewSession.date(fromSessionID: "memory-2026-09-04", calendar: utc))
        let components = utc.dateComponents([.year, .month, .day], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 4)
        #expect(MemoryReviewSession.date(fromSessionID: "ios-abc", calendar: utc) == nil)
        #expect(MemoryReviewSession.date(fromSessionID: "memory-nonsense", calendar: utc) == nil)
    }

    @Test("A review titled the old way shows its date from the id; a renamed one keeps its name")
    func legacyTitleReadsDateFromID() {
        let shown = MemoryReviewSession.displayTitle(
            storedTitle: "Memory · 4 Sep", sessionID: "memory-2026-09-04", calendar: utc
        )
        #expect(!shown.hasPrefix("Memory"))
        #expect(shown.contains("4"))
        #expect(shown.contains("2026"))
        #expect(
            MemoryReviewSession.displayTitle(
                storedTitle: "Axolotls, again", sessionID: "memory-2026-09-04", calendar: utc
            ) == "Axolotls, again"
        )
    }
}

@Suite("Memory review backlog")
struct MemoryReviewBacklogTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func candidate(
        _ id: String,
        consumedDaysAgo: Int,
        reviewCount: Int = 0,
        discussedDaysAgo: Int? = nil
    ) -> CohortCandidate {
        CohortCandidate(
            sourceID: id,
            title: "Source \(id)",
            sourceType: "paper",
            consumedAt: now.addingTimeInterval(-Double(consumedDaysAgo) * 86_400),
            confidence: .substantial,
            reviewCount: reviewCount,
            lastDiscussedAt: discussedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
        )
    }

    @Test("Nothing due falls back to what has gone longest untouched")
    func backlogOrdersByLastTouch() {
        // "c" was consumed long ago but discussed recently; "a" was consumed
        // more recently than "c" and never discussed, so "a" is the older touch.
        let picked = CohortSelector.backlog(
            candidates: [
                candidate("a", consumedDaysAgo: 30),
                candidate("b", consumedDaysAgo: 5),
                candidate("c", consumedDaysAgo: 200, reviewCount: 2, discussedDaysAgo: 2),
                candidate("d", consumedDaysAgo: 60, reviewCount: 1, discussedDaysAgo: 50),
            ],
            now: now
        )
        #expect(picked.map(\.sourceID) == ["d", "a", "b"])
    }

    @Test("The backlog is capped and deterministic")
    func backlogIsCapped() {
        let many = (0..<10).map { candidate("s\($0)", consumedDaysAgo: 20) }
        let picked = CohortSelector.backlog(candidates: many, now: now, limit: 2)
        #expect(picked.map(\.sourceID) == ["s0", "s1"])
        #expect(CohortSelector.backlog(candidates: [], now: now).isEmpty)
    }

    @Test("A backlog reason says nothing was due")
    func backlogReasonSaysSo() {
        let reason = CohortSelector.backlogReason(candidate: candidate("a", consumedDaysAgo: 30), now: now)
        #expect(reason.hasPrefix("Nothing is due today."))
        #expect(reason.contains("30d"))
    }

    @Test("A cohort is not backlog-only unless assembled as one")
    func cohortDefaultsToDue() {
        let cohort = LearningCohort(
            assembledAt: now,
            windowDays: CohortSelector.windowDays,
            sources: [],
            unfinished: [],
            droppedSpine: 0,
            droppedSpacing: 0
        )
        #expect(!cohort.isBacklogOnly)
    }
}

@Suite("Memory review source completion")
struct MemoryReviewSourceStatusTests {

    private func ideaID(_ sourceID: String, _ index: Int) -> String {
        SourceIdea.id(sourceID: sourceID, contentHash: "abcdef123456", index: index)
    }

    private func exchange(
        sequence: Int,
        coverage: [MemoryIdeaCoverage]?,
        verdict: MemoryQuestionVerdict? = .sound,
        answeredAt: Date? = nil
    ) -> ReviewExchangeRecord {
        ReviewExchangeRecord(
            id: "exchange-\(sequence)",
            sessionID: "memory-2026-09-03",
            sequenceNumber: sequence,
            question: "q",
            userAnswer: "a",
            evaluation: "e",
            score: nil,
            sourceRefs: [],
            knowledgeNote: nil,
            answeredAt: answeredAt,
            contextContent: nil,
            ideaCoverage: coverage.flatMap(MemoryIdeaCoverage.encode),
            questionVerdict: coverage == nil ? nil : verdict?.rawValue
        )
    }

    @Test("A source is complete only once its contour has been graded")
    func gradedSourcesAreComplete() throws {
        let statuses = MemoryReviewSourceStatus.statuses(from: [
            // An ungraded opening turn about the same material completes nothing.
            exchange(sequence: 1, coverage: nil),
            exchange(sequence: 2, coverage: [
                MemoryIdeaCoverage(ideaID: ideaID("source-a", 0), status: .produced),
                MemoryIdeaCoverage(ideaID: ideaID("source-a", 1), status: .partial),
                MemoryIdeaCoverage(ideaID: ideaID("source-a", 2), status: .missing)
            ])
        ])

        #expect(statuses.count == 1)
        let status = try #require(statuses["source-a"])
        #expect(status.ideaCount == 3)
        #expect(status.producedCount == 1)
        #expect(status.partialCount == 1)
        #expect(status.producedFraction == 0.5)
        #expect(status.recallSummary == "1 of 3 ideas recalled, 1 partly")
    }

    @Test("The latest grade for a source wins, and an ambiguous one claims no fraction")
    func latestGradeWinsAndAmbiguityClaimsNothing() throws {
        let statuses = MemoryReviewSourceStatus.statuses(from: [
            exchange(sequence: 2, coverage: [
                MemoryIdeaCoverage(ideaID: ideaID("source-a", 0), status: .produced)
            ]),
            exchange(sequence: 1, coverage: [
                MemoryIdeaCoverage(ideaID: ideaID("source-a", 0), status: .missing)
            ]),
            exchange(sequence: 3, coverage: [
                MemoryIdeaCoverage(ideaID: ideaID("source-b", 0), status: .produced)
            ], verdict: .ambiguous)
        ])

        #expect(statuses["source-a"]?.producedFraction == 1)
        // Out-of-order records are folded by sequence, not by array order.
        #expect(statuses["source-a"]?.producedCount == 1)

        let ambiguous = try #require(statuses["source-b"])
        #expect(ambiguous.producedFraction == nil)
        #expect(ambiguous.recallSummary.contains("ambiguous"))
    }

    @Test("The record carries the review's material first, then what was attached beside it")
    func recordCarriesMaterialThenAttachments() {
        // A chat reviewed as material has no article, so it is never in the
        // attached pool; the record must still name it or the grader refuses it.
        #expect(ReviewSessionManager.persistedSessionSourceIDs(
            reviewMaterial: ["chat-1", "src-a"],
            attached: ["src-a", "src-dropped-in"]
        ) == ["chat-1", "src-a", "src-dropped-in"])
        // An ordinary chat has no material list: the record is the pool, as before.
        #expect(ReviewSessionManager.persistedSessionSourceIDs(reviewMaterial: [], attached: ["s1", "s2"]) == ["s1", "s2"])
    }

    @Test("A resumed review restores from its briefing the sources its record lost")
    func resumeRestoresLostMaterialFromBriefing() {
        let briefing = "TODAY'S MEMORY REVIEW\n\nSOURCES\n\n### [chat-1] Methods talk — spine\n\n### [src-a] Paper — spine\n"
        // A record written from the article pool before build 94 lacks the chat.
        #expect(ReviewSessionManager.memoryReviewMaterialSourceIDs(recorded: ["src-a"], briefing: briefing)
            == ["src-a", "chat-1"])
        // A complete record is left exactly as it is, so nothing is written back.
        #expect(ReviewSessionManager.memoryReviewMaterialSourceIDs(recorded: ["chat-1", "src-a"], briefing: briefing)
            == ["chat-1", "src-a"])
        // Attachments the record gained stay; a missing briefing changes nothing.
        #expect(ReviewSessionManager.memoryReviewMaterialSourceIDs(recorded: ["src-a", "extra", "extra"], briefing: nil)
            == ["src-a", "extra"])
    }

    @Test("A source the learner removed stays out of a resumed review, whatever the record still carries")
    func resumeLeavesOutRemovedSources() {
        let briefing = "TODAY'S MEMORY REVIEW\n\nSOURCES\n\n### [chat-1] Methods talk — spine\n\n### [src-a] Paper — spine\n"
        let removed = MemoryReviewTutoring.briefing(briefing, removingSource: "src-a", title: "Paper")
        // The other Mac's record may still list it; the briefing's REMOVED line wins.
        #expect(ReviewSessionManager.memoryReviewMaterialSourceIDs(recorded: ["chat-1", "src-a"], briefing: removed)
            == ["chat-1"])
        // Nor does it come back from the briefing's own headers, which no longer name it.
        #expect(ReviewSessionManager.memoryReviewMaterialSourceIDs(recorded: [], briefing: removed) == ["chat-1"])
    }

    @Test("Removing the source the open question is about moves the review on, even before the tutor has written a turn line")
    func removalOfTheOpeningSourceInterruptsTheQuestion() {
        let briefing = [
            MemoryReviewTutoring.movesHeading,
            "1. recall [chat-1] — What they worked out.",
            "2. recall [src-a] — Its contour.",
            "",
            "SOURCES",
            "",
            "### [chat-1] Lysosomal aging talk — spine",
            "### [src-a] Atlas — spine",
        ].joined(separator: "\n")
        func takes(_ id: String, current: String? = nil, graded: Bool = false, asked: Bool = true, briefing: String? = briefing) -> Bool {
            ReviewSessionManager.memoryReviewRemovalTakesOpenQuestion(
                removing: id, current: current, anythingGraded: graded, tutorHasAsked: asked, briefing: briefing
            )
        }
        // The opening question carried no turn line: the plan says it was about the chat.
        #expect(takes("chat-1"))
        #expect(!takes("src-a"))
        // Once the tutor has marked a source, its mark is what counts.
        #expect(takes("src-a", current: "src-a"))
        #expect(!takes("chat-1", current: "src-a"))
        // A grade without a turn line still means the opening is over.
        #expect(!takes("chat-1", graded: true))
        // Nothing asked yet, or no plan to read: nothing to replace.
        #expect(!takes("chat-1", asked: false))
        #expect(!takes("chat-1", briefing: nil))
    }

    @Test("A grade naming no known source is ignored rather than guessed at")
    func foreignCoverageIsIgnored() {
        let statuses = MemoryReviewSourceStatus.statuses(from: [
            exchange(sequence: 1, coverage: [
                MemoryIdeaCoverage(ideaID: "not-an-idea-id", status: .produced)
            ])
        ])
        #expect(statuses.isEmpty)
    }
}

@Suite("Memory pane's review: the promise and the earlier reviews")
struct MemoryReviewConfirmationSheetTests {
    private func record(_ id: String, title: String = "") -> ReviewSessionRecord {
        ReviewSessionRecord(id: id, title: title, createdAt: Date(), status: "completed", sourceIDs: [])
    }

    @Test("Lists every day's review chat but today's, newest first, and nothing that is not a review")
    func earlierReviewsExcludeTodayAndSortNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 15))!
        let sessions = [
            record("memory-2026-09-08"),
            record("memory-2026-09-10", title: "10 September 2026"),
            record("loose-chat", title: "A chat"),
            record("memory-2026-09-09"),
            record("memory-2026-09-03"),
        ]
        let earlier = MemoryPane.earlierReviews(in: sessions, now: now, calendar: calendar)
        #expect(earlier.map(\.id) == ["memory-2026-09-09", "memory-2026-09-08", "memory-2026-09-03"])
    }

    @Test("A history of only today's review lists nothing")
    func onlyTodayListsNothing() {
        let now = Date()
        let earlier = MemoryPane.earlierReviews(
            in: [record(MemoryReviewSession.sessionID(for: now))], now: now
        )
        #expect(earlier.isEmpty)
    }

    /// The pane is where the commitment is made (product owner, 2026-09-19: "there
    /// needs to be a focused commitment to do that session"), so its words
    /// have to say what is agreed to before Start Review is pressed: since
    /// 2026-10-06 in one short line, the minutes and what leaving early does.
    @Test("The pane names the minutes and what ends the session in one line; an ended or done day goes on with Keep Going; a done day goes on without a promise")
    func commitmentLines() {
        let open = MemoryPane.promise(state: .open, budgetMinutes: 15)
        #expect(open == "Up to 15 minutes. Leaving early ends today's review.")
        let waiting = MemoryCardDayCounts(due: 2, new: 1, practice: 0)
        #expect(MemoryPane.primaryTitle(state: .open, counts: waiting) == "Start Review")
        #expect(MemoryPane.primaryTitle(state: .open, counts: .zero) == nil, "no card waits")

        #expect(MemoryPane.promise(state: .ended(afterSeconds: 250), budgetMinutes: 15)
            == "Today's review ended after 4 minutes.")
        #expect(MemoryPane.primaryTitle(state: .ended(afterSeconds: 250), counts: waiting) == "Keep Going", "cards waiting always have a button")
        // Under half a minute is not "after 0 minutes".
        #expect(MemoryPane.promise(state: .ended(afterSeconds: 20), budgetMinutes: 15)
            == "Today's review ended.")

        let done = MemoryPane.promise(state: .done(streak: 3), budgetMinutes: 15)
        #expect(done == "Today's review is done.")
        #expect(!done.contains("in a row"), "no streak number")
        #expect(MemoryPane.primaryTitle(state: .done(streak: 3), counts: waiting) == "Keep Going")
        #expect(MemoryPane.primaryTitle(state: .done(streak: 3), counts: .zero) == nil)
    }

    @Test("The promise shows while there is a review to start or a day ended early, never a second done")
    func promiseShows() {
        let waiting = MemoryCardDayCounts(due: 2, new: 1, practice: 0)
        #expect(MemoryPane.showsPromise(state: .open, counts: waiting), "Start Review says what it commits to")
        #expect(!MemoryPane.showsPromise(state: .open, counts: .zero), "nothing to start")
        #expect(MemoryPane.showsPromise(state: .ended(afterSeconds: 250), counts: .zero), "the day ended early says so")
        #expect(MemoryPane.showsPromise(state: .done(streak: 3), counts: waiting), "beside Keep Going")
        #expect(!MemoryPane.showsPromise(state: .done(streak: 3), counts: .zero), "the deck already says done")
    }
}
