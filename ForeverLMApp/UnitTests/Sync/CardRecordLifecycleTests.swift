import Foundation
import Testing
@testable import ForeverLM

/// The Mac's card lifecycle on generation 2's Card records (docs/memory-design.md, "Cards on the Mac under
/// generation 2"; docs/cloudkit-schema-design.md §3.5.22): a draft is a Card with status `draft`; To Check,
/// Keep, Edit, Skip, All Cards' menu and the card review's "This asks something else" read and write the
/// Card rows the phone and the web read and write; and the activation carries a deck's drafts and its
/// `cards.state.*` row into those rows once.
@Suite("Card records lifecycle")
struct CardRecordLifecycleTests {
    private typealias F = MemorySyncFixture

    private static let text = "Mitochondria couple respiration to ATP synthesis through a proton gradient. "
        + "Uncoupling proteins let protons leak back without making ATP. Complex I pumps protons across the membrane."
    private static let quote = "couple respiration to ATP synthesis through a proton gradient"
    private static let draftedAt = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate - 3_600).rounded(.down))
    private static let now = draftedAt.addingTimeInterval(60)
    private static let deckID = "carddeck-src-1"

    private static func draft(
        _ front: String = "What couples respiration to ATP synthesis?",
        seed: String? = "walk-step:step-2",
        requested: Bool = false,
        ideaID: String? = nil,
        id: String = UUID().uuidString.lowercased()
    ) -> Flashcard {
        Flashcard.mint(
            front: front, back: "A proton gradient across the inner membrane.", why: "Uncoupling breaks the link and ATP synthesis stops.",
            sourceID: "src-1", sourceTitle: "Mitochondria", quote: quote, seed: seed, ideaID: ideaID,
            origin: .drafted, isRequested: requested, at: draftedAt, id: id
        )
    }

    /// A generation-2 store holding src-1 with its text, and storage over it: activated (triggers in place,
    /// a clock) or, for the activation's own test, not yet.
    private static func makeStorage(_ name: String, activated: Bool = true) async throws -> (root: URL, store: KnowledgeStore, storage: StorageService) {
        let (root, store) = try F.makeStore(name, triggers: activated, activated: activated)
        let storage = StorageService(storeRoot: root)
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = text
        source.wordCount = 24
        source.state = .ready
        try await storage.saveSource(source)
        return (root, store, storage)
    }

    private static func toCheck(_ storage: StorageService) async throws -> [MemoryCardToCheck] {
        try await storage.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: nil, includesListings: false, includesToCheck: true
        ).toCheck
    }

    private static func row(_ store: KnowledgeStore, _ id: String, _ columns: String = "status") throws -> String? {
        try F.text(store, "SELECT \(columns) FROM memory_card_states WHERE card_id = ?", [.text(id)])
    }

    private static let seeded = SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "walk-step:step-2")

    // MARK: Drafting

    @Test("A draft is a draft Card: saved under its seed's Card id with its wording, read back as its source's deck, and sent")
    func draftsAreCards() async throws {
        let (root, store, storage) = try await Self.makeStorage("drafts")
        defer { try? FileManager.default.removeItem(at: root) }
        let given = Self.draft(id: "minted-1")
        let unseeded = Self.draft("Which proteins let protons leak back?", seed: nil, requested: true, ideaID: "idea-7", id: "card-u")
        let saved = try await storage.saveCardDrafts([given, unseeded], sourceID: "src-1", sourceTitle: "Mitochondria")
        #expect(saved.added.map(\.id) == [Self.seeded, "card-u"])
        #expect(saved.givenID(of: saved.added[0]) == "minted-1", "the caller still finds the draft it made")

        #expect(try Self.row(store, Self.seeded, "status || '|' || deck_source_id || '|' || origin || '|' || seed_key")
                == "draft|src-1|walkthrough|walk-step:step-2")
        #expect(try store.loadArtifact(Self.deckID) == nil, "no deck Artifact under generation 2")
        let fields = try #require(F.fields(try F.pending(store)["Card:\(Self.seeded)"]))
        #expect(fields["status"] == "draft" && fields["deckSourceID"] == "src-1" && fields["seedKey"] == "walk-step:step-2")
        #expect(fields["draft"]?["front"] == "What couples respiration to ATP synthesis?")
        #expect(fields["draft"]?["anchors"]?.arrayValue?.first?["excerpt"] == .string(Self.quote))
        #expect(fields["draft"]?["anchors"]?.arrayValue?.first?["target"] == "src:src-1")
        #expect(fields["draftedAt"] == SyncJSON(SyncTime.milliseconds(Self.draftedAt)))

        // The draft's rubric is the one its Keep writes, wherever it is kept (the phone's `draftFace`).
        let rubric = try #require(fields["draft"]?["rubric"]?.stringValue)
        let face = try #require(MemoryCard(storedIn: MemoryItem(
            id: Self.seeded, kind: .concept, target: "A proton gradient across the inner membrane.", rubricJSON: rubric, sources: [],
            createdAt: Self.now, updatedAt: Self.now
        )))
        #expect(face.cardID == Self.seeded && face.deckID == Self.deckID)
        #expect(face.why == ["Uncoupling breaks the link and ATP synthesis stops."] && face.origin == .drafted)

        let deck = try #require(try await storage.loadCardDrafts().first)
        #expect(deck.deckID == Self.deckID)
        let read = try #require(deck.deck.cards.first { $0.id == "card-u" })
        #expect(read.isRequested && read.ideaID == "idea-7" && read.why == "Uncoupling breaks the link and ATP synthesis stops.")
        #expect(read.draftedAt == Self.draftedAt && read.quote == Self.quote && read.seed == nil)
        #expect(Set(try await Self.toCheck(storage).map(\.cardID)) == [Self.seeded, "card-u"])

        // Drafted again: the deck holds the seed and the front, so nothing is written.
        let again = try await storage.saveCardDrafts([Self.draft(id: "minted-2")], sourceID: "src-1", sourceTitle: "Mitochondria")
        #expect(again.added.isEmpty && again.alreadyDrafted.count == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_card_states") == 2)

        // A notebook's Make Cards runs read the same Cards: the requested one is a run.
        let runs = NotebookOutputs.cardRuns(try await storage.loadCardDrafts(forSourceIDs: ["src-1"]), memberSourceIDs: ["src-1"])
        #expect(runs.map(\.cardCount) == [1] && runs.first?.draftedAt == Self.draftedAt)
    }

    @Test("A draft the learner never went through holds its seed however long it waits: the same seed is not drafted again")
    func oldDraftHoldsItsSeed() async throws {
        let (root, store, storage) = try await Self.makeStorage("old-draft")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await storage.saveCardDrafts([Self.draft(id: "old")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let again = try await storage.saveCardDrafts([Self.draft("Couples what to what?", id: "fresh")], sourceID: "src-1", sourceTitle: "Mitochondria")
        #expect(again.added.isEmpty && again.alreadyDrafted.map(\.id) == ["fresh"])
        #expect(try Self.row(store, Self.seeded, "draft_json") != nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_card_states WHERE status = 'draft'") == 1)
    }

    // MARK: Going through them, both ways

    @Test("Keep and Skip write the Card the phone reads, and the phone's Skip and Always Ask reach the Mac's To Check and card states")
    func keepAndSkipBothWays() async throws {
        let (root, store, storage) = try await Self.makeStorage("triage")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await storage.saveCardDrafts([
            Self.draft(id: "a"), Self.draft("Which proteins let protons leak back?", seed: "idea:leak", id: "b"),
            Self.draft("What does Complex I pump?", seed: "highlight:h-1", id: "c"),
        ], sourceID: "src-1", sourceTitle: "Mitochondria")
        let records = MemoryCardStateStore.Records(storage: storage)
        try await MemoryCardStateStore.$bound.withValue(records) {
            let cards = try await Self.toCheck(storage)
            let keep = try #require(cards.first { $0.cardID == Self.seeded })
            let skip = try #require(cards.first { $0.seed == "idea:leak" })
            let result = await MemoryCardTriageWriter.apply(
                [MemoryCardTriageDecision(card: keep, action: .keep), MemoryCardTriageDecision(card: skip, action: .skip)],
                storage: storage, at: Self.now
            )
            #expect(result.kept == [MemoryCardTriageResult.Kept(cardID: Self.seeded, memoryItemID: Self.seeded)], "the item is the Card's own id")
            #expect(result.failed.isEmpty)

            #expect(try Self.row(store, Self.seeded) == "kept")
            let kept = try #require(F.fields(try F.pending(store)["Card:\(Self.seeded)"]))
            #expect(kept["status"] == "kept" && kept["kept"]?["front"] == "What couples respiration to ATP synthesis?")
            #expect(kept["draft"]?["front"] != nil, "the draft wording stays beside the kept one")
            let skippedID = SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "idea:leak")
            #expect(try Self.row(store, skippedID, "status || '|' || (skipped_at IS NOT NULL)") == "skipped|1")
            #expect(MemoryCardStateStore.state(cardID: Self.seeded, deckID: Self.deckID)?.status == .kept)
            #expect(try await Self.toCheck(storage).map(\.cardID) == [SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "highlight:h-1")])

            // The phone skips the last draft and asks the kept card always in its own words.
            let lastID = SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "highlight:h-1")
            var last = try #require(F.fields(try F.pending(store)["Card:\(lastID)"]))
            last["status"] = "skipped"
            var always = kept
            always["alwaysAsk"] = true
            always["variants"] = ["front": ["text": "Ask it like this", "madeAt": 1_759_000_000_000, "retired": false]]
            try F.sendAll(store)
            try F.apply(store, [try F.record(.card, lastID, last), try F.record(.card, Self.seeded, always)])
            #expect(try await Self.toCheck(storage).isEmpty)
            MemoryCardStateStore.reload()
            await MemoryCardStateStore.settled()
            let state = try #require(MemoryCardStateStore.state(cardID: Self.seeded, deckID: Self.deckID))
            #expect(state.alwaysAsk && state.editedFront == "Ask it like this")
            #expect(MemoryCardStateStore.state(cardID: lastID, deckID: Self.deckID)?.status == .skipped)
        }
    }

    @Test("All Cards' menu and the card review's ⋯ write the Card: a rewording, Always Ask, This Asks Something Else, Start Over and Retire")
    func keptCardMenu() async throws {
        let (root, store, storage) = try await Self.makeStorage("menu")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await storage.saveCardDrafts([Self.draft(id: "a")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let records = MemoryCardStateStore.Records(storage: storage)
        try await MemoryCardStateStore.$bound.withValue(records) {
            let card = try #require(try await Self.toCheck(storage).first)
            _ = await MemoryCardTriageWriter.apply([MemoryCardTriageDecision(card: card, action: .keep)], storage: storage, at: Self.now)
            let item = try #require(try await storage.loadMemoryItem(Self.seeded))
            let listing = try #require(MemoryCardListing(item: item, attempts: []))
            try F.sendAll(store)

            #expect(await MemoryCardEditWriter.reword(listing, front: "What links respiration to ATP?", at: Self.now))
            await MemoryCardStateStore.setAlwaysAsk(true, cardID: listing.face.cardID, memoryItemID: item.id, deckID: Self.deckID, isFromBeforeCards: false)
            await MemoryCardStateStore.settled()
            #expect(try Self.row(store, Self.seeded, "always_ask") == "1")
            let change = try #require(try F.pending(store)["Card:\(Self.seeded)"])
            #expect(F.changed(change).isSuperset(of: ["alwaysAsk"]))
            #expect(F.fields(change)?["variants"]?["front"]?["text"] == "What links respiration to ATP?")

            // A card that was reworded once, then taken out in the card review.
            await MainActor.run {
                _ = MemoryCardStateStore.update(deckID: Self.deckID) { row in
                    var state = row.cards[Self.seeded] ?? MemoryCardState(status: .kept, memoryItemID: item.id, updatedAt: Self.now)
                    state.variedAt = Self.now
                    state.updatedAt = Self.now
                    row.cards[Self.seeded] = state
                }
            }
            await MemoryCardStateStore.settled()
            #expect(MemoryCardStateStore.state(cardID: Self.seeded, deckID: Self.deckID)?.variedAt != nil, "reworded once, even with nothing kept")
            #expect(try await storage.recordMemoryCardAskedSomethingElse(memoryItemID: item.id, prompt: "What ties breathing to ATP?", variantIndex: 0, sessionKey: "sitting-1"))
            let variants = try #require(SittingProjection.json(try Self.row(store, Self.seeded, "variants_json"))?.objectValue)
            #expect(variants[KnowledgeStore.variantKey("What ties breathing to ATP?")]?["retired"] == true)
            #expect(variants[KnowledgeStore.cardVariedVariantKey] != nil)
            let sent = try #require(F.fields(try F.pending(store)["Card:\(Self.seeded)"]))
            #expect(sent["variants"]?[KnowledgeStore.variantKey("What ties breathing to ATP?")]?["retired"] == true, "every device leaves it out")

            // Start over: the old Card retired, its revision a Card that supersedes it.
            let revision = try await MemoryCardEditWriter.startOver(listing, edit: MemoryCardEdit(front: "Q?", back: "The gradient.", why: []), storage: storage, at: Self.now)
            #expect(revision.item.id == revision.cardID)
            #expect(try Self.row(store, Self.seeded) == "retired")
            #expect(try Self.row(store, revision.cardID, "status || '|' || supersedes || '|' || always_ask || '|' || seed_key")
                    == "kept|\(Self.seeded)|1|walk-step:step-2")
            #expect(F.fields(try F.pending(store)["Card:\(revision.cardID)"])?["supersedes"] == .string(Self.seeded))

            try await storage.retireMemoryCard(memoryItemID: revision.item.id)
            #expect(try Self.row(store, revision.cardID) == "retired")
        }
    }

    @Test("An item from before cards stays this Mac's to check when its Card arrives from another device saying kept")
    func legacyItemStaysToCheck() async throws {
        let (root, store) = try F.makeStore("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.item(store, id: "legacy-1", target: "What is an uncoupler? — A protein that lets protons leak.")
        try store.deriveLegacyCardsToCheck()
        #expect(try Self.row(store, "legacy-1", "status || '|' || deck_source_id") == "draft|src-1")
        try F.apply(store, [try F.record(.card, "legacy-1", ["status": "kept", "deckSourceID": "src-1", "origin": "concept", "alwaysAsk": true])])
        #expect(try Self.row(store, "legacy-1", "status || '|' || always_ask") == "draft|1")
        // Its Card says kept everywhere: its item exists.
        #expect(F.fields(try F.pending(store)["Card:legacy-1"])?["status"] == "kept")
    }

    // MARK: The activation

    @Test("The activation carries a deck's drafts and its row's states into the Card rows once, the items from before cards with them")
    func activationCarriesDecks() async throws {
        let (root, _, storage) = try await Self.makeStorage("activation", activated: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await storage.notebookFilesKnowledgeStore()
        let at = Self.draftedAt
        // Generation 1's truth: the deck Artifact, a card kept from it, the deck's row, and items from before cards.
        let saved = try await storage.saveCardDrafts([
            Self.draft("Kept one?", seed: "walk-step:step-1", id: "card-k"),
            Self.draft("Skipped one?", seed: "highlight:h-1", id: "card-s"),
            Self.draft("Still to check?", seed: "walk-step:step-3", id: "card-d"),
            Self.draft("Asked for, no seed?", seed: nil, requested: true, id: "card-u"),
        ], sourceID: "src-1", sourceTitle: "Mitochondria")
        #expect(saved.added.count == 4)
        #expect(try store.loadArtifact(Self.deckID) != nil, "not activated yet: generation 1's deck")
        let face = MemoryCard(
            cardID: "card-k", front: "Kept one?", back: "A proton gradient across the inner membrane.",
            why: ["Uncoupling breaks the link and ATP synthesis stops."], origin: .drafted, deckID: Self.deckID
        )
        let kept = try await storage.keepMemoryCard(face, sourceID: "src-1", quote: Self.quote, at: at)
        #expect(kept.id == MemoryTutorIdentity.cardItemID(cardID: "card-k"))
        for id in ["legacy-1", "legacy-2"] {
            try F.item(store, id: id, target: "What is \(id)? — The answer to \(id).")
        }
        var deck = MemoryCardDeckState()
        deck.cards["card-k"] = MemoryCardState(status: .kept, memoryItemID: kept.id, editedFront: "Ask it this way", variants: ["Rephrased"],
                                              alwaysAsk: true, seed: "walk-step:step-1", variedAt: at, updatedAt: at)
        deck.cards["card-s"] = MemoryCardState(status: .skipped, seed: "highlight:h-1", updatedAt: at)
        deck.cards["legacy-1"] = MemoryCardState(status: .draft, memoryItemID: "legacy-1", alwaysAsk: true, updatedAt: at)
        try F.preference(store, key: MemoryCardDeckState.preferenceKey(deckID: Self.deckID), value: deck.preferenceValue)

        let ids = KnowledgeStore.memoryActivationDerivations.map(\.id)
        #expect(Array(ids.drop { $0 != "cardStates" }) == ["cardStates", "cardDrafts", "legacyCardsToCheck"])
        func derive() throws {
            for derivation in KnowledgeStore.memoryActivationDerivations where ["cardStates", "cardDrafts", "legacyCardsToCheck"].contains(derivation.id) {
                try derivation.run(store)
            }
        }
        try derive()
        let rows = try F.text(store, "SELECT group_concat(card_id || ':' || status || ':' || always_ask || ':' || (draft_json IS NOT NULL), ';') FROM (SELECT * FROM memory_card_states ORDER BY card_id)")
        try derive()
        #expect(try F.text(store, "SELECT group_concat(card_id || ':' || status || ':' || always_ask || ':' || (draft_json IS NOT NULL), ';') FROM (SELECT * FROM memory_card_states ORDER BY card_id)") == rows,
                "run twice, one result")

        #expect(try Self.row(store, kept.id, "status || '|' || always_ask || '|' || (draft_json IS NOT NULL) || '|' || seed_key") == "kept|1|1|walk-step:step-1")
        #expect(try Self.row(store, SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "highlight:h-1")) == "skipped")
        #expect(try Self.row(store, SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "walk-step:step-3")) == "draft")
        #expect(try Self.row(store, "card-u", "status || '|' || json_extract(draft_json, '$.requested')") == "draft|1")
        #expect(try Self.row(store, "legacy-1", "status || '|' || always_ask") == "draft|1")
        #expect(try Self.row(store, "legacy-2") == "draft")

        // Activated: the cards read from the rows as they were.
        try store.execForTesting("INSERT INTO ck_activation (id, activated_at) VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET activated_at = 1")
        let state = try #require(try store.cardRecordStates()[Self.deckID]?.cards["card-k"], "a card kept before goes by its face's id")
        #expect(state.status == .kept && state.memoryItemID == kept.id && state.alwaysAsk)
        #expect(state.editedFront == "Ask it this way" && state.variants == ["Rephrased"])
        #expect(state.variedAt.map(SyncTime.milliseconds) == SyncTime.milliseconds(at), "the day close does not reword it again")
        let waiting = try await Self.toCheck(storage)
        #expect(Set(waiting.filter { $0.kind == .draft }.map(\.cardID)) == [SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "walk-step:step-3"), "card-u"])
        #expect(Set(waiting.filter { $0.kind == .legacy }.map(\.cardID)) == ["legacy-1", "legacy-2"])
    }
}
