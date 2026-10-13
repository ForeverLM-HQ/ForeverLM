import Foundation
import Testing
@testable import ForeverLM

/// Memory as cards, stage three: the card review's pure rules — which cards a
/// sitting deals and in what order, the wording each is asked in, Review
/// forgotten, a notebook's scope, the Memory pane's numbers and lists — and
/// the store read behind them.
@Suite("Memory cards: the card review")
struct MemoryCardSittingTests {
    private let day = MemoryTutorScheduler.secondsPerDay

    // MARK: Dealing

    @Test("A sitting deals today's cards in the queue's order — a notebook needed soon, then due, then new — and asks each once")
    func dealingOrder() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 10, 1, 9)
        let (deadlineDue, deadlineReview) = dueCard("deadline-due", dueAt: now.addingTimeInterval(-3_600), sourceID: "s-finbow")
        let (longOverdue, longReview) = dueCard("long-overdue", dueAt: now.addingTimeInterval(-3 * day))
        let (justDue, justReview) = dueCard("just-due", dueAt: now.addingTimeInterval(-3_600))
        let olderNew = card("older-new", keptAt: now.addingTimeInterval(-5 * day))
        let youngerNew = card("younger-new", keptAt: now.addingTimeInterval(-2 * day))
        let items = [youngerNew, justDue, olderNew, longOverdue, deadlineDue]
        let attempts = [deadlineReview, longReview, justReview]
        let deadline = MemoryCardDeadline(notebookID: "finbow", at: now.addingTimeInterval(4 * 3_600), sourceIDs: ["s-finbow"])

        let today = MemoryCardDeal.today(
            items: items, attempts: attempts, now: now, budgetMinutes: nil, newPerDay: 10,
            deadlines: [deadline], scope: nil, calendar: calendar
        )
        // No scope is every notebook: exactly the shared queue.
        #expect(today == MemoryCardQueue.today(
            items: items, attempts: attempts, now: now, budgetMinutes: nil, newPerDay: 10,
            deadlines: [deadline], calendar: calendar
        ))
        let byItem = Dictionary(grouping: attempts, by: \.memoryItemID)
        let cards = today.entries.compactMap { MemoryCardSitting.Card.dealt($0, attempts: byItem[$0.id] ?? []) { _ in nil } }
        #expect(cards.map(\.itemID) == ["deadline-due", "long-overdue", "just-due", "older-new", "younger-new"])
        #expect(cards.map(\.isNew) == [false, false, false, true, true])
        #expect(cards.first?.prompt == "Front of deadline-due")
        #expect(cards.first?.back == "Back of deadline-due")
        #expect(cards.first?.sourceID == "s-finbow")
        #expect(cards.first?.quote == "The passage behind deadline-due")

        var sitting = MemoryCardSitting(key: "cards-2026-10-01-a", kind: .today, cards: cards)
        #expect(sitting.cardNumber == 1)
        #expect(sitting.cardCount == 5)
        // Nothing is graded before the back is shown.
        let early = sitting.answer(remembered: true)
        #expect(early == nil)
        #expect(sitting.cardNumber == 1)
        sitting.showAnswer(attempt: "An answer")
        let first = sitting.answer(remembered: true)
        #expect(first == MemoryCardSitting.Answer(
            itemID: "deadline-due", prompt: "Front of deadline-due", remembered: true, practice: false
        ))
        #expect(sitting.cardNumber == 2)
        #expect(!sitting.isAnswerShown, "the next card starts on its front")
        for remembered in [false, true, true] {
            sitting.showAnswer(attempt: "An answer")
            let answer = sitting.answer(remembered: remembered)
            #expect(answer != nil)
            #expect(!sitting.firstDealAnswered)
        }
        sitting.showAnswer(attempt: "An answer")
        let last = sitting.answer(remembered: false)
        #expect(last?.itemID == "younger-new")
        #expect(sitting.isRoundOver)
        #expect(sitting.firstDealAnswered)
        #expect(sitting.rememberedCount == 3)
        #expect(sitting.forgottenCount == 2)
        #expect(sitting.progress == 1)
    }

    @Test("A card is dealt once a sitting, and an item with no face to show is not dealt")
    func duplicatesAndFacelessItems() throws {
        let kept = card("kept", keptAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let faceless = MemoryItem(
            id: "faceless", kind: .concept, target: "A target with no separator",
            rubricJSON: #"{"criteria":["x"]}"#,
            sources: kept.sources.map { MemoryItemSource(id: "a-faceless", memoryItemID: "faceless", sourceID: $0.sourceID, excerpt: $0.excerpt, sourceSHA256: $0.sourceSHA256, sortIndex: 0) }
        )
        let entries = [kept, faceless].map {
            MemoryCardQueue.Entry(item: $0, schedule: MemoryTutorScheduler.schedule(item: $0, attempts: []), bucket: .new, notebookID: nil, daysOverdue: 0)
        }
        let cards = entries.compactMap { MemoryCardSitting.Card.dealt($0, attempts: []) { _ in nil } }
        #expect(cards.map(\.itemID) == ["kept"])
        let sitting = MemoryCardSitting(key: "k", kind: .today, cards: cards + cards)
        #expect(sitting.cardCount == 1)
        #expect(MemoryCardSitting(key: "k", kind: .today, cards: []).firstDealAnswered, "an empty deal promises nothing")
        #expect(MemoryCardSitting.newKey(day: "2026-10-01", token: "ABC") == "cards-2026-10-01-abc")
    }

    // MARK: Review forgotten

    @Test("Review forgotten deals the round's forgotten cards again and writes none of them twice; Continue writes the new ones")
    func reviewForgottenOnce() {
        let cards = ["a", "b", "c"].map { MemoryCardSitting.Card(itemID: $0, prompt: "Q \($0)", back: "A \($0)") }
        var sitting = MemoryCardSitting(key: "k", kind: .today, cards: cards)
        let tooEarly = sitting.reviewForgotten()
        #expect(!tooEarly, "not before the round is over")
        var written: [String] = []
        for remembered in [true, false, false] {
            sitting.showAnswer(attempt: "An answer")
            if let answer = sitting.answer(remembered: remembered) { written.append(answer.itemID) }
        }
        #expect(written == ["a", "b", "c"])
        #expect(sitting.forgottenCards.map(\.itemID) == ["b", "c"])

        let repeated = sitting.reviewForgotten()
        #expect(repeated)
        #expect(sitting.isRepeat)
        #expect(sitting.cards.map(\.itemID) == ["b", "c"])
        #expect(sitting.cardNumber == 1)
        for remembered in [true, false] {
            sitting.showAnswer(attempt: "An answer")
            let answer = sitting.answer(remembered: remembered)
            #expect(answer == nil, "a repeat is shown, never written")
        }
        #expect(sitting.firstDealAnswered)
        // A card forgotten again comes back again, still unwritten.
        let again = sitting.reviewForgotten()
        #expect(again)
        #expect(sitting.cards.map(\.itemID) == ["c"])
        sitting.showAnswer(attempt: "An answer")
        let repeatAnswer = sitting.answer(remembered: true)
        #expect(repeatAnswer == nil)
        let nothingForgotten = sitting.reviewForgotten()
        #expect(!nothingForgotten, "nothing was forgotten")

        // More of today's cards: only those the sitting has not written.
        let more = ["c", "d"].map { MemoryCardSitting.Card(itemID: $0, prompt: "Q \($0)", back: "A \($0)") }
        let dealt = sitting.dealMore(more)
        #expect(dealt)
        #expect(!sitting.isRepeat)
        #expect(sitting.cards.map(\.itemID) == ["d"])
        sitting.showAnswer(attempt: "An answer")
        let moreAnswer = sitting.answer(remembered: false)
        #expect(moreAnswer?.itemID == "d")
        #expect(sitting.recordedItemIDs == ["a", "b", "c", "d"])
        let dealtAgain = sitting.dealMore(more)
        #expect(!dealtAgain, "every card there has been written")
    }

    @Test("A card's back opens only on an answer, typed or said, or on I don't know, which can only be Forgot")
    func backOpensOnAnAnswer() {
        let cards = ["a", "b", "c"].map { MemoryCardSitting.Card(itemID: $0, prompt: "Q \($0)", back: "A \($0)") }
        var sitting = MemoryCardSitting(key: "k", kind: .today, cards: cards)
        // No bare flip: a blank answer opens nothing.
        let empty = sitting.showAnswer(attempt: "")
        let blank = sitting.showAnswer(attempt: "  \n ")
        #expect(!empty)
        #expect(!blank)
        #expect(!sitting.isAnswerShown)
        let unanswered = sitting.answer(remembered: true)
        #expect(unanswered == nil)

        let checked = sitting.showAnswer(attempt: "  The answer, said back \n")
        #expect(checked)
        #expect(sitting.isAnswerShown)
        #expect(sitting.attempt == "The answer, said back")
        #expect(!sitting.saidNotKnown)
        let secondGo = sitting.showAnswer(attempt: "A second go")
        #expect(!secondGo, "the back is already open")
        #expect(sitting.attempt == "The answer, said back")
        let first = sitting.answer(remembered: true)
        #expect(first?.remembered == true)
        #expect(sitting.attempt == nil, "the next card starts with nothing answered")

        // I don't know opens the back with nothing to grade, and is Forgot
        // whatever is asked.
        sitting.showAnswerNotKnown()
        #expect(sitting.isAnswerShown)
        #expect(sitting.saidNotKnown)
        #expect(sitting.attempt == nil)
        let notKnown = sitting.answer(remembered: true)
        #expect(notKnown?.remembered == false)
        #expect(!sitting.saidNotKnown)
        #expect(sitting.forgottenCards.map(\.itemID) == ["b"])

        sitting.showAnswer(attempt: "C")
        sitting.answer(remembered: true)
        #expect(sitting.isRoundOver)
        // Review Forgotten asks again on an answer too.
        sitting.reviewForgotten()
        #expect(!sitting.isAnswerShown)
        #expect(!sitting.saidNotKnown)
        #expect(sitting.attempt == nil)
        let blankAgain = sitting.showAnswer(attempt: "")
        #expect(!blankAgain)
    }

    @Test("Practice answers say they are practice")
    func practiceAnswers() {
        var sitting = MemoryCardSitting(
            key: "k", kind: .practice,
            cards: [MemoryCardSitting.Card(itemID: "kept-today", prompt: "Q", back: "A", isNew: true)]
        )
        sitting.showAnswer(attempt: "An answer")
        let answer = sitting.answer(remembered: true)
        #expect(answer?.practice == true)
    }

    // MARK: A day done by its cards

    @Test("A day whose cards ran out is done, whatever the minutes say; until then it is open")
    func dayDoneByCards() {
        let goal = MemoryReviewGoal.goalSeconds(budgetMinutes: 15)
        let short = MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: "2026-10-01", activeSeconds: 240, goalSeconds: goal),
            streak: 2
        )
        #expect(MemoryReviewCommitment.state(snapshot: short, end: nil) == .open)
        #expect(MemoryReviewCommitment.state(snapshot: short, end: nil, cardsFinished: true) == .done(streak: 2))
        // Done is done, as for minutes met elsewhere after this Mac gave up.
        let end = MemoryReviewSessionEnd(day: "2026-10-01", activeSeconds: 240, endedAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(MemoryReviewCommitment.state(snapshot: short, end: end, cardsFinished: true) == .done(streak: 2))
        #expect(MemoryReviewCommitment.state(snapshot: short, end: end) == .ended(afterSeconds: 240))
        #expect(!MemoryReviewCommitment.leavingEndsSession(.done(streak: 2)), "leaving a day done by its cards ends nothing")
    }

    // MARK: Wording

    @Test("A card is asked in its front until it has been remembered twice, then in a variant, never the one asked last")
    func rotation() {
        let face = MemoryCard(cardID: "c1", front: "Front", back: "Back", origin: .drafted)
        let variants = MemoryCardState(status: .kept, memoryItemID: "item", variants: ["V1", "V2"], updatedAt: Date())
        func attempt(_ id: String, _ prompt: String, _ rating: MemoryScheduleRating, at offset: TimeInterval) -> MemoryAttempt {
            MemoryAttempt(
                id: id, memoryItemID: "item", prompt: prompt, learnerAnswer: "(self-graded)",
                score: rating == .again ? 0 : 1, scheduleRating: rating, gradeState: .graded,
                attemptedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
            )
        }
        // No state, or one success: the front.
        #expect(MemoryCardWording.asked(card: face, state: nil, attempts: []).text == "Front")
        #expect(MemoryCardWording.asked(card: face, state: variants, attempts: [attempt("a", "Front", .good, at: 0)]).text == "Front")
        // A miss is not a success.
        #expect(MemoryCardWording.asked(card: face, state: variants, attempts: [
            attempt("a", "Front", .good, at: 0), attempt("b", "Front", .again, at: 10),
        ]).text == "Front")

        // Two successes, the front asked last: the first variant, said once.
        let twice = [attempt("a", "Front", .good, at: 0), attempt("b", "Front", .good, at: 10)]
        let first = MemoryCardWording.asked(card: face, state: variants, attempts: twice)
        #expect(first == MemoryCardWording.Asked(text: "V1", isVariant: true, isFirstVariedServe: true, variantIndex: 0))
        // V1 asked last: V2, and no longer the first varied serve.
        let afterV1 = MemoryCardWording.asked(card: face, state: variants, attempts: twice + [attempt("c", "V1", .good, at: 20)])
        #expect(afterV1 == MemoryCardWording.Asked(text: "V2", isVariant: true, isFirstVariedServe: false, variantIndex: 1))
        // V2 asked last: round to V1.
        #expect(MemoryCardWording.asked(card: face, state: variants, attempts: twice + [attempt("d", "V2", .good, at: 30)]).text == "V1")

        // A retired variant is skipped; the one left, asked last, gives way to the front.
        var retired = variants
        retired.retiredVariants = ["V1"]
        #expect(MemoryCardWording.asked(card: face, state: retired, attempts: twice + [attempt("e", "V2", .good, at: 40)]).text == "Front")
        #expect(MemoryCardWording.asked(card: face, state: retired, attempts: twice).text == "V2")

        // Always ask it this way: the front, however many successes.
        var always = variants
        always.alwaysAsk = true
        #expect(MemoryCardWording.asked(card: face, state: always, attempts: twice) == MemoryCardWording.Asked(text: "Front", isVariant: false, isFirstVariedServe: false))

        // The learner's rewording stands in for the front, and a variant that
        // says the same is no variant.
        var reworded = MemoryCardState(status: .kept, editedFront: "Mine", variants: ["Mine"], updatedAt: Date())
        #expect(MemoryCardWording.asked(card: face, state: reworded, attempts: []).text == "Mine")
        #expect(MemoryCardWording.asked(card: face, state: reworded, attempts: twice).text == "Mine")
        reworded.variants = ["Mine", "Other"]
        #expect(MemoryCardWording.asked(card: face, state: reworded, attempts: twice).text == "Other")
    }

    // MARK: Scope

    @Test("A notebook's cards are those anchored on its sources, a team copy's own twin included, through homing's one rule")
    func scopeThroughAnchors() {
        let scope = MemoryCardScope(
            notebookID: "nb",
            memberSourceIDs: ["team-copy-1", "own-2", "  "],
            teamCopyAliases: ["team-copy-1": "own-1", "team-copy-2": "own-2"],
            goalParents: ["goal-in-nb": "nb"]
        )
        // The membership holds the learner's own rows; a deadline matches
        // anchors against every id they go by.
        #expect(scope.membership == NotebookMembership(
            notebookID: "nb",
            memberSourceIDs: ["team-copy-1", "own-2"],
            goalParents: ["goal-in-nb": "nb"],
            sourceAliases: ["team-copy-1": "own-1", "team-copy-2": "own-2"]
        ))
        #expect(scope.membership.sourceIDs == ["own-1", "own-2"])
        #expect(scope.sourceIDs == ["team-copy-1", "own-1", "team-copy-2", "own-2"])
        // The notebook lists a team copy; the card is anchored on the own source.
        #expect(scope.contains(card("on-own-1", keptAt: Date(), sourceID: "own-1")))
        #expect(scope.contains(card("on-own-2", keptAt: Date(), sourceID: "own-2")))
        // The card names a team copy whose own twin the notebook holds.
        #expect(scope.contains(card("on-copy-2", keptAt: Date(), sourceID: "team-copy-2")))
        #expect(!scope.contains(card("elsewhere", keptAt: Date(), sourceID: "s-elsewhere")))
        // An item from before cards made with the notebook, or one of its
        // Goals, as its goal is filed there.
        #expect(scope.contains(card("goal", keptAt: Date(), sourceID: "s-elsewhere", goalID: "nb")))
        #expect(scope.contains(card("nested-goal", keptAt: Date(), sourceID: "s-elsewhere", goalID: "goal-in-nb")))
        #expect(!scope.contains(card("other-goal", keptAt: Date(), sourceID: "s-elsewhere", goalID: "other")))
        // The same answer homing gives a derived thing riding the source.
        #expect(scope.membership.containsDerived(sourceID: "team-copy-2"))
    }

    @Test("A notebook's review deals only its cards, and the day's new-card allowance is one across notebooks")
    func scopedDealSharesTheAllowance() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 10, 1, 15)
        let scope = MemoryCardScope(notebookID: "nb", memberSourceIDs: ["in"])
        // Introduced this morning outside the notebook: its first graded
        // answer was today and it was not a discovery.
        let introducedElsewhere = card("introduced-elsewhere", keptAt: now.addingTimeInterval(-2 * day), sourceID: "out")
        let introduction = graded("introduced-elsewhere", .good, at: try local(calendar, 10, 1, 8))
        let newInside = (1...3).map { card("new-in-\($0)", keptAt: now.addingTimeInterval(-Double(5 - $0) * day), sourceID: "in") }
        let newOutside = card("new-out", keptAt: now.addingTimeInterval(-3.5 * day), sourceID: "out")
        let (dueInside, dueReview) = dueCard("due-in", dueAt: now.addingTimeInterval(-3_600), sourceID: "in")
        let items = newInside + [introducedElsewhere, newOutside, dueInside]
        let attempts = [introduction, dueReview]

        let scoped = MemoryCardDeal.today(
            items: items, attempts: attempts, now: now, budgetMinutes: nil, newPerDay: 3,
            deadlines: [], scope: scope, calendar: calendar
        )
        // Three a day, one used elsewhere: two of the notebook's new cards.
        #expect(scoped.entries.map(\.id) == ["due-in", "new-in-1", "new-in-2"])
        #expect(scoped.newLeftOver == 1)

        // Every notebook: the same two new cards' worth, oldest kept first,
        // whichever notebook they are in.
        let everywhere = MemoryCardDeal.today(
            items: items, attempts: attempts, now: now, budgetMinutes: nil, newPerDay: 3,
            deadlines: [], scope: nil, calendar: calendar
        )
        #expect(everywhere.entries.map(\.id) == ["due-in", "new-in-1", "new-out"])
    }

    @Test("Practice takes the scope's new cards today's review leaves out, kept today included, oldest first")
    func practiceDeal() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 10, 1, 15)
        let keptToday = card("kept-today", keptAt: try local(calendar, 10, 1, 9), sourceID: "in")
        let pastAllowance = card("past-allowance", keptAt: now.addingTimeInterval(-3 * day), sourceID: "in")
        let dealtToday = card("dealt-today", keptAt: now.addingTimeInterval(-4 * day), sourceID: "in")
        let (seen, seenReview) = dueCard("seen", dueAt: now.addingTimeInterval(3 * day), sourceID: "in")
        let outside = card("outside", keptAt: now.addingTimeInterval(-5 * day), sourceID: "out")
        let retired = card("retired", keptAt: now.addingTimeInterval(-6 * day), sourceID: "in", status: .retired)
        let practice = MemoryCardDeal.practice(
            items: [keptToday, pastAllowance, dealtToday, seen, outside, retired],
            attempts: [seenReview],
            scope: MemoryCardScope(notebookID: "nb", memberSourceIDs: ["in"]),
            excluding: ["dealt-today"],
            calendar: calendar
        )
        #expect(practice.map(\.id) == ["past-allowance", "kept-today"])
        #expect(practice.allSatisfy { $0.isNew && $0.bucket == .new })
    }

    // MARK: A notebook's Practice

    @Test("A notebook's Practice deals every kept card of the notebook: due first, then new, a card kept today among them, then the rest, soonest due first")
    func notebookPracticeDeal() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 10, 1, 15)
        let scope = MemoryCardScope(
            notebookID: "nb",
            memberSourceIDs: ["in", "team-copy"],
            teamCopyAliases: ["team-copy": "own-twin"]
        )
        let (justDue, justReview) = dueCard("just-due", dueAt: now.addingTimeInterval(-3_600), sourceID: "in")
        let (overdue, overdueReview) = dueCard("overdue", dueAt: now.addingTimeInterval(-3 * day), sourceID: "in")
        let older = card("older-new", keptAt: now.addingTimeInterval(-4 * day), sourceID: "own-twin")
        let keptToday = card("kept-today", keptAt: try local(calendar, 10, 1, 9), sourceID: "in")
        let filed = card("filed", keptAt: now.addingTimeInterval(-5 * day), sourceID: "out", goalID: "nb")
        let (later, laterReview) = dueCard("later", dueAt: now.addingTimeInterval(3 * day), sourceID: "in")
        let (sooner, soonerReview) = dueCard("sooner", dueAt: now.addingTimeInterval(day), sourceID: "in")
        let outside = card("outside", keptAt: now.addingTimeInterval(-5 * day), sourceID: "out")
        let retired = card("retired", keptAt: now.addingTimeInterval(-6 * day), sourceID: "in", status: .retired)

        let dealt = MemoryCardDeal.notebookPractice(
            items: [keptToday, later, outside, justDue, older, retired, sooner, overdue, filed, older],
            attempts: [justReview, overdueReview, laterReview, soonerReview],
            scope: scope,
            now: now,
            calendar: calendar
        )
        // The cards whose answer is written first, due then new; the cards
        // not due yet apart, for last.
        #expect(dealt.answerable.map(\.id) == ["overdue", "just-due", "filed", "older-new", "kept-today"])
        #expect(dealt.notDueYet.map(\.id) == ["sooner", "later"])
        #expect(dealt.all.count == 7, "the duplicate, the retired card and the card elsewhere are not dealt")
        #expect(dealt.answerable.first?.daysOverdue == 3)
        #expect(dealt.answerable.filter(\.isNew).map(\.id) == ["filed", "older-new", "kept-today"])
        #expect(dealt.notDueYet.allSatisfy { $0.daysOverdue == 0 && !$0.isNew }, "a card not due yet is not overdue")
        // Practice is the learner's: every answer counts as practice, which
        // storage writes only for a card due or new.
        #expect(dealt.answerable.allSatisfy { MemoryCardQueue.answerCounts(status: .active, schedule: $0.schedule, now: now, practice: true) })
        #expect(!dealt.notDueYet.contains { MemoryCardQueue.answerCounts(status: .active, schedule: $0.schedule, now: now, practice: true) }, "practice never stretches an interval")
    }

    @Test("On a draft a notebook's Practice deals, answering keeps it, Skip drops it unanswered, and Edit keeps it before it is answered")
    func draftsInPractice() throws {
        func draft(_ id: String) -> MemoryCardToCheck {
            MemoryCardToCheck(
                kind: .draft,
                face: MemoryCard(cardID: id, front: "Front \(id)", back: "Back \(id)", why: ["Why \(id)"], origin: .drafted, deckID: "carddeck-src"),
                deckID: "carddeck-src",
                sourceID: "src",
                quote: "The passage behind \(id)",
                seed: "seed-\(id)",
                ideaID: nil,
                draftedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                isRequested: false,
                memoryItemID: nil
            )
        }
        let toKeep = draft("keep-me"), toSkip = draft("skip-me"), toEdit = draft("edit-me")
        let legacy = MemoryCardToCheck(
            kind: .legacy, face: MemoryCard(cardID: "legacy", front: "Q", back: "A", origin: .legacy),
            deckID: "carddeck-src", sourceID: "src", quote: "q", seed: nil, ideaID: nil,
            draftedAt: nil, isRequested: false, memoryItemID: "legacy"
        )
        #expect(MemoryCardSitting.Card.draft(legacy) == nil, "an item from before cards is kept already")
        let keepCard = try #require(MemoryCardSitting.Card.draft(toKeep))
        #expect(keepCard.itemID == MemoryTutorIdentity.cardItemID(cardID: "keep-me"), "asked under the item Keep makes of it")
        #expect(keepCard.prompt == "Front keep-me")
        #expect(keepCard.back == "Back keep-me")
        #expect(keepCard.why == ["Why keep-me"])
        #expect(keepCard.sourceID == "src")
        #expect(keepCard.quote == "The passage behind keep-me")
        #expect(keepCard.isDraft)

        var sitting = MemoryCardSitting(
            key: "cards-2026-10-01-p",
            kind: .practice,
            cards: [
                MemoryCardSitting.Card(itemID: "kept", prompt: "Kept front", back: "Kept back"),
                keepCard,
                try #require(MemoryCardSitting.Card.draft(toSkip)),
                try #require(MemoryCardSitting.Card.draft(toEdit)),
            ]
        )
        // A kept card: no Skip.
        let noSkip = sitting.skipCurrentDraft()
        #expect(noSkip == nil)
        sitting.showAnswer(attempt: "An answer")
        let first = sitting.answer(remembered: true)
        #expect(first == MemoryCardSitting.Answer(itemID: "kept", prompt: "Kept front", remembered: true, practice: true))

        // Answering a draft keeps it, then writes the answer on it.
        sitting.showAnswer(attempt: "An answer")
        let kept = sitting.answer(remembered: false)
        #expect(kept?.keeping == toKeep)
        #expect(kept?.itemID == MemoryTutorIdentity.cardItemID(cardID: "keep-me"))
        #expect(kept?.practice == true)
        #expect(sitting.cards[1].isDraft == false, "answered, it is a kept card")

        // Skip drops it with no answer.
        let skipped = sitting.skipCurrentDraft()
        #expect(skipped == toSkip)
        #expect(sitting.cardNumber == 4)
        #expect(sitting.results[MemoryTutorIdentity.cardItemID(cardID: "skip-me")] == nil)

        // Edit, then Keep: the card the learner kept takes the draft's place.
        let editedFace = MemoryCard(cardID: "edit-me", front: "My front", back: "My back", origin: .drafted, deckID: "carddeck-src")
        let current = try #require(sitting.current)
        sitting.keepDraft(itemID: current.itemID, as: current.keptEdited(editedFace, as: current.itemID))
        #expect(sitting.current?.isDraft == false)
        #expect(sitting.current?.prompt == "My front")
        #expect(sitting.current?.back == "My back")
        #expect(sitting.current?.isNew == true)
        sitting.showAnswer(attempt: "An answer")
        let edited = sitting.answer(remembered: true)
        #expect(edited?.keeping == nil, "kept already by the edit")
        #expect(edited?.prompt == "My front")
        #expect(sitting.isRoundOver)
        #expect(sitting.firstDealAnswered)
        #expect(sitting.skippedCount == 1)
        #expect(sitting.forgottenCount == 1)

        // Review Forgotten asks the forgotten draft as the kept card it is now,
        // and writes nothing.
        let again = sitting.reviewForgotten()
        #expect(again)
        #expect(sitting.current?.isDraft == false)
        let noSkipAgain = sitting.skipCurrentDraft()
        #expect(noSkipAgain == nil)
        sitting.showAnswer(attempt: "An answer")
        let repeated = sitting.answer(remembered: true)
        #expect(repeated == nil)
        #expect(sitting.skippedCount == 0, "the repeat round skipped nothing")
    }

    @Test("A notebook's Practice reads every kept card of its sources and its undecided drafts, a team copy's own twin included; its counts say kept, due and to check")
    func notebookPracticeRead() throws {
        let store = try KnowledgeStore(inMemory: true)
        for (id, text) in [
            ("src-1", "Mitochondria couple respiration to ATP synthesis through a proton gradient. Uncoupling proteins let protons leak back without making ATP."),
            ("src-2", "Sleep consolidates what was learned during the day."),
        ] {
            var source = StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, discoveryOrigin: .manual, id: id)
            source.normalizedURL = URLNormalizer.normalize(source.url)
            source.content = text
            source.state = .ready
            try store.saveSource(source)
        }
        let now = Date()
        func drafted(_ id: String, on sourceID: String = "src-1") -> MemoryCard {
            MemoryCard(cardID: id, front: "Front \(id)", back: "Back \(id)", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: sourceID))
        }
        let due = try store.keepMemoryCard(drafted("due"), sourceID: "src-1", quote: "a proton gradient", at: now.addingTimeInterval(-10 * day))
        _ = try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: due.id, prompt: "Front due", remembered: false, sessionKey: "earlier", at: now.addingTimeInterval(-2 * day)
        )
        let older = try store.keepMemoryCard(drafted("older"), sourceID: "src-1", quote: "couple respiration to ATP synthesis", at: now.addingTimeInterval(-2 * day))
        let keptToday = try store.keepMemoryCard(drafted("today"), sourceID: "src-1", quote: "Uncoupling proteins let protons leak back", at: now)
        _ = try store.keepMemoryCard(drafted("elsewhere", on: "src-2"), sourceID: "src-2", quote: "Sleep consolidates", at: now.addingTimeInterval(-3 * day))
        let deckID = MemoryCard.draftDeckID(sourceID: "src-1")
        let draft = Flashcard.mint(
            front: "What leaks protons?", back: "Uncoupling proteins.", sourceID: "src-1", sourceTitle: "src-1",
            quote: "Uncoupling proteins let protons leak back", origin: .drafted, isRequested: false, at: now
        )
        let decks = [
            MemoryCardDraftDeck(deckID: deckID, sourceID: "src-1", deck: FlashcardDeck(title: "T", cards: [draft])),
            MemoryCardDraftDeck(
                deckID: MemoryCard.draftDeckID(sourceID: "src-2"), sourceID: "src-2",
                deck: FlashcardDeck(title: "S", cards: [Flashcard.mint(
                    front: "What does sleep do?", back: "Consolidates.", sourceID: "src-2", sourceTitle: "src-2",
                    quote: "Sleep consolidates", origin: .drafted, isRequested: false, at: now
                )])
            ),
        ]
        // The notebook lists the team's copy; the cards stand on the learner's own source.
        let scope = MemoryCardScope(notebookID: "team-nb", memberSourceIDs: ["team-copy"], teamCopyAliases: ["team-copy": "src-1"])

        let deal = try store.memoryCardNotebookPractice(scope: scope, now: now, toCheckFrom: decks, deckState: { _ in nil })
        #expect(deal.kept.answerable.map(\.id) == [due.id, older.id, keptToday.id])
        #expect(deal.kept.notDueYet.isEmpty)
        #expect(deal.drafts.map(\.cardID) == [draft.id])
        #expect(Set(deal.attemptsByItemID.keys).isSubset(of: [due.id, older.id, keptToday.id]))
        #expect(deal.attemptsByItemID[due.id]?.count == 1)

        // A draft gone through is not dealt again.
        var row = MemoryCardDeckState()
        row.markSkipped(cardID: draft.id, at: now)
        let afterSkip = try store.memoryCardNotebookPractice(scope: scope, now: now, toCheckFrom: decks, deckState: { $0 == deckID ? row : nil })
        #expect(afterSkip.drafts.isEmpty)

        // The Studio's line: three kept, one due, one to check.
        let snapshot = try store.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: scope,
            toCheckFrom: decks, deckState: { _ in nil }
        )
        #expect(snapshot.notebookCounts == NotebookCardCounts(kept: 3, due: 1, toCheck: 1))
        #expect(snapshot.notebookCounts.line == "3 kept · 1 due · 1 to check")
        let elsewhere = try store.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [],
            scope: MemoryCardScope(notebookID: "sleep", memberSourceIDs: ["src-2"]),
            toCheckFrom: decks, deckState: { _ in nil }
        )
        #expect(elsewhere.notebookCounts == NotebookCardCounts(kept: 1, due: 0, toCheck: 1))
    }

    // MARK: The cards a chat chose

    @Test("A chat's chosen cards are dealt as a notebook's Practice is: only those cards, due first, then new, then the rest, soonest due first")
    func chosenPracticeDeal() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 10, 13, 15)
        let (overdue, overdueReview) = dueCard("mito-overdue", dueAt: now.addingTimeInterval(-2 * day))
        let (sooner, soonerReview) = dueCard("mito-sooner", dueAt: now.addingTimeInterval(day))
        let (later, laterReview) = dueCard("mito-later", dueAt: now.addingTimeInterval(4 * day))
        let new = card("mito-new", keptAt: now.addingTimeInterval(-3 * day))
        let (sleep, sleepReview) = dueCard("sleep-overdue", dueAt: now.addingTimeInterval(-3 * day))
        let retired = card("mito-retired", keptAt: now.addingTimeInterval(-6 * day), status: .retired)

        let dealt = MemoryCardDeal.chosenPractice(
            items: [later, sleep, new, retired, sooner, overdue],
            attempts: [overdueReview, soonerReview, laterReview, sleepReview],
            itemIDs: ["mito-overdue", "mito-sooner", "mito-later", "mito-new", "mito-retired", "not-a-card"],
            now: now,
            calendar: calendar
        )
        #expect(dealt.answerable.map(\.id) == ["mito-overdue", "mito-new"])
        #expect(dealt.notDueYet.map(\.id) == ["mito-sooner", "mito-later"])
        #expect(!dealt.all.contains { $0.id == "sleep-overdue" }, "a card not chosen is not dealt, due or not")
        #expect(!dealt.all.contains { $0.id == "mito-retired" }, "a retired card is never asked")
        #expect(!dealt.notDueYet.contains { MemoryCardQueue.answerCounts(status: .active, schedule: $0.schedule, now: now, practice: true) }, "practice never stretches an interval")
    }

    @Test("The store finds a chat's chosen cards by card id or item id, and names the ids no kept card answers to")
    func chosenPracticeRead() throws {
        let store = try KnowledgeStore(inMemory: true)
        for (id, text) in [
            ("src-mito", "Mitochondria couple respiration to ATP synthesis through a proton gradient."),
            ("src-sleep", "Sleep consolidates what was learned during the day."),
        ] {
            var source = StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, discoveryOrigin: .manual, id: id)
            source.normalizedURL = URLNormalizer.normalize(source.url)
            source.content = text
            source.state = .ready
            try store.saveSource(source)
        }
        let now = Date()
        func drafted(_ id: String, on sourceID: String) -> MemoryCard {
            MemoryCard(cardID: id, front: "Front \(id)", back: "Back \(id)", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: sourceID))
        }
        let gradient = try store.keepMemoryCard(drafted("gradient", on: "src-mito"), sourceID: "src-mito", quote: "a proton gradient", at: now.addingTimeInterval(-2 * day))
        let atp = try store.keepMemoryCard(drafted("atp", on: "src-mito"), sourceID: "src-mito", quote: "couple respiration to ATP synthesis", at: now.addingTimeInterval(-3 * day))
        let sleep = try store.keepMemoryCard(drafted("sleep", on: "src-sleep"), sourceID: "src-sleep", quote: "Sleep consolidates", at: now.addingTimeInterval(-3 * day))
        let retired = try store.keepMemoryCard(drafted("retired", on: "src-mito"), sourceID: "src-mito", quote: "Mitochondria couple respiration", at: now.addingTimeInterval(-4 * day))
        try store.retireMemoryCard(memoryItemID: retired.id, at: now)

        // A drafted card is named by its card id, whose item a store before
        // the new sync keeps under `MemoryTutorIdentity.cardItemID`; an item
        // id works too.
        let deal = try store.memoryCardChosenPractice(
            cardIDs: ["gradient", atp.id, "retired", "no-such-card"],
            now: now
        )
        #expect(Set(deal.kept.all.map(\.id)) == [gradient.id, atp.id])
        #expect(!deal.kept.all.contains { $0.id == sleep.id }, "a card not chosen is not dealt")
        #expect(deal.unknownCardIDs == ["retired", "no-such-card"], "a retired card answers to nothing")
        #expect(Set(deal.attemptsByItemID.keys).isSubset(of: [gradient.id, atp.id]))
    }

    @Test("A notebook's Cards line says kept, due and to check, any part that is zero left out")
    func notebookCardsLine() {
        #expect(NotebookCardCounts(kept: 42, due: 6, toCheck: 9).line == "42 kept · 6 due · 9 to check")
        #expect(NotebookCardCounts(kept: 42, due: 0, toCheck: 0).line == "42 kept")
        #expect(NotebookCardCounts(kept: 0, due: 0, toCheck: 9).line == "9 to check")
        #expect(NotebookCardCounts(kept: 0, due: 0, toCheck: 0).line == nil)
        #expect(NotebookCardCounts(kept: 0, due: 0, toCheck: 0).isEmpty)
        #expect(!NotebookCardCounts(kept: 0, due: 0, toCheck: 1).isEmpty)
    }

    // MARK: The pane's numbers and lists

    @Test("The Memory pane says today's cards in a line, and nothing when none are waiting")
    func paneCounts() {
        #expect(MemoryCardDayCounts(due: 6, new: 4, practice: 2).line == "6 due · 4 new")
        #expect(MemoryCardDayCounts(due: 0, new: 4, practice: 0).line == "4 new")
        #expect(MemoryCardDayCounts(due: 6, new: 0, practice: 0).line == "6 due")
        #expect(MemoryCardDayCounts.zero.line == nil)
        #expect(MemoryCardDayCounts(due: 6, new: 4, practice: 2).today == 10)
        let entry = { (id: String, isNew: Bool) -> MemoryCardQueue.Entry in
            let item = self.card(id, keptAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
            let schedule = MemorySchedule(memoryItemID: id, dueAt: Date(timeIntervalSinceReferenceDate: 800_000_000), repetitionCount: isNew ? 0 : 1)
            return MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: isNew ? .new : .due, notebookID: nil, daysOverdue: 0)
        }
        let today = MemoryCardQueue.Today(
            entries: [entry("a", false), entry("b", true), entry("c", false)],
            dueLeftOver: 0, newLeftOver: 0, newIntroducedToday: 0
        )
        #expect(MemoryCardDayCounts(today: today, practice: 3) == MemoryCardDayCounts(due: 2, new: 1, practice: 3))
    }

    @Test("All Cards finds a card by any of its words or its source, and groups by source or by notebook")
    func catalog() {
        func listing(_ id: String, front: String, back: String, sourceID: String) -> MemoryCardListing {
            MemoryCardListing(
                itemID: id,
                face: MemoryCard(cardID: id, front: front, back: back, why: ["Because ΔΨ"], origin: .drafted),
                sourceIDs: [sourceID],
                schedule: MemorySchedule(memoryItemID: id, dueAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
            )
        }
        let cards = [
            listing("1", front: "What leaks protons?", back: "Uncoupling proteins", sourceID: "mito"),
            listing("2", front: "What drives ATP synthase?", back: "The proton gradient", sourceID: "mito"),
            listing("3", front: "Who wrote the letter?", back: "Fields and Levin", sourceID: "letter"),
        ]
        let titles = ["mito": "Mitochondria", "letter": "Metabolism as Inference"]
        let title: (String) -> String? = { titles[$0] }
        #expect(MemoryCardCatalog.search(cards, query: "", sourceTitle: title).map(\.itemID) == ["1", "2", "3"])
        #expect(MemoryCardCatalog.search(cards, query: "PROTON", sourceTitle: title).map(\.itemID) == ["1", "2"])
        #expect(MemoryCardCatalog.search(cards, query: "proton gradient", sourceTitle: title).map(\.itemID) == ["2"])
        #expect(MemoryCardCatalog.search(cards, query: "inference", sourceTitle: title).map(\.itemID) == ["3"])
        #expect(MemoryCardCatalog.search(cards, query: "δψ", sourceTitle: title).count == 3, "case and accents are ignored")
        // The learner's rewording is searched too.
        #expect(MemoryCardCatalog.search(cards, query: "mine", wording: { $0.itemID == "3" ? "Mine" : $0.face.front }, sourceTitle: title).map(\.itemID) == ["3"])

        let bySource = MemoryCardCatalog.grouped(cards, by: .source, sourceTitle: title, notebooks: [])
        #expect(bySource.map(\.title) == ["Metabolism as Inference", "Mitochondria"])
        #expect(bySource.map { $0.cards.map(\.itemID) } == [["3"], ["1", "2"]])

        let notebooks = [
            (title: "Powerhouse", scope: MemoryCardScope(notebookID: "power", memberSourceIDs: ["mito"])),
            (title: "Finbow", scope: MemoryCardScope(notebookID: "finbow", memberSourceIDs: ["mito"])),
            (title: "Empty", scope: MemoryCardScope(notebookID: "empty", memberSourceIDs: ["nothing"])),
        ]
        let byNotebook = MemoryCardCatalog.grouped(cards, by: .notebook, sourceTitle: title, notebooks: notebooks)
        #expect(byNotebook.map(\.id) == ["power", "finbow", MemoryCardCatalog.unfiledID])
        #expect(byNotebook.map { $0.cards.map(\.itemID) } == [["1", "2"], ["1", "2"], ["3"]])
    }

    // MARK: The store's read

    @Test("The card review's read deals today's cards, offers today's keeps as practice, lists every kept card, and narrows to a notebook")
    func storeSnapshot() throws {
        let store = try KnowledgeStore(inMemory: true)
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = "Mitochondria couple respiration to ATP synthesis through a proton gradient. Uncoupling proteins let protons leak back without making ATP."
        source.state = .ready
        try store.saveSource(source)
        let now = Date()
        let yesterday = now.addingTimeInterval(-day)
        func drafted(_ id: String) -> MemoryCard {
            MemoryCard(cardID: id, front: "Front \(id)", back: "Back \(id)", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "src-1"))
        }
        let older = try store.keepMemoryCard(drafted("older"), sourceID: "src-1", quote: "couple respiration to ATP synthesis", at: yesterday.addingTimeInterval(-day))
        let keptToday = try store.keepMemoryCard(drafted("today"), sourceID: "src-1", quote: "Uncoupling proteins let protons leak back", at: now)
        // An item from before cards that no attempt reached and no separator
        // splits has no face, and is no card.
        try store.saveMemoryItem(MemoryItem(
            id: "faceless", kind: .concept, target: "A target to recall",
            rubricJSON: #"{"criteria":["recall"]}"#,
            sources: [MemoryItemSource(id: "anchor-faceless", memoryItemID: "faceless", sourceID: "src-1", excerpt: "a proton gradient", sourceSHA256: "h", sortIndex: 0)],
            createdAt: yesterday.addingTimeInterval(-2 * day),
            updatedAt: yesterday.addingTimeInterval(-2 * day)
        ))

        let everywhere = try store.memoryCardReviewSnapshot(now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: nil)
        #expect(everywhere.today.entries.map(\.id) == [older.id])
        #expect(everywhere.practice.map(\.id) == [keptToday.id])
        #expect(everywhere.cards.map(\.itemID) == [older.id, keptToday.id])
        #expect(everywhere.cards.first?.face.front == "Front older")
        #expect(everywhere.counts == MemoryCardDayCounts(due: 0, new: 1, practice: 1))
        #expect(Set(everywhere.attemptsByItemID.keys).isSubset(of: [older.id, keptToday.id]))

        let unlisted = try store.memoryCardReviewSnapshot(now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: nil, includesListings: false)
        #expect(unlisted.cards.isEmpty)
        #expect(unlisted.today.entries.map(\.id) == [older.id])

        // A notebook holding the team's copy of the source reaches its cards.
        let teamNotebook = MemoryCardScope(notebookID: "team-nb", memberSourceIDs: ["team-copy"], teamCopyAliases: ["team-copy": "src-1"])
        let scoped = try store.memoryCardReviewSnapshot(now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: teamNotebook)
        #expect(scoped.today.entries.map(\.id) == [older.id])
        #expect(scoped.cards.count == 2)

        let otherNotebook = MemoryCardScope(notebookID: "other", memberSourceIDs: ["src-2"])
        let none = try store.memoryCardReviewSnapshot(now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: otherNotebook)
        #expect(none.today.entries.isEmpty)
        #expect(none.practice.isEmpty)
        #expect(none.cards.isEmpty)
    }

    // MARK: Helpers

    private func losAngeles() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private func local(_ calendar: Calendar, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    /// A kept card with a face, anchored on `sourceID`.
    private func card(
        _ id: String,
        keptAt: Date,
        sourceID: String? = nil,
        goalID: String? = nil,
        status: MemoryItemStatus = .active
    ) -> MemoryItem {
        let face = MemoryCard(cardID: id, front: "Front of \(id)", back: "Back of \(id)", origin: .drafted)
        return MemoryItem(
            id: id,
            kind: .concept,
            target: face.back,
            rubricJSON: (try? face.rubricJSON()) ?? "",
            goalID: goalID,
            status: status,
            sources: [
                MemoryItemSource(
                    id: "anchor-\(id)",
                    memoryItemID: id,
                    sourceID: sourceID ?? "source-\(id)",
                    excerpt: "The passage behind \(id)",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ],
            createdAt: keptAt,
            updatedAt: keptAt
        )
    }

    private func graded(_ itemID: String, _ rating: MemoryScheduleRating, at: Date) -> MemoryAttempt {
        MemoryAttempt(
            id: "attempt-\(itemID)-\(Int(at.timeIntervalSinceReferenceDate))",
            memoryItemID: itemID,
            prompt: "Front of \(itemID)",
            learnerAnswer: MemoryAttempt.selfGradedAnswer,
            score: rating == .again ? 0 : 1,
            scheduleRating: rating,
            gradeState: .graded,
            attemptedAt: at
        )
    }

    /// A card reviewed once and due again at `dueAt`: a first `.good` sets
    /// 2 days × 2.1, so the review is dated 4.2 days before.
    private func dueCard(_ id: String, dueAt: Date, sourceID: String? = nil) -> (MemoryItem, MemoryAttempt) {
        let reviewedAt = dueAt.addingTimeInterval(-4.2 * day)
        return (card(id, keptAt: reviewedAt.addingTimeInterval(-2 * day), sourceID: sourceID), graded(id, .good, at: reviewedAt))
    }
}
