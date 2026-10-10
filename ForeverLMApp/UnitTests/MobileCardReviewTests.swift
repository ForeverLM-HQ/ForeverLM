import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's card review and a notebook's Practice, against the Mac's own
/// store (docs/memory-design.md, "The card review on the iPhone"): the phone
/// deals what `memoryCardReviewSnapshot` and `memoryCardNotebookPractice`
/// deal, words each card as `MemoryCardWording` does from its state row, and
/// writes exactly what `recordSelfGradedMemoryCardAttempt` writes — the same
/// attempt, under the same id, only when the Mac's store would.
@Suite("The card review on the phone")
struct MobileCardReviewTests {
    private let day = MemoryTutorScheduler.secondsPerDay
    private static let text = "Mitochondria couple respiration to ATP synthesis through a proton gradient. "
        + "Uncoupling proteins let protons leak back without making ATP."
    private static let sleep = "Sleep consolidates what was learned during the day."

    // MARK: - Fixtures

    private func makeStore() throws -> KnowledgeStore {
        let store = try KnowledgeStore(inMemory: true)
        for (id, text) in [("src-1", Self.text), ("src-2", Self.sleep)] {
            var source = StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, discoveryOrigin: .manual, id: id)
            source.normalizedURL = URLNormalizer.normalize(source.url)
            source.content = text
            source.state = .ready
            try store.saveSource(source)
        }
        return store
    }

    private func drafted(_ id: String, on sourceID: String = "src-1") -> MemoryCard {
        MemoryCard(
            cardID: id,
            front: "Front \(id)",
            back: "Back \(id)",
            why: ["Why \(id)"],
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: sourceID)
        )
    }

    /// Kept cards in every state a deal tells apart: due (missed two days
    /// ago), new and eligible, kept today, on another notebook's source, and
    /// an item from before cards with no face.
    private func seededStore(now: Date) throws -> (store: KnowledgeStore, due: MemoryItem, older: MemoryItem, keptToday: MemoryItem, elsewhere: MemoryItem) {
        let store = try makeStore()
        let due = try store.keepMemoryCard(drafted("due"), sourceID: "src-1", quote: "a proton gradient", at: now.addingTimeInterval(-10 * day))
        _ = try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: due.id, prompt: "Front due", remembered: false, sessionKey: "earlier", at: now.addingTimeInterval(-2 * day)
        )
        let older = try store.keepMemoryCard(drafted("older"), sourceID: "src-1", quote: "couple respiration to ATP synthesis", at: now.addingTimeInterval(-2 * day))
        let keptToday = try store.keepMemoryCard(drafted("today"), sourceID: "src-1", quote: "Uncoupling proteins let protons leak back", at: now)
        let elsewhere = try store.keepMemoryCard(drafted("elsewhere", on: "src-2"), sourceID: "src-2", quote: "Sleep consolidates", at: now.addingTimeInterval(-3 * day))
        try store.saveMemoryItem(MemoryItem(
            id: "faceless", kind: .concept, target: "A target to recall",
            rubricJSON: #"{"criteria":["recall"]}"#,
            sources: [MemoryItemSource(id: "anchor-faceless", memoryItemID: "faceless", sourceID: "src-1", excerpt: "a proton gradient", sourceSHA256: "h", sortIndex: 0)],
            createdAt: now.addingTimeInterval(-5 * day),
            updatedAt: now.addingTimeInterval(-5 * day)
        ))
        return (store, due, older, keptToday, elsewhere)
    }

    // MARK: - The deal

    @Test("Today's cards on the phone are the Mac's store's: due, then new by the allowance, faceless items left out, today's keeps as practice")
    func readMatchesTheStore() throws {
        let now = Date()
        let seeded = try seededStore(now: now)
        let reviewable = try seeded.store.reviewableMemoryItems()
        for scope in [nil, MobileNotebookCards.scope(notebookID: "mito", memberSourceIDs: ["src-1"])] as [MemoryCardScope?] {
            for (budget, allowance) in [(nil, 10), (5, 10), (nil, 1)] as [(Int?, Int)] {
                let phone = MobileCardReviewDealing.read(
                    items: reviewable.items, attempts: reviewable.attempts,
                    now: now, budgetMinutes: budget, newPerDay: allowance, scope: scope
                )
                let mac = try seeded.store.memoryCardReviewSnapshot(
                    now: now, budgetMinutes: budget, newPerDay: allowance, deadlines: [], scope: scope, includesListings: false
                )
                #expect(phone.today == mac.today, "scope \(String(describing: scope?.notebookID)), \(String(describing: budget)) min, \(allowance) new")
                #expect(phone.practice.map(\.id) == mac.practice.map(\.id))
                #expect(phone.counts == mac.counts)
                #expect(phone.attemptsByItemID.mapValues { $0.map(\.id).sorted() } == mac.attemptsByItemID.mapValues { $0.map(\.id).sorted() })
            }
        }
        let everywhere = MobileCardReviewDealing.read(
            items: reviewable.items, attempts: reviewable.attempts, now: now, budgetMinutes: nil, newPerDay: 10, scope: nil
        )
        #expect(everywhere.today.entries.map(\.id) == [seeded.due.id, seeded.elsewhere.id, seeded.older.id])
        #expect(everywhere.practice.map(\.id) == [seeded.keptToday.id], "kept today: practice, not today's")
        #expect(!everywhere.today.entries.contains { $0.id == "faceless" }, "an item with no face is no card")
        #expect(everywhere.counts.todayLine == "1 due · 2 new")
    }

    @Test("A notebook's scope is its own pool, and the day's new-card allowance stays one across notebooks")
    func scopeAndAllowance() throws {
        let now = Date()
        let seeded = try seededStore(now: now)
        let reviewable = try seeded.store.reviewableMemoryItems()
        let mito = MobileNotebookCards.scope(notebookID: "mito", memberSourceIDs: ["src-1"])
        #expect(mito == MemoryCardScope(notebookID: "mito", memberSourceIDs: ["src-1"]), "the Mac's own scope")
        let scoped = MobileCardReviewDealing.read(
            items: reviewable.items, attempts: reviewable.attempts, now: now, budgetMinutes: nil, newPerDay: 10, scope: mito
        )
        #expect(scoped.today.entries.map(\.id) == [seeded.due.id, seeded.older.id])

        // A new card introduced today in another notebook comes off this one's allowance.
        _ = try seeded.store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: seeded.elsewhere.id, prompt: "Front elsewhere", remembered: true, sessionKey: "sleep-sitting", at: now
        )
        let after = try seeded.store.reviewableMemoryItems()
        let narrowed = MobileCardReviewDealing.read(
            items: after.items, attempts: after.attempts, now: now, budgetMinutes: nil, newPerDay: 1, scope: mito
        )
        #expect(narrowed.today.entries.map(\.id) == [seeded.due.id], "the one new card today was dealt elsewhere")
        #expect(narrowed.practice.map(\.id) == [seeded.older.id, seeded.keptToday.id])
        let mac = try seeded.store.memoryCardReviewSnapshot(now: now, budgetMinutes: nil, newPerDay: 1, deadlines: [], scope: mito, includesListings: false)
        #expect(narrowed.today == mac.today)
    }

    @Test("A notebook's Practice deals its kept cards as the Mac's does — due, new (kept today among them), then not yet due — and its Studio line counts kept and due")
    func notebookPracticeMatchesTheStore() throws {
        let now = Date()
        let seeded = try seededStore(now: now)
        // Remembered on its first eligible day: seen, and not due again yet.
        let seen = try seeded.store.keepMemoryCard(drafted("seen"), sourceID: "src-1", quote: "without making ATP", at: now.addingTimeInterval(-4 * day))
        _ = try seeded.store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: seen.id, prompt: "Front seen", remembered: true, sessionKey: "earlier", at: now.addingTimeInterval(-3 * day)
        )
        let reviewable = try seeded.store.reviewableMemoryItems()
        let scope = MobileNotebookCards.scope(notebookID: "mito", memberSourceIDs: ["src-1"])

        let phone = MobileCardReviewDealing.notebookPractice(items: reviewable.items, attempts: reviewable.attempts, scope: scope, now: now)
        let mac = try seeded.store.memoryCardNotebookPractice(scope: scope, now: now, toCheckFrom: [], deckState: { _ in nil })
        #expect(phone.kept == mac.kept)
        #expect(phone.entries.map(\.id) == [seeded.due.id, seeded.older.id, seeded.keptToday.id, seen.id])
        #expect(phone.kept.notDueYet.map(\.id) == [seen.id])
        #expect(phone.attemptsByItemID.mapValues { $0.map(\.id).sorted() } == mac.attemptsByItemID.mapValues { $0.map(\.id).sorted() })

        let counts = MobileCardReviewDealing.notebookCounts(
            items: reviewable.items, attempts: reviewable.attempts, scope: scope, now: now, budgetMinutes: nil, newPerDay: 10
        )
        let macCounts = try seeded.store.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: scope, toCheckFrom: [], deckState: { _ in nil }
        ).notebookCounts
        #expect(counts == macCounts)
        #expect(counts == NotebookCardCounts(kept: 4, due: 1, toCheck: 0))
        #expect(MobileCardReviewCopy.studioLine(counts) == "4 kept · 1 due")
        #expect(MobileCardReviewCopy.studioLine(NotebookCardCounts(kept: 0, due: 0, toCheck: 0)) == "No cards kept yet")
        #expect(MobileCardReviewCopy.studioLine(nil) == "Counting…")

        // Practice's own answers count for the due and new cards and not for the one seen and not due.
        let practiced = try #require(phone.entries.last)
        let context = try #require(reviewable.items.first { $0.id == practiced.id })
        let decision = try MobileSelfGradedAnswer.decide(
            item: context, history: reviewable.attempts, prompt: "Front seen", remembered: true,
            sessionKey: "practice-sitting", practice: true, at: now
        )
        #expect(decision == .skip(.notCounted), "practice never stretches an interval")
        let keptToday = try MobileSelfGradedAnswer.decide(
            item: seeded.keptToday, history: reviewable.attempts, prompt: "Front today", remembered: true,
            sessionKey: "practice-sitting", practice: true, at: now
        )
        guard case .write(let attempt) = keptToday else {
            Issue.record("practice the learner started counts a card kept today")
            return
        }
        #expect(attempt.memoryItemID == seeded.keptToday.id)
    }

    @Test("The Memory screen's All Cards lists the Mac's store's kept cards, oldest kept first, an item with no face left out")
    func keptCardListingsMatchTheStore() throws {
        let now = Date()
        let seeded = try seededStore(now: now)
        let reviewable = try seeded.store.reviewableMemoryItems()
        let phone = MobileCardReviewDealing.listings(items: reviewable.items, attempts: reviewable.attempts)
        let mac = try seeded.store.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: nil, includesListings: true
        ).cards
        #expect(phone == mac)
        #expect(phone.map(\.itemID) == [seeded.due.id, seeded.elsewhere.id, seeded.older.id, seeded.keptToday.id])
        #expect(phone.first?.schedule.isNew == false, "the due card has been answered")
        #expect(MobileCardReviewDealing.listings(items: reviewable.items + [seeded.due], attempts: reviewable.attempts) == phone, "an item held twice is listed once")
    }

    // MARK: - The wording

    @Test("Each card is worded from its state row: the learner's rewording, a rewording in rotation once remembered twice, its own words when held to them or with no row")
    func wordingFromTheStateRows() throws {
        let now = Date()
        let keptAt = now.addingTimeInterval(-30 * day)
        let face = drafted("varied")
        let item = try face.memoryItem(
            id: MemoryTutorIdentity.cardItemID(cardID: face.cardID),
            anchors: [MemorySourceAnchorValidation(sourceID: "src-1", excerpt: "a proton gradient", sourceSHA256: "h")],
            at: keptAt
        )
        let remembered = (0..<2).map { index in
            MemoryAttempt.selfGraded(
                id: "seen-\(index)", memoryItemID: item.id, prompt: face.front, remembered: true,
                at: keptAt.addingTimeInterval(Double(index + 2) * day)
            )
        }
        let entry = MemoryCardQueue.Entry(
            item: item,
            schedule: MemoryTutorScheduler.schedule(item: item, attempts: remembered),
            bucket: .due, notebookID: nil, daysOverdue: 0
        )
        let deckID = try #require(face.deckID)
        #expect(face.stateDeckID(in: item) == deckID)

        func asked(_ state: MemoryCardState?) -> MemoryCardSitting.Card? {
            let states = state.map { [deckID: MemoryCardDeckState(cards: [face.cardID: $0])] } ?? [:]
            return MobileCardReviewDealing.sittingCards([entry], attemptsByItemID: [item.id: remembered], states: states).first
        }
        #expect(asked(nil)?.prompt == face.front, "no row read: its own words")
        let variants = MemoryCardState(status: .kept, memoryItemID: item.id, variants: ["Another angle on it?"], updatedAt: now)
        let varied = try #require(asked(variants))
        #expect(varied.prompt == "Another angle on it?")
        #expect(varied.isVariant && varied.isFirstVariedServe)
        #expect(varied.front == face.front)
        var held = variants
        held.alwaysAsk = true
        #expect(asked(held)?.prompt == face.front, "always ask it this way")
        let reworded = MemoryCardState(status: .kept, memoryItemID: item.id, editedFront: "In my words?", updatedAt: now)
        #expect(asked(reworded)?.prompt == "In my words?")
        // The sitting's card is the Mac's, worded the Mac's way.
        let mac = MemoryCardSitting.Card.dealt(entry, attempts: remembered) { _ in variants }
        #expect(varied == mac)

        // A card kept when it was missed carries no deck: its row is its anchor source's deck's.
        let missed = MemoryCard(cardID: "walk-q", front: "Q?", back: "A.", origin: .walkthrough)
        let missedItem = try missed.memoryItem(
            id: "walk-q",
            anchors: [MemorySourceAnchorValidation(sourceID: "src-2", excerpt: "Sleep consolidates", sourceSHA256: "h")],
            at: keptAt
        )
        let missedEntry = MemoryCardQueue.Entry(
            item: missedItem, schedule: MemoryTutorScheduler.schedule(item: missedItem, attempts: []),
            bucket: .new, notebookID: nil, daysOverdue: 0
        )
        #expect(MemoryCard.face(of: missedEntry.item, attempts: [])?.stateDeckID(in: missedItem) == MemoryCard.draftDeckID(sourceID: "src-2"))
    }

    // MARK: - Recording

    @Test("An answer on the phone is written exactly when, and as, the Mac's store writes it: once a sitting, never retired, only due or new and eligible")
    func recordingMatchesTheStore() throws {
        let store = try makeStore()
        let morning = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 812_000_000)))
        let item = try store.keepMemoryCard(drafted("card"), sourceID: "src-1", quote: "a proton gradient", at: morning)
        var history: [MemoryAttempt] = []

        /// The phone decides from its history; the store records; they must agree.
        func answer(_ remembered: Bool, _ sitting: String, practice: Bool = false, prompt: String = "Front card", at date: Date) throws -> MemoryCardAnswerOutcome {
            let current = try #require(try store.loadMemoryItem(item.id))
            let decision = try MobileSelfGradedAnswer.decide(
                item: current, history: history, prompt: prompt, remembered: remembered,
                sessionKey: sitting, practice: practice, at: date
            )
            let mac = try store.recordSelfGradedMemoryCardAttempt(
                memoryItemID: item.id, prompt: prompt, remembered: remembered, sessionKey: sitting, practice: practice, at: date
            )
            switch decision {
            case .write(let attempt):
                #expect(mac == .recorded, "the phone writes \(attempt.id) where the Mac would")
                let written = try #require(try store.loadMemoryAttempts(memoryItemID: item.id).first { $0.id == attempt.id })
                #expect(written == attempt, "the very attempt the Mac's store writes")
                history.append(attempt)
                return .recorded
            case .skip(let outcome):
                #expect(mac == outcome)
                return outcome
            }
        }

        let soon = morning.addingTimeInterval(60)
        #expect(try answer(true, "review-0", at: soon) == .notCounted, "not on the day it was kept")
        #expect(try answer(false, "practice-0", practice: true, at: soon) == .recorded, "practice the learner started counts it")
        #expect(try answer(true, "practice-1", practice: true, at: soon.addingTimeInterval(60)) == .notCounted, "seen and not due")
        let dueAt = MemoryTutorScheduler.schedule(item: item, attempts: history).dueAt
        let nextDay = dueAt.addingTimeInterval(9 * 3_600)
        #expect(try answer(false, "review-1", prompt: "Reworded?", at: nextDay) == .recorded)
        #expect(try answer(false, "review-1", at: nextDay.addingTimeInterval(120)) == .alreadyRecorded, "Review Forgotten writes nothing")
        #expect(try answer(true, "review-1", at: nextDay.addingTimeInterval(240)) == .alreadyRecorded)

        let reviewed = try #require(history.last)
        #expect(reviewed.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "review-1", memoryItemID: item.id))
        #expect(reviewed.gradeState == .graded)
        #expect(reviewed.attemptType == .review)
        #expect(reviewed.learnerAnswer == "(self-graded)")
        #expect(reviewed.score == 0)
        #expect(reviewed.scheduleRating == .again)
        #expect(reviewed.prompt == "Reworded?", "the wording asked")
        #expect(reviewed.sessionID == nil && reviewed.exchangeID == nil)
        #expect(reviewed.attemptedAt == nextDay, "when it was answered")

        try store.retireMemoryCard(memoryItemID: item.id)
        let later = MemoryTutorScheduler.schedule(item: item, attempts: history).dueAt.addingTimeInterval(60)
        #expect(try answer(true, "review-2", at: later) == .retired)

        #expect(throws: MobileCardReviewError.noSitting) {
            try MobileSelfGradedAnswer.decide(
                item: item, history: [], prompt: "Q", remembered: true, sessionKey: "  ", practice: false, at: later
            )
        }
    }

    @Test("An answer's id is the sitting's and the card's alone, so a retry or the record on the other device is one attempt")
    func attemptIDsAreStable() throws {
        let item = MemoryItem(
            id: "item-1", kind: .concept, target: "Back", rubricJSON: try drafted("x").rubricJSON(),
            sources: [MemoryItemSource(id: "a", memoryItemID: "item-1", sourceID: "src-1", excerpt: "e", sourceSHA256: "h", sortIndex: 0)],
            createdAt: Date(timeIntervalSinceReferenceDate: 0), updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let at = Date(timeIntervalSinceReferenceDate: 10 * day)
        func id(_ sitting: String, remembered: Bool, prompt: String) throws -> String? {
            guard case .write(let attempt) = try MobileSelfGradedAnswer.decide(
                item: item, history: [], prompt: prompt, remembered: remembered, sessionKey: sitting, practice: true, at: at
            ) else { return nil }
            return attempt.id
        }
        let first = try #require(try id("cards-2026-10-02-a", remembered: true, prompt: "Front"))
        #expect(try id("cards-2026-10-02-a", remembered: false, prompt: "Other words") == first)
        #expect(try id(" cards-2026-10-02-a\n", remembered: true, prompt: "Front") == first)
        #expect(try id("cards-2026-10-02-b", remembered: true, prompt: "Front") != first)
        #expect(first == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "cards-2026-10-02-a", memoryItemID: "item-1"))
    }

    // MARK: - Words and scope

    @Test("Home, the scope control and a round's end say what the Mac's Memory pane says")
    func copy() {
        #expect(MobileCardReviewCopy.homeLine(.empty) == nil, "Home draws no strip while nothing waits")
        #expect(MobileCardReviewCopy.homeLine(.empty, toCheck: 9) == "9 to check")
        let notebooks = [
            MobileCloudNotebook(id: "p1", title: "Mitochondria", instructions: nil, sourceIDs: [], isArchived: false, updatedAt: .distantPast),
            MobileCloudNotebook(id: "p2", title: "  ", instructions: nil, sourceIDs: [], isArchived: true, updatedAt: .distantPast),
        ]
        #expect(MobileCardReviewCopy.scopeTitle(.allNotebooks, notebooks: notebooks) == "All notebooks")
        #expect(MobileCardReviewCopy.scopeTitle(.notebook("p1"), notebooks: notebooks) == "Mitochondria")
        #expect(MobileCardReviewCopy.scopeTitle(.notebook("p2"), notebooks: notebooks) == "Notebook")
        #expect(MobileCardReviewCopy.validScope(.notebook("p2"), notebookIDs: ["p1", "p2"]) == .notebook("p2"), "an archived notebook's cards are still asked")
        #expect(MobileCardReviewCopy.validScope(.notebook("gone"), notebookIDs: ["p1"]) == .allNotebooks)
        #expect(MobileCardReviewCopy.validScope(.allNotebooks, notebookIDs: []) == .allNotebooks)
        #expect(MobileCardReviewCopy.roundSummary(cardCount: 18, remembered: 12, forgot: 6) == "18 cards · 12 remembered · 6 forgot")
        #expect(MobileCardReviewCopy.roundSummary(cardCount: 1, remembered: 1, forgot: 0) == "1 card · 1 remembered · 0 forgot")
        #expect(MobileCardReviewCopy.practiceNewCards(1) == "Practice 1 New Card")
        #expect(MobileCardReviewCopy.practiceNewCards(4) == "Practice 4 New Cards")
    }
}
