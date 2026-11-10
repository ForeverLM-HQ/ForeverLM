import Foundation
import Testing
@testable import ForeverLM

// Memory as cards, stage five: variations. A kept card's rewordings join its
// rotation in its `cards.state.<deckID>` row. The rotation never asks the
// wording asked last; "Always ask it this way" turns it off; "This asks
// something else" is a failed attempt that retires the rewording; a
// rewording missed more often than the card's own words over three uses
// retires itself. The rules are pure and pinned first; the one test that
// writes rows through the state store uses a defaults suite of its own.

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

    // MARK: The row

    // MARK: The row

    @Test("A card's rewordings and the day they were made ride its row, read back as written, once")
    func rowRoundTrip() throws {
        let made = Date(timeIntervalSince1970: 1_790_000_000)
        let deck = MemoryCardDeckState(cards: ["card-a": row(variants: [firstVariant], variedAt: made)])
        let read = try #require(MemoryCardDeckState(preferenceValue: deck.preferenceValue))
        #expect(read == deck)
        #expect(read.cards["card-a"]?.variedAt == made)
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
        let held = try #require(MemoryCardSitting.Card.dealt(entry, attempts: attempts) { _ in row(variants: [firstVariant], alwaysAsk: true) })
        #expect(held.prompt == front)
        #expect(held.alwaysAsk)
    }

    @Test("Always ask it this way is written in the card's row")
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
            at: keptAt.addingTimeInterval(day), defaults: defaults
        )
        #expect(on.cards["card-a"]?.alwaysAsk == true)
        #expect(on.cards["card-a"]?.variants == [firstVariant], "its rewordings are kept for when it may vary again")
        #expect(on.cards["card-a"]?.updatedAt == keptAt.addingTimeInterval(day))
        let off = MemoryCardStateStore.setAlwaysAsk(
            false, cardID: "card-a", memoryItemID: "item-a", deckID: "carddeck-src-1",
            at: keptAt.addingTimeInterval(2 * day), defaults: defaults
        )
        #expect(off.cards["card-a"]?.alwaysAsk == false)
    }
}

// MARK: - Over storage

@Suite("Memory cards: asking something else")
struct CardAskedSomethingElseTests {
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
}
