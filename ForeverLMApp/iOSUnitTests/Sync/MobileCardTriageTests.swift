import Foundation
import Testing
@testable import ForeverLM

/// Going through cards on the phone under generation 2 (docs/memory-design.md, "Cards to check on the
/// iPhone"; docs/cloudkit-schema-design.md §3.5.22): the drafts To Check offers are the replica's draft
/// Cards, in the Mac's order and by the Mac's rules; Keep writes the kept wording on the same Card, Skip
/// its status; a kept card's menu rewords it, holds it to its own words, retires it, takes a rewording
/// out or starts it over, each a patch on its Card.
@Suite("iPhone cards to check", .serialized)
struct MobileCardTriageTests {
    typealias Fixture = MobileWriterFixture
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let text = "Mitochondria couple respiration to ATP synthesis through a proton gradient across the inner membrane."

    static func draft(
        _ id: String,
        deck: String = "src1",
        front: String,
        back: String = "A proton gradient.",
        quote: String? = "a proton gradient across the inner membrane",
        seed: String? = nil,
        status: String = "draft",
        draftedAt: Date = now.addingTimeInterval(-86_400),
        rubric: String? = nil
    ) throws -> (String, SyncEnvelope) {
        var draft: [String: SyncJSON] = ["front": .string(front), "back": .string(back)]
        if let quote {
            draft["anchors"] = .array([.object(["target": .string("src:\(deck)"), "excerpt": .string(quote), "textHash": .string("h")])])
        }
        if let rubric { draft["rubric"] = .string(rubric) }
        var fields: [String: SyncJSON] = [
            "status": .string(status), "deckSourceID": .string(deck), "origin": .string("guide"),
            "draft": .object(draft), "draftedAt": SyncJSON(SyncTime.milliseconds(draftedAt)),
        ]
        if let seed { fields["seedKey"] = .string(seed) }
        return (Fixture.library, try MobileSyncFixture.envelope(.card, id, fields))
    }

    static func cards(_ replica: MobileReplica) async throws -> [MobileCardRecord] {
        try await replica.read { try MobileReadModels.draftDecks(in: $0) }
    }

    static func card(_ id: String, front: String = "What couples respiration to ATP synthesis?") -> MemoryCardToCheck {
        MemoryCardToCheck(
            kind: .draft,
            face: MemoryCard(cardID: id, front: front, back: "A proton gradient.", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "src1")),
            deckID: MemoryCard.draftDeckID(sourceID: "src1"),
            sourceID: "src1",
            quote: "a proton gradient across the inner membrane",
            seed: nil, ideaID: nil, draftedAt: now, isRequested: false, memoryItemID: nil
        )
    }

    // MARK: - Which cards wait

    @Test("A draft the Mac made carries the idea it was drafted from and the learner's request into To Check")
    func macDraftCarriesIdeaAndRequest() throws {
        let (_, envelope) = try Self.draft("card:src1:idea:abc", front: "What couples respiration to ATP synthesis?", seed: "idea:abc")
        var fields = envelope.fields
        var draft = try #require(fields["draft"]?.objectValue)
        draft["ideaID"] = "idea-7"
        draft["requested"] = true
        fields["draft"] = .object(draft)
        let record = MobileCardRecord(id: "card:src1:idea:abc", fields: fields)
        #expect(record.draftIdeaID == "idea-7" && record.draftRequested)
        let offered = try #require(MobileCardRecords.toCheck([record], availableSourceIDs: nil, now: Self.now).first)
        #expect(offered.ideaID == "idea-7" && offered.isRequested)
    }

    @Test("To Check offers the replica's draft Cards a source at a time, newest source first, by the Mac's rules")
    func draftsAreOffered() async throws {
        let replica = try await Fixture.replica(space: nil)
        let why = #"{"card":{"cardID":"d1","difficulty":"hard","front":"x","origin":"drafted"},"criteria":["Uncoupling stops ATP synthesis."]}"#
        try await Fixture.apply(replica, [
            try Self.draft("d1", front: "What couples respiration to ATP synthesis?", seed: "walk:src1#q1", rubric: why),
            try Self.draft("d2", front: "Where is the gradient?", seed: "walk:src1#q2", draftedAt: Self.now.addingTimeInterval(-3_600)),
            // A twin of d1's seed, kept on another device: d1 is gone through by seed, so not offered.
            try Self.draft("d3", deck: "src2", front: "Kept elsewhere?", seed: "s", status: "kept"),
            try Self.draft("d4", deck: "src2", front: "Same seed, drafted twice?", seed: "s"),
            // Skipped: never offered again.
            try Self.draft("d5", deck: "src2", front: "Skipped?", seed: "t", status: "skipped"),
            // Lapsed: drafted more than 14 days ago.
            try Self.draft("d6", deck: "src2", front: "Lapsed?", draftedAt: Self.now.addingTimeInterval(-15 * 86_400)),
            // No quote: cannot be kept, so not offered.
            try Self.draft("d7", deck: "src3", front: "Quotes nothing?", quote: nil),
            // A source this phone does not list waits until it does.
            try Self.draft("d8", deck: "src-elsewhere", front: "Not here?"),
            try Self.draft("d9", deck: "src3", front: "The newest deck?", draftedAt: Self.now.addingTimeInterval(-60)),
        ])
        let records = try await Self.cards(replica)
        let offered = MobileCardRecords.toCheck(records, availableSourceIDs: ["src1", "src2", "src3"], now: Self.now)
        #expect(offered.map(\.cardID) == ["d9", "d1", "d2"])
        let first = try #require(offered.first { $0.cardID == "d1" })
        #expect(first.kind == .draft)
        #expect(first.deckID == "carddeck-src1")
        #expect(first.sourceID == "src1")
        #expect(first.quote == "a proton gradient across the inner membrane")
        #expect(first.face.why == ["Uncoupling stops ATP synthesis."], "the why rides the draft's rubric")
        #expect(first.face.difficulty == .hard)
        #expect(MobileCardRecords.toCheck(records, availableSourceIDs: nil, now: Self.now).map(\.cardID).contains("d8"))
    }

    // MARK: - Keep and Skip

    @Test("Keep writes the kept wording on the draft's own Card, which reads back as a Memory item; the draft wording stays beside it")
    func keepWritesTheCard() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [try Self.draft("d1", front: "What couples respiration to ATP synthesis?", seed: "walk:src1#q1")])
        let writer = Fixture.writer(replica, at: Self.now)
        let outcome = await MobileCardTriageWriter.apply(
            [MemoryCardTriageDecision(card: Self.card("d1"), action: .keep)],
            writer: writer,
            sourceText: { $0 == "src1" ? Self.text : nil },
            at: Self.now
        )
        #expect(outcome.result.failed.isEmpty)
        #expect(outcome.result.kept == [MemoryCardTriageResult.Kept(cardID: "d1", memoryItemID: "d1")])
        let card = try #require(try await Fixture.held(replica, .card, "d1", in: Fixture.library))
        #expect(card.fields["status"] == .string("kept"))
        #expect(card.fields["kept"]?["front"] == .string("What couples respiration to ATP synthesis?"))
        #expect(card.fields["kept"]?["back"] == .string("A proton gradient."))
        #expect(card.fields["draft"]?["front"] == .string("What couples respiration to ATP synthesis?"), "the draft wording stays")
        #expect(card.fields["origin"] == .string("guide"), "an S field Keep leaves as drafted")
        let item = try #require(MobileMemoryRecords.item(fromCard: card.fields, id: "d1"))
        #expect(item.sources.first?.excerpt == "a proton gradient across the inner membrane")
        #expect(item.sources.first?.sourceSHA256 == MobileMnemonicReading.sha256(Self.text))
        #expect(MemoryCard(storedIn: item)?.deckID == "carddeck-src1")
        let memory = try await replica.read { try MobileReadModels.memory(in: $0) }
        #expect(memory.items.map(\.id) == ["d1"], "a kept draft is a card of Memory")
        #expect(try await Self.cards(replica).isEmpty, "no draft left, no deck read")
    }

    @Test("Edit, then Keep keeps the learner's words; a quote the source no longer prints leaves the card to check; Skip says skipped")
    func editRefuseAndSkip() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [
            try Self.draft("d1", front: "What couples respiration to ATP synthesis?"),
            try Self.draft("d2", front: "Where is the gradient?"),
            try Self.draft("d3", front: "Unprinted?"),
        ])
        let writer = Fixture.writer(replica, at: Self.now)
        let edit = MemoryCardEdit(front: "What links respiration to ATP?", back: "The proton gradient.", why: [])
        var unprinted = Self.card("d3", front: "Unprinted?")
        unprinted = MemoryCardToCheck(kind: .draft, face: unprinted.face, deckID: unprinted.deckID, sourceID: "src1",
                                      quote: "a passage the source does not print", seed: nil, ideaID: nil, draftedAt: Self.now,
                                      isRequested: false, memoryItemID: nil)
        let outcome = await MobileCardTriageWriter.apply(
            [
                MemoryCardTriageDecision(card: Self.card("d1"), action: .keepEdited(edit)),
                MemoryCardTriageDecision(card: Self.card("d2", front: "Where is the gradient?"), action: .skip),
                MemoryCardTriageDecision(card: unprinted, action: .keep),
            ],
            writer: writer,
            sourceText: { _ in Self.text },
            at: Self.now
        )
        #expect(outcome.result.kept.map(\.cardID) == ["d1"])
        #expect(outcome.result.skipped == ["d2"])
        #expect(outcome.result.failed.map(\.cardID) == ["d3"])
        #expect(outcome.result.failed.first?.reason == MobileCardRecords.Refusal.passageNotFound.localizedDescription)
        let kept = try #require(try await Fixture.held(replica, .card, "d1", in: Fixture.library))
        #expect(kept.fields["kept"]?["front"] == .string("What links respiration to ATP?"))
        #expect(kept.fields["draft"]?["front"] == .string("What couples respiration to ATP synthesis?"), "the before beside the after")
        let skipped = try #require(try await Fixture.held(replica, .card, "d2", in: Fixture.library))
        #expect(skipped.fields["status"] == .string("skipped"))
        #expect(skipped.fields["skippedAt"] == SyncJSON(SyncTime.milliseconds(Self.now)))
        #expect(try await Fixture.held(replica, .card, "d3", in: Fixture.library)?.fields["status"] == .string("draft"))
        #expect(try await Self.cards(replica).filter(\.isDraft).map(\.id) == ["d3"])

        let noText = await MobileCardTriageWriter.apply([MemoryCardTriageDecision(card: Self.card("d3", front: "Unprinted?"), action: .keep)],
                                                        writer: writer, sourceText: { _ in nil }, at: Self.now)
        #expect(noText.result.failed.first?.reason == MobileCardRecords.Refusal.noText.localizedDescription)
    }

    @Test("A Keep another device made first stands; a skipped card kept elsewhere stays kept; a retired card is never kept again")
    func keepRaces() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [try Self.draft("d1", front: "What couples respiration to ATP synthesis?")])
        let writer = Fixture.writer(replica, at: Self.now)
        let text = Self.text
        let face = Self.card("d1").face
        let first = try MobileCardRecords.keptItem(Self.card("d1"), face: face, sourceText: text, at: Self.now)
        #expect(try await writer.transaction { try $0.keepDraftCard(first) } == .kept)
        let other = MemoryCard(cardID: "d1", front: "Other words?", back: "A gradient.", origin: .drafted, deckID: "carddeck-src1")
        let second = try MobileCardRecords.keptItem(Self.card("d1"), face: other, sourceText: text, at: Self.now)
        guard case .keptElsewhere(let held) = try await writer.transaction({ try $0.keepDraftCard(second) }) else {
            Issue.record("the first Keep stands")
            return
        }
        #expect(held.target == "A proton gradient.")
        try await writer.transaction { try $0.skipDraftCard("d1") }
        #expect(try await Fixture.held(replica, .card, "d1", in: Fixture.library)?.fields["status"] == .string("kept"), "a kept card is not skipped")
        try await writer.transaction { try $0.retireCard("d1") }
        #expect(try await Fixture.held(replica, .card, "d1", in: Fixture.library)?.fields["status"] == .string("retired"))
        try await Fixture.apply(replica, [try Self.draft("d2", front: "Retired?", status: "retired")])
        let retired = try MobileCardRecords.keptItem(Self.card("d2", front: "Retired?"), face: Self.card("d2", front: "Retired?").face,
                                                     sourceText: text, at: Self.now)
        await #expect(throws: MobileCardRecords.Refusal.gone) { try await writer.transaction { try $0.keepDraftCard(retired) } }
    }

    // MARK: - A kept card

    @Test("A kept card's menu writes its Card: a rewording and taking it back, always ask, a rewording taken out, Start Over and Retire")
    func keptCardChanges() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [try Self.draft("d1", front: "What couples respiration to ATP synthesis?")])
        let writer = Fixture.writer(replica, at: Self.now)
        let item = try MobileCardRecords.keptItem(Self.card("d1"), face: Self.card("d1").face, sourceText: Self.text, at: Self.now)
        _ = try await writer.transaction { try $0.keepDraftCard(item) }

        try await writer.transaction { try $0.rewordCard("d1", front: "In my words?") }
        var record = MobileCardRecord(id: "d1", fields: try #require(try await Fixture.held(replica, .card, "d1", in: Fixture.library)).fields)
        #expect(record.editedFront == "In my words?")
        #expect(record.state.editedFront == "In my words?")
        try await writer.transaction { try $0.rewordCard("d1", front: nil) }
        record = MobileCardRecord(id: "d1", fields: try #require(try await Fixture.held(replica, .card, "d1", in: Fixture.library)).fields)
        #expect(record.editedFront == nil, "the front it was kept with takes the rewording back")

        try await writer.transaction { try $0.setCardAlwaysAsk("d1", true) }
        try await writer.transaction { try $0.retireCardVariant("d1", text: "Another angle?") }
        record = MobileCardRecord(id: "d1", fields: try #require(try await Fixture.held(replica, .card, "d1", in: Fixture.library)).fields)
        #expect(record.alwaysAsk)
        #expect(record.state.retiredVariants == ["Another angle?"])
        #expect(record.variants.first?.key == MobileCardRecords.variantKey("Another angle?"), "keyed by the hash of its words, as the Mac keys it")

        let face = MemoryCard(cardID: "rev-1", front: "What couples respiration to ATP synthesis?", back: "The proton-motive force.",
                              origin: .drafted, deckID: "carddeck-src1")
        let revision = try MobileCardRecords.revision(of: item, as: face, texts: ["src1": Self.text], at: Self.now)
        try await writer.transaction { try $0.startCardOver("d1", as: revision) }
        let old = try #require(try await Fixture.held(replica, .card, "d1", in: Fixture.library))
        #expect(old.fields["status"] == .string("retired"))
        let new = try #require(try await Fixture.held(replica, .card, "rev-1", in: Fixture.library))
        #expect(new.fields["status"] == .string("kept"))
        #expect(new.fields["supersedes"] == .string("d1"))
        #expect(new.fields["deckSourceID"] == .string("src1"))
        #expect(new.fields["alwaysAsk"] == .bool(true), "always ask goes with it")
        #expect(new.fields["kept"]?["back"] == .string("The proton-motive force."))
        #expect(MobileMemoryRecords.item(fromCard: new.fields, id: "rev-1")?.sources.first?.excerpt == "a proton gradient across the inner membrane")
        #expect(throws: MobileCardRecords.Refusal.passageNotFound) {
            try MobileCardRecords.revision(of: item, as: face, texts: ["src1": "A different text."], at: Self.now)
        }
        #expect(throws: MobileCardRecords.Refusal.noText) {
            try MobileCardRecords.revision(of: item, as: face, texts: [:], at: Self.now)
        }
    }

    @Test("A sitting's card is worded by its Card: the rewordings, the learner's front and always ask reach the Mac's wording rule")
    func sittingWordingFromCards() throws {
        let face = MemoryCard(cardID: "d1", front: "Q?", back: "A.", origin: .drafted, deckID: "carddeck-src1")
        let item = try face.memoryItem(
            id: "d1",
            anchors: [MemorySourceAnchorValidation(sourceID: "src1", excerpt: "a proton gradient", sourceSHA256: "h")],
            at: Self.now.addingTimeInterval(-30 * 86_400)
        )
        let remembered = (0..<2).map {
            MemoryAttempt.selfGraded(id: "a\($0)", memoryItemID: "d1", prompt: "Q?", remembered: true,
                                     at: Self.now.addingTimeInterval(Double($0 - 20) * 86_400))
        }
        let entry = MemoryCardQueue.Entry(item: item, schedule: MemoryTutorScheduler.schedule(item: item, attempts: remembered),
                                          bucket: .due, notebookID: nil, daysOverdue: 0)
        let record = MobileCardRecord(id: "d1", fields: [
            "status": .string("kept"),
            "variants": .object([
                MobileCardRecords.variantKey("Another angle?"): .object(["text": .string("Another angle?"), "madeAt": SyncJSON(1), "retired": .bool(false)]),
            ]),
        ])
        let states = MobileCardRecords.deckStates([entry], attemptsByItemID: ["d1": remembered], records: ["d1": record])
        let cards = MobileCardReviewDealing.sittingCards([entry], attemptsByItemID: ["d1": remembered], states: states)
        #expect(cards.first?.prompt == "Another angle?")
        #expect(cards.first?.isVariant == true)
        #expect(cards.first?.variantIndex == 0)
        var heldFields: [String: SyncJSON] = ["status": .string("kept"), "alwaysAsk": .bool(true)]
        heldFields["variants"] = .object([
            MobileCardRecords.variantKey("Another angle?"): .object(["text": .string("Another angle?"), "madeAt": SyncJSON(1)]),
        ])
        let held = MobileCardRecord(id: "d1", fields: heldFields)
        let asked = MobileCardReviewDealing.sittingCards([entry], attemptsByItemID: ["d1": remembered],
                                                         states: MobileCardRecords.deckStates([entry], attemptsByItemID: ["d1": remembered], records: ["d1": held]))
        #expect(asked.first?.prompt == "Q?", "always ask it this way")
        #expect(asked.first?.alwaysAsk == true)
    }

    @Test("This asks something else is once a sitting and wording, by the Mac's id")
    func askedSomethingElseID() {
        #expect(MobileCardEditWriter.askedSomethingElseAttemptID(sessionKey: "cards-2027-01-15-tok", memoryItemID: "card-a", prompt: "Another angle?")
            == "memory-asked-else-v1-e733a5cf127a93cef9418d2b2883daee195e04e33207fb38dfdedb1f22ce6e86")
    }

    @Test("A kept card's edit rewords it when only the front changed, and starts it over when its answer did")
    func editRules() throws {
        let face = MemoryCard(cardID: "c1", front: "Q?", back: "A.", why: ["Because."], origin: .drafted)
        let listing = MemoryCardListing(itemID: "c1", face: face, sourceIDs: ["src1"],
                                        schedule: MemoryTutorScheduler.schedule(item: try face.memoryItem(
                                            id: "c1", anchors: [MemorySourceAnchorValidation(sourceID: "src1", excerpt: "x", sourceSHA256: "h")], at: Self.now
                                        ), attempts: []))
        #expect(!MobileCardEditWriter.startsOver(listing, MemoryCardEdit(front: "New Q?", back: "A.", why: ["Because."])))
        #expect(MobileCardEditWriter.startsOver(listing, MemoryCardEdit(front: "Q?", back: "B.", why: ["Because."])))
        #expect(MobileCardEditWriter.startsOver(listing, MemoryCardEdit(front: "Q?", back: "A.", why: [])))
        #expect(try MobileCardEditWriter.rewording(listing, front: " New Q? ", wording: "Q?") == "New Q?")
        #expect(try MobileCardEditWriter.rewording(listing, front: "Q?", wording: "Mine?") == nil, "back to the kept front")
        #expect(throws: MobileCardEditWriter.Refusal.unchanged) { try MobileCardEditWriter.rewording(listing, front: "Mine?", wording: "Mine?") }
        let legacy = MemoryCardListing(itemID: "c2", face: MemoryCard(cardID: "c2", front: "Q?", back: "A.", origin: .legacy),
                                       sourceIDs: ["src1"], schedule: listing.schedule)
        #expect(MobileCardEditWriter.revisedFace(legacy, edit: nil, wording: "Mine?", newID: "n").origin == .walkthrough)
        #expect(MobileCardEditWriter.revisedFace(legacy, edit: nil, wording: "Mine?", newID: "n").front == "Mine?")
    }
}
