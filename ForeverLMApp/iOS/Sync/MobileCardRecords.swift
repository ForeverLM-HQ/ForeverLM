import Foundation

// Cards on the phone under generation 2 (docs/memory-design.md, "Cards to check on the iPhone";
// docs/cloudkit-schema-design.md §3.5.22). A drafted card is a `Card` whose status is `draft`: its draft
// wording (`draft`: front, back, the rubric that carries its why and pictures, and the
// anchors it stands on) is editable until Keep, and its deck is the source it was drafted from
// (`deckSourceID`). Keep writes the kept wording on the same record (`kept`, S: the first Keep stands)
// and the status `kept`; Skip writes `skipped`; Retire `retired`, which nothing turns back. What the
// learner changes about a kept card lives on its Card too: "always ask it this way" (`alwaysAsk`), a
// new front (the variant `front`), a rewording taken out (its variant `retired`), and starting it over,
// which retires it and keeps a new Card that `supersedes` it. The Card is the generation-1 deck row's
// successor (§10, `cards.state.*` → Card), so the phone reads and writes no deck row.

/// One Card record as the phone reads it.
struct MobileCardRecord: Equatable, Sendable {
    struct Anchor: Equatable, Sendable {
        let sourceID: String
        let excerpt: String
    }

    struct Variant: Equatable, Sendable {
        let key: String
        let text: String
        let madeAt: Int64
        let retired: Bool
    }

    /// The variant key a learner's own front is kept under (the Mac's `mirrorCardDeckState`).
    static let frontVariantKey = "front"

    let id: String
    /// `draft`, `kept`, `skipped` or `retired`.
    let status: String
    let deckSourceID: String?
    /// `Card.origin`'s wire value.
    let origin: String?
    let seedKey: String?
    let draftFront: String?
    let draftBack: String?
    /// The rubric the draft would be kept with, as a Memory item's `rubricJSON`.
    let draftRubric: String?
    let draftAnchors: [Anchor]
    /// The source idea the draft was drafted from, which its kept item records (the Mac's drafts carry it).
    let draftIdeaID: String?
    /// The learner asked for the draft (the Mac's Make Cards): kept by default where ticks are offered.
    let draftRequested: Bool
    /// The wording a kept card was kept with: what a sibling draft of the same front is checked against.
    let keptFront: String?
    let draftedAt: Date?
    let alwaysAsk: Bool
    let variants: [Variant]
    let editedAt: Date?

    init(id: String, fields: [String: SyncJSON]) {
        self.id = id
        status = fields["status"]?.stringValue ?? "draft"
        deckSourceID = Self.clean(fields["deckSourceID"])
        origin = Self.clean(fields["origin"])
        seedKey = Self.clean(fields["seedKey"])
        let draft = fields["draft"]?.objectValue ?? [:]
        draftFront = Self.clean(draft["front"])
        draftBack = Self.clean(draft["back"])
        draftRubric = Self.clean(draft["rubric"])
        draftAnchors = (draft["anchors"]?.arrayValue ?? []).compactMap { anchor in
            guard let object = anchor.objectValue,
                  let excerpt = Self.clean(object["excerpt"]) else { return nil }
            let target = object["target"]?.stringValue ?? ""
            let sourceID = target.hasPrefix("src:") ? String(target.dropFirst(4)).components(separatedBy: "#")[0] : target
            return Anchor(sourceID: sourceID, excerpt: excerpt)
        }
        draftIdeaID = Self.clean(draft["ideaID"])
        draftRequested = draft["requested"]?.boolValue ?? false
        keptFront = Self.clean(fields["kept"]?["front"])
        draftedAt = fields["draftedAt"]?.int64Value.map(SyncTime.date(milliseconds:))
        alwaysAsk = fields["alwaysAsk"]?.boolValue ?? false
        variants = (fields["variants"]?.objectValue ?? [:]).compactMap { key, value in
            guard let object = value.objectValue, let text = Self.clean(object["text"]) else { return nil }
            return Variant(key: key, text: text, madeAt: object["madeAt"]?.int64Value ?? 0, retired: object["retired"]?.boolValue ?? false)
        }
        .sorted { ($0.madeAt, $0.key) < ($1.madeAt, $1.key) }
        editedAt = fields["editedAt"]?.int64Value.map(SyncTime.date(milliseconds:))
    }

    var isDraft: Bool { status == "draft" }

    /// The learner's own front, when they reworded the card and have not taken it back.
    var editedFront: String? {
        variants.first { $0.key == Self.frontVariantKey && !$0.retired }?.text
    }

    /// The card's state as the card review words it (`MemoryCardWording`): its rewording, its rewordings
    /// in the order they were made and those taken out, and "always ask it this way".
    var state: MemoryCardState {
        let rewordings = variants.filter { $0.key != Self.frontVariantKey }
        return MemoryCardState(
            status: status == "skipped" ? .skipped : (status == "draft" ? .draft : .kept),
            memoryItemID: isDraft || status == "skipped" ? nil : id,
            editedFront: editedFront,
            variants: rewordings.filter { !$0.retired }.map(\.text),
            retiredVariants: rewordings.filter(\.retired).map(\.text),
            alwaysAsk: alwaysAsk,
            seed: seedKey,
            updatedAt: editedAt ?? Date(timeIntervalSince1970: 0)
        )
    }

    /// The draft as the card it would be kept as, under the Card's own id: its front and back, the why
    /// and pictures its rubric carries, and who drafted it. Nil when the draft has no front or
    /// no back.
    var draftFace: MemoryCard? {
        guard let front = draftFront, let back = draftBack, let deckSourceID else { return nil }
        let rubric = draftRubric.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        let card = rubric[MemoryCard.cardKey] as? [String: Any] ?? [:]
        let why = (rubric[MemoryCard.criteriaKey] as? [String]) ?? []
        let face = MemoryCard(
            cardID: id,
            front: front,
            back: back,
            why: why,
            origin: (card[MemoryCard.originKey] as? String).map(MemoryCardOrigin.init(rawValue:)) ?? Self.faceOrigin(of: origin),
            deckID: MemoryCard.draftDeckID(sourceID: deckSourceID),
            frontImages: MemoryCardImage.readRubric(card[MemoryCard.frontImagesKey]),
            backImages: MemoryCardImage.readRubric(card[MemoryCard.backImagesKey])
        )
        return face.front.isEmpty || face.back.isEmpty ? nil : face
    }

    /// The origin a kept card's face records for a draft whose rubric names none: an assistant's and a
    /// course quiz's keep theirs; every other draft is ForeverLM's.
    static func faceOrigin(of wire: String?) -> MemoryCardOrigin {
        switch wire {
        case "assistant": return .assistant
        case "courseQuiz": return .courseQuiz
        default: return .drafted
        }
    }

    private static func clean(_ value: SyncJSON?) -> String? {
        guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

// MARK: - Which cards wait

enum MobileCardRecords {
    /// The cards to check among `records`, in To Check's order (`MemoryCardTriage.toCheck`, the Mac's
    /// rules): a deck is a draft's source, its cards in the order they were drafted; a card gone through
    /// (kept, skipped or retired) holds its seed and front, so a twin drafted before the devices synced
    /// is not offered; a draft whose source the phone does
    /// not list (`availableSourceIDs`) waits until it does.
    static func toCheck(_ records: [MobileCardRecord], availableSourceIDs: Set<String>?, now: Date) -> [MemoryCardToCheck] {
        var bySource: [String: [MobileCardRecord]] = [:]
        for record in records {
            guard let deck = record.deckSourceID else { continue }
            bySource[deck, default: []].append(record)
        }
        var decks: [MemoryCardDraftDeck] = []
        var states: [String: MemoryCardDeckState] = [:]
        for (sourceID, cards) in bySource {
            guard cards.contains(where: \.isDraft), availableSourceIDs?.contains(sourceID) ?? true else { continue }
            let deckID = MemoryCard.draftDeckID(sourceID: sourceID)
            var deckState = MemoryCardDeckState()
            var flashcards: [Flashcard] = []
            let ordered = cards.sorted {
                ($0.draftedAt ?? .distantPast, $0.id) < ($1.draftedAt ?? .distantPast, $1.id)
            }
            for card in ordered {
                if !card.isDraft {
                    deckState.cards[card.id] = MemoryCardState(
                        status: card.status == "skipped" ? .skipped : .kept,
                        memoryItemID: card.status == "skipped" ? nil : card.id,
                        seed: card.seedKey,
                        updatedAt: card.editedAt ?? now
                    )
                }
                guard let front = card.draftFront ?? card.keptFront else { continue }
                let face = card.draftFace
                flashcards.append(Flashcard(
                    id: card.id,
                    front: front,
                    back: card.draftBack ?? "",
                    why: face?.why.first,
                    sourceID: sourceID,
                    quote: card.draftAnchors.first?.excerpt,
                    seed: card.seedKey,
                    ideaID: card.draftIdeaID,
                    draftedAt: card.draftedAt,
                    origin: face?.origin ?? MobileCardRecord.faceOrigin(of: card.origin),
                    isRequested: card.draftRequested,
                    frontImages: face?.frontImages ?? [],
                    backImages: face?.backImages ?? [],
                    // The anchors after the first are the other sources the draft also stands on.
                    alsoFrom: card.draftAnchors.dropFirst().map { CardSourceLink(sourceID: $0.sourceID, quote: $0.excerpt) }
                ))
            }
            decks.append(MemoryCardDraftDeck(deckID: deckID, sourceID: sourceID, deck: FlashcardDeck(title: "", cards: flashcards)))
            states[deckID] = deckState
        }
        let faces = Dictionary(records.compactMap { record in record.draftFace.map { (record.id, $0) } }, uniquingKeysWith: { first, _ in first })
        return MemoryCardTriage.toCheck(
            decks: decks,
            deckStates: states,
            itemIDs: []
        )
        // The deck's Flashcard keeps one line of why; the draft's own face keeps them all.
        .map { card in
            guard let face = faces[card.cardID] else { return card }
            return MemoryCardToCheck(
                kind: card.kind, face: face, deckID: card.deckID, sourceID: card.sourceID, quote: card.quote, seed: card.seed,
                ideaID: card.ideaID, draftedAt: card.draftedAt, isRequested: card.isRequested, memoryItemID: card.memoryItemID,
                alsoFrom: card.alsoFrom
            )
        }
    }

    /// Each kept card's state by its item's id, as its deck's row held it under generation 1
    /// (`MemoryCardDeckState`): what words a sitting's cards (`MobileCardReviewDealing.sittingCards`).
    /// A card with no face, or none of whose records the phone holds, is left out.
    static func deckStates(
        _ entries: [MemoryCardQueue.Entry],
        attemptsByItemID: [String: [MemoryAttempt]],
        records: [String: MobileCardRecord]
    ) -> [String: MemoryCardDeckState] {
        var states: [String: MemoryCardDeckState] = [:]
        for entry in entries {
            guard let record = records[entry.item.id],
                  let face = MemoryCard.face(of: entry.item, attempts: attemptsByItemID[entry.id] ?? []),
                  let deckID = face.stateDeckID(in: entry.item) else { continue }
            states[deckID, default: MemoryCardDeckState()].cards[face.cardID] = record.state
        }
        return states
    }

    // MARK: Keeping a draft

    /// Why a draft or a card was not kept, in words for the learner.
    enum Refusal: LocalizedError, Equatable {
        case noFace
        case noQuote
        case noText
        case passageNotFound
        case gone

        var errorDescription: String? {
            switch self {
            case .noFace: return "A card needs a front and a back to be kept."
            case .noQuote: return "This card quotes no passage of its source, so it cannot be kept."
            case .noText: return "Its source's text is not on this iPhone yet."
            case .passageNotFound: return "Its source no longer prints the passage it quotes."
            case .gone: return "This card is no longer on this iPhone."
            }
        }
    }

    /// The Memory item Keep makes of a draft, under the Card's own id: `face` (the draft's, or the
    /// learner's edit), anchored on its quote, which `sourceText` must print — the check the Mac's Keep
    /// makes (`validatedMemorySourceAnchor`). No goal (a notebook reaches a card through its sources), the
    /// idea it was drafted from.
    ///
    /// The card is anchored on every source it stands on, its own first (`alsoFrom`, each printed by its own
    /// source's text in `linkTexts`): another device keeping the same card must write the same anchors, or
    /// the two items disagree on the card's curriculum, so a linked source whose text is not on the phone
    /// refuses the keep rather than leaving its anchor off.
    static func keptItem(
        _ card: MemoryCardToCheck,
        face: MemoryCard,
        sourceText: String?,
        alsoFrom: [CardSourceLink]? = nil,
        linkTexts: [String: String] = [:],
        at now: Date
    ) throws -> MemoryItem {
        guard let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { throw Refusal.noQuote }
        var anchors = [try anchor(sourceID: card.sourceID, excerpt: quote, sourceText: sourceText)]
        for link in CardSourceLink.normalized(alsoFrom ?? card.alsoFrom, excluding: CardSourceLink(sourceID: card.sourceID, quote: quote)) {
            anchors.append(try anchor(sourceID: link.sourceID, excerpt: link.quote, sourceText: linkTexts[link.sourceID]))
        }
        do {
            return try face.memoryItem(id: card.cardID, anchors: anchors, goalID: nil, ideaID: card.ideaID, at: now)
        } catch {
            throw Refusal.noFace
        }
    }

    /// `excerpt` as an anchor on `sourceID`, when `sourceText` prints it (`MemoryGroundingText`).
    static func anchor(sourceID: String, excerpt: String, sourceText: String?) throws -> MemorySourceAnchorValidation {
        guard let sourceText, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.noText }
        guard MemoryGroundingText(sourceText).contains(excerpt) else { throw Refusal.passageNotFound }
        return MemorySourceAnchorValidation(sourceID: sourceID, excerpt: excerpt, sourceSHA256: MobileMnemonicReading.sha256(sourceText))
    }

    // MARK: Starting a kept card over

    /// "Start this card over?" (`KnowledgeStore.startMemoryCardOver`): the revision, under a new card id,
    /// kept on the old item's passages that the sources still print (`texts`, by source), with the old
    /// item's goal and idea; first asked the day after. Throws when no passage is printed any more.
    static func revision(of old: MemoryItem, as face: MemoryCard, texts: [String: String], at now: Date) throws -> MemoryItem {
        let anchors = old.sources
            .sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
            .compactMap { try? anchor(sourceID: $0.sourceID, excerpt: $0.excerpt, sourceText: texts[$0.sourceID]) }
        guard !anchors.isEmpty else {
            throw old.sources.contains(where: { texts[$0.sourceID] != nil }) ? Refusal.passageNotFound : Refusal.noText
        }
        do {
            return try face.memoryItem(id: face.cardID, anchors: anchors, goalID: old.goalID, ideaID: old.ideaID, at: now)
        } catch {
            throw Refusal.noFace
        }
    }

    /// `item` as its Card reads once retired: never asked again, its wording and anchors as they were.
    static func retired(_ item: MemoryItem, at now: Date) -> MemoryItem {
        MemoryItem(
            id: item.id, kind: item.kind, target: item.target, rubricJSON: item.rubricJSON, learnerContext: item.learnerContext,
            goalID: item.goalID, status: .retired, sources: item.sources, createdAt: item.createdAt, updatedAt: now, ideaID: item.ideaID
        )
    }

    /// The variant key of a rewording (the Mac's `KnowledgeStore.variantKey`): a hash of its words, so two
    /// devices taking out the same rewording touch one element.
    static func variantKey(_ text: String) -> String {
        "v" + SyncIdentity.sha256Hex(Data(text.utf8)).prefix(16)
    }
}

// MARK: - Reading the Cards

extension MobileReadModels {
    /// The Cards of every deck that holds a draft, drafts and the cards gone through beside them: what To
    /// Check reads (`MobileCardRecords.toCheck`).
    static func draftDecks(in replica: MobileReplica) throws -> [MobileCardRecord] {
        var ids: [String] = []
        try replica.connection.query("""
            SELECT id FROM m_cards WHERE zone_key = ? AND deck_source_id IN (
                SELECT deck_source_id FROM m_cards WHERE zone_key = ? AND status = 'draft' AND deck_source_id IS NOT NULL
            ) ORDER BY id
        """, [.text(libraryKey), .text(libraryKey)]) { ids.append($0.text(0) ?? "") }
        return try ids.compactMap { id in
            try MobileProjection.held(.card, id, zoneKey: libraryKey, in: replica).map { MobileCardRecord(id: id, fields: $0.fields) }
        }
    }

    /// The Cards under `ids` the phone holds, by id.
    static func cards(_ ids: [String], in replica: MobileReplica) throws -> [String: MobileCardRecord] {
        var records: [String: MobileCardRecord] = [:]
        for id in Set(ids) {
            if let envelope = try MobileProjection.held(.card, id, zoneKey: libraryKey, in: replica) {
                records[id] = MobileCardRecord(id: id, fields: envelope.fields)
            }
        }
        return records
    }
}

// MARK: - Writing the Cards

extension MobileWrite {
    private func card(_ id: String) throws -> SyncEnvelope {
        guard let card = try held(.card, id, in: Self.libraryKey) else { throw MobileCardRecords.Refusal.gone }
        return card
    }

    /// Keep on a draft: its kept wording on the same Card (S: when another device kept it first, its
    /// wording stands and comes back as `keptElsewhere`), the status `kept`, when, and the item's other
    /// columns. The draft wording stays beside it, the before of the learner's edit. A retired card is
    /// never kept again.
    mutating func keepDraftCard(_ item: MemoryItem) throws -> MobileKeepOutcome {
        let held = try card(item.id)
        if let kept = MobileMemoryRecords.item(fromCard: held.fields, id: item.id) {
            return MemoryTutorIdentity.hasSameImmutableCurriculum(kept, item) ? .kept : .keptElsewhere(kept)
        }
        guard held.fields["status"]?.stringValue != "retired" else { throw MobileCardRecords.Refusal.gone }
        let encoded = MobileMemoryRecords.keptCardPatch(item)
        var patch = RecordPatch(.card, id: item.id)
        for field in ["status", "kept", "keptAt", "legacy"] {
            if let change = encoded.changes[field] { patch.changes[field] = change }
        }
        try write(patch, in: Self.libraryKey)
        return .kept
    }

    /// Skip on a draft: gone through and not wanted, so its seed is never offered again. A card kept
    /// meanwhile stays kept, and a retired one retired.
    mutating func skipDraftCard(_ id: String) throws {
        let held = try card(id)
        guard held.fields["status"]?.stringValue == "draft" else { return }
        var patch = RecordPatch(.card, id: id)
        patch.changes["status"] = .value(.string("skipped"))
        patch.changes["skippedAt"] = .value(SyncJSON(milliseconds))
        try write(patch, in: Self.libraryKey)
    }

    /// Retire: the card is never asked again; its answers stay. Retiring a retired card does nothing.
    mutating func retireCard(_ id: String) throws {
        let held = try card(id)
        guard held.fields["status"]?.stringValue != "retired" else { return }
        var patch = RecordPatch(.card, id: id)
        patch.changes["status"] = .value(.string("retired"))
        patch.changes["retiredAt"] = .value(SyncJSON(milliseconds))
        try write(patch, in: Self.libraryKey)
    }

    /// "Always ask it this way", or off again.
    mutating func setCardAlwaysAsk(_ id: String, _ on: Bool) throws {
        _ = try card(id)
        var patch = RecordPatch(.card, id: id)
        patch.changes["alwaysAsk"] = .value(.bool(on))
        try write(patch, in: Self.libraryKey)
    }

    /// A new front alone: the card reworded, its item and schedule untouched. Nil takes the rewording
    /// back, so the card is asked as it was kept.
    mutating func rewordCard(_ id: String, front: String?) throws {
        _ = try card(id)
        var patch = RecordPatch(.card, id: id)
        let element: SyncJSON = front.map {
            .object(["text": .string($0), "madeAt": SyncJSON(milliseconds), "retired": .bool(false)])
        } ?? .null
        patch.changes["variants"] = .elements([MobileCardRecord.frontVariantKey: element])
        try write(patch, in: Self.libraryKey)
    }

    /// "This asks something else" on a card asked in a rewording: the rewording taken out of the card's
    /// rotation on every device that reads the Card. The failed attempt that says so goes in this
    /// device's Sitting too (`recordAnswer`), as the Mac records it.
    mutating func retireCardVariant(_ id: String, text: String) throws {
        let record = MobileCardRecord(id: id, fields: try card(id).fields)
        let wording = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let held = record.variants.first { $0.key != MobileCardRecord.frontVariantKey && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == wording }
        var patch = RecordPatch(.card, id: id)
        patch.changes["variants"] = .elements([held?.key ?? MobileCardRecords.variantKey(wording): .object([
            "text": .string(held?.text ?? wording), "madeAt": SyncJSON(held?.madeAt ?? milliseconds), "retired": .bool(true),
        ])])
        try write(patch, in: Self.libraryKey)
    }

    /// "Start this card over?": the old card retired with its answers, and its revision kept as a new
    /// Card that `supersedes` it, on the same deck, with "always ask it this way" as the old one had it.
    mutating func startCardOver(_ oldID: String, as revision: MemoryItem) throws {
        let old = try card(oldID)
        guard try held(.card, revision.id, in: Self.libraryKey) == nil else {
            throw MobileRecordWriterError.refused("Card \(revision.id) is kept already; a card started over needs a new card id.")
        }
        try retireCard(oldID)
        var patch = MobileMemoryRecords.keptCardPatch(revision)
        if let deck = old.fields["deckSourceID"], !deck.isNull { patch.changes["deckSourceID"] = .value(deck) }
        if let origin = old.fields["origin"], !origin.isNull { patch.changes["origin"] = .value(origin) }
        patch.changes["supersedes"] = .value(.string(oldID))
        if old.fields["alwaysAsk"]?.boolValue == true { patch.changes["alwaysAsk"] = .value(.bool(true)) }
        if let seed = old.fields["seedKey"], !seed.isNull { patch.changes["seedKey"] = .value(seed) }
        try write(patch, in: Self.libraryKey)
    }
}
