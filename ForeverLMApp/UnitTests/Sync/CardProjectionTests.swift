import Foundation
import Testing
@testable import ForeverLM

/// The Card record (docs/cloudkit-schema-design.md §3.5.22): the kept wording is S and never re-worded by
/// this Mac, a losing Keep becomes a card of its own (`splitFrom`) through `onServerFirstLoss`, retired
/// is terminal, and a deck's state row becomes its cards' states (the drafts: `CardRecordLifecycleTests`).
@Suite("Card projection")
struct CardProjectionTests {
    private typealias F = MemorySyncFixture

    private static let faceRubric = #"{"card":{"cardID":"c-1","front":"How many protons does Complex I pump?","origin":"drafted"},"criteria":["four"]}"#

    @Test("A card kept here goes out with its wording once, and is never re-worded after")
    func keptWordingIsSentOnce() throws {
        let (root, store) = try F.makeStore("card-kept")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.item(store, id: "card-1", rubric: Self.faceRubric)
        let fields = try #require(F.fields(try F.pending(store)["Card:card-1"]))
        #expect(fields["status"] == "kept" && fields["deckSourceID"] == "src-1" && fields["origin"] == "guide")
        let kept = try #require(fields["kept"])
        #expect(kept["front"] == "How many protons does Complex I pump?" && kept["back"] == "Four protons per NADH")
        #expect(kept["rubric"] == .string(Self.faceRubric) && kept["anchors"]?.arrayValue?.first?["target"] == "src:src-1")
        let item = try #require(try CardProjection.loadRows(id: "card-1", connection: store)?.item)
        #expect(kept["fingerprint"] == .string(MemoryTutorIdentity.immutableCurriculumFingerprint(item)))
        #expect(fields["legacy"]?["target"] == "Four protons per NADH" && fields["keptAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 700_000_000)))

        try F.sendAll(store)
        try store.execute("INSERT INTO memory_card_states (card_id, status, always_ask) VALUES ('card-1', 'kept', 1)")
        let next = try #require(try F.pending(store)["Card:card-1"])
        #expect(F.changed(next) == ["alwaysAsk"], "kept wording equals what the server holds: never sent again")
        #expect(F.fields(next)?["alwaysAsk"] == true)
    }

    @Test("A card kept against a team's copy names the work by its wire id, so every device resolves it")
    func teamCopyAnchorsUseTheWireID() throws {
        let (root, store) = try F.makeStore("card-team-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        try NotebookSyncFixture.addSource(store, "src-p")
        try NotebookSyncFixture.addTeamCopy(store, "team-copy", of: "src-p")
        try F.item(store, id: "card-t", sourceID: "team-copy", rubric: Self.faceRubric)
        let fields = try #require(F.fields(try F.pending(store)["Card:card-t"]))
        #expect(fields["deckSourceID"] == "src-p", "the deck is the work, not this Mac's copy")
        #expect(fields["kept"]?["anchors"]?.arrayValue?.first?["target"] == "src:src-p")
        // The fingerprint still covers the anchors as this Mac holds them: the tutor's attempts match it.
        let item = try #require(try CardProjection.loadRows(id: "card-t", connection: store)?.item)
        #expect(fields["kept"]?["fingerprint"] == .string(MemoryTutorIdentity.immutableCurriculumFingerprint(item)))
    }

    @Test("A card kept on another device lands as a Memory item and goes back exactly as it came")
    func keptElsewhere() throws {
        let (root, store) = try F.makeStore("card-web")
        defer { try? FileManager.default.removeItem(at: root) }
        // As the web's saveMemoryItem writes one: the target as the front, no back, the anchors without ids.
        let kept: SyncJSON = [
            "front": "Supercomplexes stabilize respiration", "back": "", "rubric": "{}",
            "anchors": [["target": "src:src-7", "locator": .null, "excerpt": "respirasomes", "textHash": "h7"]],
            "fingerprint": "memory-curriculum-v1-web", "at": 1_759_000_000_000,
        ]
        try F.apply(store, [try F.record(.card, "card-web", [
            "status": "kept", "deckSourceID": "src-7", "origin": "concept", "kept": kept, "keptAt": 1_759_000_000_000,
            "legacy": ["kind": "concept", "target": "Supercomplexes stabilize respiration", "learnerContext": .null, "goalID": .null, "ideaID": .null],
        ])])
        #expect(try F.text(store, "SELECT target || '|' || kind || '|' || status FROM memory_items WHERE id = 'card-web'") == "Supercomplexes stabilize respiration|concept|active")
        #expect(try F.text(store, "SELECT id || '|' || source_id || '|' || sort_index FROM memory_item_sources WHERE memory_item_id = 'card-web'") == "card-web#anchor-0|src-7|0")
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_schedules WHERE memory_item_id = 'card-web'") == 1, "it is scheduled like any card")

        // A later change here re-encodes the card; its kept wording is the replica's, so it is not sent.
        try store.execute("UPDATE memory_card_states SET always_ask = 1 WHERE card_id = 'card-web'")
        let change = try #require(try F.pending(store)["Card:card-web"])
        #expect(F.changed(change) == ["alwaysAsk"], "\(F.changed(change).sorted())")
    }

    @Test("A Keep that lost to another device's different Keep becomes a card of its own that splitFrom it")
    func losingKeepSplits() throws {
        let (root, store) = try F.makeStore("card-split")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.item(store, id: "card-1", target: "My own words", rubric: Self.faceRubric)
        #expect(try F.pending(store)["Card:card-1"] != nil, "this Mac's Keep is waiting to go out")

        // The server already holds another device's Keep of card-1, other wording, other fingerprint.
        let theirs: SyncJSON = ["front": "Their front", "back": "Their words", "rubric": "{}", "anchors": [], "fingerprint": "theirs", "at": 1_759_000_000_000]
        let payload = try SourceSyncFixture.payload(.card, "card-1", [
            "status": "kept", "deckSourceID": "src-1", "origin": "guide", "kept": theirs, "keptAt": 1_759_000_000_000,
        ])
        let record = CloudRecord(
            id: CloudRecordID(RecordNaming.recordName(type: .card, id: "card-1", salt: OutboxTestProjections.salt), in: PrivateSyncZones.library),
            recordType: SyncRecordType.card.rawValue, encryptedFields: [CloudRecord.payloadKey: .bytes(payload)]
        )
        let state = MacPrivateSyncStore.State(store: store, registry: F.registry)
        try store.replica.apply { _ in
            _ = try InboundApply(state: state, now: Date().addingTimeInterval(60), passStart: nil, moveMaps: MoveMapIndex())
                .absorb(record, zoneKey: F.libraryZoneKey)
        }

        let splitID = try #require(try F.text(store, "SELECT card_id FROM memory_card_states WHERE split_from = 'card-1'"))
        #expect(splitID.hasPrefix("card:src-1:split:card-1:"))
        #expect(try F.text(store, "SELECT target || '|' || rubric_json FROM memory_items WHERE id = ?", [.text(splitID)]) == "My own words|\(Self.faceRubric)",
                "nothing the learner kept is lost")
        let fields = try #require(F.fields(try F.pending(store)["Card:\(splitID)"]), "the new card goes out")
        #expect(fields["splitFrom"] == "card-1" && fields["status"] == "kept" && fields["kept"]?["back"] == "My own words")
        #expect(try F.text(store, "SELECT target FROM memory_items WHERE id = 'card-1'") == "Their words",
                "card-1 is the first acknowledged Keep everywhere; this Mac's wording is the split card's")

        // The same conflict merged again makes no second card.
        try store.replica.apply { _ in
            _ = try InboundApply(state: state, now: Date().addingTimeInterval(60), passStart: nil, moveMaps: MoveMapIndex())
                .absorb(record, zoneKey: F.libraryZoneKey)
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_card_states WHERE split_from = 'card-1'") == 1)
    }

    @Test("Retired is terminal: an older Keep never brings a card back, and no change out of retired is sent")
    func retiredIsTerminal() throws {
        let (root, store) = try F.makeStore("card-retired")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.item(store, id: "card-1", rubric: Self.faceRubric)
        try F.sendAll(store)
        try store.execute("UPDATE memory_items SET status = 'retired', updated_at = 700000500 WHERE id = 'card-1'")
        let retire = try #require(F.fields(try F.pending(store)["Card:card-1"]))
        #expect(retire["status"] == "retired" && retire["retiredAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 700_000_500)))
        try F.sendAll(store)

        // A local write out of retired is never sent: the codec refuses the transition and its rows go.
        try store.execute("UPDATE memory_items SET status = 'active' WHERE id = 'card-1'")
        let batch = try OutboxFeeder(connection: store, registry: F.registry).nextBatch(now: Date().addingTimeInterval(600))
        #expect(!batch.contains { $0.wireID == "card-1" })
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'memory_items'") == 0)

        // An older record that still says kept: the item stays retired.
        try store.execute("UPDATE memory_items SET status = 'retired' WHERE id = 'card-1'")
        try F.apply(store, [try F.record(.card, "card-1", ["status": "kept", "deckSourceID": "src-1", "origin": "guide"])])
        #expect(try F.text(store, "SELECT status FROM memory_items WHERE id = 'card-1'") == "retired")
        #expect(try F.text(store, "SELECT status FROM memory_card_states WHERE card_id = 'card-1'") == "retired")
    }

    @Test("A deck's state row becomes its kept and skipped cards' states; a draft's state waits for its deck's wording")
    func deckStateRows() throws {
        let (root, store) = try F.makeStore("card-deck")
        defer { try? FileManager.default.removeItem(at: root) }
        var deck = MemoryCardDeckState()
        let at = Date(timeIntervalSince1970: 1_759_000_000)
        deck.cards["c-kept"] = MemoryCardState(status: .kept, memoryItemID: "item-k", editedFront: "Ask it this way", variants: ["Rephrased"],
                                              retiredVariants: ["Old wording"], alwaysAsk: true, seed: "walk:src-1#q3", updatedAt: at)
        deck.cards["c-skip"] = MemoryCardState(status: .skipped, seed: "hl:h-9", updatedAt: at)
        deck.cards["c-draft"] = MemoryCardState(status: .draft, seed: "idea:i-1", updatedAt: at)
        try F.preference(store, key: MemoryCardDeckState.preferenceKey(deckID: "carddeck-src-1"), value: deck.preferenceValue)
        try store.deriveCardStates()

        #expect(try F.text(store, "SELECT status || '|' || deck_source_id || '|' || seed_key || '|' || always_ask FROM memory_card_states WHERE card_id = 'item-k'")
                == "kept|src-1|walk:src-1#q3|1")
        let variants = try SyncJSON(parsing: Data((try F.text(store, "SELECT variants_json FROM memory_card_states WHERE card_id = 'item-k'") ?? "").utf8))
        #expect(variants[KnowledgeStore.variantKey("Rephrased")]?["retired"] == false && variants[KnowledgeStore.variantKey("Old wording")]?["retired"] == true)
        #expect(variants["front"]?["text"] == "Ask it this way")
        #expect(try F.text(store, "SELECT status FROM memory_card_states WHERE card_id = ?", [.text(SyncIdentity.cardDraftID(deckSourceID: "src-1", seedKey: "hl:h-9"))]) == "skipped")
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_card_states") == 2, "a draft is a Card from its deck's wording (deriveCardDrafts)")
        // Run again: one result.
        let before = try F.text(store, "SELECT group_concat(card_id || status || variants_json, ';') FROM memory_card_states")
        try store.deriveCardStates()
        #expect(try F.text(store, "SELECT group_concat(card_id || status || variants_json, ';') FROM memory_card_states") == before)
    }
}
