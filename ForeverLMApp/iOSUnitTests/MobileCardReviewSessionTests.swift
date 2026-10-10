import Foundation
import XCTest
@testable import ForeverLM

/// The phone's card review as a sitting (docs/memory-design.md, "The card
/// review on the iPhone"): opening deals and writes nothing; each card's
/// first answer is written once, under the sitting's key, as the Mac's store
/// writes a self-graded answer; a repeat round, an answer that does not
/// count and a card answered twice write nothing more; a failed write is said
/// and the review goes on; Continue deals today's cards not yet recorded; a
/// notebook's Practice answers as practice; and the widget's counts.
@MainActor
final class MobileCardReviewSessionTests: XCTestCase {
    private let day = MemoryTutorScheduler.secondsPerDay
    private let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    /// The synced items and attempts as the catalog holds them, and what the
    /// sitting wrote.
    @MainActor
    private final class Cards {
        var items: [MemoryItem]
        var attempts: [MemoryAttempt]
        var written: [MemoryAttempt] = []
        var fingerprints: [String] = []
        var deals: [(mode: MobileCardReviewSession.Mode, kind: MemoryCardSitting.Kind)] = []
        var failsWrites = false
        var awake = 0

        init(items: [MemoryItem], attempts: [MemoryAttempt] = []) {
            self.items = items
            self.attempts = attempts
        }

        /// The closures hold this fixture strongly: a session's write and its
        /// follow-up read run in tasks that may outlive the test that made
        /// them, and an unowned capture crashed the host when they did.
        func backend(now: Date, newPerDay: Int = 10, budgetMinutes: Int? = nil) -> MobileCardReviewSession.Backend {
            MobileCardReviewSession.Backend(
                deal: { mode, kind, now in
                    self.deals.append((mode, kind))
                    switch mode {
                    case .today(let scope):
                        let cardScope: MemoryCardScope? = switch scope {
                        case .allNotebooks: nil
                        case .notebook(let id): MobileNotebookCards.scope(notebookID: id, memberSourceIDs: ["src-1"])
                        }
                        let read = MobileCardReviewDealing.read(
                            items: self.items, attempts: self.attempts, now: now,
                            budgetMinutes: budgetMinutes, newPerDay: newPerDay, scope: cardScope
                        )
                        let entries = kind == .practice ? read.practice : read.today.entries
                        return MobileCardReviewSession.Deal(
                            cards: MobileCardReviewDealing.sittingCards(entries, attemptsByItemID: read.attemptsByItemID, states: [:]),
                            practiceCount: read.practice.count,
                            sourceTitles: ["src-1": "Mitochondria"]
                        )
                    case .notebookPractice(let notebookID):
                        let practice = MobileCardReviewDealing.notebookPractice(
                            items: self.items, attempts: self.attempts,
                            scope: MobileNotebookCards.scope(notebookID: notebookID, memberSourceIDs: ["src-1"]), now: now
                        )
                        return MobileCardReviewSession.Deal(
                            cards: MobileCardReviewDealing.sittingCards(practice.entries, attemptsByItemID: practice.attemptsByItemID, states: [:]),
                            practiceCount: 0,
                            sourceTitles: [:]
                        )
                    }
                },
                notebookIDs: { ["p"] },
                answerContext: { itemID in
                    guard let item = self.items.first(where: { $0.id == itemID }) else { return nil }
                    return (item, self.attempts.filter { $0.memoryItemID == itemID })
                },
                write: { attempt, fingerprint in
                    if self.failsWrites { throw URLError(.notConnectedToInternet) }
                    self.written.append(attempt)
                    self.fingerprints.append(fingerprint)
                    return .recorded
                },
                noteRecorded: { attempt in self.attempts.append(attempt) },
                dayChatIsUnderway: { false },
                keepAwake: {
                    self.awake += 1
                    return { self.awake -= 1 }
                },
                now: { now }
            )
        }
    }

    private func card(_ id: String, keptAt: Date, sourceID: String = "src-1") throws -> MemoryItem {
        let face = MemoryCard(
            cardID: id, front: "Front \(id)", back: "Back \(id)", why: ["Why \(id)"],
            origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: sourceID)
        )
        return try face.memoryItem(
            id: MemoryTutorIdentity.cardItemID(cardID: id),
            anchors: [MemorySourceAnchorValidation(sourceID: sourceID, excerpt: "The passage of \(id)", sourceSHA256: "h")],
            at: keptAt
        )
    }

    /// A card missed `missedDaysAgo` days ago, due again by now.
    private func dueCard(_ id: String, missedDaysAgo: Double = 3) throws -> (MemoryItem, MemoryAttempt) {
        let item = try card(id, keptAt: now.addingTimeInterval(-10 * day))
        let missed = MemoryAttempt.selfGraded(
            id: "missed-\(id)", memoryItemID: item.id, prompt: "Front \(id)", remembered: false,
            at: now.addingTimeInterval(-missedDaysAgo * day)
        )
        return (item, missed)
    }

    private func answer(_ session: MobileCardReviewSession, remembered: Bool) {
        session.showAnswer()
        session.answer(remembered: remembered)
    }

    // MARK: - The sitting

    func testOpeningDealsTodaysCardsAndWritesNothing() async throws {
        let (due, missed) = try dueCard("due")
        let newCard = try card("new", keptAt: now.addingTimeInterval(-2 * day))
        let cards = Cards(items: [due, newCard], attempts: [missed])
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), backend: cards.backend(now: now))

        await session.open()
        await session.open()

        XCTAssertEqual(session.phase, .reviewing)
        XCTAssertEqual(session.sitting?.cards.map(\.itemID), [due.id, newCard.id], "due first, then new")
        XCTAssertEqual(session.sitting?.kind, .today)
        XCTAssertEqual(session.sitting?.current?.prompt, "Front due")
        XCTAssertEqual(session.currentSourceTitle, "Mitochondria")
        XCTAssertTrue(session.sitting?.key.hasPrefix("cards-") == true)
        XCTAssertEqual(cards.deals.count, 1, "opening again (back from the Reader) deals nothing new")
        XCTAssertTrue(cards.written.isEmpty, "opening writes nothing")
        XCTAssertEqual(cards.awake, 0)
    }

    func testEachFirstAnswerIsWrittenOnceAsTheMacWritesIt() async throws {
        let (due, missed) = try dueCard("due")
        let newCard = try card("new", keptAt: now.addingTimeInterval(-2 * day))
        let cards = Cards(items: [due, newCard], attempts: [missed])
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), backend: cards.backend(now: now))
        await session.open()
        let key = try XCTUnwrap(session.sitting?.key)

        session.answer(remembered: true)
        XCTAssertEqual(session.sitting?.cardNumber, 1, "nothing is answered before the back is shown")
        answer(session, remembered: false)
        answer(session, remembered: true)
        await session.waitForWrites()

        XCTAssertEqual(cards.written.map(\.id), [
            MemoryTutorIdentity.selfGradedAttemptID(sessionKey: key, memoryItemID: due.id),
            MemoryTutorIdentity.selfGradedAttemptID(sessionKey: key, memoryItemID: newCard.id),
        ], "in the order given, under the sitting's key")
        let forgot = try XCTUnwrap(cards.written.first)
        XCTAssertEqual(forgot, MemoryAttempt.selfGraded(
            id: forgot.id, memoryItemID: due.id, prompt: "Front due", remembered: false, at: now
        ))
        XCTAssertEqual(forgot.learnerAnswer, "(self-graded)")
        XCTAssertEqual(forgot.gradeState, .graded)
        XCTAssertEqual(forgot.scheduleRating, .again)
        XCTAssertEqual(forgot.score, 0)
        XCTAssertNil(forgot.sessionID)
        XCTAssertEqual(cards.written.last?.scheduleRating, .good)
        XCTAssertEqual(cards.fingerprints.first, MemoryTutorIdentity.immutableCurriculumFingerprint(due))
        XCTAssertEqual(cards.awake, 0, "every write let the app sleep again")
        XCTAssertNil(session.saveError)

        // Review Forgotten asks the forgotten card again and writes nothing.
        XCTAssertTrue(session.sitting?.isRoundOver == true)
        session.reviewForgotten()
        XCTAssertEqual(session.sitting?.cards.map(\.itemID), [due.id])
        answer(session, remembered: true)
        await session.waitForWrites()
        XCTAssertEqual(cards.written.count, 2, "a repeat is shown and not written")
    }

    func testAnAnswerThatDoesNotCountIsNotWritten() async throws {
        // Dealt as new and eligible, then seen on another device before the
        // answer: the phone's history says it is not due, so nothing is written.
        let newCard = try card("new", keptAt: now.addingTimeInterval(-2 * day))
        let cards = Cards(items: [newCard])
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), backend: cards.backend(now: now))
        await session.open()
        cards.attempts.append(MemoryAttempt.selfGraded(
            id: "elsewhere", memoryItemID: newCard.id, prompt: "Front new", remembered: true, at: now.addingTimeInterval(-60)
        ))
        answer(session, remembered: true)
        await session.waitForWrites()
        XCTAssertTrue(cards.written.isEmpty)
        XCTAssertNil(session.saveError, "not counting is not a failure")
    }

    func testAFailedWriteIsSaidAndTheReviewGoesOn() async throws {
        let (first, missedFirst) = try dueCard("first")
        let (second, missedSecond) = try dueCard("second", missedDaysAgo: 2)
        let cards = Cards(items: [first, second], attempts: [missedFirst, missedSecond])
        cards.failsWrites = true
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), backend: cards.backend(now: now))
        await session.open()
        answer(session, remembered: true)
        await session.waitForWrites()
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(session.sitting?.cardNumber, 2, "the review goes on")
        XCTAssertEqual(cards.awake, 0)

        cards.failsWrites = false
        answer(session, remembered: true)
        await session.waitForWrites()
        XCTAssertNil(session.saveError, "the next saved answer clears it")
        XCTAssertEqual(cards.written.map(\.memoryItemID), [second.id])
    }

    func testContinueDealsTodaysCardsThisSittingHasNotRecorded() async throws {
        // Six new cards, five minutes: five fit the day's minutes at a
        // minute each, and the sixth waits.
        let newCards = try (1...6).map { try card("new-\($0)", keptAt: now.addingTimeInterval(-Double(10 - $0) * day)) }
        let cards = Cards(items: newCards)
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), backend: cards.backend(now: now, budgetMinutes: 5))
        await session.open()
        XCTAssertEqual(session.sitting?.cards.map(\.itemID), newCards.prefix(5).map(\.id), "oldest kept first, cut to the minutes")
        for remembered in [true, false, true, true, true] { answer(session, remembered: remembered) }
        await session.waitForWrites()
        await session.waitForFollowup()
        XCTAssertEqual(session.waitingCards.map(\.itemID), [newCards[5].id], "the card the minutes left, and none answered")
        XCTAssertFalse(session.isReadingFollowup)

        session.continueWithWaitingCards()
        XCTAssertEqual(session.sitting?.cards.map(\.itemID), [newCards[5].id])
        XCTAssertFalse(session.sitting?.isRepeat ?? true, "written like the first deal")
        answer(session, remembered: true)
        await session.waitForWrites()
        XCTAssertEqual(cards.written.map(\.memoryItemID), newCards.map(\.id))

        // One new card a day: once it is introduced, today holds nothing more.
        let (due, missed) = try dueCard("due")
        let strict = Cards(items: [due] + newCards, attempts: [missed])
        let oneNew = MobileCardReviewSession(mode: .today(.allNotebooks), backend: strict.backend(now: now, newPerDay: 1))
        await oneNew.open()
        XCTAssertEqual(oneNew.sitting?.cards.map(\.itemID), [due.id, newCards[0].id])
        answer(oneNew, remembered: true)
        answer(oneNew, remembered: true)
        await oneNew.waitForWrites()
        await oneNew.waitForFollowup()
        XCTAssertTrue(oneNew.waitingCards.isEmpty)
    }

    func testPracticeAndANewScopeAreSittingsOfTheirOwn() async throws {
        let keptToday = try card("today", keptAt: now.addingTimeInterval(-60))
        let cards = Cards(items: [keptToday])
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), backend: cards.backend(now: now))
        await session.open()
        XCTAssertEqual(session.phase, .empty, "a card kept today is not today's")
        XCTAssertEqual(session.practiceCount, 1)

        session.startPractice()
        try await waitUntil { session.phase == .reviewing }
        XCTAssertEqual(session.sitting?.kind, .practice)
        answer(session, remembered: false)
        await session.waitForWrites()
        XCTAssertEqual(cards.written.map(\.memoryItemID), [keptToday.id], "practice the learner started counts a card kept today")
        let practiceKey = try XCTUnwrap(session.sitting?.key)

        session.changeScope(.notebook("p"))
        try await waitUntil { session.phase != .loading && session.sitting?.key != practiceKey }
        XCTAssertEqual(session.mode, .today(.notebook("p")))
        XCTAssertEqual(session.notebookInScope, "p")
        XCTAssertEqual(cards.deals.last?.mode, .today(.notebook("p")))
    }

    func testOpenedAsPracticeDealsTheNewCardsTodayLeavesOut() async throws {
        let (due, missed) = try dueCard("due")
        let keptToday = try card("today", keptAt: now.addingTimeInterval(-60))
        let cards = Cards(items: [due, keptToday], attempts: [missed])
        let session = MobileCardReviewSession(mode: .today(.allNotebooks), opensAsPractice: true, backend: cards.backend(now: now))
        await session.open()

        XCTAssertEqual(session.phase, .reviewing)
        XCTAssertEqual(session.sitting?.kind, .practice)
        XCTAssertEqual(session.sitting?.cards.map(\.itemID), [keptToday.id], "the Memory screen's Practice: not today's due card")
        XCTAssertEqual(cards.deals.map { $0.kind }, [.practice])
        XCTAssertTrue(cards.written.isEmpty, "opening writes nothing")
        answer(session, remembered: true)
        await session.waitForWrites()
        await session.waitForFollowup()
        XCTAssertEqual(cards.written.map(\.memoryItemID), [keptToday.id], "practice the learner started counts a card kept today")
        XCTAssertTrue(session.waitingCards.isEmpty, "practice deals nothing after it")

        session.changeScope(.notebook("p"))
        try await waitUntil { cards.deals.count == 2 && session.phase != .loading }
        XCTAssertEqual(cards.deals.last?.kind, .practice, "a new scope is practised too")
    }

    func testANotebooksPracticeWritesOnlyTheAnswersThatCount() async throws {
        let (due, missed) = try dueCard("due")
        let keptToday = try card("today", keptAt: now.addingTimeInterval(-60))
        // Remembered three days ago on its first day: seen, not due yet.
        let seen = try card("seen", keptAt: now.addingTimeInterval(-5 * day))
        let remembered = MemoryAttempt.selfGraded(
            id: "seen-once", memoryItemID: seen.id, prompt: "Front seen", remembered: true, at: now.addingTimeInterval(-3 * day)
        )
        let elsewhere = try card("elsewhere", keptAt: now.addingTimeInterval(-3 * day), sourceID: "src-2")
        let cards = Cards(items: [due, keptToday, seen, elsewhere], attempts: [missed, remembered])
        let session = MobileCardReviewSession(mode: .notebookPractice(notebookID: "p"), backend: cards.backend(now: now))
        await session.open()

        XCTAssertEqual(session.sitting?.kind, .practice)
        XCTAssertEqual(session.sitting?.cards.map(\.itemID), [due.id, keptToday.id, seen.id], "due, new, then not due yet; only the notebook's")
        XCTAssertEqual(session.notebookInScope, "p")
        for _ in 0..<3 { answer(session, remembered: true) }
        await session.waitForWrites()
        await session.waitForFollowup()
        XCTAssertEqual(cards.written.map(\.memoryItemID), [due.id, keptToday.id], "the card not due yet is shown and not written")
        XCTAssertTrue(session.waitingCards.isEmpty, "Practice deals nothing after it")
    }

    // MARK: - The widget

    func testTheWidgetCountsDueAndNewCardsAndNamesNone() {
        func line(_ due: Int, _ new: Int) -> String {
            MobileTodayWidgetSnapshot(pendingCount: 0, nextTitle: nil, memoryDueCount: due, memoryNewCount: new, updatedAt: now).memoryLine
        }
        XCTAssertEqual(line(6, 4), "6 due · 4 new")
        XCTAssertEqual(line(6, 0), "6 due")
        XCTAssertEqual(line(0, 1), "1 new card")
        XCTAssertEqual(line(0, 4), "4 new cards")

        let bout = MobileTodayWidgetSnapshot(pendingCount: 1, nextTitle: "Plan", boutTitle: "Bout", isOnBreak: true, updatedAt: now)
        let day = MobileTodayWidgetSnapshotStore.replacingDay(
            in: bout, pendingCount: 2, nextTitle: "Next", memoryDueCount: 6, memoryNewCount: 4, now: now
        )
        XCTAssertEqual(day.memoryCardCount, 10)
        XCTAssertEqual(day.boutTitle, "Bout", "the bout's half is kept")
        XCTAssertEqual(day.memoryLine, "6 due · 4 new")
    }

    func testTheRecorderNamesAnAttemptAsTheMacDoes() throws {
        let item = try card("payload", keptAt: now)
        let attempt = MemoryAttempt.selfGraded(id: "a1", memoryItemID: item.id, prompt: "Front payload", remembered: true, at: now)
        let name = MobileMemoryAttemptRecorder.recordName(for: attempt.id)
        XCTAssertEqual(name.count, 64, "the Mac's record name for the attempt: a digest of its entity and id alone")
        XCTAssertNotEqual(name, MobileMemoryAttemptRecorder.recordName(for: "a2"))
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
