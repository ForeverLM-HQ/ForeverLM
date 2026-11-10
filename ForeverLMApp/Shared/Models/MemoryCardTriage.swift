import Foundation

// MARK: - Memory as cards: the cards to check
//
// docs/memory-design.md, "Cards to check". Stage four of memory as cards: cards
// drafted from a source wait in its draft deck (`FlashcardDeck`: the
// source's draft Cards, `KnowledgeStore.cardRecordDecks`, whose kept item is
// the Card's own id) until
// the learner goes through them — Keep, Edit, Skip — in the Memory pane's To
// Check. Everything here is pure (Foundation only): which cards wait, in what order, and what a
// decision writes; storage reads the decks and the state rows, and the Memory
// pane and the MCP tools ask the same rules.

/// One source's draft deck as storage read it.
struct MemoryCardDraftDeck: Equatable, Sendable {
    /// `carddeck-<sourceID>` (`MemoryCard.draftDeckID`).
    let deckID: String
    /// The source the deck's cards stand on.
    let sourceID: String
    let deck: FlashcardDeck
}

/// One card waiting to be gone through.
struct MemoryCardToCheck: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// Drafted from a source — by ForeverLM or an assistant — and neither
        /// kept nor skipped yet.
        case draft
    }

    let kind: Kind
    /// What Keep makes the item from: the draft's face.
    let face: MemoryCard
    /// The deck whose `cards.state.<deckID>` row records the decision.
    let deckID: String
    /// The source the card stands on: the deck's.
    let sourceID: String
    /// The passage it quotes, which Keep checks against the source's text.
    let quote: String?
    let seed: String?
    let ideaID: String?
    /// When it was drafted.
    let draftedAt: Date?
    /// The learner asked for this draft. To Check decides it like any other
    /// (since 2026-10-12); the corner card counts only the drafts not asked for.
    let isRequested: Bool
    /// The item the card is kept as, when it has one.
    let memoryItemID: String?
    /// Passages of other sources the card also stands on, beside `quote` in
    /// `sourceID`: Keep anchors the card on each of them too. Empty for a card
    /// with one source.
    var alsoFrom: [CardSourceLink] = []

    var id: String { face.cardID }

    /// Every passage the card stands on, its own source's first: what Keep
    /// anchors it on, and what its source chips are.
    var links: [CardSourceLink] {
        let own = quote.map { CardSourceLink(sourceID: sourceID, quote: $0) }
        return CardSourceLink.normalized((own.map { [$0] } ?? []) + alsoFrom)
    }

    /// Every source the card stands on, once each, its own first.
    var sourceIDs: [String] {
        var seen = Set<String>()
        return ([sourceID] + alsoFrom.map(\.sourceID)).filter { seen.insert($0).inserted }
    }
    var cardID: String { face.cardID }

    /// Kept unless the learner says otherwise: a requested draft.
    var isKeptByDefault: Bool { isRequested }
}

/// What the learner decided about a card to check.
enum MemoryCardTriageAction: Equatable, Sendable {
    /// Keep it as drafted: the draft's item is made.
    case keep
    /// Edit, then Keep: the draft is kept in the learner's words.
    case keepEdited(MemoryCardEdit)
    /// Not wanted: a draft's seed is never offered again.
    case skip
}

struct MemoryCardTriageDecision: Equatable, Sendable {
    let card: MemoryCardToCheck
    let action: MemoryCardTriageAction
}

/// What a batch of decisions did.
struct MemoryCardTriageResult: Equatable, Sendable {
    struct Kept: Equatable, Sendable {
        let cardID: String
        let memoryItemID: String
    }

    struct Failure: Equatable, Sendable {
        let cardID: String
        let reason: String
    }

    var kept: [Kept] = []
    var skipped: [String] = []
    /// Decisions storage refused — a quote its source no longer prints, an
    /// edit with no front — each left to check.
    var failed: [Failure] = []

    var decidedCount: Int { kept.count + skipped.count }
}

enum MemoryCardTriage {
    /// The cards to check, in the order To Check lists them: a source at a
    /// time, the source drafted for most recently first, and within a source
    /// its drafts in the deck's order.
    ///
    /// A draft waits until it is kept or skipped in its deck's row, or until
    /// its item exists (kept on another device whose row has not arrived);
    /// it never lapses. A draft with no quote cannot be
    /// kept and is not offered, nor is one whose seed or front belongs to a
    /// card of its deck gone through, or offered before it.
    ///
    /// - Parameters:
    ///   - decks: the sources' draft decks, already narrowed to the sources
    ///     that may be shown.
    ///   - deckStates: the `cards.state.<deckID>` rows, by deck id.
    ///   - itemIDs: every Memory item's id, whatever its status.
    static func toCheck(
        decks: [MemoryCardDraftDeck],
        deckStates: [String: MemoryCardDeckState],
        itemIDs: Set<String>
    ) -> [MemoryCardToCheck] {
        struct Pile {
            var drafts: [MemoryCardToCheck] = []
            var newestDraft: Date = .distantPast
        }
        var piles: [String: Pile] = [:]

        for deck in decks {
            let states = deckStates[deck.deckID]?.cards ?? [:]
            func isGoneThrough(_ card: Flashcard) -> Bool {
                if let status = states[card.id]?.status, status != .draft { return true }
                return itemIDs.contains(card.id) || itemIDs.contains(MemoryTutorIdentity.cardItemID(cardID: card.id))
            }
            // A seed or a front gone through once, under any of the deck's
            // card ids, is not offered again; of two drafts of one seed or
            // front, only the first is. One writer never appends such a twin
            // (`FlashcardDeck.appending`), but two Macs that drafted before
            // they synced keep both (`FlashcardDeck.union`).
            var takenSeeds = Set<String>()
            var takenFronts = Set<String>()
            for card in deck.deck.cards where isGoneThrough(card) {
                if let seed = card.seed { takenSeeds.insert(seed) }
                takenFronts.insert(Flashcard.normalizedFront(card.front))
            }
            for card in deck.deck.cards {
                if isGoneThrough(card) { continue }
                guard let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { continue }
                let front = Flashcard.normalizedFront(card.front)
                if let seed = card.seed, takenSeeds.contains(seed) { continue }
                if takenFronts.contains(front) { continue }
                if let seed = card.seed { takenSeeds.insert(seed) }
                takenFronts.insert(front)
                let entry = MemoryCardToCheck(
                    kind: .draft,
                    face: MemoryCard(
                        cardID: card.id,
                        front: card.front,
                        back: card.back,
                        why: card.why.map { [$0] } ?? [],
                        origin: card.origin ?? .drafted,
                        deckID: deck.deckID,
                        frontImages: card.frontImages,
                        backImages: card.backImages
                    ),
                    deckID: deck.deckID,
                    sourceID: deck.sourceID,
                    quote: quote,
                    seed: card.seed,
                    ideaID: card.ideaID,
                    draftedAt: card.draftedAt,
                    isRequested: card.isRequested,
                    memoryItemID: nil,
                    alsoFrom: card.alsoFrom
                )
                var pile = piles[deck.sourceID] ?? Pile()
                pile.drafts.append(entry)
                if let draftedAt = card.draftedAt, draftedAt > pile.newestDraft { pile.newestDraft = draftedAt }
                piles[deck.sourceID] = pile
            }
        }

        let order = piles.keys.sorted { lhs, rhs in
            let left = piles[lhs]!, right = piles[rhs]!
            if left.newestDraft != right.newestDraft { return left.newestDraft > right.newestDraft }
            return lhs < rhs
        }
        return order.flatMap { piles[$0]!.drafts }
    }

    /// One source's cards to check, as To Check groups them.
    struct Group: Equatable, Identifiable, Sendable {
        let sourceID: String
        let cards: [MemoryCardToCheck]
        var id: String { sourceID }
    }

    /// `cards` a source at a time, in the order they come.
    static func grouped(_ cards: [MemoryCardToCheck]) -> [Group] {
        var order: [String] = []
        var bySource: [String: [MemoryCardToCheck]] = [:]
        for card in cards {
            if bySource[card.sourceID] == nil { order.append(card.sourceID) }
            bySource[card.sourceID, default: []].append(card)
        }
        return order.map { Group(sourceID: $0, cards: bySource[$0] ?? []) }
    }

    /// "9 cards from 3 sources", "1 card from 1 source"; nil when nothing
    /// waits.
    static func summary(_ cards: [MemoryCardToCheck]) -> String? {
        guard !cards.isEmpty else { return nil }
        let sources = Set(cards.map(\.sourceID)).count
        let cardWord = cards.count == 1 ? "card" : "cards"
        let sourceWord = sources == 1 ? "source" : "sources"
        return "\(cards.count) \(cardWord) from \(sources) \(sourceWord)"
    }

    /// Keep All on a source: every card of the group kept.
    static func keepAll(_ cards: [MemoryCardToCheck]) -> [MemoryCardTriageDecision] {
        cards.map { MemoryCardTriageDecision(card: $0, action: .keep) }
    }

    /// The face a draft is kept with after the learner's edit: their words
    /// under the draft's card id, origin and deck. Nil when the
    /// edit leaves no front or no back.
    static func editedFace(_ card: MemoryCardToCheck, _ edit: MemoryCardEdit) -> MemoryCard? {
        let face = MemoryCard(
            cardID: card.face.cardID,
            front: edit.front,
            back: edit.back,
            why: edit.why,
            origin: card.face.origin,
            deckID: card.face.deckID,
            frontImages: edit.frontImages,
            backImages: edit.backImages
        )
        guard !face.front.isEmpty, !face.back.isEmpty else { return nil }
        return face
    }
}

// MARK: - The cards a chat saved

/// The cards a chat saved with `save_card_drafts` (docs/memory-design.md,
/// "The cards in the chat"). Read off the tool's result while the turn runs,
/// and stored at the head of the reply as one link line,
/// `[6 cards to check](foreverlm://cards?source=…&card=…)`, so a reopened chat
/// draws them again. The Mac draws that line as the cards themselves; every
/// other reader of the stored reply — the iPhone, the web, an MCP transcript —
/// sees a link that names them.
///
/// Until 2026-10-06 a reply said in prose what it had saved, and the learner
/// asked "where are these cards?". The prose had also miscounted them: "10
/// cards" for six saved, three the deck already held and one refused.
struct ChatSavedCards: Equatable, Sendable {
    /// The cards in the order the call listed them: those it saved, then those
    /// the deck already held (drafted before from the same seed or front).
    var cardIDs: [String]
    /// The sources whose draft decks hold them.
    var sourceIDs: [String]
    /// Cards the call sent that were not saved: a quote the source does not
    /// print, a back that reads as a heading, a card missing a field.
    var notSavedCount: Int

    /// The stored scheme, `StudioEntityLink.productScheme` on the Mac; written
    /// out here because the iPhone compiles this file without that one.
    static let scheme = "foreverlm"
    static let host = "cards"

    init(cardIDs: [String], sourceIDs: [String], notSavedCount: Int = 0) {
        self.cardIDs = cardIDs
        self.sourceIDs = sourceIDs
        self.notSavedCount = notSavedCount
    }

    /// What one `save_card_drafts` result names. Nil when it names no card:
    /// a call that saved nothing keeps its ordinary row, which says why.
    static func parse(toolResult: String) -> ChatSavedCards? {
        guard let data = toolResult.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sources = object["sources"] as? [[String: Any]] else { return nil }
        var cards = ChatSavedCards(cardIDs: [], sourceIDs: [])
        for source in sources {
            let saved = (source["saved_card_ids"] as? [String]) ?? []
            let before = ((source["already_drafted"] as? [[String: Any]]) ?? []).compactMap { $0["card_id"] as? String }
            for id in saved + before where !id.isEmpty && !cards.cardIDs.contains(id) {
                cards.cardIDs.append(id)
            }
            if let sourceID = source["source_id"] as? String, !sourceID.isEmpty,
               !cards.sourceIDs.contains(sourceID), !(saved + before).isEmpty {
                cards.sourceIDs.append(sourceID)
            }
            cards.notSavedCount += ((source["not_grounded"] as? [Any])?.count ?? 0)
                + ((source["not_saved"] as? [Any])?.count ?? 0)
        }
        cards.notSavedCount += (object["incomplete"] as? [Any])?.count ?? 0
        return cards.cardIDs.isEmpty ? nil : cards
    }

    /// What the in-app chat's model is told with the result: the cards are on
    /// screen already, so its reply need not list or count them. On
    /// 2026-10-06 a reply listed them and miscounted them.
    static let shownInChatNote = "The chat shows the learner these cards above your reply, drawn as cards, each with where it stands and a button that opens To Check at it. Do not list, recount or describe the cards again: say in a sentence what you made them from, and why any were not saved."

    /// A `save_card_drafts` result with `shown_in_chat` added, for the in-app
    /// chat. A result that names no card, or is not the tool's JSON, is
    /// returned as it was.
    static func notingShownInChat(_ toolResult: String) -> String {
        guard parse(toolResult: toolResult) != nil,
              let data = toolResult.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return toolResult }
        object["shown_in_chat"] = shownInChatNote
        guard let noted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: noted, encoding: .utf8) else { return toolResult }
        return text
    }

    /// Two calls in one turn, as one set of cards.
    func merging(_ other: ChatSavedCards) -> ChatSavedCards {
        var merged = self
        for id in other.cardIDs where !merged.cardIDs.contains(id) { merged.cardIDs.append(id) }
        for id in other.sourceIDs where !merged.sourceIDs.contains(id) { merged.sourceIDs.append(id) }
        merged.notSavedCount += other.notSavedCount
        return merged
    }

    // MARK: The stored line

    /// "6 cards to check": the link's words, true when the reply was written.
    var label: String {
        cardIDs.count == 1 ? "1 card to check" : "\(cardIDs.count) cards to check"
    }

    /// `foreverlm://cards?source=…&card=…&not_saved=1`, in the product scheme
    /// so it reads on every client and in a Dev build alike. Each value is
    /// percent-encoded down to letters, digits and `-._~:`, so no id can end
    /// the Markdown link early.
    var destination: String {
        var query = sourceIDs.map { "source=\(Self.encode($0))" } + cardIDs.map { "card=\(Self.encode($0))" }
        if notSavedCount > 0 { query.append("not_saved=\(notSavedCount)") }
        return "\(Self.scheme)://\(Self.host)?\(query.joined(separator: "&"))"
    }

    var markdownLine: String { "[\(label)](\(destination))" }

    /// The reply as it is stored: the line first, where the cards stood in the
    /// turn, ahead of what the reply says about them.
    static func storing(_ reply: String, with cards: ChatSavedCards?) -> String {
        guard let cards else { return reply }
        return cards.markdownLine + "\n\n" + reply
    }

    /// The cards a `foreverlm://cards` address names, in the product scheme or
    /// the running build's. Nil for any other address, or one naming no card.
    static func parse(_ url: URL) -> ChatSavedCards? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == Self.scheme || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased(),
              url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var cards = ChatSavedCards(cardIDs: [], sourceIDs: [])
        for item in items {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            switch item.name {
            case "card": if !cards.cardIDs.contains(value) { cards.cardIDs.append(value) }
            case "source": if !cards.sourceIDs.contains(value) { cards.sourceIDs.append(value) }
            case "not_saved": cards.notSavedCount = Int(value) ?? 0
            default: break
            }
        }
        return cards.cardIDs.isEmpty ? nil : cards
    }

    // MARK: Splitting a reply

    enum Part: Equatable, Sendable {
        case text(String)
        case cards(ChatSavedCards)
    }

    /// The reply split around its card lines: a line that is nothing but a
    /// `foreverlm://cards` link. A link inside a sentence stays prose. Prose
    /// parts are trimmed and never empty.
    static func split(_ text: String) -> [Part] {
        // Runs on every stored reply a chat reopens; most hold no card line.
        guard text.contains("://\(host)?") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }
        var parts: [Part] = []
        var pending: [Substring] = []
        func flush() {
            let prose = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeAll()
            if !prose.isEmpty { parts.append(.text(prose)) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let cards = cardsLine(line) {
                flush()
                parts.append(.cards(cards))
            } else {
                pending.append(line)
            }
        }
        flush()
        return parts
    }

    /// The reply's prose without its card lines: what two stored copies of
    /// one reply are compared by, when only one of them carries the cards.
    static func prose(of text: String) -> String {
        split(text).compactMap { part -> String? in
            if case .text(let prose) = part { return prose }
            return nil
        }.joined(separator: "\n\n")
    }

    /// The cards a line names when it is exactly `[words](foreverlm://cards?…)`.
    private static func cardsLine(_ line: Substring) -> ChatSavedCards? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix(")"),
              let middle = trimmed.range(of: "]("),
              !trimmed[trimmed.index(after: trimmed.startIndex)..<middle.lowerBound].contains("]") else { return nil }
        let destination = trimmed[middle.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard !destination.contains(where: \.isWhitespace), let url = URL(string: String(destination)) else { return nil }
        return parse(url)
    }

    private static let encodable: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~:")
        return allowed
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: encodable) ?? value
    }
}

// MARK: - A card id an assistant shortened

/// The card an assistant meant by an id it shortened. A card id can run past
/// 150 characters (`card:<source id>:gist:<source id>`: the source's 68-character
/// id twice), and a model copying one into a tool call often keeps the head and
/// writes the tail as `…` or `...`, or stops short. The ids the library holds
/// settle it: a shortened id names the one card whose id starts with its head
/// and ends with its tail, and when two cards fit, the call is refused with
/// their full ids so the retry is exact.
enum CardIDCompletion {
    enum Result: Equatable {
        /// The id is a card's own.
        case exact
        /// The one card the shortened id fits, by its full id.
        case completed(String)
        /// Two or more cards fit: their full ids, at most `maxCandidates`.
        case ambiguous([String])
        /// No card's id starts like this one.
        case unknown
    }

    static let maxCandidates = 5

    /// `given` against the ids `known`. A `…` or a run of three or more dots
    /// stands for the part left out: what is before the first one must start
    /// the id and what is after the last must end it. With none, the id is
    /// taken as cut short, a prefix.
    static func resolve(_ given: String, among known: [String]) -> Result {
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        if known.contains(trimmed) { return .exact }
        let marked = trimmed.replacingOccurrences(of: "(\\.{3,}|\u{2026})+", with: "\u{2026}", options: .regularExpression)
        let pieces = marked.components(separatedBy: "\u{2026}")
        let head = pieces.first ?? ""
        let tail = pieces.count > 1 ? (pieces.last ?? "") : ""
        guard !head.isEmpty else { return .unknown }
        var seen = Set<String>()
        let fits = known.filter { id in
            id.count >= head.count + tail.count && id.hasPrefix(head) && id.hasSuffix(tail) && seen.insert(id).inserted
        }
        switch fits.count {
        case 0: return .unknown
        case 1: return .completed(fits[0])
        default: return .ambiguous(Array(fits.prefix(maxCandidates)))
        }
    }
}
