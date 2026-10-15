import Foundation
import Testing
@testable import ForeverLM

/// A card stands on every source that prints it (docs/memory-design.md, "Cards
/// stand on every source that prints them"): a draft carries the other sources'
/// passages beside its own, the deck's Markdown and the Card's draft keep them,
/// Keep anchors the item on all of them, and finding them is a retrieval whose
/// picks are checked against the passages before anything is saved.
@Suite("Memory cards: several sources")
struct CardSourceLinksTests {
    private static let talk = "In the talk, Zara Holt showed that stomach cells given extra ion channels reproduce the electric face pattern and grow extra eyes."
    private static let paper = "Induced bioelectric prepatterns in endodermal cells were sufficient to produce ectopic eyes in frog embryos, which wired to the brain through optic nerves."

    // MARK: The links

    @Test("Links are one passage per source, in order, never the card's own and never empty")
    func normalizedLinks() {
        let own = CardSourceLink(sourceID: "talk", quote: "extra ion channels")
        let links = CardSourceLink.normalized([
            CardSourceLink(sourceID: "paper", quote: "  ectopic eyes  "),
            own,
            CardSourceLink(sourceID: "paper", quote: "ectopic eyes"),
            CardSourceLink(sourceID: "", quote: "no source"),
            CardSourceLink(sourceID: "review", quote: ""),
            CardSourceLink(sourceID: "review", quote: "a second look"),
        ], excluding: own)
        #expect(links == [
            CardSourceLink(sourceID: "paper", quote: "ectopic eyes"),
            CardSourceLink(sourceID: "review", quote: "a second look"),
        ])
        let many = (0..<9).map { CardSourceLink(sourceID: "s\($0)", quote: "q") }
        #expect(CardSourceLink.normalized(many).count == MemoryCard.maximumLinkedSources)
    }

    @Test("A deck writes a card's other sources as more Source lines and reads them back whole")
    func deckMarkdownRoundTrip() {
        let card = Flashcard.mint(
            front: "What did Holt's team do to induce extra eyes in frog embryos?",
            back: "They gave stomach cells extra ion channels.",
            sourceID: "talk",
            sourceTitle: "Persuading the Body to Regenerate Its Limbs",
            quote: "extra ion channels reproduce the electric face pattern",
            origin: .drafted,
            isRequested: false,
            alsoFrom: [
                CardSourceLink(sourceID: "paper", quote: "sufficient to produce ectopic eyes in frog embryos"),
                CardSourceLink(sourceID: "talk", quote: "extra ion channels reproduce the electric face pattern"),
            ],
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        // A passage of the card's own source it already quotes is no second source.
        #expect(card.alsoFrom == [CardSourceLink(sourceID: "paper", quote: "sufficient to produce ectopic eyes in frog embryos")])
        let markdown = FlashcardDeck(title: "Cards", cards: [card]).markdown
        #expect(markdown.components(separatedBy: "Source: [").count == 3)
        let parsed = FlashcardDeck.parse(markdown, fallbackTitle: "Cards")
        #expect(parsed.cards == [card])
        #expect(FlashcardDeck.readBack(card) == card)

        // A card with no source of its own stands on none.
        let loose = Flashcard(id: "loose", front: "Q", back: "A", alsoFrom: [CardSourceLink(sourceID: "paper", quote: "x")]).asWritten
        #expect(loose.alsoFrom.isEmpty)
    }

    @Test("A card to check lists every source it stands on, its own first")
    func cardToCheckSources() {
        let card = Flashcard(
            id: "card-1", front: "Q?", back: "A.", sourceID: "talk", quote: "own passage", draftedAt: Date(),
            alsoFrom: [CardSourceLink(sourceID: "paper", quote: "paper passage"), CardSourceLink(sourceID: "talk", quote: "later passage")]
        )
        let deck = MemoryCardDraftDeck(deckID: MemoryCard.draftDeckID(sourceID: "talk"), sourceID: "talk", deck: FlashcardDeck(title: "", cards: [card]))
        let waiting = MemoryCardTriage.toCheck(
            decks: [deck], deckStates: [:], itemIDs: [], legacyItems: [], attemptsByItemID: [:], now: Date()
        )
        #expect(waiting.count == 1)
        #expect(waiting[0].sourceIDs == ["talk", "paper"])
        #expect(waiting[0].links == [
            CardSourceLink(sourceID: "talk", quote: "own passage"),
            CardSourceLink(sourceID: "paper", quote: "paper passage"),
            CardSourceLink(sourceID: "talk", quote: "later passage"),
        ])
        #expect(MemoryCardSitting.Card.draft(waiting[0])?.links == waiting[0].links)
    }

    // MARK: Finding them

    @Test("The judging turn numbers the cards and their passages, and leaves out a card with none")
    func linkingTurn() {
        let candidates = [
            [CardSourceCandidate(sourceID: "paper", title: "Bioelectric Eyes", passage: Self.paper)],
            [],
        ]
        let message = CardSourceLinking.message(
            cards: [(front: "What induced extra eyes?", back: "Extra ion channels."), (front: "Other?", back: "None.")],
            candidates: candidates
        )
        #expect(message.contains("Card 1\nQuestion: What induced extra eyes?\nAnswer: Extra ion channels.\nPassage 1 (from Bioelectric Eyes): \(Self.paper)"))
        #expect(!message.contains("Card 2"))
    }

    @Test("A pick becomes a link only when its passage prints the quote, once for each source")
    func picksAreChecked() throws {
        let candidates = [[
            CardSourceCandidate(sourceID: "paper", title: "Bioelectric Eyes", passage: Self.paper),
            CardSourceCandidate(sourceID: "talk-2", title: "Second Talk", passage: Self.talk),
            CardSourceCandidate(sourceID: "paper", title: "Bioelectric Eyes", passage: Self.paper),
        ], [
            CardSourceCandidate(sourceID: "talk-2", title: "Second Talk", passage: Self.talk),
        ]]
        let answer: CardSourceLinkingAnswer = try MemoryReviewPlanning.decodeJSON("""
        {"cards": [
          {"card": 1, "links": [
            {"candidate": 1, "quote": "sufficient to produce ectopic eyes in frog embryos"},
            {"candidate": 2, "quote": "words the second talk never says"},
            {"candidate": 3, "quote": "which wired to the brain through optic nerves"},
            {"candidate": 9, "quote": "ectopic eyes"}
          ]},
          {"card": 2}
        ]}
        """)
        let links = CardSourceLinking.links(from: answer.cards, cardCount: 2, candidates: candidates)
        #expect(links[0] == [CardSourceLink(sourceID: "paper", quote: "sufficient to produce ectopic eyes in frog embryos")])
        #expect(links[1].isEmpty)
    }

    // MARK: Saving and keeping

    private func makeStorage() async throws -> (StorageService, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CardSourceLinks_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(storeRoot: root)
        for (id, title, text) in [("talk", "Persuading the Body to Regenerate Its Limbs", Self.talk), ("paper", "Bioelectric Eyes", Self.paper)] {
            var source = StudioArticle(url: "https://example.org/\(id)", title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
            source.normalizedURL = URLNormalizer.normalize(source.url)
            source.content = text
            source.state = .ready
            try await storage.saveSource(source)
        }
        return (storage, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("Drafts are saved with the other sources whose text prints their quotes, and the rest are reported")
    func savingGroundsEveryLink() async throws {
        let (storage, cleanup) = try await makeStorage()
        defer { cleanup() }
        let draft = Flashcard.mint(
            front: "What did Holt's team do to induce extra eyes in frog embryos?",
            back: "They gave stomach cells extra ion channels.",
            sourceID: "talk",
            sourceTitle: "Persuading the Body to Regenerate Its Limbs",
            quote: "stomach cells given extra ion channels reproduce the electric face pattern",
            origin: .drafted,
            isRequested: false,
            alsoFrom: [
                CardSourceLink(sourceID: "paper", quote: "sufficient to produce ectopic eyes in frog embryos"),
                CardSourceLink(sourceID: "paper", quote: "a sentence the paper never prints"),
                CardSourceLink(sourceID: "gone", quote: "no such source"),
            ],
            at: Date()
        )
        let saved = try await storage.saveCardDrafts([draft], sourceID: "talk", sourceTitle: "Persuading the Body to Regenerate Its Limbs")
        #expect(saved.added.count == 1)
        #expect(saved.added[0].alsoFrom == [CardSourceLink(sourceID: "paper", quote: "sufficient to produce ectopic eyes in frog embryos")])
        #expect(saved.ungroundedLinks.count == 2)
        #expect(Set(saved.ungroundedLinks.map(\.link.sourceID)) == ["paper", "gone"])

        let decks = try await storage.loadCardDrafts()
        #expect(decks.first?.deck.cards.first?.alsoFrom == saved.added[0].alsoFrom)
    }

    @Test("Keep anchors the card on every source it stands on, its own first, and refuses a passage a source does not print")
    func keepAnchorsOnEverySource() async throws {
        let (storage, cleanup) = try await makeStorage()
        defer { cleanup() }
        let card = MemoryCard(
            cardID: "card-eyes", front: "What did Holt's team do to induce extra eyes in frog embryos?",
            back: "They gave stomach cells extra ion channels.", origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "talk")
        )
        // A link the second source does not print keeps nothing: the keep below makes the item.
        await #expect(throws: (any Error).self) {
            try await storage.keepMemoryCard(
                card, sourceID: "talk", quote: "extra ion channels reproduce the electric face pattern",
                alsoFrom: [CardSourceLink(sourceID: "paper", quote: "a sentence the paper never prints")]
            )
        }

        let item = try await storage.keepMemoryCard(
            card, sourceID: "talk", quote: "extra ion channels reproduce the electric face pattern",
            alsoFrom: [
                CardSourceLink(sourceID: "paper", quote: "ectopic eyes in frog embryos"),
                CardSourceLink(sourceID: "talk", quote: "extra ion channels reproduce the electric face pattern"),
            ]
        )
        let anchors = item.sources.sorted { $0.sortIndex < $1.sortIndex }
        #expect(anchors.map(\.sourceID) == ["talk", "paper"])
        #expect(anchors.map(\.excerpt) == ["extra ion channels reproduce the electric face pattern", "ectopic eyes in frog embryos"])

        let listing = try #require(MemoryCardListing(item: item, attempts: []))
        #expect(listing.sourceIDs == ["talk", "paper"])
        #expect(listing.links.map(\.sourceID) == ["talk", "paper"])
    }
}
