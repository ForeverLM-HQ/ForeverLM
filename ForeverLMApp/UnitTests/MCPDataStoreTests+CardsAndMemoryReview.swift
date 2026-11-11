// MCPDataStoreTests: the card tools, the card review over MCP and memory review.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    // MARK: Memory cards: save_card_drafts, list_cards, triage_cards

    /// A store whose card tools keep their state rows in a defaults suite of
    /// their own, so nothing reaches the host's defaults or its sync queue.
    /// A card store over a fresh library. `activated` gives it the shape every Mac's store has once
    /// generation 2's activation ran (what ships): a card to check is a draft Card row in
    /// `memory_card_states`. Without it the store is not activated yet, and drafts go to the source's
    /// draft-deck Artifact, generation 1's shape, which WP30 deletes.
    func makeCardStore(activated: Bool = false) throws -> (store: MCPDataStore, dbPath: String, defaults: UserDefaults, cleanup: () -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_cards_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = activated
            ? MCPDataStore(dbPath: dbPath, cardStateDefaults: defaults)
            : MCPDataStore(dbPath: dbPath, cardStateDefaults: defaults)
        let knowledge = try store.knowledgeStore()
        if activated {
            try knowledge.execForTesting("INSERT INTO ck_activation (id, activated_at) VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET activated_at = 1")
            #expect(try knowledge.recordsMemoryForGeneration2())
        }
        return (store, dbPath, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tmpDir)
        })
    }

    private static let cardSourceText = "Retrieval practice strengthens later access more than passive rereading. Spacing the practice helps too."

    @Test("The card tools are registered: list_cards only reads, triage_cards can drop cards for good, and a study chat saves drafts")
    func cardToolsAreRegistered() {
        let names = Set(MCPToolRegistry(store: MCPDataStore()).tools.map(\.name))
        #expect(names.isSuperset(of: ["save_card_drafts", "list_cards", "triage_cards"]))
        #expect(MCPToolRegistry.annotations(for: "list_cards")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "triage_cards")["destructiveHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "save_card_drafts")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "save_card_drafts")["destructiveHint"] as? Bool == false)
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("save_card_drafts"))
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("save_card_drafts"), "drafts an assistant wrote cost nothing to save")
    }

    @Test("save_card_drafts saves grounded cards, free, to wait in To Check, refuses an unknown source, and the deck is never a Doc")
    func saveCardDraftsTool() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)

        let payload = try parseJSON(try await store.saveCardDrafts(cards: [
            [
                "source_id": "source-cards",
                "front": "What strengthens later access more than rereading?",
                "back": "Retrieval practice.",
                "why": "Recalling is itself practice.",
                "quote": "Retrieval practice strengthens later access",
                "seed": "guide:q1",
                "back_images": [
                    "![Retrieval curve](foreverlm://image/source-cards/page/2)",
                    ["target": "foreverlm://image/source-cards/page/3", "alt": "Spacing comparison"],
                ],
            ],
            ["source_id": "source-cards", "front": "What does rereading feel like?", "back": "Familiar.", "quote": "words the source never printed"],
            ["source_id": "source-cards", "front": "A card without an answer?", "quote": "Spacing the practice helps too"],
        ], keptByDefault: true))
        #expect(payload["saved_count"] as? Int == 1)
        let entry = try #require((payload["sources"] as? [[String: Any]])?.first)
        #expect(entry["source_id"] as? String == "source-cards")
        #expect((entry["saved_card_ids"] as? [String])?.count == 1)
        #expect((entry["not_grounded"] as? [[String: Any]])?.first?["front"] as? String == "What does rereading feel like?")
        #expect((payload["incomplete"] as? [[String: Any]])?.first?["missing"] as? [String] == ["back"])

        // It waits in To Check, kept by default since the learner asked for it.
        let listed = try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil))
        let card = try #require((listed["to_check"] as? [[String: Any]])?.first)
        #expect(card["kind"] as? String == "draft")
        #expect(card["kept_by_default"] as? Bool == true)
        #expect(card["origin"] as? String == MemoryCardOrigin.assistant.rawValue)
        #expect(card["seed"] as? String == "guide:q1")
        #expect(card["source_title"] as? String == "Retrieval practice")
        #expect(card["expires_at"] == nil, "a draft never expires")
        let backImages = try #require(card["back_images"] as? [[String: Any]])
        #expect(backImages.compactMap { $0["alt"] as? String } == ["Retrieval curve", "Spacing comparison"])
        #expect(MemoryCardStateStore.load(deckID: MemoryCard.draftDeckID(sourceID: "source-cards"), defaults: defaults).cards.isEmpty, "saving writes no state row")

        // An id the library does not hold refuses the whole call and names list_sources.
        do {
            _ = try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "Q?", "back": "A.", "quote": "Spacing the practice helps too"],
                ["source_id": "no-such-source", "front": "Q?", "back": "A.", "quote": "x"],
            ], keptByDefault: false)
            Issue.record("An unknown source id was accepted")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_sources"))
            #expect(error.localizedDescription.contains("no-such-source"))
        }
        #expect((try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil)))["to_check_count"] as? Int == 1)

        // The deck is the learner's own memory state and no Doc: list_docs
        // never lists it, and every Doc tool refuses its id.
        let docs = try parseJSON(try await store.listArtifacts(notebookID: nil))
        #expect((docs["docs"] as? [[String: Any]])?.isEmpty == true)
        let registry = MCPToolRegistry(store: store)
        for (tool, arguments) in [
            ("read_doc", ["doc_id": MemoryCard.draftDeckID(sourceID: "source-cards")]),
            ("delete_doc", ["doc_id": MemoryCard.draftDeckID(sourceID: "source-cards")]),
        ] as [(String, [String: Any])] {
            let outcome = await registry.callToolDetailed(name: tool, arguments: arguments)
            #expect(outcome.isError, "\(tool) answered \(outcome.text)")
            #expect(outcome.text.contains("list_cards"), "\(tool) answered \(outcome.text)")
        }
        #expect(try store.knowledgeStore().loadArtifact(MemoryCard.draftDeckID(sourceID: "source-cards")) != nil)
    }

    @Test("update_card puts pictures on a card still to check, with no Memory pane open, and leaves its words alone")
    func updateCardPicturesOnCardToCheck() async throws {
        // The pictures are written onto the draft Card (`setCardDraftPictures`), generation 2's
        // card to check, so the store is activated as every shipping Mac's is.
        let (store, dbPath, _, cleanup) = try makeCardStore(activated: true)
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "What strengthens later access?", "back": "Retrieval practice.",
             "quote": "Retrieval practice strengthens later access",
             "back_images": ["![Curve](foreverlm://image/source-cards/page/4)"]],
        ], keptByDefault: false)
        let listed = try parseJSON(try await store.listCards(status: "to_check", notebookID: nil, sourceID: nil, limit: nil))
        let draftID = try #require((listed["to_check"] as? [[String: Any]])?.first?["card_id"] as? String)

        let payload = try parseJSON(try await store.updateCard(
            cardID: draftID, itemID: nil, front: nil, back: nil, why: nil,
            frontImages: nil,
            backImages: [
                "![Curve](foreverlm://image/source-cards/page/4)",
                "![Fig. 1](foreverlm://image/source-cards/page/2?crop=0.06,0.11,0.88,0.28)",
            ],
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(payload["held"] as? Bool == true)

        let after = try parseJSON(try await store.listCards(status: "to_check", notebookID: nil, sourceID: nil, limit: nil))
        let card = try #require((after["to_check"] as? [[String: Any]])?.first)
        #expect(card["card_id"] as? String == draftID)
        #expect(card["front"] as? String == "What strengthens later access?")
        let images = try #require(card["back_images"] as? [[String: Any]])
        #expect(images.count == 2)
        #expect(images.last?["alt"] as? String == "Fig. 1")
        #expect(try store.knowledgeStore().loadMemoryItem(MemoryTutorIdentity.cardItemID(cardID: draftID)) == nil, "the card is still a draft")

        // Its words still go through triage_cards, not here.
        do {
            _ = try await store.updateCard(
                cardID: draftID, itemID: nil, front: "Reworded?", back: nil, why: nil,
                backImages: ["![Curve](foreverlm://image/source-cards/page/4)"],
                startOver: nil, alwaysAsk: nil, retire: nil
            )
            Issue.record("update_card reworded a card still to check")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("triage_cards"))
        }
    }

    @Test("A card's face takes one saved animation beside its pictures, by its address, and only one the library holds")
    func cardFaceTakesAnAnimation() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let saved = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "Spacing curve", description: "How spaced practice flattens forgetting.",
            html: "<!doctype html><title>Spacing curve</title><button id=\"play\">Play</button><script>1</script>",
            files: nil, sources: [], homeNotebookID: nil, notebookIDs: []
        ))
        let animationID = try #require(saved["animation_id"] as? String)
        let address = "foreverlm-site://\(animationID)/"
        func draft(front: String, backImages: [Any]) -> [String: Any] {
            ["source_id": "source-cards", "front": front, "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access", "back_images": backImages]
        }

        let payload = try parseJSON(try await store.saveCardDrafts(cards: [
            draft(front: "What strengthens later access?", backImages: [
                ["target": "foreverlm://image/source-cards/page/2", "alt": "Curve"],
                "![Spacing in motion](\(address))",
            ]),
        ], keptByDefault: false))
        #expect(payload["saved_count"] as? Int == 1)
        let listed = try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil))
        let card = try #require((listed["to_check"] as? [[String: Any]])?.first)
        let images = try #require(card["back_images"] as? [[String: Any]])
        #expect(images.compactMap { $0["target"] as? String } == ["foreverlm://image/source-cards/page/2", address])
        #expect(images.last?["alt"] as? String == "Spacing in motion")

        // A second animation on one face, an animation the library does not
        // hold, and a site that is no animation are each refused whole.
        for (images, reason) in [
            ([address, "![Again](\(address))"] as [Any], "takes one animation"),
            (["foreverlm-site://no-such-animation/"] as [Any], "does not hold"),
        ] {
            do {
                _ = try await store.saveCardDrafts(cards: [draft(front: "Another question about \(reason)?", backImages: images)], keptByDefault: false)
                Issue.record("\(reason): the call was accepted")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("Nothing was saved"))
                #expect(error.localizedDescription.contains(reason), "\(error.localizedDescription)")
            }
        }
        #expect((try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil)))["to_check_count"] as? Int == 1)
    }

    @Test("triage_cards keeps, edits and skips cards to check on the learner's word, and list_cards lists the kept ones with the wording to ask")
    func listAndTriageCardsTools() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "What strengthens later access?", "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access", "seed": "q1"],
            ["source_id": "source-cards", "front": "What else helps?", "back": "Spacing.", "quote": "Spacing the practice helps too", "seed": "q2"],
            ["source_id": "source-cards", "front": "Is rereading passive?", "back": "Yes.", "quote": "passive rereading", "seed": "q3"],
        ], keptByDefault: false)
        let listed = try parseJSON(try await store.listCards(status: "to_check", notebookID: nil, sourceID: "source-cards", limit: nil))
        #expect(listed["to_check_count"] as? Int == 3)
        #expect(listed["to_check_summary"] as? String == "3 cards from 1 source")
        let ids = (listed["to_check"] as? [[String: Any]] ?? []).compactMap { $0["card_id"] as? String }
        #expect(ids.count == 3)

        // A decision with no such action changes nothing.
        do {
            _ = try await store.triageCards(decisions: [["card_id": ids[0], "action": "archive"]], keepSourceIDs: [], skipSourceIDs: [])
            Issue.record("An unknown action was accepted")
        } catch is MCPError {}

        let triaged = try parseJSON(try await store.triageCards(decisions: [
            ["card_id": ids[0], "action": "keep"],
            ["card_id": ids[1], "action": "keep", "front": "Besides retrieval, what helps later access?"],
            ["card_id": ids[2], "action": "skip"],
            ["card_id": "card-nobody-drafted", "action": "keep"],
        ], keepSourceIDs: [], skipSourceIDs: []))
        #expect((triaged["kept"] as? [[String: Any]])?.count == 2)
        #expect(triaged["skipped"] as? [String] == [ids[2]])
        #expect(triaged["not_found"] as? [String] == ["card-nobody-drafted"])
        #expect(triaged["to_check_count"] as? Int == 0)
        let deckID = MemoryCard.draftDeckID(sourceID: "source-cards")
        #expect(MemoryCardStateStore.state(cardID: ids[2], deckID: deckID, defaults: defaults)?.status == .skipped)
        #expect(MemoryCardStateStore.state(cardID: ids[0], deckID: deckID, defaults: defaults)?.status == .kept)

        let kept = try parseJSON(try await store.listCards(status: "kept", notebookID: nil, sourceID: nil, limit: nil))
        let cards = kept["kept"] as? [[String: Any]] ?? []
        #expect(Set(cards.compactMap { $0["ask"] as? String }) == ["What strengthens later access?", "Besides retrieval, what helps later access?"])
        #expect(cards.allSatisfy { $0["schedule"] as? String == "new" }, "a kept card is first asked the day after it is kept")
        #expect(cards.allSatisfy { ($0["item_id"] as? String)?.hasPrefix("memory-card-v1") == true })
        #expect((try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil)))["to_check_count"] as? Int == 0)
    }

    @Test("triage_cards decides a source's cards at once, and list_cards narrows to one Notebook's sources")
    func triageCardsBySourceAndNotebook() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-other", title: "Sleep", content: "Sleep consolidates what was learned during the day.")
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "What strengthens later access?", "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access"],
            ["source_id": "source-cards", "front": "What else helps?", "back": "Spacing.", "quote": "Spacing the practice helps too"],
            ["source_id": "source-other", "front": "What does sleep do to learning?", "back": "It consolidates it.", "quote": "Sleep consolidates what was learned"],
        ], keptByDefault: false)
        let ks = try store.knowledgeStore()
        let notebook = try ks.createCompanionGoal(
            title: "Retrieval", topic: "retrieval", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["source-cards"]
        )
        let inNotebook = try parseJSON(try await store.listCards(status: nil, notebookID: notebook.id, sourceID: nil, limit: nil))
        #expect(inNotebook["to_check_count"] as? Int == 2)
        #expect(Set((inNotebook["to_check"] as? [[String: Any]] ?? []).compactMap { $0["source_id"] as? String }) == ["source-cards"])

        let triaged = try parseJSON(try await store.triageCards(
            decisions: [], keepSourceIDs: ["source-cards"], skipSourceIDs: ["source-other", "source-unknown"]
        ))
        #expect((triaged["kept"] as? [[String: Any]])?.count == 2)
        #expect((triaged["skipped"] as? [String])?.count == 1)
        #expect(triaged["sources_with_nothing_to_check"] as? [String] == ["source-unknown"])
        #expect(try ks.loadMemoryItems().count == 2)

        // The same source in both lists is refused before anything is written.
        do {
            _ = try await store.triageCards(decisions: [], keepSourceIDs: ["source-cards"], skipSourceIDs: ["source-cards"])
            Issue.record("A source both kept and skipped was accepted")
        } catch is MCPError {}
    }

    // MARK: The card review over MCP: get_due_cards, record_card_result, update_card

    /// A card kept on `source-cards` `daysAgo` days ago, its state in the
    /// source's deck.
    private static let secondCardSourceText = "Testing yourself beats rereading: retrieval practice strengthens memory, and spreading the practice over days helps further."

    @Test("A card stands on several sources: save_card_drafts takes also_from, list_cards shows every source, triage_cards chooses them at Keep, and a link its source does not print is left off")
    func cardsStandOnSeveralSources() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-second", title: "Testing yourself", content: Self.secondCardSourceText)

        let saved = try parseJSON(try await store.saveCardDrafts(cards: [
            [
                "source_id": "source-cards",
                "front": "What strengthens later access more than rereading?",
                "back": "Retrieval practice.",
                "quote": "Retrieval practice strengthens later access",
                "also_from": [
                    ["source_id": "source-second", "quote": "retrieval practice strengthens memory"],
                    ["source_id": "source-second", "quote": "a sentence the second source never prints"],
                ],
            ],
            [
                "source_id": "source-cards",
                "front": "What does spacing the practice do?",
                "back": "It helps.",
                "quote": "Spacing the practice helps too",
                "also_from": [["source_id": "source-second", "quote": "spreading the practice over days helps further"]],
            ],
        ], keptByDefault: false))
        #expect(saved["saved_count"] as? Int == 2)
        let entry = try #require((saved["sources"] as? [[String: Any]])?.first)
        let missed = try #require(entry["not_grounded_links"] as? [[String: Any]])
        #expect(missed.count == 1)
        #expect(missed.first?["source_id"] as? String == "source-second")

        // An unknown source in also_from refuses the whole call, before anything is written.
        do {
            _ = try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "Another?", "back": "Yes.", "quote": "Spacing the practice helps too",
                 "also_from": [["source_id": "no-such-source", "quote": "x"]]],
            ], keptByDefault: false)
            Issue.record("An unknown also_from source was accepted")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("no-such-source"))
        }

        let listed = try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: "source-second", limit: nil))
        let cards = try #require(listed["to_check"] as? [[String: Any]])
        #expect(cards.count == 2, "a card stands on each of its sources, so the second source's filter finds both")
        let first = try #require(cards.first { ($0["front"] as? String)?.hasPrefix("What strengthens") == true })
        let sources = try #require(first["sources"] as? [[String: Any]])
        #expect(sources.compactMap { $0["source_id"] as? String } == ["source-cards", "source-second"])
        #expect(sources.last?["source_title"] as? String == "Testing yourself")

        // Keep as drafted: anchored on both. Keep the other with also_from [] : on its own source alone.
        let secondID = try #require(cards.first { ($0["front"] as? String)?.hasPrefix("What does spacing") == true }?["card_id"] as? String)
        let firstID = try #require(first["card_id"] as? String)
        let kept = try parseJSON(try await store.triageCards(decisions: [
            ["card_id": firstID, "action": "keep"],
            ["card_id": secondID, "action": "keep", "also_from": [] as [[String: Any]]],
        ], keepSourceIDs: [], skipSourceIDs: []))
        #expect((kept["kept"] as? [[String: Any]])?.count == 2)

        let keptList = try parseJSON(try await store.listCards(status: "kept", notebookID: nil, sourceID: nil, limit: nil))
        let keptCards = try #require(keptList["kept"] as? [[String: Any]])
        let byFront = Dictionary(uniqueKeysWithValues: keptCards.compactMap { card in (card["front"] as? String).map { ($0, card) } })
        let both = try #require(byFront["What strengthens later access more than rereading?"]?["sources"] as? [[String: Any]])
        #expect(both.compactMap { $0["source_id"] as? String } == ["source-cards", "source-second"])
        #expect(both.last?["quote"] as? String == "retrieval practice strengthens memory")
        let alone = try #require(byFront["What does spacing the practice do?"]?["sources"] as? [[String: Any]])
        #expect(alone.compactMap { $0["source_id"] as? String } == ["source-cards"])
    }

    @Test("list_source_card_coverage lists the sources no card covers, then every source with where its cards stand")
    func listSourceCardCoverageTool() async throws {
        let registry = MCPToolRegistry(store: MCPDataStore())
        let tool = try #require(registry.tools.first { $0.name == "list_source_card_coverage" })
        #expect(tool.inputSchema["anyOf"] == nil && tool.inputSchema["oneOf"] == nil)
        #expect(MCPToolRegistry.annotations(for: "list_source_card_coverage")["readOnlyHint"] as? Bool == true)
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("list_source_card_coverage"))
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("list_source_card_coverage"))

        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-second", title: "Testing yourself", content: Self.secondCardSourceText)
        try insertSource(dbPath: dbPath, id: "source-bare", title: "Bare source", content: "Some words to read here.")

        let none = try parseJSON(try await store.listSourceCardCoverage(scope: nil, notebookID: nil, limit: nil))
        #expect(none["scope"] as? String == "without_cards")
        #expect(none["without_cards"] as? Int == 3)
        #expect(none["total"] as? Int == 3)
        #expect(Set((none["sources"] as? [[String: Any]] ?? []).compactMap { $0["source_id"] as? String })
            == ["source-cards", "source-second", "source-bare"])
        #expect(none["guidance"] != nil)

        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "What strengthens later access more than rereading?",
             "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access"],
        ], keptByDefault: false)
        let drafted = try parseJSON(try await store.listSourceCardCoverage(scope: "all", notebookID: nil, limit: nil))
        let rows = try #require(drafted["sources"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in (row["source_id"] as? String).map { ($0, row) } })
        #expect(byID["source-cards"]?["status"] as? String == "to_check")
        #expect(byID["source-second"]?["status"] as? String == "none")
        #expect(drafted["without_cards"] as? Int == 2)
        #expect(rows.first?["status"] as? String == "none", "the sources with no card come first")

        let cardID = try #require(((try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil)))["to_check"] as? [[String: Any]])?.first?["card_id"] as? String)
        _ = try await store.triageCards(decisions: [["card_id": cardID, "action": "keep"]], keepSourceIDs: [], skipSourceIDs: [])
        let kept = try parseJSON(try await store.listSourceCardCoverage(scope: "all", notebookID: nil, limit: 1))
        #expect(kept["returned"] as? Int == 1, "limit caps the list")
        let keptRows = try parseJSON(try await store.listSourceCardCoverage(scope: "all", notebookID: nil, limit: nil))
        let keptSource = try #require((keptRows["sources"] as? [[String: Any]])?.first { $0["source_id"] as? String == "source-cards" })
        #expect(keptSource["status"] as? String == "kept")
        #expect(keptSource["cards"] as? Int == 1)

        do {
            _ = try await store.listSourceCardCoverage(scope: "everything", notebookID: nil, limit: nil)
            Issue.record("An unknown scope was accepted")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("without_cards"))
        }
    }

    @Test("find_card_sources is read-only, takes a card or a question and an answer, and refuses an unknown card")
    func findCardSourcesTool() async throws {
        let registry = MCPToolRegistry(store: MCPDataStore())
        let tool = try #require(registry.tools.first { $0.name == "find_card_sources" })
        #expect(tool.inputSchema["anyOf"] == nil && tool.inputSchema["oneOf"] == nil)
        #expect(MCPToolRegistry.annotations(for: "find_card_sources")["readOnlyHint"] as? Bool == true)
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("find_card_sources"))
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("find_card_sources"))

        let (_, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        // No embedding model: the search runs on text alone.
        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in throw MCPError.invalidInput("no embedding model") }, cardStateDefaults: defaults)
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-second", title: "Testing yourself", content: Self.secondCardSourceText)

        let found = try parseJSON(try await store.findCardSources(
            cardID: nil,
            question: "What strengthens memory more than rereading?",
            answer: "Retrieval practice strengthens memory.",
            sourceIDs: ["source-second"],
            notebookID: nil
        ))
        #expect(found["question"] as? String == "What strengthens memory more than rereading?")
        let candidates = try #require(found["candidates"] as? [[String: Any]])
        #expect(candidates.allSatisfy { $0["source_id"] as? String == "source-second" })
        #expect(found["guidance"] != nil)

        do {
            _ = try await store.findCardSources(cardID: "no-such-card", question: nil, answer: nil, sourceIDs: [], notebookID: nil)
            Issue.record("An unknown card was accepted")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("no-such-card"))
        }
        do {
            _ = try await store.findCardSources(cardID: nil, question: "Only a question?", answer: nil, sourceIDs: [], notebookID: nil)
            Issue.record("A question without an answer was accepted")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("card_id"))
        }
    }

    private func keepCard(
        _ store: MCPDataStore,
        front: String,
        back: String,
        quote: String,
        keptDaysAgo: Double
    ) throws -> (card: MemoryCard, item: MemoryItem) {
        let card = MemoryCard(
            cardID: "card-\(UUID().uuidString)",
            front: front,
            back: back,
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "source-cards")
        )
        let item = try store.knowledgeStore().keepMemoryCard(
            card, sourceID: "source-cards", quote: quote,
            at: Date().addingTimeInterval(-keptDaysAgo * 86_400)
        )
        return (card, item)
    }

    @Test("The card review's tools are registered: get_due_cards only reads, record_card_result takes nothing back, update_card can retire a card")
    func cardReviewToolsAreRegistered() {
        let registry = MCPToolRegistry(store: MCPDataStore())
        let names = Set(registry.tools.map(\.name))
        #expect(names.isSuperset(of: ["get_due_cards", "record_card_result", "update_card"]))
        #expect(MCPToolRegistry.annotations(for: "get_due_cards")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "record_card_result")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "record_card_result")["destructiveHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "update_card")["destructiveHint"] as? Bool == true)
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("record_card_result"), "an answer costs nothing")
        let recordSchema = registry.tools.first { $0.name == "record_card_result" }?.inputSchema
        #expect(recordSchema?["required"] as? [String] == ["remembered"])
        #expect(recordSchema?["anyOf"] == nil && recordSchema?["oneOf"] == nil, "either id is said in the description, never a top-level anyOf")
        // The assistant-facing texts say how a kept card is asked.
        #expect(Prompts.mcpServerInstructions.contains("get_due_cards"))
        #expect(registry.tools.first { $0.name == "memory_review" }?.description.contains("get_due_cards") == true)
        #expect(MCPDataStore.cohortConductInstructions.contains("through get_due_cards or memory_review"))
        #expect(MCPDataStore.dueCardsInstructions.contains("exactly as written"))
    }

    @Test("practice_cards opens the app's card review on chosen cards: never read-only, free, off the store gate, and refused without cards or a title")
    func practiceCardsIsRegistered() async throws {
        let registry = MCPToolRegistry(store: MCPDataStore())
        let tool = try #require(registry.tools.first { $0.name == "practice_cards" })
        #expect(tool.inputSchema["required"] as? [String] == ["card_ids", "title"])
        #expect(tool.inputSchema["anyOf"] == nil && tool.inputSchema["oneOf"] == nil)
        // It changes the learner's window, so it never falls back to the
        // hosted mirror, and it takes nothing back.
        #expect(MCPToolRegistry.annotations(for: "practice_cards")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "practice_cards")["destructiveHint"] as? Bool == false)
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("practice_cards"), "opening the review costs nothing")
        #expect(MCPToolRegistry.storeGateExemptToolNames.contains("practice_cards"), "it waits on the window, as open_in_app does")
        #expect(Prompts.mcpServerInstructions.contains("practice_cards"))
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: ["list_cards", "practice_cards"]), "said in the chat about a paper too")
        #expect(ReviewSessionManager.chatExcludedToolNames.isDisjoint(with: ["list_cards", "practice_cards"]))

        // Refused before anything opens.
        let store = MCPDataStore()
        let refused: [(ids: Any?, title: String?)] = [
            (nil, "Mitochondria"), ([] as [Any], "Mitochondria"), ([42], "Mitochondria"),
            (["card-a"], nil), (["card-a"], "   "),
            ((0...MCPDataStore.maxPracticeCardsPerCall).map { "card-\($0)" }, "Mitochondria"),
        ]
        for call in refused {
            await #expect(throws: MCPError.self) { try await store.practiceCards(cardIDs: call.ids, title: call.title) }
        }
    }

    @Test("get_due_cards deals today's cards in the card review's order with the wording to ask, and narrows to a Notebook")
    func getDueCardsDealsToday() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-other", title: "Sleep", content: "Sleep consolidates what was learned during the day.")
        let knowledge = try store.knowledgeStore()
        let now = Date()
        // Due: kept ten days ago and forgotten two days ago.
        let (dueCard, due) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 10)
        #expect(try knowledge.recordSelfGradedMemoryCardAttempt(
            memoryItemID: due.id, prompt: dueCard.front, remembered: false, sessionKey: "earlier",
            at: now.addingTimeInterval(-2 * 86_400)
        ) == .recorded)
        // New and eligible: kept two days ago, never answered.
        let (newCard, fresh) = try keepCard(store, front: "What else helps?", back: "Spacing.", quote: "Spacing the practice helps too", keptDaysAgo: 2)
        // Kept just now: first asked tomorrow, so not today's.
        let (_, keptToday) = try keepCard(store, front: "Is rereading passive?", back: "Yes.", quote: "passive rereading", keptDaysAgo: 0)

        let payload = try parseJSON(try await store.getDueCards(notebookID: nil, limit: nil))
        let cards = payload["cards"] as? [[String: Any]] ?? []
        #expect(cards.compactMap { $0["item_id"] as? String } == [due.id, fresh.id], "due first, then new; a card kept today waits")
        #expect(!cards.contains { $0["item_id"] as? String == keptToday.id })
        #expect(cards.first?["ask"] as? String == dueCard.front)
        #expect(cards.first?["back"] as? String == "Retrieval practice.")
        #expect(cards.first?["card_id"] as? String == dueCard.cardID)
        #expect(cards.first?["is_new"] as? Bool == false)
        #expect(cards.first?["source_title"] as? String == "Retrieval practice")
        #expect(cards.first?["quote"] as? String == "Retrieval practice strengthens later access")
        #expect(cards.last?["is_new"] as? Bool == true)
        #expect(cards.last?["reason"] as? String == "new")
        #expect(payload["due_count"] as? Int == 1)
        #expect(payload["new_count"] as? Int == 1)
        #expect((payload["sitting_id"] as? String)?.hasPrefix("mcp-cards-") == true)
        #expect((payload["instructions"] as? String)?.contains("record_card_result") == true)

        // The learner's own rewording is the wording to ask.
        let deckID = MemoryCard.draftDeckID(sourceID: "source-cards")
        var row = MemoryCardStateStore.load(deckID: deckID, defaults: defaults)
        row.markKept(cardID: newCard.cardID, memoryItemID: fresh.id, at: now)
        row.cards[newCard.cardID]?.editedFront = "Besides retrieval, what helps later access?"
        defaults.set(row.preferenceValue, forKey: MemoryCardDeckState.preferenceKey(deckID: deckID))
        let reworded = try parseJSON(try await store.getDueCards(notebookID: nil, limit: nil))
        #expect((reworded["cards"] as? [[String: Any]])?.last?["ask"] as? String == "Besides retrieval, what helps later access?")

        // A Notebook's cards are those on its sources.
        let notebook = try knowledge.createCompanionGoal(
            title: "Sleep", topic: "sleep", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["source-other"]
        )
        let narrowed = try parseJSON(try await store.getDueCards(notebookID: notebook.id, limit: nil))
        #expect((narrowed["cards"] as? [[String: Any]])?.isEmpty == true)
        #expect((narrowed["notebook"] as? [String: Any])?["notebook_id"] as? String == notebook.id)
        let limited = try parseJSON(try await store.getDueCards(notebookID: nil, limit: 1))
        #expect((limited["cards"] as? [[String: Any]])?.count == 1)
        #expect(limited["listed"] as? Int == 1)
    }

    @Test("record_card_result records a self-graded answer by the card review's rules, once a sitting, and refuses what is no kept card")
    func recordCardResultTool() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let (dueCard, due) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 10)
        _ = try knowledge.recordSelfGradedMemoryCardAttempt(
            memoryItemID: due.id, prompt: dueCard.front, remembered: false, sessionKey: "earlier",
            at: now.addingTimeInterval(-2 * 86_400)
        )

        let recorded = try parseJSON(try await store.recordCardResult(
            cardID: dueCard.cardID, itemID: nil, remembered: true,
            asked: "Which strengthens later access?", sittingID: "mcp-cards-test", practice: nil
        ))
        #expect(recorded["outcome"] as? String == "recorded")
        #expect(recorded["item_id"] as? String == due.id)
        #expect(recorded["next_due_at"] != nil)
        let attempt = try #require(try knowledge.loadMemoryAttempts(memoryItemID: due.id).first { $0.attemptedAt > now.addingTimeInterval(-60) })
        #expect(attempt.prompt == "Which strengthens later access?", "the wording asked is the attempt's question")
        #expect(attempt.learnerAnswer == MemoryAttempt.selfGradedAnswer)
        #expect(attempt.score == 1)
        #expect(attempt.scheduleRating == .good)
        #expect(attempt.gradeState == .graded)
        #expect(attempt.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "mcp-cards-test", memoryItemID: due.id))

        // The same answer sent again in the sitting is counted once; another
        // sitting finds the card not due any more, and an early answer never
        // moves its schedule.
        let again = try parseJSON(try await store.recordCardResult(
            cardID: nil, itemID: due.id, remembered: false, asked: nil, sittingID: "mcp-cards-test", practice: nil
        ))
        #expect(again["outcome"] as? String == "already_recorded")
        let early = try parseJSON(try await store.recordCardResult(
            cardID: dueCard.cardID, itemID: nil, remembered: true, asked: nil, sittingID: "mcp-cards-later", practice: nil
        ))
        #expect(early["outcome"] as? String == "not_counted")
        #expect(try knowledge.loadMemoryAttempts(memoryItemID: due.id).count == 2)

        // A card kept today is first asked tomorrow, unless the learner asked
        // to practise it; without asked, the card's own wording is recorded.
        let (todayCard, today) = try keepCard(store, front: "What else helps?", back: "Spacing.", quote: "Spacing the practice helps too", keptDaysAgo: 0)
        let notYet = try parseJSON(try await store.recordCardResult(
            cardID: todayCard.cardID, itemID: nil, remembered: true, asked: nil, sittingID: nil, practice: nil
        ))
        #expect(notYet["outcome"] as? String == "not_counted")
        #expect((notYet["message"] as? String)?.contains("practice") == true)
        let practised = try parseJSON(try await store.recordCardResult(
            cardID: todayCard.cardID, itemID: nil, remembered: false, asked: nil, sittingID: nil, practice: true
        ))
        #expect(practised["outcome"] as? String == "recorded")
        #expect(practised["asked"] as? String == todayCard.front)
        #expect((practised["sitting_id"] as? String)?.hasPrefix("mcp-cards-") == true, "one sitting a day without sitting_id")
        #expect(try knowledge.loadMemoryAttempts(memoryItemID: today.id).first?.scheduleRating == .again)

        // A retired card is never recorded.
        try knowledge.retireMemoryCard(memoryItemID: today.id)
        let retired = try parseJSON(try await store.recordCardResult(
            cardID: todayCard.cardID, itemID: nil, remembered: true, asked: nil, sittingID: "mcp-other", practice: true
        ))
        #expect(retired["outcome"] as? String == "retired")

        // Refusals: no answer, a number for a boolean, no id, two cards, a
        // card still to check, an id no card answers to.
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "Is rereading passive?", "back": "Yes.", "quote": "passive rereading"],
        ], keptByDefault: false)
        let draftID = try #require((try parseJSON(try await store.listCards(status: "to_check", notebookID: nil, sourceID: nil, limit: nil))["to_check"] as? [[String: Any]])?.first?["card_id"] as? String)
        let refusals: [(String?, String?, Any?, String)] = [
            (dueCard.cardID, nil, nil, "remembered is required"),
            (dueCard.cardID, nil, 1, "true or false"),
            (nil, nil, true, "card_id"),
            (dueCard.cardID, today.id, true, "two different cards"),
            (draftID, nil, true, "triage_cards"),
            ("card-nobody-kept", nil, true, "No kept card"),
        ]
        for (cardID, itemID, remembered, expected) in refusals {
            do {
                _ = try await store.recordCardResult(cardID: cardID, itemID: itemID, remembered: remembered, asked: nil, sittingID: "mcp-refused", practice: nil)
                Issue.record("record_card_result accepted \(String(describing: cardID)) / \(String(describing: remembered))")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains(expected), "\(error.localizedDescription)")
            }
        }
        #expect(try knowledge.loadMemoryItem(MemoryTutorIdentity.cardItemID(cardID: draftID)) == nil, "a card to check stays a draft")
    }

    @Test("save_card_drafts and update_card hold every card to standing on its own: reworded once, or refused with the reason")
    func cardWordingGateOverMCP() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let wording = CannedCardWording(pointing: ["this lecture", "the speaker"]) { question in
            question.contains("this lecture") ? "In retrieval research, what strengthens later access more than rereading?" : nil
        }
        try await CardWordingGate.$backendOverride.withValue(wording) {
            let payload = try parseJSON(try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "In this lecture, what strengthens later access more than rereading?",
                 "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access"],
                ["source_id": "source-cards", "front": "What does the speaker say spacing does?",
                 "back": "It helps too.", "quote": "Spacing the practice helps too"],
            ], keptByDefault: false))
            #expect(payload["saved_count"] as? Int == 1)
            let entry = try #require((payload["sources"] as? [[String: Any]])?.first)
            let reworded = try #require((entry["reworded"] as? [[String: Any]])?.first)
            #expect(reworded["was"] as? String == "In this lecture, what strengthens later access more than rereading?")
            #expect(reworded["front"] as? String == "In retrieval research, what strengthens later access more than rereading?")
            let refused = try #require((entry["not_standalone"] as? [[String: Any]])?.first)
            #expect(refused["front"] as? String == "What does the speaker say spacing does?")
            #expect((refused["reason"] as? String)?.contains("points at its source") == true)
            #expect(payload["wording_guidance"] != nil)

            // update_card: new words that point at the source and do not
            // mend are refused, and nothing changes.
            let (card, _) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 3)
            do {
                _ = try await store.updateCard(
                    cardID: card.cardID, itemID: nil, front: "What does the speaker call it?", back: nil, why: nil,
                    startOver: nil, alwaysAsk: nil, retire: nil
                )
                Issue.record("update_card saved a card that points at its source")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("points at its source"), "\(error.localizedDescription)")
            }
        }

        // A check that cannot run saves nothing, and says why.
        let down = CannedCardWording(failure: CardWordingGate.Unavailable(message: "No model is set up for Card Wording Check."))
        try await CardWordingGate.$backendOverride.withValue(down) {
            let payload = try parseJSON(try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "What helps besides retrieval?", "back": "Spacing the practice.", "quote": "Spacing the practice helps too"],
            ], keptByDefault: false))
            #expect(payload["saved_count"] as? Int == 0)
            let reason = (payload["sources_not_saved"] as? [[String: Any]])?.first?["reason"] as? String
            #expect(reason?.contains("could not be checked") == true)
        }
    }

    @Test("update_card rewords, holds, starts over and retires a kept card as All Cards does")
    func updateCardTool() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let knowledge = try store.knowledgeStore()
        let (card, item) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 3)
        let deckID = MemoryCard.draftDeckID(sourceID: "source-cards")

        // A new front alone rewords it: the item and its schedule stay.
        let reworded = try parseJSON(try await store.updateCard(
            cardID: card.cardID, itemID: nil, front: "Which beats rereading for later access?", back: nil, why: nil,
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(reworded["changed"] as? Bool == true)
        #expect(reworded["ask"] as? String == "Which beats rereading for later access?")
        #expect(reworded["item_id"] as? String == item.id)
        #expect(MemoryCardStateStore.state(cardID: card.cardID, deckID: deckID, defaults: defaults)?.editedFront == "Which beats rereading for later access?")
        #expect(try knowledge.loadMemoryItem(item.id)?.status == .active)
        let kept = try parseJSON(try await store.listCards(status: "kept", notebookID: nil, sourceID: nil, limit: nil))
        #expect((kept["kept"] as? [[String: Any]])?.first?["ask"] as? String == "Which beats rereading for later access?")
        // The same words again change nothing; the words it was kept with clear the rewording.
        let unchanged = try parseJSON(try await store.updateCard(
            cardID: card.cardID, itemID: nil, front: "Which beats rereading for later access?", back: nil, why: nil,
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(unchanged["changed"] as? Bool == false)
        _ = try await store.updateCard(cardID: card.cardID, itemID: nil, front: card.front, back: nil, why: nil, startOver: nil, alwaysAsk: true, retire: nil)
        let held = MemoryCardStateStore.state(cardID: card.cardID, deckID: deckID, defaults: defaults)
        #expect(held?.editedFront == nil)
        #expect(held?.alwaysAsk == true)

        // A new back starts it over: a new card, the old one retired.
        let restarted = try parseJSON(try await store.updateCard(
            cardID: card.cardID, itemID: nil, front: nil, back: "Practising retrieval.", why: nil,
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(restarted["started_over"] as? Bool == true)
        #expect(restarted["previous_item_id"] as? String == item.id)
        let newItemID = try #require(restarted["item_id"] as? String)
        let newCardID = try #require(restarted["card_id"] as? String)
        #expect(newItemID != item.id && newCardID != card.cardID)
        #expect(try knowledge.loadMemoryItem(item.id)?.status == .retired)
        let revision = try #require(try knowledge.loadMemoryItem(newItemID))
        #expect(revision.target == "Practising retrieval.")
        #expect(MemoryCard(storedIn: revision)?.front == card.front, "asked as it was asked before")
        #expect(MemoryCardStateStore.state(cardID: newCardID, deckID: deckID, defaults: defaults)?.alwaysAsk == true, "a card started over keeps always ask")

        // Refusals: nothing asked, retire with an edit, an empty front, a retired card.
        let refusals: [(String?, String?, Any?, Any?, String)] = [
            (nil, nil, nil, nil, "Pass front"),
            ("New words", nil, nil, true, "retire takes no other change"),
            ("  ", nil, nil, nil, "front and a back"),
        ]
        for (front, back, startOver, retire, expected) in refusals {
            do {
                _ = try await store.updateCard(cardID: newCardID, itemID: nil, front: front, back: back, why: nil, startOver: startOver, alwaysAsk: nil, retire: retire)
                Issue.record("update_card accepted \(String(describing: front))")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains(expected), "\(error.localizedDescription)")
            }
        }
        do {
            _ = try await store.updateCard(cardID: card.cardID, itemID: nil, front: "Again?", back: nil, why: nil, startOver: nil, alwaysAsk: nil, retire: nil)
            Issue.record("A retired card was changed")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("retired"))
        }

        // Retire: never asked again; retiring again says so.
        let retired = try parseJSON(try await store.updateCard(cardID: newCardID, itemID: nil, front: nil, back: nil, why: nil, startOver: nil, alwaysAsk: nil, retire: true))
        #expect(retired["retired"] as? Bool == true)
        #expect(try knowledge.loadMemoryItem(newItemID)?.status == .retired)
        let twice = try parseJSON(try await store.updateCard(cardID: nil, itemID: newItemID, front: nil, back: nil, why: nil, startOver: nil, alwaysAsk: nil, retire: true))
        #expect((twice["message"] as? String)?.contains("already") == true)
    }

    @Test("memoryReview reserves one source-level intake slot beside four due concepts")
    func memoryReviewMatchesSharedFiveItemSelection() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let attemptedAt = now.addingTimeInterval(-30 * 86_400)

        for index in 0..<5 {
            let sourceID = "concept-source-\(index)"
            let itemID = "concept-item-\(index)"
            let content = "Concept \(index) requires effortful retrieval before corrective feedback."
            try insertSource(
                dbPath: dbPath,
                id: sourceID,
                title: "Concept \(index)",
                content: content
            )
            try knowledge.saveMemoryItem(
                MemoryItem(
                    id: itemID,
                    kind: .concept,
                    target: "Explain concept \(index)",
                    rubricJSON: #"{"criteria":["Explains the mechanism"]}"#,
                    sources: [
                        MemoryItemSource(
                            id: "concept-anchor-\(index)",
                            memoryItemID: itemID,
                            sourceID: sourceID,
                            excerpt: content,
                            sourceSHA256: PaperContentPreparationService.sha256(content),
                            sortIndex: 0
                        ),
                    ],
                    createdAt: attemptedAt.addingTimeInterval(-86_400),
                    updatedAt: attemptedAt.addingTimeInterval(-86_400)
                )
            )
            _ = try knowledge.recordMemoryAttempt(
                MemoryAttempt(
                    id: "concept-attempt-\(index)",
                    memoryItemID: itemID,
                    attemptType: .review,
                    prompt: "Explain concept \(index).",
                    learnerAnswer: "A partial explanation.",
                    feedback: "Retrieve it again later.",
                    score: 0.8,
                    scheduleRating: .good,
                    gradeState: .graded,
                    attemptedAt: attemptedAt
                )
            )
        }

        let sourceLevelContent = "A legacy source-level review must become a concept trace."
        try insertSource(
            dbPath: dbPath,
            id: "legacy-intake-source",
            title: "Legacy intake",
            content: sourceLevelContent
        )
        try knowledge.createReviewSession(
            id: "legacy-intake-session",
            topic: "Legacy intake review",
            sourceIDs: ["legacy-intake-source"],
            startedAt: attemptedAt
        )
        _ = try knowledge.addReviewExchange(
            sessionID: "legacy-intake-session",
            question: "What is the mechanism?",
            answer: "I do not remember.",
            evaluation: "Needs another retrieval.",
            score: 0.2,
            knowledgeNote: nil,
            sourceRefs: ["legacy-intake-source"],
            answeredAt: attemptedAt
        )
        try knowledge.completeReviewSession(
            sessionID: "legacy-intake-session",
            overallScore: 0.2,
            summary: "Weak legacy recall.",
            endedAt: attemptedAt
        )

        let payload = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 5,
                startSession: false
            )
        )
        let conceptItems = try #require(payload["memory_items"] as? [[String: Any]])
        let intakeItems = try #require(payload["items"] as? [[String: Any]])
        let newItems = try #require(payload["new_items"] as? [[String: Any]])

        #expect(conceptItems.count == 4)
        #expect(intakeItems.count == 1)
        #expect(intakeItems.first?["source_id"] as? String == "legacy-intake-source")
        #expect(newItems.isEmpty)
    }

    @Test("memoryReview operation id reuses one session and rejects changed arguments")
    func memoryReviewStartIsIdempotentByOperationID() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let content = "Retrieval before feedback exposes accessible knowledge."
        try insertSource(
            dbPath: dbPath,
            id: "operation-source",
            title: "Operation identity",
            content: content
        )
        let old = Date().addingTimeInterval(-20 * 86_400)
        try knowledge.saveMemoryItem(
            MemoryItem(
                id: "operation-item",
                kind: .concept,
                target: "Explain retrieval before feedback",
                rubricJSON: #"{"criteria":["Explains diagnostic effort"]}"#,
                sources: [
                    MemoryItemSource(
                        id: "operation-anchor",
                        memoryItemID: "operation-item",
                        sourceID: "operation-source",
                        excerpt: content,
                        sourceSHA256: PaperContentPreparationService.sha256(content),
                        sortIndex: 0
                    ),
                ],
                createdAt: old.addingTimeInterval(-86_400),
                updatedAt: old.addingTimeInterval(-86_400)
            )
        )
        _ = try knowledge.recordMemoryAttempt(
            MemoryAttempt(
                id: "operation-attempt",
                memoryItemID: "operation-item",
                attemptType: .review,
                prompt: "Explain retrieval before feedback.",
                learnerAnswer: "It reveals what is accessible.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old
            )
        )

        let first = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "provider-call-42"
            )
        )
        let firstSessionID = try #require(first["session_id"] as? String)
        let persistedPlan = try #require(
            try knowledge.loadReviewSessionForSync(firstSessionID)
        )
        #expect(persistedPlan.sourceIDs == ["operation-source"])
        let launchedItem = try #require(try knowledge.loadMemoryItem("operation-item"))
        #expect(persistedPlan.cardIDs == [
            "memory-item-v2:\(MemoryTutorIdentity.immutableCurriculumFingerprint(launchedItem)):operation-item"
        ])
        let lateContent = "A later sync must not replace the queue chosen by an existing operation."
        try insertSource(
            dbPath: dbPath,
            id: "operation-source-late",
            title: "Late operation source",
            content: lateContent
        )
        let lateItem = MemoryItem(
            id: "operation-item-late",
            kind: .concept,
            target: "Explain stable operation replay",
            rubricJSON: #"{"criteria":["Explains stable replay"]}"#,
            sources: [
                MemoryItemSource(
                    id: "operation-anchor-late",
                    memoryItemID: "operation-item-late",
                    sourceID: "operation-source-late",
                    excerpt: lateContent,
                    sourceSHA256: PaperContentPreparationService.sha256(lateContent),
                    sortIndex: 0
                ),
            ],
            createdAt: old.addingTimeInterval(-100 * 86_400),
            updatedAt: old.addingTimeInterval(-100 * 86_400)
        )
        try knowledge.saveMemoryItem(lateItem)
        _ = try knowledge.recordMemoryAttempt(
            MemoryAttempt(
                id: "operation-attempt-late",
                memoryItemID: lateItem.id,
                attemptType: .review,
                prompt: "Why must a retry be stable?",
                learnerAnswer: "It prevents the request from changing underneath the caller.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old.addingTimeInterval(-100 * 86_400)
            )
        )
        let second = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "provider-call-42"
            )
        )
        let sessionID = try #require(first["session_id"] as? String)
        let firstIDs = (first["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String }
        let secondIDs = (second["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String }

        #expect(second["session_id"] as? String == sessionID)
        #expect(secondIDs == firstIDs)
        #expect(secondIDs == ["operation-item"])
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id = '\(sessionID)'"
        ) == 1)

        do {
            _ = try await store.memoryReview(
                goalID: nil,
                limit: 2,
                startSession: true,
                operationID: "provider-call-42"
            )
            Issue.record("Expected changed arguments for a reused operation_id to fail")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("different memory_review arguments"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id LIKE 'mcp-memory-review-operation-%'"
        ) == 1)

        // Simulate CloudKit adopting a divergent server curriculum under the
        // same deterministic item ID after the assistant received its queue.
        try execSQL(
            dbPath: dbPath,
            "UPDATE memory_items SET target = 'Replacement server curriculum' WHERE id = 'operation-item'"
        )
        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0.8,
                summary: "Must remain open after curriculum replacement.",
                transcript: "Tutor: Explain retrieval.\nLearner: It reveals accessible knowledge.",
                memoryAttempts: [[
                    "item_id": "operation-item",
                    "score": 0.8,
                    "retrieval_quality": "independent",
                    "missing_rubric_elements": [] as [String],
                    "evaluation": "Good.",
                    "prompt": "Explain retrieval before feedback.",
                    "learner_answer": "It reveals what is accessible.",
                ]]
            )
            Issue.record("Expected a replaced queued curriculum to fail closed")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("changed after this review was prepared"))
        }
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM memory_attempts WHERE session_id = '\(sessionID)'"
        ) == 0)
    }

    @Test("memoryReview replay resolves a portable first-review card after source id remap")
    func memoryReviewReplayResolvesPortableFirstReviewSource() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let localSourceID = "local-portable-review-source"
        let foreignSourceID = "foreign-portable-review-source"
        let normalizedURL = "https://example.com/\(localSourceID)"
        try insertSource(
            dbPath: dbPath,
            id: localSourceID,
            title: "Portable first review",
            content: "Portable source identity keeps a queued first review stable across devices."
        )
        let portableKey = try knowledge.portableMemorySourceKey(sourceID: localSourceID)
        let operation = try #require(try store.deterministicMCPOperationSessionIdentity(
            "portable-first-review-retry",
            namespace: "memory-review-v1",
            sessionPrefix: "mcp-memory-review",
            requestFields: [
                "version": 1,
                "goal_id": NSNull(),
                "limit": 1,
            ]
        ))
        try knowledge.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: operation.sessionID,
                topic: "Daily memory refresh",
                startedAt: Date(timeIntervalSinceReferenceDate: 500),
                endedAt: nil,
                status: "active",
                overallScore: nil,
                summary: nil,
                sourceIDs: [foreignSourceID],
                cardIDs: ["new-first-review-portable:\(portableKey)"],
                exchangeCount: 0,
                goalID: nil,
                exchanges: [],
                sourceIdentities: [
                    CloudKitSourceIdentityPayload(
                        sourceID: foreignSourceID,
                        url: normalizedURL,
                        normalizedURL: normalizedURL,
                        doi: nil,
                        publishedDOI: nil
                    ),
                ]
            )
        )

        let persisted = try #require(try knowledge.loadReviewSessionForSync(operation.sessionID))
        #expect(persisted.sourceIDs == [localSourceID])
        #expect(persisted.cardIDs == ["new-first-review-portable:\(portableKey)"])

        let replay = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "portable-first-review-retry"
            )
        )
        #expect(replay["session_id"] as? String == operation.sessionID)
        let firstReviews = try #require(replay["new_items"] as? [[String: Any]])
        #expect(firstReviews.compactMap { $0["source_id"] as? String } == [localSourceID])
    }

    @Test("memory review completion marks only the source actually attempted")
    func memoryReviewStopAfterOneLeavesUntouchedQueueSourcesEligible() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let old = Date().addingTimeInterval(-45 * 86_400)

        for index in 1...2 {
            let sourceID = "partial-memory-source-\(index)"
            let itemID = "partial-memory-item-\(index)"
            let content = "Canonical concept \(index) must remain independently eligible until it is actually attempted."
            try insertSource(
                dbPath: dbPath,
                id: sourceID,
                title: "Partial memory \(index)",
                content: content
            )
            try knowledge.saveMemoryItem(
                MemoryItem(
                    id: itemID,
                    kind: .concept,
                    target: "Explain canonical concept \(index)",
                    rubricJSON: #"{"criteria":["Explains the concept"]}"#,
                    sources: [
                        MemoryItemSource(
                            id: "partial-memory-anchor-\(index)",
                            memoryItemID: itemID,
                            sourceID: sourceID,
                            excerpt: content,
                            sourceSHA256: PaperContentPreparationService.sha256(content),
                            sortIndex: 0
                        ),
                    ],
                    createdAt: old,
                    updatedAt: old
                )
            )
            _ = try knowledge.recordMemoryAttempt(
                MemoryAttempt(
                    id: "partial-memory-old-attempt-\(index)",
                    memoryItemID: itemID,
                    attemptType: .review,
                    prompt: "Explain concept \(index).",
                    learnerAnswer: "An old answer.",
                    feedback: "Needs a refresh.",
                    score: 0.5,
                    scheduleRating: .hard,
                    gradeState: .graded,
                    attemptedAt: old.addingTimeInterval(Double(index))
                )
            )
        }

        let start = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 2,
                startSession: true,
                operationID: "partial-memory-operation"
            )
        )
        let sessionID = try #require(start["session_id"] as? String)
        let queued = try #require(start["memory_items"] as? [[String: Any]])
        #expect(queued.count == 2)
        let attemptedID = try #require(queued.first?["item_id"] as? String)
        let untouchedID = attemptedID == "partial-memory-item-1"
            ? "partial-memory-item-2"
            : "partial-memory-item-1"
        let attemptedSourceID = attemptedID.replacingOccurrences(
            of: "partial-memory-item-",
            with: "partial-memory-source-"
        )
        let untouchedSourceID = untouchedID.replacingOccurrences(
            of: "partial-memory-item-",
            with: "partial-memory-source-"
        )
        let memoryAttempts: [[String: Any]] = [[
            "item_id": attemptedID,
            "prompt": "Explain this concept without looking back.",
            "learner_answer": "I can now explain the mechanism independently.",
            "evaluation": "Correct and independent.",
            "score": 0.95,
            "retrieval_quality": "independent",
            "missing_rubric_elements": [] as [String],
        ]]
        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.95,
            summary: "Stopped after one of two queued concepts.",
            transcript: "Tutor: Explain one concept.\nLearner: I can explain it independently.",
            memoryAttempts: memoryAttempts
        )

        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = '\(attemptedSourceID)' AND completed_at IS NOT NULL"
        ) == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = '\(untouchedSourceID)' AND completed_at IS NOT NULL"
        ) == 0)
        let next = try parseJSON(
            try await store.memoryReview(goalID: nil, limit: 2, startSession: false)
        )
        let nextIDs = (next["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String } ?? []
        #expect(nextIDs.contains(untouchedID))
    }

    @Test("memoryReview cannot consume source-level state without graded concept evidence")
    func memoryReviewRejectsEmptyEvidenceCompletion() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let old = Date().addingTimeInterval(-40 * 86_400)
        let content = "Legacy retrieval history must not be consumed without a concept attempt."
        try insertSource(
            dbPath: dbPath,
            id: "empty-evidence-source",
            title: "Empty evidence guard",
            content: content
        )
        try knowledge.createReviewSession(
            id: "empty-evidence-legacy",
            topic: "Old review",
            sourceIDs: ["empty-evidence-source"],
            startedAt: old
        )
        _ = try knowledge.addReviewExchange(
            sessionID: "empty-evidence-legacy",
            question: "What was the mechanism?",
            answer: "I do not remember.",
            evaluation: "Needs retrieval.",
            score: 0.2,
            knowledgeNote: nil,
            sourceRefs: ["empty-evidence-source"],
            answeredAt: old
        )
        try knowledge.completeReviewSession(
            sessionID: "empty-evidence-legacy",
            overallScore: 0.2,
            summary: "Weak recall.",
            endedAt: old
        )
        let plannedAt = Date().timeIntervalSinceReferenceDate
        try execSQL(dbPath: dbPath, """
            INSERT INTO scheduled_sources
                (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
            VALUES
                ('empty-evidence-schedule', 'empty-evidence-source', \(plannedAt), \(plannedAt), NULL, \(plannedAt), \(plannedAt));
        """)

        let plan = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "empty-evidence-start"
            )
        )
        let sessionID = try #require(plan["session_id"] as? String)

        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0.5,
                summary: "A review allegedly happened.",
                transcript: "Tutor: Explain it.\nLearner: I am unsure."
            )
            Issue.record("Expected memory completion without memory_attempts to fail")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("structured memory_attempts"))
        }

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == 0)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE id = 'empty-evidence-schedule' AND completed_at IS NULL"
        ) == 1)

        // A launched memory queue is durable resume state even before its first
        // grade. Refuse completion rather than deleting that queue or consuming
        // review state without evidence.
        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0,
                summary: "Canceled before review."
            )
            Issue.record("Expected a durable memory queue without evidence to remain open")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("no structured memory_attempts"))
        }
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE id = 'empty-evidence-schedule' AND completed_at IS NULL"
        ) == 1)

        do {
            _ = try store.endReviewSession(
                sessionID: "mcp-memory-review-missing",
                overallScore: 0.5,
                summary: "Late transcript retry.",
                transcript: "Tutor: Explain it.\nLearner: I am unsure.",
                sourceIDs: ["empty-evidence-source"]
            )
            Issue.record("Expected a missing memory-review identity to fail closed")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("will not import its transcript"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        ) == 1)
    }

    @Test("failed-only memory evidence cannot consume review or Schedule state")
    func memoryReviewRejectsFailedOnlyEvidenceCompletion() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let sourceID = "failed-only-memory-source"
        let itemID = "failed-only-memory-item"
        let sessionID = "mcp-memory-review-failed-only"
        let content = "A grader failure is durable evidence, but it is not a successful review."
        try insertSource(
            dbPath: dbPath,
            id: sourceID,
            title: "Failed-only memory evidence",
            content: content
        )
        try knowledge.saveMemoryItem(MemoryItem(
            id: itemID,
            kind: .concept,
            target: "Explain why failed grading must not advance review state",
            rubricJSON: #"{"criteria":["Separates durable failure evidence from a grade"]}"#,
            sources: [
                MemoryItemSource(
                    id: "failed-only-memory-anchor",
                    memoryItemID: itemID,
                    sourceID: sourceID,
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ]
        ))
        try knowledge.createReviewSession(
            id: sessionID,
            topic: "Failed-only memory review",
            sourceIDs: [sourceID]
        )
        _ = try knowledge.recordMemoryAttemptCreatingReviewExchange(
            sessionID: sessionID,
            sourceRefs: [sourceID],
            attempt: MemoryAttempt(
                id: "failed-only-memory-attempt",
                memoryItemID: itemID,
                prompt: "Why should a grader failure leave this concept due?",
                learnerAnswer: "Because the app has no trustworthy grade.",
                gradeState: .failed,
                gradingError: "The configured grading model failed.",
                attemptedAt: Date()
            )
        )

        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0,
                summary: "Grading failed."
            )
            Issue.record("Expected failed-only memory evidence to leave the review open")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("recorded learner conversation"))
        }

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = '\(sourceID)'"
        ) == 0)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM memory_attempts WHERE id = 'failed-only-memory-attempt' AND grade_state = 'failed'"
        ) == 1)
    }

    @Test("Concurrent memory review and completion mutations serialize one shared connection")
    func concurrentMemoryReviewAndCompletionMutationsSerialize() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval must happen before feedback to expose accessible knowledge."
        try insertSource(
            dbPath: dbPath,
            id: "concurrent-source",
            title: "Concurrent retrieval",
            content: content
        )
        let knowledge = try store.knowledgeStore()
        let now = Date()
        try knowledge.saveMemoryItem(
            MemoryItem(
                id: "concurrent-memory-item",
                kind: .concept,
                target: "Explain retrieval before feedback.",
                rubricJSON: #"{"criteria":["Explains diagnostic effort"]}"#,
                sources: [
                    MemoryItemSource(
                        id: "concurrent-anchor",
                        memoryItemID: "concurrent-memory-item",
                        sourceID: "concurrent-source",
                        excerpt: content,
                        sourceSHA256: PaperContentPreparationService.sha256(content),
                        sortIndex: 0
                    )
                ],
                createdAt: now.addingTimeInterval(-10 * 86_400),
                updatedAt: now.addingTimeInterval(-10 * 86_400)
            )
        )
        // Reviewed once and due again, so every memory_review starts a session:
        // a never-reviewed item is new and never due.
        _ = try knowledge.recordMemoryAttempt(
            MemoryAttempt(
                id: "concurrent-memory-attempt",
                memoryItemID: "concurrent-memory-item",
                attemptType: .review,
                prompt: "Why retrieve before feedback?",
                learnerAnswer: "It shows what I can reach.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: now.addingTimeInterval(-9 * 86_400)
            )
        )

        let operationCount = 8
        for index in 0..<operationCount {
            try knowledge.createReviewSession(
                id: "concurrent-end-\(index)",
                topic: "Concurrent completion \(index)",
                sourceIDs: ["concurrent-source"],
                startedAt: now.addingTimeInterval(Double(index))
            )
        }

        // Widen the transaction overlap enough that the pre-gate implementation
        // deterministically issued nested BEGIN/ROLLBACK calls on the one cached
        // connection. With whole-tool mutation serialization, every call succeeds.
        try knowledge.exec("""
            CREATE TRIGGER slow_concurrent_session_insert
            BEFORE INSERT ON review_sessions
            BEGIN
                SELECT sum(value) FROM (
                    WITH RECURSIVE numbers(value) AS (
                        VALUES(0)
                        UNION ALL
                        SELECT value + 1 FROM numbers WHERE value < 30000
                    )
                    SELECT value FROM numbers
                );
            END
        """)
        try knowledge.exec("""
            CREATE TRIGGER slow_concurrent_session_complete
            BEFORE UPDATE OF status ON review_sessions
            WHEN NEW.status = 'completed'
            BEGIN
                SELECT sum(value) FROM (
                    WITH RECURSIVE numbers(value) AS (
                        VALUES(0)
                        UNION ALL
                        SELECT value + 1 FROM numbers WHERE value < 30000
                    )
                    SELECT value FROM numbers
                );
            END
        """)

        let registry = MCPToolRegistry(store: store)
        let successes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<operationCount {
                group.addTask {
                    let outcome = await registry.callToolDetailed(
                        name: "memory_review",
                        arguments: ["limit": 1, "start_session": true],
                        access: .internalFullAccess
                    )
                    return !outcome.isError && !outcome.text.contains("transaction within a transaction")
                }
                group.addTask {
                    let outcome = await registry.callToolDetailed(
                        name: "end_review_session",
                        arguments: [
                            "session_id": "concurrent-end-\(index)",
                            "overall_score": 0.8,
                            "summary": "Concurrent review completed.",
                            "transcript": "Tutor: Explain retrieval.\nLearner: Recall before feedback.",
                        ],
                        access: .internalFullAccess
                    )
                    return !outcome.isError && !outcome.text.contains("transaction within a transaction")
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(successes.count == operationCount * 2)
        #expect(successes.allSatisfy { $0 })
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id LIKE 'concurrent-end-%' AND status = 'completed'"
        ) == operationCount)
    }
}

#endif
