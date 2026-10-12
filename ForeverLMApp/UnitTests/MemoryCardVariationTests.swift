import Foundation
import Testing
@testable import ForeverLM

// Memory as cards, stage five: variations. A kept card remembered twice is
// reworded at the day close — three rewordings, the code's checks (length,
// newness, the answer not in them), then a separate judge — and the
// rewordings that pass join its rotation in its `cards.state.<deckID>` row.
// The rotation never asks the wording asked last; "Always ask it this way"
// turns it off; "This asks something else" is a failed attempt that retires
// the rewording; a rewording missed more often than the card's own words over
// three uses retires itself. The rules are pure and pinned first; the pass
// runs over a store of its own with a canned model and rows held in memory;
// the one test that writes rows through the state store uses a defaults
// suite of its own.

// MARK: - Fixtures

private let quote = "couple respiration to ATP synthesis through a proton gradient"
private let keptAt = Date(timeIntervalSinceReferenceDate: 812_000_000)
private let day: TimeInterval = 86_400
private let front = "What couples respiration to ATP synthesis?"
private let back = "A proton gradient across the inner membrane."
private let firstVariant = "Which gradient links respiration with making ATP?"
private let secondVariant = "Across which membrane does the coupling gradient run?"

private func keptCard(_ cardID: String = "card-a", front: String = front, back: String = back) throws -> (MemoryCard, MemoryItem) {
    let card = MemoryCard(
        cardID: cardID, front: front, back: back, why: ["Uncoupling stops ATP synthesis."],
        origin: .drafted, deckID: "carddeck-src-1"
    )
    let item = try card.memoryItem(
        id: MemoryTutorIdentity.cardItemID(cardID: cardID),
        anchors: [MemorySourceAnchorValidation(sourceID: "src-1", excerpt: quote, sourceSHA256: "h")],
        at: keptAt
    )
    return (card, item)
}

private func graded(_ id: String, on itemID: String, prompt: String = front, rating: MemoryScheduleRating = .good, onDay offset: Double) -> MemoryAttempt {
    MemoryAttempt(
        id: id, memoryItemID: itemID, prompt: prompt, learnerAnswer: "An answer.",
        score: rating == .again ? 0 : 1, scheduleRating: rating, gradeState: .graded,
        attemptedAt: keptAt.addingTimeInterval(offset * day)
    )
}

private func saidElse(_ id: String, on itemID: String, prompt: String, variant: Int, onDay offset: Double) -> MemoryAttempt {
    MemoryCardVariation.askedSomethingElseAttempt(
        id: id, memoryItemID: itemID, prompt: prompt, variantIndex: variant, at: keptAt.addingTimeInterval(offset * day)
    )
}

private func row(variants: [String] = [], alwaysAsk: Bool = false, variedAt: Date? = nil, editedFront: String? = nil) -> MemoryCardState {
    MemoryCardState(
        status: .kept, memoryItemID: MemoryTutorIdentity.cardItemID(cardID: "card-a"), editedFront: editedFront,
        variants: variants, alwaysAsk: alwaysAsk, variedAt: variedAt, updatedAt: keptAt
    )
}

private let testRoute = NotebookWritingRoute(
    provider: .openRouter,
    model: "test/card-variation",
    writerInputBudget: nil,
    condenserInputBudget: nil,
    inputUSDPerMillion: 1,
    outputUSDPerMillion: 2
)

/// The variation model's turns, and what a test hands back for them.
private final class CannedVariation: CardVariationBackend, @unchecked Sendable {
    let route: NotebookWritingRoute?
    private let rewordings: [CardVariationModelCard]
    private let verdicts: [CardVariationVerdict]
    private let lock = NSLock()
    private var storedRewordTurns: [String] = []
    private var storedJudgeTurns: [String] = []

    init(route: NotebookWritingRoute? = testRoute, rewordings: [CardVariationModelCard], verdicts: [CardVariationVerdict] = []) {
        self.route = route
        self.rewordings = rewordings
        self.verdicts = verdicts
    }

    var rewordTurns: [String] { lock.withLock { storedRewordTurns } }
    var judgeTurns: [String] { lock.withLock { storedJudgeTurns } }

    func reword(user: String, source: AIUsageSource) async throws -> [CardVariationModelCard] {
        lock.withLock { storedRewordTurns.append(user) }
        return rewordings
    }

    func judge(user: String, source: AIUsageSource) async throws -> [CardVariationVerdict] {
        lock.withLock { storedJudgeTurns.append(user) }
        return verdicts
    }
}

/// `cards.state.<deckID>` rows held in memory, written the way the live pass
/// writes them (`CardVariationPass.apply`).
private final class Rows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: MemoryCardDeckState] = [:]

    func load(_ deckID: String) -> MemoryCardDeckState {
        lock.withLock { rows[deckID] ?? MemoryCardDeckState() }
    }

    func set(_ deckID: String, _ row: MemoryCardDeckState) {
        lock.withLock { rows[deckID] = row }
    }

    func write(_ deckID: String, _ writes: [CardVariationWrite], _ now: Date) {
        lock.withLock {
            var row = rows[deckID] ?? MemoryCardDeckState()
            CardVariationPass.apply(writes, to: &row, at: now)
            rows[deckID] = row
        }
    }
}

private func pass(_ storage: StorageService, _ backend: CannedVariation, _ rows: Rows, spendAllowed: Bool = true) -> CardVariationPass {
    CardVariationPass(
        storage: storage,
        backend: backend,
        spendAllowed: { spendAllowed },
        readState: { rows.load($0) },
        write: { deckID, writes, now in rows.write(deckID, writes, now) }
    )
}

/// Storage on a folder of its own holding src-1, and the card kept on it
/// with two successes: due its rewordings.
private func storageWithEarnedCard() async throws -> (StorageService, MemoryCard, MemoryItem, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CardVariation_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storage = StorageService(storeRoot: root)
    var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
    source.normalizedURL = URLNormalizer.normalize(source.url)
    source.content = "Mitochondria couple respiration to ATP synthesis through a proton gradient across the inner membrane."
    source.state = .ready
    try await storage.saveSource(source)
    let (card, _) = try keptCard()
    let item = try await storage.keepMemoryCard(card, sourceID: "src-1", quote: quote, at: keptAt)
    _ = try await storage.recordMemoryAttempt(graded("success-1", on: item.id, onDay: 1))
    _ = try await storage.recordMemoryAttempt(graded("success-2", on: item.id, onDay: 4))
    return (storage, card, item, { try? FileManager.default.removeItem(at: root) })
}

// MARK: - The rules

@Suite("Memory cards: variations")
struct MemoryCardVariationTests {

    // MARK: The code's checks

    @Test("A rewording is kept only on one line, no longer than 1.3 times the question, new, and without the answer in it; three at most")
    func codeChecks() {
        let limit = Int((Double(front.count) * 1.3).rounded(.down))
        let tooLong = "Which gradient across which membrane links respiration with the making of ATP in the cell?"
        #expect(tooLong.count > limit)
        let kept = MemoryCardVariation.acceptable([
            "  \(firstVariant)  ",
            front,
            "what COUPLES respiration, to ATP synthesis",
            "A question on\ntwo lines?",
            tooLong,
            "What does a proton gradient across the inner membrane do?",
            "",
            firstVariant,
            secondVariant,
            "What is the link between respiration and ATP made?",
            "One more that would make four?",
        ], wording: front, back: back)
        #expect(kept == [firstVariant, secondVariant, "What is the link between respiration and ATP made?"])

        // A one-word answer may be named in a fair question: the judge rules.
        let named = MemoryCardVariation.acceptable(
            ["Is it four or two protons that complex I pumps per NADH?"],
            wording: "How many protons does complex I pump for each NADH?",
            back: "Four."
        )
        #expect(named.count == 1)
        #expect(MemoryCardVariation.compared("What's  the ATP/ADP ratio?") == "what s the atp adp ratio")
    }

    @Test("A card is reworded once it has been remembered twice, never while it is asked as kept or has been reworded, and an item from before cards only once it is gone through")
    func needsVariants() throws {
        let (card, item) = try keptCard()
        let twice = [graded("a", on: item.id, onDay: 1), graded("b", on: item.id, onDay: 3)]
        let once = [graded("a", on: item.id, onDay: 1), graded("b", on: item.id, rating: .again, onDay: 3)]
        #expect(MemoryCardVariation.successes(twice) == 2)
        #expect(MemoryCardVariation.successes(once) == 1)
        #expect(MemoryCardVariation.needsVariants(item: item, face: card, state: nil, attempts: twice))
        #expect(MemoryCardVariation.needsVariants(item: item, face: card, state: row(), attempts: twice))
        #expect(!MemoryCardVariation.needsVariants(item: item, face: card, state: row(), attempts: once))
        #expect(!MemoryCardVariation.needsVariants(item: item, face: card, state: row(alwaysAsk: true), attempts: twice))
        #expect(!MemoryCardVariation.needsVariants(item: item, face: card, state: row(variedAt: keptAt), attempts: twice), "reworded, and billed, once")
        #expect(!MemoryCardVariation.needsVariants(item: item, face: card, state: row(variants: [firstVariant]), attempts: twice))
        let retired = MemoryItem(
            id: item.id, kind: item.kind, target: item.target, rubricJSON: item.rubricJSON,
            status: .retired, sources: item.sources, createdAt: item.createdAt, updatedAt: item.updatedAt
        )
        #expect(!MemoryCardVariation.needsVariants(item: retired, face: card, state: row(), attempts: twice))

        let legacy = MemoryCard(cardID: "legacy-1", front: "What is an uncoupler?", back: "A leak.", origin: .legacy)
        #expect(!MemoryCardVariation.needsVariants(item: item, face: legacy, state: nil, attempts: twice), "it waits in To Check first")
        #expect(MemoryCardVariation.needsVariants(item: item, face: legacy, state: MemoryCardState(status: .kept, updatedAt: keptAt), attempts: twice))
    }

    // MARK: Retiring

    @Test("A rewording the learner said asks something else is retired, by its words or its place, and one missed more often than the card's own words over three uses retires itself")
    func retiring() throws {
        let (_, item) = try keptCard()
        let third = "Through what does respiration drive ATP synthesis?"
        let variants = [firstVariant, secondVariant, third]
        var attempts = [
            graded("own-1", on: item.id, onDay: 1),
            graded("own-2", on: item.id, onDay: 3),
            graded("own-3", on: item.id, rating: .again, onDay: 5),
            graded("own-4", on: item.id, onDay: 7),
        ]
        #expect(MemoryCardVariation.retired(variants: variants, wording: front, attempts: attempts).isEmpty)

        // Said of the first by its words; of the third by its place alone.
        attempts.append(saidElse("else-1", on: item.id, prompt: firstVariant, variant: 0, onDay: 8))
        attempts.append(saidElse("else-2", on: item.id, prompt: "A wording since edited away?", variant: 2, onDay: 9))
        #expect(MemoryCardVariation.retired(variants: variants, wording: front, attempts: attempts) == [firstVariant, third])
        #expect(MemoryCardVariation.askedSomethingElseVariantIndex(attempts[4]) == 0)

        // The second: two misses in three uses (67%) against the card's own
        // words' one in four (25%) retires it; two uses are not enough.
        let drift = [
            graded("v-1", on: item.id, prompt: secondVariant, rating: .again, onDay: 10),
            graded("v-2", on: item.id, prompt: secondVariant, rating: .again, onDay: 12),
        ]
        #expect(MemoryCardVariation.retired(variants: variants, wording: front, attempts: attempts + drift) == [firstVariant, third])
        let thirdUse = graded("v-3", on: item.id, prompt: secondVariant, onDay: 14)
        #expect(MemoryCardVariation.retired(variants: variants, wording: front, attempts: attempts + drift + [thirdUse]) == Set(variants))

        // Missed no more often than the card's own words: kept.
        let even = [
            graded("e-1", on: item.id, prompt: secondVariant, onDay: 10),
            graded("e-2", on: item.id, prompt: secondVariant, onDay: 12),
            graded("e-3", on: item.id, prompt: secondVariant, onDay: 14),
        ]
        #expect(!MemoryCardVariation.retired(variants: variants, wording: front, attempts: attempts + even).contains(secondVariant))
    }

    // MARK: The rotation

    @Test("The card's own words until it has been remembered twice, then a rewording, never the one asked last; Always ask it this way keeps its own words")
    func rotation() throws {
        let (card, item) = try keptCard()
        let state = row(variants: [firstVariant, secondVariant])
        let one = [graded("a", on: item.id, onDay: 1)]
        #expect(MemoryCardWording.asked(card: card, state: state, attempts: one).text == front, "remembered once: its own words")

        let twice = one + [graded("b", on: item.id, onDay: 3)]
        let first = MemoryCardWording.asked(card: card, state: state, attempts: twice)
        #expect(first.text == firstVariant)
        #expect(first.isVariant)
        #expect(first.isFirstVariedServe, "the review says once: worded differently on purpose")
        #expect(first.variantIndex == 0)

        let afterFirst = twice + [graded("c", on: item.id, prompt: firstVariant, onDay: 6)]
        let second = MemoryCardWording.asked(card: card, state: state, attempts: afterFirst)
        #expect(second.text == secondVariant)
        #expect(!second.isFirstVariedServe)
        #expect(second.variantIndex == 1)
        let afterSecond = afterFirst + [graded("d", on: item.id, prompt: secondVariant, onDay: 12)]
        #expect(MemoryCardWording.asked(card: card, state: state, attempts: afterSecond).text == firstVariant)

        // One rewording, asked last: the card's own words this time.
        let single = row(variants: [firstVariant])
        let ownWords = MemoryCardWording.asked(card: card, state: single, attempts: afterFirst)
        #expect(ownWords.text == front)
        #expect(!ownWords.isVariant)
        #expect(ownWords.variantIndex == nil)

        #expect(MemoryCardWording.asked(card: card, state: row(variants: [firstVariant, secondVariant], alwaysAsk: true), attempts: twice).text == front)
        // The learner's own rewording is the card's words.
        #expect(MemoryCardWording.asked(card: card, state: row(editedFront: "My own question?"), attempts: twice).text == "My own question?")

        // Said to ask something else, the first is out of the rotation.
        let said = afterFirst + [saidElse("else", on: item.id, prompt: firstVariant, variant: 0, onDay: 7)]
        #expect(MemoryCardWording.asked(card: card, state: state, attempts: said).text == secondVariant)
        #expect(MemoryCardWording.asked(card: card, state: single, attempts: said).text == front)
    }

    // MARK: The turns

    @Test("The rewording turn shows each card's question, answer, why and passage; the judge sees only what the code kept, and passes only what answers and does not leak")
    func turns() throws {
        let (card, item) = try keptCard()
        let candidate = CardVariationCandidate(
            itemID: item.id, cardID: card.cardID, deckID: "carddeck-src-1", sourceID: "src-1",
            wording: front, back: back, why: card.why, quote: quote
        )
        let rewording = CardVariationTurn.rewording([candidate], sourceTitle: "Mitochondria")
        #expect(rewording == """
        Source: Mitochondria

        Cards:
        1. Question: \(front)
           Answer: \(back)
           Why: Uncoupling stops ATP synthesis.
           Passage: \u{201C}\(quote)\u{201D}
        """)

        let checked = CardVariationTurn.checked([
            CardVariationModelCard(card: 1, variants: [firstVariant, front, secondVariant]),
            CardVariationModelCard(card: 1, variants: ["A second answer for card 1 is ignored?"]),
            CardVariationModelCard(card: 7, variants: ["No such card?"]),
        ], cards: [candidate])
        #expect(checked == [1: [firstVariant, secondVariant]])
        let judging = CardVariationTurn.judging([candidate], rewordings: checked)
        #expect(judging.contains("   1. \(firstVariant)\n   2. \(secondVariant)"))
        #expect(!judging.contains("No such card"))

        let passed = CardVariationTurn.judged([
            CardVariationVerdict(card: 1, variant: 1, answersIt: true, leaksAnswer: false),
            CardVariationVerdict(card: 1, variant: 2, answersIt: true, leaksAnswer: true),
        ], rewordings: [1: [firstVariant, secondVariant, "A third the judge said nothing of?"]])
        #expect(passed == [1: [firstVariant]])
        #expect(CardVariationTurn.judged([
            CardVariationVerdict(card: 1, variant: 1, answersIt: false, leaksAnswer: false),
        ], rewordings: [1: [firstVariant]]) == [1: []])
    }

    @Test("The cards due their rewordings are read in the order they were kept, in the wording asked now")
    func dueVariants() throws {
        let (card, item) = try keptCard()
        let (later, laterItem) = try keptCard("card-b", front: "What does complex IV reduce?", back: "Oxygen, to water.")
        let laterKept = MemoryItem(
            id: laterItem.id, kind: laterItem.kind, target: laterItem.target, rubricJSON: laterItem.rubricJSON,
            sources: laterItem.sources, createdAt: keptAt.addingTimeInterval(60), updatedAt: keptAt.addingTimeInterval(60)
        )
        let attempts = [
            graded("a1", on: item.id, onDay: 1), graded("a2", on: item.id, onDay: 3),
            graded("b1", on: laterItem.id, prompt: later.front, onDay: 1), graded("b2", on: laterItem.id, prompt: later.front, onDay: 3),
        ]
        let due = CardVariationCandidate.dueVariants(items: [laterKept, item], attempts: attempts) { cardID, deckID in
            #expect(deckID == "carddeck-src-1")
            return cardID == card.cardID ? row(editedFront: "My own question?") : nil
        }
        #expect(due.map(\.cardID) == [card.cardID, later.cardID])
        #expect(due.first?.wording == "My own question?")
        #expect(due.first?.quote == quote)
        #expect(due.first?.sourceID == "src-1")
    }

    // MARK: The row

    @Test("A card's rewordings and the day they were made ride its row, read back as written, once")
    func rowRoundTrip() throws {
        let made = Date(timeIntervalSince1970: 1_790_000_000)
        var deck = MemoryCardDeckState(cards: ["card-a": row(variants: [firstVariant], variedAt: made)])
        let read = try #require(MemoryCardDeckState(preferenceValue: deck.preferenceValue))
        #expect(read == deck)
        #expect(read.cards["card-a"]?.variedAt == made)

        // The pass writes a card's rewordings once, kept, with the day.
        CardVariationPass.apply([
            CardVariationWrite(cardID: "card-a", itemID: "item-a", variants: [secondVariant]),
            CardVariationWrite(cardID: "card-b", itemID: "item-b", variants: []),
        ], to: &deck, at: made.addingTimeInterval(day))
        #expect(deck.cards["card-a"]?.variants == [firstVariant], "another Mac's rewordings got there first")
        let fresh = try #require(deck.cards["card-b"])
        #expect(fresh.status == .kept)
        #expect(fresh.memoryItemID == "item-b")
        #expect(fresh.variants.isEmpty)
        #expect(fresh.variedAt == made.addingTimeInterval(day), "reworded with nothing kept: not reworded again")
    }

    // MARK: The sitting

    @Test("This asks something else, and Always ask it this way, put the card on screen back in its own words with its answer hidden")
    func sittingInOwnWords() {
        var sitting = MemoryCardSitting(key: "cards-test", kind: .today, cards: [
            .init(
                itemID: "item-a", prompt: firstVariant, front: front, cardID: "card-a", deckID: "carddeck-src-1",
                back: back, isVariant: true, isFirstVariedServe: true, variantIndex: 0
            ),
            .init(itemID: "item-b", prompt: secondVariant, front: "What is the coupling membrane?", back: "The inner one.", isVariant: true, variantIndex: 1),
        ])
        #expect(sitting.current?.variantIndex == 0)
        sitting.showAnswer(attempt: "An answer")
        sitting.askCurrentInOwnWords()
        #expect(sitting.current?.prompt == front)
        #expect(sitting.current?.isVariant == false)
        #expect(sitting.current?.isFirstVariedServe == false)
        #expect(sitting.current?.variantIndex == nil)
        #expect(!sitting.isAnswerShown, "it is answered in its own words, from the start")

        sitting.setCurrentAlwaysAsk(true)
        #expect(sitting.current?.alwaysAsk == true)
        sitting.setCurrentAlwaysAsk(false)
        #expect(sitting.current?.alwaysAsk == false)
        #expect(sitting.current?.prompt == front)

        sitting.showAnswer(attempt: "An answer")
        _ = sitting.answer(remembered: true)
        #expect(sitting.current?.itemID == "item-b")
        sitting.setCurrentAlwaysAsk(true)
        #expect(sitting.current?.prompt == "What is the coupling membrane?", "on, a card asked in a rewording is asked in its own words at once")
        #expect(sitting.current?.alwaysAsk == true)

        // A card that is no variant has no index, whatever it was given.
        let plain = MemoryCardSitting.Card(itemID: "item-c", prompt: front, back: back, variantIndex: 2)
        #expect(plain.variantIndex == nil)
        #expect(plain.front == front)
        #expect(plain.cardID == "item-c")
    }

    @Test("A dealt card carries what its wording menu needs: its own words, its row's place, its switch")
    func dealtCard() throws {
        let (card, item) = try keptCard()
        let attempts = [graded("a", on: item.id, onDay: 1), graded("b", on: item.id, onDay: 3)]
        let entry = MemoryCardQueue.Entry(
            item: item, schedule: MemoryTutorScheduler.schedule(item: item, attempts: attempts),
            bucket: .due, notebookID: nil, daysOverdue: 0
        )
        let varied = try #require(MemoryCardSitting.Card.dealt(entry, attempts: attempts) { _ in row(variants: [firstVariant]) })
        #expect(varied.prompt == firstVariant)
        #expect(varied.front == front)
        #expect(varied.cardID == card.cardID)
        #expect(varied.deckID == "carddeck-src-1")
        #expect(varied.variantIndex == 0)
        #expect(varied.isFirstVariedServe)
        #expect(!varied.alwaysAsk)
        #expect(!varied.isFromBeforeCards)
        let held = try #require(MemoryCardSitting.Card.dealt(entry, attempts: attempts) { _ in row(variants: [firstVariant], alwaysAsk: true) })
        #expect(held.prompt == front)
        #expect(held.alwaysAsk)
    }

    @Test("Always ask it this way is written in the card's row; an item from before cards with no row still waits in To Check")
    @MainActor
    func alwaysAskRow() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = MemoryCardStateStore.update(deckID: "carddeck-src-1", defaults: defaults) { deck in
            deck.cards["card-a"] = row(variants: [firstVariant])
        }
        #expect(kept.cards["card-a"]?.alwaysAsk == false)
        let on = MemoryCardStateStore.setAlwaysAsk(
            true, cardID: "card-a", memoryItemID: "item-a", deckID: "carddeck-src-1",
            isFromBeforeCards: false, at: keptAt.addingTimeInterval(day), defaults: defaults
        )
        #expect(on.cards["card-a"]?.alwaysAsk == true)
        #expect(on.cards["card-a"]?.variants == [firstVariant], "its rewordings are kept for when it may vary again")
        #expect(on.cards["card-a"]?.updatedAt == keptAt.addingTimeInterval(day))
        let off = MemoryCardStateStore.setAlwaysAsk(
            false, cardID: "card-a", memoryItemID: "item-a", deckID: "carddeck-src-1",
            isFromBeforeCards: false, at: keptAt.addingTimeInterval(2 * day), defaults: defaults
        )
        #expect(off.cards["card-a"]?.alwaysAsk == false)

        let legacy = MemoryCardStateStore.setAlwaysAsk(
            true, cardID: "legacy-1", memoryItemID: "legacy-1", deckID: "carddeck-src-1",
            isFromBeforeCards: true, defaults: defaults
        )
        #expect(legacy.cards["legacy-1"]?.status == .draft)
        #expect(legacy.cards["legacy-1"]?.alwaysAsk == true)
        #expect(MemoryCardStateStore.state(cardID: "legacy-1", deckID: "carddeck-src-1", defaults: defaults)?.alwaysAsk == true)
    }
}

// MARK: - Over storage

@Suite("Memory cards: variations at the day close")
struct CardVariationPassTests {
    @Test("This asks something else is a failed attempt, once a sitting, that moves no schedule and takes the rewording out on every device")
    func askedSomethingElse() async throws {
        let (storage, card, item, cleanup) = try await storageWithEarnedCard()
        defer { cleanup() }
        let before = try #require(try await storage.loadMemorySchedule(memoryItemID: item.id))
        let at = keptAt.addingTimeInterval(10 * day)
        let written = try await storage.recordMemoryCardAskedSomethingElse(
            memoryItemID: item.id, prompt: "  \(firstVariant) ", variantIndex: 0, sessionKey: "cards-1", at: at
        )
        #expect(written)
        let again = try await storage.recordMemoryCardAskedSomethingElse(
            memoryItemID: item.id, prompt: firstVariant, variantIndex: 0, sessionKey: "cards-1", at: at
        )
        #expect(!again, "once a sitting")
        // No schedule moves: the card is as due, as stable and as practised.
        let after = try #require(try await storage.loadMemorySchedule(memoryItemID: item.id))
        #expect(after.dueAt == before.dueAt)
        #expect(after.stability == before.stability)
        #expect(after.difficulty == before.difficulty)
        #expect(after.repetitionCount == before.repetitionCount)
        #expect(after.lapseCount == before.lapseCount)
        #expect(after.lastSuccessAt == before.lastSuccessAt)

        let attempts = try await storage.loadMemoryAttempts(memoryItemID: item.id)
        let said = try #require(attempts.first { $0.gradeState == .failed })
        #expect(said.gradingError == "asked something else")
        #expect(said.evidenceJSON == #"{"variant":0}"#)
        #expect(said.prompt == firstVariant)
        #expect(said.learnerAnswer.isEmpty)
        #expect(said.scheduleRating == nil)
        #expect(said.id == KnowledgeStore.askedSomethingElseAttemptID(sessionKey: "cards-1", memoryItemID: item.id, prompt: firstVariant))
        // Every device reads it off the attempts: the rotation skips it.
        let state = row(variants: [firstVariant, secondVariant])
        #expect(MemoryCardWording.asked(card: card, state: state, attempts: attempts).text == secondVariant)

        await #expect(throws: (any Error).self) {
            try await storage.recordMemoryCardAskedSomethingElse(memoryItemID: item.id, prompt: firstVariant, variantIndex: 0, sessionKey: " ")
        }
        await #expect(throws: (any Error).self) {
            try await storage.recordMemoryCardAskedSomethingElse(memoryItemID: "no-such-item", prompt: firstVariant, variantIndex: 0, sessionKey: "cards-1")
        }
    }

    @Test("The day close rewords a card remembered twice, once: the code's checks, then the judge, and only what passes joins its rotation")
    func rewordsOnce() async throws {
        let (storage, card, _, cleanup) = try await storageWithEarnedCard()
        defer { cleanup() }
        let rows = Rows()
        let backend = CannedVariation(rewordings: [
            CardVariationModelCard(card: 1, variants: [
                firstVariant,
                front,
                "What does a proton gradient across the inner membrane do?",
                secondVariant,
            ]),
        ], verdicts: [
            CardVariationVerdict(card: 1, variant: 1, answersIt: true, leaksAnswer: false),
            CardVariationVerdict(card: 1, variant: 2, answersIt: true, leaksAnswer: true),
        ])
        let now = keptAt.addingTimeInterval(5 * day)
        let report = await pass(storage, backend, rows).run(now: now)
        #expect(report == CardVariationReport(reworded: 1, varied: 1, waiting: 0, failures: []))
        #expect(backend.rewordTurns.count == 1)
        #expect(backend.rewordTurns.first?.contains("1. Question: \(front)") == true)
        #expect(backend.judgeTurns.count == 1)
        #expect(backend.judgeTurns.first?.contains("   1. \(firstVariant)\n   2. \(secondVariant)") == true, "the judge sees only what the code kept")
        let state = try #require(rows.load("carddeck-src-1").cards[card.cardID])
        #expect(state.variants == [firstVariant])
        #expect(state.variedAt == now)
        #expect(state.status == .kept)

        // The next evening: nothing more to reword, nothing spent.
        let again = await pass(storage, backend, rows).run(now: now.addingTimeInterval(day))
        #expect(again == CardVariationReport())
        #expect(backend.rewordTurns.count == 1)
        #expect(backend.judgeTurns.count == 1)
    }

    @Test("No rewording past the code's checks: no judge is asked, and the card is not reworded again")
    func nothingPassesTheChecks() async throws {
        let (storage, card, _, cleanup) = try await storageWithEarnedCard()
        defer { cleanup() }
        let rows = Rows()
        let backend = CannedVariation(rewordings: [CardVariationModelCard(card: 1, variants: [front, "Two\nlines?"])])
        let now = keptAt.addingTimeInterval(5 * day)
        let report = await pass(storage, backend, rows).run(now: now)
        #expect(report.reworded == 1)
        #expect(report.varied == 0)
        #expect(backend.judgeTurns.isEmpty)
        let state = try #require(rows.load("carddeck-src-1").cards[card.cardID])
        #expect(state.variants.isEmpty)
        #expect(state.variedAt == now)
    }

    @Test("A card the model gave no rewordings for waits for another evening")
    func unansweredCardWaits() async throws {
        let (storage, card, _, cleanup) = try await storageWithEarnedCard()
        defer { cleanup() }
        let rows = Rows()
        let backend = CannedVariation(rewordings: [CardVariationModelCard(card: 2, variants: [firstVariant])])
        let report = await pass(storage, backend, rows).run(now: keptAt.addingTimeInterval(5 * day))
        #expect(report.reworded == 0)
        #expect(rows.load("carddeck-src-1").cards[card.cardID] == nil)
    }

    @Test("At the daily background AI limit nothing is sent and the cards wait; with no model the pass says so and sends nothing")
    func gatedOnBackgroundSpend() async throws {
        let (storage, card, _, cleanup) = try await storageWithEarnedCard()
        defer { cleanup() }
        let rows = Rows()
        let backend = CannedVariation(rewordings: [CardVariationModelCard(card: 1, variants: [firstVariant])])
        let capped = await pass(storage, backend, rows, spendAllowed: false).run(now: keptAt.addingTimeInterval(5 * day))
        #expect(capped.waiting == 1)
        #expect(capped.reworded == 0)
        #expect(backend.rewordTurns.isEmpty)
        #expect(rows.load("carddeck-src-1").cards[card.cardID] == nil)

        let unrouted = CannedVariation(route: nil, rewordings: [CardVariationModelCard(card: 1, variants: [firstVariant])])
        let noModel = await pass(storage, unrouted, rows).run(now: keptAt.addingTimeInterval(5 * day))
        #expect(noModel.failures.count == 1)
        #expect(unrouted.rewordTurns.isEmpty)
    }

    @Test("The day close reports the cards it reworded, and the ones the limit left for the next evening")
    func dayCloseReports() async throws {
        let (storage, _, _, cleanup) = try await storageWithEarnedCard()
        defer { cleanup() }
        let now = keptAt.addingTimeInterval(5 * day)
        let rows = Rows()
        let backend = CannedVariation(
            rewordings: [CardVariationModelCard(card: 1, variants: [firstVariant])],
            verdicts: [CardVariationVerdict(card: 1, variant: 1, answersIt: true, leaksAnswer: false)]
        )
        let capped = DayClosePass(storage: storage, aiService: AIService(), spendAllowed: { false }, variations: pass(storage, backend, rows, spendAllowed: false))
        let waiting = await capped.consolidate(now: now, closeConfig: nil)
        #expect(waiting.rewordedCards == 0)
        #expect(waiting.notes == ["1 card waits to be reworded: today's background AI limit is reached."])
        #expect(waiting.failures.isEmpty, "\(waiting.failures)")
        #expect(backend.rewordTurns.isEmpty)

        let open = DayClosePass(storage: storage, aiService: AIService(), spendAllowed: { true }, variations: pass(storage, backend, rows))
        let done = await open.consolidate(now: now.addingTimeInterval(60), closeConfig: nil)
        #expect(done.rewordedCards == 1)
        #expect(done.variedCards == 1)
        #expect(done.notes.isEmpty)
        #expect(!done.isEmpty)
    }
}
