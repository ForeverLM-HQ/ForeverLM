import Foundation

// MARK: - Cards as their Card records (docs/cloudkit-schema-design.md §3.5.22; docs/memory-design.md,
// "Cards on the Mac under generation 2")
//
// On an activated generation-2 store a card's whole life is its `Card`, the rows `CardProjection` reads:
// a draft is a `memory_card_states` row whose status is `draft`, with its wording in `draft_json` and its
// deck in `deck_source_id`; Keep makes the Memory item under the Card's own id and says `kept`; Skip
// says `skipped`; what the learner changes about a kept card (its own front, rewordings taken out,
// "always ask it this way", the day close's rewordings) is the row's `variants_json` and `always_ask`.
// The phone and the web read and write the same records, so nothing here keeps a deck Artifact or a
// `cards.state.<deckID>` row. The Mac's pure card rules (`MemoryCardTriage`, `MemoryCardWording`,
// `CardDraftingExemplars`) still take decks and deck states, so the rows are read into those shapes:
//
// - a deck is a source's rows, those holding a draft wording and those gone through with a seed, in
//   the order they were drafted; a card of it goes by the id the card's face carries (`cardKey`), which
//   is the Card's own id except for a card kept before the cutover, whose face names the deck card it was
//   kept from (its item, and so its Card, is `MemoryTutorIdentity.cardItemID` of that);
// - a deck's state is its rows as `MemoryCardState`s under the same keys.

/// One `memory_card_states` row as the card readers take it, with what its Memory item, if it has one,
/// says about it.
struct CardRecordRow: Equatable, Sendable {
    let cardID: String
    let status: String
    /// The row's own deck.
    let deckSourceID: String?
    /// The item's first anchor's source, the deck of a card kept with none.
    let anchorSourceID: String?
    let origin: String?
    let seedKey: String?
    let draft: SyncJSON?
    let variants: [String: SyncJSON]
    let alwaysAsk: Bool
    let draftedAt: Double?
    let skippedAt: Double?
    let retiredAt: Double?
    let item: Item?

    struct Item: Equatable, Sendable {
        let status: String
        let createdAt: Double
        let rubricJSON: String?
        let target: String?
    }

    /// The source whose deck the card is in: its own, else its item's first anchor's.
    var deckSource: String? { deckSourceID ?? anchorSourceID }
}

extension KnowledgeStore {
    /// The variant key a learner's own front is kept under (the phone's `MobileCardRecord.frontVariantKey`).
    static let cardFrontVariantKey = "front"
    /// The variant element that says the day close reworded the card, once, whether or not a rewording
    /// passed: no text, so no reader asks it (the phone and the web read only elements with text), and
    /// `madeAt` the time (`MemoryCardState.variedAt`). Generation 1 kept it in the deck's row.
    static let cardVariedVariantKey = "varied"

    // MARK: Reading

    /// Every Card row this Mac holds, those of the decks of `deckSourceIDs`, or the one under `cardID`.
    func cardRecordRows(deckSourceIDs: Set<String>? = nil, cardID: String? = nil) throws -> [CardRecordRow] {
        var rows: [CardRecordRow] = []
        try query("""
            SELECT s.card_id, s.status, s.deck_source_id, s.origin, s.seed_key, s.draft_json, s.variants_json, s.always_ask,
                   s.drafted_at, s.skipped_at, s.retired_at,
                   i.id, i.status, i.created_at, i.rubric_json, i.target,
                   (SELECT a.source_id FROM memory_item_sources a WHERE a.memory_item_id = s.card_id ORDER BY a.sort_index, a.id LIMIT 1)
            FROM memory_card_states s LEFT JOIN memory_items i ON i.id = s.card_id
            WHERE ? IS NULL OR s.card_id = ?
            ORDER BY COALESCE(s.drafted_at, 0), s.card_id
        """, [.text(cardID), .text(cardID)]) { row in
            guard let id = row.text(0) else { return }
            let item = row.text(11).map { _ in
                CardRecordRow.Item(status: row.text(12) ?? "active", createdAt: row.real(13) ?? 0, rubricJSON: row.text(14), target: row.text(15))
            }
            rows.append(CardRecordRow(
                cardID: id, status: row.text(1) ?? "kept", deckSourceID: row.text(2), anchorSourceID: row.text(16),
                origin: row.text(3), seedKey: row.text(4), draft: SittingProjection.json(row.text(5)),
                variants: SittingProjection.json(row.text(6))?.objectValue ?? [:], alwaysAsk: row.integer(7) == 1,
                draftedAt: row.real(8), skippedAt: row.real(9), retiredAt: row.real(10), item: item
            ))
        }
        guard let deckSourceIDs else { return rows }
        return rows.filter { $0.deckSource.map(deckSourceIDs.contains) ?? false }
    }

    /// Every deck's card states, by deck id (`carddeck-<sourceID>`), as the card readers take a deck's row.
    func cardRecordStates(deckSourceIDs: Set<String>? = nil) throws -> [String: MemoryCardDeckState] {
        var decks: [String: MemoryCardDeckState] = [:]
        for row in try cardRecordRows(deckSourceIDs: deckSourceIDs) {
            guard let source = row.deckSource else { continue }
            decks[MemoryCard.draftDeckID(sourceID: source), default: MemoryCardDeckState()].cards[Self.cardKey(row)] = Self.cardState(row)
        }
        return decks
    }

    /// The sources' decks, as To Check, drafting and a notebook's Make Cards runs read them: per source, its
    /// rows that hold a draft wording, and those gone through that hold a seed (so a seed kept or skipped
    /// on any device is never offered again), in the order they were drafted. Nil reads every deck.
    func cardRecordDecks(sourceIDs: Set<String>?) throws -> [MemoryCardDraftDeck] {
        if let sourceIDs, sourceIDs.isEmpty { return [] }
        var order: [String] = []
        var cards: [String: [Flashcard]] = [:]
        for row in try cardRecordRows(deckSourceIDs: sourceIDs) {
            guard let source = row.deckSourceID, let card = Self.flashcard(row) else { continue }
            if cards[source] == nil { order.append(source) }
            cards[source, default: []].append(card)
        }
        return order.sorted().map { source in
            MemoryCardDraftDeck(
                deckID: MemoryCard.draftDeckID(sourceID: source), sourceID: source,
                deck: FlashcardDeck(title: "", cards: cards[source] ?? [])
            )
        }
    }

    /// The decks drafted into so far, and when each was first drafted into: background drafting's "has a
    /// deck" and its day's count of new decks.
    func cardRecordDeckFirstDrafts() throws -> [String: Date] {
        var first: [String: Date] = [:]
        try query("""
            SELECT deck_source_id, MIN(COALESCE(drafted_at, 0)) FROM memory_card_states
            WHERE deck_source_id IS NOT NULL AND draft_json IS NOT NULL GROUP BY deck_source_id
        """, []) { row in
            if let source = row.text(0) { first[source] = Date(timeIntervalSinceReferenceDate: row.real(1) ?? 0) }
        }
        return first
    }

    /// The id the card's face carries: the deck card a card kept before the cutover was kept from, which
    /// its rubric names; the Card's own id for every other card (a draft, a card kept since, a card kept
    /// on another device, an item from before cards, a missed question).
    static func cardKey(_ row: CardRecordRow) -> String {
        guard let rubric = row.item?.rubricJSON,
              let object = (try? JSONSerialization.jsonObject(with: Data(rubric.utf8))) as? [String: Any],
              let card = object[MemoryCard.cardKey] as? [String: Any],
              let id = (card[MemoryCard.cardIDKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return row.cardID }
        return id
    }

    /// A row as the card readers' state: kept with its item (a retired card stays kept, its item retired,
    /// as generation 1 kept it), skipped, or a draft (also an item from before cards not gone through yet);
    /// the learner's front, the rewordings in the order they were made and those taken out, when the day
    /// close reworded it, "always ask", the seed.
    static func cardState(_ row: CardRecordRow) -> MemoryCardState {
        let status: MemoryCardStatus
        switch row.status {
        case "draft": status = .draft
        case "skipped": status = .skipped
        case "retired": status = row.item == nil ? .skipped : .kept
        default: status = .kept
        }
        let variants = variantState(row.variants)
        var times = [row.draftedAt, row.skippedAt, row.retiredAt, row.item?.createdAt].compactMap { $0 }
        times += variants.madeAt.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        return MemoryCardState(
            status: status,
            memoryItemID: row.item != nil || status == .kept ? row.cardID : nil,
            editedFront: variants.front,
            variants: variants.rewordings,
            retiredVariants: variants.retired,
            alwaysAsk: row.alwaysAsk,
            seed: row.seedKey,
            variedAt: variants.variedAt.map(SyncTime.date(milliseconds:)),
            updatedAt: Date(timeIntervalSinceReferenceDate: times.max() ?? 0)
        )
    }

    /// The `variants` map read: the learner's front, the rewordings in the order they were made (by
    /// `madeAt`, then key) and those taken out, and when the card was reworded — the `varied` element, or
    /// else its first rewording.
    static func variantState(_ variants: [String: SyncJSON]) -> (front: String?, rewordings: [String], retired: [String], variedAt: Int64?, madeAt: [Int64]) {
        var front: String?
        var varied: Int64?
        var entries: [(key: String, text: String, madeAt: Int64, retired: Bool)] = []
        for (key, value) in variants {
            guard let object = value.objectValue else { continue }
            let madeAt = object["madeAt"]?.int64Value ?? 0
            if key == cardVariedVariantKey {
                varied = madeAt
                continue
            }
            guard let text = object["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let retired = object["retired"]?.boolValue ?? false
            if key == cardFrontVariantKey {
                if !retired { front = text }
                continue
            }
            entries.append((key, text, madeAt, retired))
        }
        entries.sort { ($0.madeAt, $0.key) < ($1.madeAt, $1.key) }
        return (
            front, entries.filter { !$0.retired }.map(\.text), entries.filter(\.retired).map(\.text),
            varied ?? entries.first?.madeAt, entries.map(\.madeAt) + (varied.map { [$0] } ?? [])
        )
    }

    /// A row as its deck's card: the draft wording (front, back, the why, pictures and
    /// origin its rubric carries, the quote its first anchor holds), its seed and idea, when it was
    /// drafted and whether the learner asked for it; a card gone through that has no draft wording (kept
    /// on another device from a draft its seed names) holds its seed and its kept front. Nil for a row
    /// with neither a draft wording nor a seed gone through.
    static func flashcard(_ row: CardRecordRow) -> Flashcard? {
        let draft = row.draft?.objectValue
        if draft == nil, row.status == "draft" || row.seedKey == nil { return nil }
        let rubric = (draft?["rubric"]?.stringValue)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        let face = rubric[MemoryCard.cardKey] as? [String: Any] ?? [:]
        let keptFace = row.item.flatMap { item in
            (item.rubricJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })?[MemoryCard.cardKey] as? [String: Any]
        }
        let front = draft?["front"]?.stringValue ?? (keptFace?[MemoryCard.frontKey] as? String) ?? row.item?.target ?? ""
        let back = draft?["back"]?.stringValue ?? row.item?.target ?? ""
        let why = ((rubric[MemoryCard.criteriaKey] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != back.trimmingCharacters(in: .whitespacesAndNewlines) }
        let anchors = draft?["anchors"]?.arrayValue ?? []
        let quote = anchors.first?["excerpt"]?.stringValue
        // The anchors after the first are the other sources the card also stands on.
        let alsoFrom: [CardSourceLink] = anchors.dropFirst().compactMap { anchor in
            guard let target = anchor["target"]?.stringValue, target.hasPrefix("src:"),
                  let excerpt = anchor["excerpt"]?.stringValue else { return nil }
            return CardSourceLink(sourceID: String(target.dropFirst(4)).components(separatedBy: "#")[0], quote: excerpt)
        }
        let origin = (face[MemoryCard.originKey] as? String).map(MemoryCardOrigin.init(rawValue:)) ?? faceOrigin(of: row.origin)
        return Flashcard(
            id: cardKey(row),
            front: front,
            back: back,
            why: why,
            sourceID: row.deckSourceID,
            quote: quote,
            seed: row.seedKey,
            ideaID: draft?["ideaID"]?.stringValue,
            draftedAt: row.draftedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
            origin: origin,
            isRequested: draft?["requested"]?.boolValue ?? false,
            frontImages: MemoryCardImage.readRubric(face[MemoryCard.frontImagesKey]),
            backImages: MemoryCardImage.readRubric(face[MemoryCard.backImagesKey]),
            alsoFrom: alsoFrom
        )
    }

    /// The face origin of a draft whose rubric names none: an assistant's and a course quiz's keep theirs,
    /// every other draft is ForeverLM's (the phone's `MobileCardRecord.faceOrigin`).
    static func faceOrigin(of wire: String?) -> MemoryCardOrigin {
        switch wire {
        case "assistant": return .assistant
        case "courseQuiz": return .courseQuiz
        case "walkthrough": return .walkthrough
        default: return .drafted
        }
    }

    // MARK: Drafting

    /// A draft's wording as its Card holds it (`Card.draft`): front and back, the rubric it would be kept
    /// with (its why, pictures and origin, `MemoryCard.rubricJSON`), and its quote as the one
    /// anchor on its source (`target` the source's wire id, `textHash` the source text's hash when it is
    /// known); the idea it was drafted from and whether the learner asked for it ride beside them.
    static func draftJSON(
        _ card: Flashcard, deckSourceID: String, anchorSourceKey: String, textHash: String,
        links: [(key: String, hash: String, quote: String)] = []
    ) throws -> SyncJSON {
        let face = MemoryCard(
            cardID: card.id, front: card.front, back: card.back, why: card.why.map { [$0] } ?? [],
            origin: card.origin ?? .drafted, deckID: MemoryCard.draftDeckID(sourceID: deckSourceID),
            frontImages: card.frontImages, backImages: card.backImages
        )
        var draft: [String: SyncJSON] = [
            "front": .string(face.front), "back": .string(face.back), "rubric": .string(try face.rubricJSON()),
            "anchors": .array(card.quote.map { quote -> [SyncJSON] in
                var entries: [SyncJSON] = [
                    ["target": .string("src:" + anchorSourceKey), "locator": .null, "excerpt": .string(quote), "textHash": .string(textHash)],
                ]
                for link in links {
                    entries.append(["target": .string("src:" + link.key), "locator": .null, "excerpt": .string(link.quote), "textHash": .string(link.hash)])
                }
                return entries
            } ?? []),
        ]
        if card.isRequested { draft["requested"] = .bool(true) }
        if let idea = card.ideaID { draft["ideaID"] = .string(idea) }
        return .object(draft)
    }

    /// `Card.origin` of a draft: an assistant's, a course quiz's, a walkthrough question's; else what
    /// ForeverLM drafted it from, read off its seed (`CardDraftingSeedKey`).
    static func wireOrigin(_ origin: MemoryCardOrigin?, seedKey: String?) -> String {
        switch origin {
        case .assistant?: return "assistant"
        case .courseQuiz?: return "courseQuiz"
        case .walkthrough?: return "walkthrough"
        default: return draftedOrigin(seedKey: seedKey)
        }
    }

    /// What ForeverLM drafted a card from, by its seed: a walk step, a highlight, an idea, else a guide's
    /// question or a passage of the text (`guide`).
    static func draftedOrigin(seedKey: String?) -> String {
        guard let seed = seedKey else { return "guide" }
        if seed.hasPrefix("walk-step:") || seed.hasPrefix("walk:") { return "walkthrough" }
        if seed.hasPrefix("highlight:") || seed.hasPrefix("hl:") { return "highlight" }
        if seed.hasPrefix("idea:") { return "idea" }
        return "guide"
    }

    /// Whether a Card row exists under `id`, whatever its status.
    func cardRecordExists(_ id: String) throws -> Bool {
        try scalarInteger("SELECT EXISTS(SELECT 1 FROM memory_card_states WHERE card_id = ?)", [.text(id)]) == 1
    }

    /// Saves drafts as draft Cards on `deckSourceID`'s deck, one transaction: each under its own id, which
    /// the caller chose (`card:<deckSourceID>:<seedKey>` for a seeded draft whose id is free). A Card that
    /// exists under an id is never written over: a draft is never written twice, and a card gone through
    /// never becomes a draft again.
    func saveCardDraftRecords(_ cards: [Flashcard], deckSourceID: String, textHash: String, linkHashes: [String: String] = [:]) throws {
        guard !cards.isEmpty else { return }
        let anchorKey = try personalStateSourceKey(deckSourceID)
        var written: [(Flashcard, String)] = []
        for card in cards {
            // A card's other sources' anchors follow its own, each by its source's wire key and text hash.
            let links = try card.alsoFrom.map { link in
                (key: try personalStateSourceKey(link.sourceID), hash: linkHashes[link.sourceID] ?? "", quote: link.quote)
            }
            let json = try Self.draftJSON(card, deckSourceID: deckSourceID, anchorSourceKey: anchorKey, textHash: textHash, links: links)
            written.append((card, SittingProjection.text(json) ?? "{}"))
        }
        try inDerivationTransaction { store in
            for (card, draft) in written {
                try store.execute("""
                    INSERT INTO memory_card_states (card_id, status, deck_source_id, origin, seed_key, draft_json, variants_json, always_ask, drafted_at)
                    VALUES (?, 'draft', ?, ?, ?, ?, '{}', 0, ?)
                    ON CONFLICT(card_id) DO NOTHING
                """, [
                    .text(card.id), .text(deckSourceID), .text(Self.wireOrigin(card.origin, seedKey: card.seed)), .text(card.seed), .text(draft),
                    .real((card.draftedAt ?? Date()).timeIntervalSinceReferenceDate),
                ])
            }
        }
    }

    // MARK: What the learner did

    /// A card's state as a writer changed it: what the writer read, and what it made of it.
    struct CardStateChange: Sendable {
        let before: MemoryCardState?
        let after: MemoryCardState
    }

    /// Writes cards' changed states into their rows (a deck's state as the card writers change it,
    /// `MemoryCardStateStore.update`), one transaction. A card's row is its kept item's id, else the key it
    /// goes by. Only what the change changed is written, onto what the row holds now, so a state another
    /// device wrote since the writer read survives: a status (a retired card stays retired, a kept one is
    /// never skipped, a draft's status is the row's), "always ask", the learner's front, a rewording added
    /// or taken out (elements of `variants`), the day close's `varied`. The seed and the deck are kept once
    /// set. A row that would not change is not written.
    func writeCardRecordStates(deckID: String, _ changes: [String: CardStateChange], at now: Date = Date()) throws {
        let deckSource = MemoryCard.sourceID(fromDraftDeckID: deckID)
        try inDerivationTransaction { store in
            for (key, change) in changes.sorted(by: { $0.key < $1.key }) {
                try store.writeCardRecordState(id: change.after.memoryItemID ?? key, change, deckSourceID: deckSource, at: now)
            }
        }
    }

    private func writeCardRecordState(id: String, _ change: CardStateChange, deckSourceID: String?, at now: Date) throws {
        let state = change.after
        let before = change.before
        var held: (status: String, deck: String?, seed: String?, variants: [String: SyncJSON], alwaysAsk: Bool, skippedAt: Double?)?
        try query("SELECT status, deck_source_id, seed_key, variants_json, always_ask, skipped_at FROM memory_card_states WHERE card_id = ?", [.text(id)]) { row in
            held = (row.text(0) ?? "kept", row.text(1), row.text(2), SittingProjection.json(row.text(3))?.objectValue ?? [:], row.integer(4) == 1, row.real(5))
        }
        var status = held?.status ?? "draft"
        if held == nil || before?.status != state.status {
            switch state.status {
            case .kept: status = held?.status == "retired" ? "retired" : "kept"
            case .skipped: status = held?.status == "kept" || held?.status == "retired" ? held!.status : "skipped"
            case .draft: status = held?.status ?? "draft"
            }
        }
        let alwaysAsk = held == nil || before?.alwaysAsk != state.alwaysAsk ? state.alwaysAsk : held!.alwaysAsk
        let variants = Self.mergedVariants(held?.variants ?? [:], from: before, to: state, at: SyncTime.milliseconds(now))
        let deck = held?.deck ?? deckSourceID
        let seed = held?.seed ?? state.seed
        let skippedAt = held?.skippedAt ?? (status == "skipped" ? now.timeIntervalSinceReferenceDate : nil)
        if let held, held.status == status, held.deck == deck, held.seed == seed, held.variants == variants,
           held.alwaysAsk == alwaysAsk, held.skippedAt == skippedAt { return }
        try execute("""
            INSERT INTO memory_card_states (card_id, status, deck_source_id, seed_key, variants_json, always_ask, skipped_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(card_id) DO UPDATE SET
                status = excluded.status, deck_source_id = excluded.deck_source_id, seed_key = excluded.seed_key,
                variants_json = excluded.variants_json, always_ask = excluded.always_ask, skipped_at = excluded.skipped_at
        """, [
            .text(id), .text(status), .text(deck), .text(seed), .text(SittingProjection.text(.object(variants)) ?? "{}"),
            .integer(alwaysAsk ? 1 : 0), .real(skippedAt),
        ])
    }

    /// What a change makes of the variants the row holds: the learner's front when the change set or took
    /// it back (gone when the state has none); each rewording the change added and each it took out, under
    /// the element that holds its words, else under the hash of them (`variantKey`), keeping when it was
    /// made; `varied` once the day close reworded the card. What the change did not touch stays as held.
    static func mergedVariants(_ held: [String: SyncJSON], from before: MemoryCardState?, to state: MemoryCardState, at ms: Int64) -> [String: SyncJSON] {
        var variants = held
        if before == nil || before?.editedFront != state.editedFront {
            if let front = state.editedFront?.trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty {
                let heldFront = held[cardFrontVariantKey]
                if heldFront?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) != front || heldFront?["retired"]?.boolValue == true {
                    variants[cardFrontVariantKey] = ["text": .string(front), "madeAt": SyncJSON(ms), "retired": false]
                }
            } else if before != nil {
                variants[cardFrontVariantKey] = nil
            }
        }
        func put(_ text: String, retired: Bool) {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            let key = variants.keys.sorted().first { key in
                key != cardFrontVariantKey && key != cardVariedVariantKey
                    && variants[key]?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == words
            } ?? variantKey(words)
            let element: SyncJSON = [
                "text": .string(variants[key]?["text"]?.stringValue ?? words),
                "madeAt": SyncJSON(variants[key]?["madeAt"]?.int64Value ?? ms), "retired": .bool(retired),
            ]
            if variants[key] != element { variants[key] = element }
        }
        for text in state.variants where !(before?.variants.contains(text) ?? false) { put(text, retired: false) }
        for text in state.retiredVariants where !(before?.retiredVariants.contains(text) ?? false) { put(text, retired: true) }
        if let variedAt = state.variedAt, before?.variedAt == nil, variants[cardVariedVariantKey] == nil {
            variants[cardVariedVariantKey] = ["text": "", "madeAt": SyncJSON(SyncTime.milliseconds(variedAt)), "retired": true]
        }
        return variants
    }

    /// "This asks something else" on a card asked in `text`: that rewording taken out on the card's Card
    /// (its element `retired`), so every device leaves it out. A card with no row gets one: an item from
    /// before cards as not gone through yet, any other as kept.
    func retireCardRecordVariant(cardID: String, text: String, at now: Date = Date()) throws {
        try inDerivationTransaction { store in
            let held = try store.cardRecordRows(cardID: cardID).first
            let fromBeforeCards = try store.isCardFromBeforeCards(cardID)
            let before = held.map(Self.cardState)
            var state = before ?? MemoryCardState(
                status: fromBeforeCards ? .draft : .kept, memoryItemID: cardID, updatedAt: now
            )
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            state.variants.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == words }
            if !state.retiredVariants.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == words }) {
                state.retiredVariants.append(text)
            }
            let item = try store.loadMemoryItem(cardID)
            let deck = held?.deckSource ?? item?.sources.min { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }?.sourceID
            try store.writeCardRecordState(id: cardID, CardStateChange(before: before, after: state), deckSourceID: deck, at: now)
        }
    }

    /// Whether `itemID` is an item from before cards: its rubric carries no card.
    func isCardFromBeforeCards(_ itemID: String) throws -> Bool {
        guard let item = try loadMemoryItem(itemID) else { return false }
        return MemoryCard(storedIn: item) == nil
    }

    /// A draft kept here: its Card says kept at once, in the transaction after its item's, so a read of the
    /// cards to check never offers it again. A retired card stays retired.
    func markCardRecordKept(_ id: String) throws {
        try execute("UPDATE memory_card_states SET status = 'kept' WHERE card_id = ? AND status IN ('draft', 'skipped')", [.text(id)])
    }

    /// Whether the Card under `id` is retired: it is never kept again.
    func cardRecordIsRetired(_ id: String) throws -> Bool {
        try scalarText("SELECT status FROM memory_card_states WHERE card_id = ?", [.text(id)]) == "retired"
    }

    /// A card started over (`startMemoryCardOver`): the old Card retired, and its revision's Card on the
    /// same deck, with the old one's origin, seed and "always ask it this way", superseding it, as the
    /// phone writes it.
    func recordCardRecordStartOver(oldID: String, old: MemoryItem, newID: String, at now: Date) throws {
        var held: (deck: String?, origin: String?, seed: String?, alwaysAsk: Bool)?
        try query("SELECT deck_source_id, origin, seed_key, always_ask FROM memory_card_states WHERE card_id = ?", [.text(oldID)]) { row in
            held = (row.text(0), row.text(1), row.text(2), row.integer(3) == 1)
        }
        let anchor = old.sources.min { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }?.sourceID
        try execute("""
            UPDATE memory_card_states SET status = 'retired', retired_at = COALESCE(retired_at, ?) WHERE card_id = ? AND status <> 'retired'
        """, [.real(now.timeIntervalSinceReferenceDate), .text(oldID)])
        try execute("""
            INSERT INTO memory_card_states (card_id, status, deck_source_id, origin, seed_key, variants_json, always_ask, supersedes)
            VALUES (?, 'kept', ?, ?, ?, '{}', ?, ?)
            ON CONFLICT(card_id) DO UPDATE SET supersedes = excluded.supersedes
        """, [
            .text(newID), .text(held?.deck ?? anchor), .text(held?.origin), .text(held?.seed), .integer(held?.alwaysAsk == true ? 1 : 0), .text(oldID),
        ])
    }

    /// A retired card's Card says so at once.
    func markCardRecordRetired(_ id: String, at now: Date) throws {
        try execute("""
            UPDATE memory_card_states SET status = 'retired', retired_at = COALESCE(retired_at, ?) WHERE card_id = ? AND status <> 'retired'
        """, [.real(now.timeIntervalSinceReferenceDate), .text(id)])
    }
}

// MARK: - The activation's derivations (§13.3 step 3c, §10: `carddeck-*` → `Card(status draft)`)

extension KnowledgeStore {
    /// Every source's draft deck as its cards' Cards, once, after `deriveCardStates` made the deck rows'
    /// states (§10: a deck's draft becomes a Card with status `draft`; the deck Artifact stays this Mac's,
    /// unsynced, until generation 1 is deleted). A deck card goes under the id its state takes: the Memory
    /// item it was kept as (its deck row says so, or its item exists), else `card:<deckSourceID>:<seed>`
    /// for a seeded card, else its own deck id; of two deck cards under one id the first is taken. A card
    /// with no row is written with the status its deck row gives it (kept, skipped, else draft); a row that
    /// exists keeps its status and takes only the draft wording, seed, deck, origin and drafting time it
    /// lacks. A deck whose body is not on this Mac is left out, and logged. Idempotent.
    func deriveCardDrafts() throws {
        var decks: [(id: String, source: String)] = []
        try query("""
            SELECT a.id, (SELECT l.source_id FROM global_artifact_source_links l WHERE l.artifact_id = a.id ORDER BY l.source_id LIMIT 1)
            FROM global_artifacts a WHERE a.team_id IS NULL AND (a.kind = ? OR substr(a.id, 1, ?) = ?) ORDER BY a.id
        """, [.text(ArtifactKind.flashcards.rawValue), .integer(Int64(MemoryCard.draftDeckIDPrefix.count)), .text(MemoryCard.draftDeckIDPrefix)]) { row in
            guard let id = row.text(0), let source = MemoryCard.sourceID(fromDraftDeckID: id) ?? row.text(1) else { return }
            decks.append((id, source))
        }
        guard !decks.isEmpty else { return }
        let itemIDs = Set(try loadAllMemoryItemIDs())
        for deck in decks {
            guard let markdown = try loadArtifactMarkdownForSync(deck.id) else { continue }
            let cards = FlashcardDeck.parse(markdown, fallbackTitle: "").cards
            var deckState = MemoryCardDeckState()
            if let xml = try scalarText("SELECT value FROM user_preferences WHERE key = ?", [.text(MemoryCardDeckState.preferenceKey(deckID: deck.id))]),
               let value = PreferenceStore.decodePlist(xml), let row = MemoryCardDeckState(preferenceValue: value) {
                deckState = row
            }
            let anchorKey = try personalStateSourceKey(deck.source)
            try inDerivationTransaction { store in
                var taken = Set<String>()
                for card in cards {
                    let state = deckState.cards[card.id]
                    let itemID = MemoryTutorIdentity.cardItemID(cardID: card.id)
                    let keptAs = state?.status == .kept ? (state?.memoryItemID ?? itemID) : (itemIDs.contains(itemID) ? itemID : nil)
                    let id = keptAs ?? card.seed.map { SyncIdentity.cardDraftID(deckSourceID: deck.source, seedKey: $0) } ?? card.id
                    guard taken.insert(id).inserted else { continue }
                    let status = keptAs != nil ? "kept" : (state?.status == .skipped ? "skipped" : "draft")
                    let draft = try Self.draftJSON(card, deckSourceID: deck.source, anchorSourceKey: anchorKey, textHash: "")
                    try store.execute("""
                        INSERT INTO memory_card_states (card_id, status, deck_source_id, origin, seed_key, draft_json, variants_json, always_ask,
                            drafted_at, skipped_at)
                        VALUES (?, ?, ?, ?, ?, ?, '{}', 0, ?, ?)
                        ON CONFLICT(card_id) DO UPDATE SET
                            draft_json = COALESCE(memory_card_states.draft_json, excluded.draft_json),
                            drafted_at = COALESCE(memory_card_states.drafted_at, excluded.drafted_at),
                            origin = COALESCE(memory_card_states.origin, excluded.origin),
                            seed_key = COALESCE(memory_card_states.seed_key, excluded.seed_key),
                            deck_source_id = COALESCE(memory_card_states.deck_source_id, excluded.deck_source_id)
                    """, [
                        .text(id), .text(status), .text(deck.source), .text(Self.wireOrigin(card.origin, seedKey: card.seed)), .text(card.seed),
                        .text(SittingProjection.text(draft)), .real(card.draftedAt?.timeIntervalSinceReferenceDate),
                        .real(status == "skipped" ? state?.updatedAt.timeIntervalSinceReferenceDate : nil),
                    ])
                }
            }
        }
    }

    /// Every active item from before cards that no row says was gone through, as a row that says it is
    /// not yet (`draft`, on its first anchor's deck): To Check offers it until it is, and a Card of it
    /// arriving from another device (which says `kept`, since its item exists) does not take it out of
    /// this Mac's To Check (`CardProjection.applyFields`). Idempotent.
    func deriveLegacyCardsToCheck() throws {
        var items: [(id: String, rubric: String, source: String?)] = []
        try query("""
            SELECT i.id, i.rubric_json,
                   (SELECT a.source_id FROM memory_item_sources a WHERE a.memory_item_id = i.id ORDER BY a.sort_index, a.id LIMIT 1)
            FROM memory_items i
            WHERE i.status = 'active' AND NOT EXISTS (SELECT 1 FROM memory_card_states s WHERE s.card_id = i.id)
            ORDER BY i.id
        """, []) { row in
            if let id = row.text(0) { items.append((id, row.text(1) ?? "{}", row.text(2))) }
        }
        for item in items {
            let object = (try? JSONSerialization.jsonObject(with: Data(item.rubric.utf8))) as? [String: Any]
            guard object?[MemoryCard.cardKey] == nil, let source = item.source else { continue }
            try execute("""
                INSERT INTO memory_card_states (card_id, status, deck_source_id, variants_json, always_ask) VALUES (?, 'draft', ?, '{}', 0)
                ON CONFLICT(card_id) DO NOTHING
            """, [.text(item.id), .text(source)])
        }
    }
}
