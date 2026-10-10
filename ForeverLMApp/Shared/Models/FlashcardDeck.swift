import CryptoKit
import Foundation

/// A source's draft deck: the cards drafted for it, kept and skipped ones
/// included (docs/memory-design.md, "Cards to check").
///
/// A deck is the body of one private Artifact per source, kind `.flashcards`,
/// under the fixed id `carddeck-<sourceID>` (`MemoryCard.draftDeckID`), so two
/// Macs drafting for one source write one deck. Its body is ordinary Markdown
/// in one fixed shape, so a build that does not know the kind still reads it:
///
/// ```
/// <!-- foreverlm:flashcards v1 -->
/// # Cards to check: Mitochondria
///
/// ## What couples respiration to ATP synthesis?
/// <!-- card:6f1c2a9e-3b0d-4d1e-9c55-7a2f4d0e8b11 -->
/// A proton gradient across the inner membrane.
///
/// > Why: Uncoupling breaks the link and ATP synthesis stops.
///
/// Source: [Mitochondria](foreverlm://source/src_1 "couple respiration to ATP synthesis")
/// Difficulty: medium
/// Seed: walk-step:step-2
/// Drafted: 2026-10-01T18:04:05Z
/// Origin: assistant
/// Requested: yes
/// ```
///
/// Every `## ` heading starts a card and is its front; the card's minted id
/// is the `<!-- card:<id> -->` line under it; the lines after that, up to the
/// card's `> Why:` and its metadata lines, are its back. The metadata says
/// where the card stands on its source (the quote its source prints), what it
/// was drafted from (`Seed:`, and `Idea:` for a source idea), when (`Drafted:`,
/// which the 14-day expiry is computed from on read), by whom (`Origin:`, a
/// `MemoryCardOrigin`), and whether the learner asked for it (`Requested:`,
/// kept by default). A line this build does not know is left out of the card.
///
/// **Append-only.** Nothing in a deck is rewritten or removed: what the learner
/// did with a card — kept, skipped, a reworded front — lives in the deck's
/// `cards.state.<deckID>` row (`MemoryCardDeckState`), and a card's kept face
/// in its Memory item. A card is added only when its id, its seed and its
/// front are all new to the deck (`appending`), so a seed drafted once — and
/// skipped — is never offered again. Two Macs that appended before syncing are
/// merged card by card (`union`), never held for a choice.
///
/// Foundation only.
struct FlashcardDeck: Equatable, Sendable {
    static let formatMarker = "<!-- foreverlm:flashcards v1 -->"
    static let cardLinePrefix = "<!-- card:"
    static let commentSuffix = "-->"

    var title: String
    var cards: [Flashcard]

    init(title: String, cards: [Flashcard] = []) {
        self.title = title
        self.cards = cards
    }

    /// The deck title a source's draft deck is made with.
    static func title(forSourceTitle sourceTitle: String) -> String {
        let source = singleLine(sourceTitle)
        return source.isEmpty ? "Cards to check" : "Cards to check: \(source)"
    }

    /// Whether a body is written in the deck format: its first non-empty line
    /// is the format marker.
    static func isDeckMarkdown(_ markdown: String) -> Bool {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) == formatMarker
    }

    // MARK: Reading

    /// Reads a deck body. A card with an empty front or back is dropped
    /// rather than offered blank; a card with no card line (a body written by
    /// hand) takes an id from its front (`Flashcard.stableID`).
    static func parse(_ markdown: String, fallbackTitle: String) -> FlashcardDeck {
        var title: String?
        var drafts: [CardLines] = []

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                drafts.append(CardLines(front: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard var draft = drafts.popLast() else {
                if title == nil, line.hasPrefix("# ") {
                    title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            draft.read(line: line)
            drafts.append(draft)
        }

        var seenFronts: [String: Int] = [:]
        var seenIDs = Set<String>()
        var cards: [Flashcard] = []
        for draft in drafts {
            let front = draft.front
            let back = draft.backLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else { continue }
            let key = Flashcard.normalizedFront(front)
            let occurrence = seenFronts[key, default: 0]
            seenFronts[key] = occurrence + 1
            let id = draft.cardID ?? Flashcard.stableID(front: front, occurrence: occurrence)
            // Two cards under one id would be one card to everything that
            // keys on it — its state, its item — so only the first is read.
            guard seenIDs.insert(id).inserted else { continue }
            let why = draft.whyLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            cards.append(Flashcard(
                id: id,
                front: front,
                back: back,
                why: why.isEmpty ? nil : why,
                sourceID: draft.sourceID,
                sourceTitle: draft.sourceTitle,
                quote: draft.quote,
                difficulty: draft.difficulty,
                seed: draft.seed,
                ideaID: draft.ideaID,
                draftedAt: draft.draftedAt,
                origin: draft.origin,
                isRequested: draft.isRequested,
                frontImages: draft.frontImages,
                backImages: draft.backImages
            ))
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespaces) ?? ""
        return FlashcardDeck(title: trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle, cards: cards)
    }

    // MARK: Writing

    /// The deck's body in the fixed shape `parse` reads back.
    var markdown: String {
        var lines: [String] = [Self.formatMarker, "# \(Self.singleLine(title))"]
        for card in cards {
            lines.append("")
            lines.append("## \(Self.singleLine(card.front))")
            lines.append("\(Self.cardLinePrefix)\(card.id) \(Self.commentSuffix)")
            lines.append(card.back.trimmingCharacters(in: .whitespacesAndNewlines))
            if let why = card.why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
                lines.append("")
                lines.append("> Why: \(Self.singleLine(why))")
            }
            var meta: [String] = []
            if let sourceID = card.sourceID, !sourceID.isEmpty {
                let label = Self.linkLabel(card.sourceTitle ?? "Source")
                let target = sourceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceID
                if let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
                    meta.append("Source: [\(label)](foreverlm://source/\(target) \"\(Self.linkTitle(quote))\")")
                } else {
                    meta.append("Source: [\(label)](foreverlm://source/\(target))")
                }
            }
            if let difficulty = card.difficulty { meta.append("Difficulty: \(difficulty.rawValue)") }
            if let seed = card.seed.flatMap(Self.nonEmptySingleLine) { meta.append("Seed: \(seed)") }
            if let ideaID = card.ideaID.flatMap(Self.nonEmptySingleLine) { meta.append("Idea: \(ideaID)") }
            if let draftedAt = card.draftedAt { meta.append("Drafted: \(draftedAt.formatted(Self.dateStyle))") }
            if let origin = card.origin { meta.append("Origin: \(origin.rawValue)") }
            if card.isRequested { meta.append("Requested: yes") }
            meta.append(contentsOf: card.frontImages.map { "Front image: \($0.markdown)" })
            meta.append(contentsOf: card.backImages.map { "Back image: \($0.markdown)" })
            if !meta.isEmpty {
                lines.append("")
                lines.append(contentsOf: meta)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Appending

    /// What `appending` did with each draft it was given.
    struct Appended: Equatable, Sendable {
        /// The deck with the new cards at its end.
        var deck: FlashcardDeck
        /// The drafts added, as the deck now holds them.
        var added: [Flashcard] = []
        /// Drafts whose id, seed or front the deck already holds: drafted
        /// before, kept or skipped since, so never offered again.
        var alreadyDrafted: [Flashcard] = []
        /// Drafts the deck's Markdown would not give back whole — a back line
        /// that reads as a heading or as the card's metadata — so they are
        /// not saved rather than saved changed.
        var unreadable: [Flashcard] = []
    }

    /// The deck with `drafts` added at its end, in their order: only those
    /// whose id, seed and front are all new to it, and only those its format
    /// gives back whole. Nothing already in the deck changes. The seeds and
    /// fronts of `lapsed` cards (`MemoryCardTriage.lapsedDraftIDs`: offered
    /// for two weeks and never gone through) do not count as drafted.
    func appending(_ drafts: [Flashcard], ignoring lapsed: Set<String> = []) -> Appended {
        var result = Appended(deck: self)
        var ids = Set(cards.map(\.id))
        let counted = cards.filter { !lapsed.contains($0.id) }
        var seeds = Set(counted.compactMap { $0.seed.flatMap(Self.nonEmptySingleLine) })
        var fronts = Set(counted.map { Flashcard.normalizedFront($0.front) })
        for draft in drafts {
            guard let read = Self.readBack(draft.asWritten) else {
                result.unreadable.append(draft)
                continue
            }
            let seed = read.seed.flatMap(Self.nonEmptySingleLine)
            let front = Flashcard.normalizedFront(read.front)
            guard !ids.contains(read.id), seed.map({ !seeds.contains($0) }) ?? true, !fronts.contains(front) else {
                result.alreadyDrafted.append(read)
                continue
            }
            ids.insert(read.id)
            if let seed { seeds.insert(seed) }
            fronts.insert(front)
            result.deck.cards.append(read)
            result.added.append(read)
        }
        return result
    }

    /// The card as the deck's Markdown gives it back, or nil when it does not
    /// come back whole.
    static func readBack(_ card: Flashcard) -> Flashcard? {
        let parsed = parse(FlashcardDeck(title: "Card", cards: [card]).markdown, fallbackTitle: "Card")
        guard parsed.cards.count == 1, let read = parsed.cards.first, read == card else { return nil }
        return read
    }

    // MARK: Two Macs

    /// Two copies of a deck as one, for a body that arrived from another Mac
    /// while this one held a newer body of its own (`CloudKitRecordMapper
    /// .mergeArtifactServerConflict`). A deck only grows, so the merge is
    /// this copy with the other's cards it lacks appended in their order —
    /// nothing is held for a choice, which a deck, never opened as a Doc,
    /// could not offer. Two drafts of one seed, minted apart, both stay: To
    /// Check offers only the first (`MemoryCardTriage.toCheck`). `mine`
    /// itself when the other adds nothing; nil unless both are deck bodies.
    static func union(mine: String, theirs: String) -> String? {
        guard isDeckMarkdown(mine), isDeckMarkdown(theirs) else { return nil }
        var merged = parse(mine, fallbackTitle: "Cards to check")
        let other = parse(theirs, fallbackTitle: merged.title)
        var ids = Set(merged.cards.map(\.id))
        let missing = other.cards.filter { ids.insert($0.id).inserted }
        guard !missing.isEmpty else { return mine }
        merged.cards.append(contentsOf: missing)
        return merged.markdown
    }

    // MARK: Text

    /// Seconds are all a deck keeps of a time: `Drafted:` reads back as
    /// written.
    static let dateStyle = Date.ISO8601FormatStyle()

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    fileprivate static func nonEmptySingleLine(_ text: String) -> String? {
        let line = singleLine(text)
        return line.isEmpty ? nil : line
    }

    /// A source title rides the link's label, where a square bracket would
    /// end it.
    static func linkLabel(_ text: String) -> String {
        singleLine(text).replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
    }

    /// A quote rides the link's title, where a straight double quote would
    /// end it. The grounding check reads letters only, so the quote still
    /// matches its passage.
    static func linkTitle(_ text: String) -> String {
        singleLine(text).replacingOccurrences(of: "\"", with: "'")
    }
}

/// One drafted card of a deck.
struct Flashcard: Identifiable, Equatable, Sendable {
    /// Minted when the card is drafted (`mint`) and written on its card line:
    /// the card's identity for its state row and its kept item
    /// (`MemoryTutorIdentity.cardItemID`), whatever happens to its words.
    let id: String
    var front: String
    var back: String
    var why: String?
    var sourceID: String?
    var sourceTitle: String?
    /// The passage the card stands on, which its source's text prints.
    var quote: String?
    var difficulty: MemoryCardDifficulty?
    /// What it was drafted from: a walk step, a highlight, an idea's or a
    /// review-guide question's hash, as the drafter names it.
    var seed: String?
    /// The source idea it was drafted from, which its kept item records.
    var ideaID: String?
    var draftedAt: Date?
    /// Who drafted it; nil reads as ForeverLM (`MemoryCardOrigin.drafted`).
    var origin: MemoryCardOrigin?
    /// The learner asked for it: it waits kept by default, ticked, and one
    /// Keep N Cards keeps it.
    var isRequested: Bool
    var frontImages: [MemoryCardImage]
    var backImages: [MemoryCardImage]

    init(
        id: String,
        front: String,
        back: String,
        why: String? = nil,
        sourceID: String? = nil,
        sourceTitle: String? = nil,
        quote: String? = nil,
        difficulty: MemoryCardDifficulty? = nil,
        seed: String? = nil,
        ideaID: String? = nil,
        draftedAt: Date? = nil,
        origin: MemoryCardOrigin? = nil,
        isRequested: Bool = false,
        frontImages: [MemoryCardImage] = [],
        backImages: [MemoryCardImage] = []
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.why = why
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.quote = quote
        self.difficulty = difficulty
        self.seed = seed
        self.ideaID = ideaID
        self.draftedAt = draftedAt
        self.origin = origin
        self.isRequested = isRequested
        self.frontImages = Array(frontImages.prefix(MemoryCard.maximumImagesPerFace))
        self.backImages = Array(backImages.prefix(MemoryCard.maximumImagesPerFace))
    }

    /// A newly drafted card under a freshly minted id, its text in the form the
    /// deck writes it — one-line front, why and quote, the back's lines
    /// trimmed — and its time to the second, so it reads back as it was made.
    static func mint(
        front: String,
        back: String,
        why: String? = nil,
        sourceID: String,
        sourceTitle: String,
        quote: String,
        difficulty: MemoryCardDifficulty? = nil,
        seed: String? = nil,
        ideaID: String? = nil,
        origin: MemoryCardOrigin,
        isRequested: Bool,
        frontImages: [MemoryCardImage] = [],
        backImages: [MemoryCardImage] = [],
        at now: Date,
        id: String = UUID().uuidString.lowercased()
    ) -> Flashcard {
        Flashcard(
            id: id,
            front: front,
            back: back,
            why: why,
            sourceID: sourceID,
            sourceTitle: sourceTitle,
            quote: quote,
            difficulty: difficulty,
            seed: seed,
            ideaID: ideaID,
            draftedAt: now,
            origin: origin,
            isRequested: isRequested,
            frontImages: frontImages,
            backImages: backImages
        ).asWritten
    }

    /// The card in the form the deck writes its parts: a one-line front, why,
    /// seed and idea; the back's lines trimmed; the source's title as a link
    /// label (named "Source" when it has none) and the quote as a link title;
    /// the time to the second. What still differs on reading back is a card
    /// the format cannot carry (`FlashcardDeck.readBack`).
    var asWritten: Flashcard {
        var card = self
        card.front = FlashcardDeck.singleLine(front)
        card.back = back
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        card.why = why.flatMap(FlashcardDeck.nonEmptySingleLine)
        card.seed = seed.flatMap(FlashcardDeck.nonEmptySingleLine)
        card.ideaID = ideaID.flatMap(FlashcardDeck.nonEmptySingleLine)
        if let sourceID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
            card.sourceID = sourceID
            card.sourceTitle = FlashcardDeck.linkLabel(sourceTitle ?? "Source")
            card.quote = quote.flatMap { quote in
                let title = FlashcardDeck.linkTitle(quote)
                return title.isEmpty ? nil : title
            }
        } else {
            card.sourceID = nil
            card.sourceTitle = nil
            card.quote = nil
        }
        card.draftedAt = draftedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        return card
    }

    /// An id for a card written without a card line, stable for as long as
    /// its front's text is; two cards with one front stay apart by order.
    static func stableID(front: String, occurrence: Int) -> String {
        let digest = SHA256.hash(data: Data("\(normalizedFront(front))#\(occurrence)".utf8))
        return "card_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A front as the deck compares fronts: lower case, its spacing collapsed.
    static func normalizedFront(_ front: String) -> String {
        front.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// One card's lines while a deck is read.
private struct CardLines {
    var front: String
    var cardID: String?
    var backLines: [String] = []
    var whyLines: [String] = []
    var sourceID: String?
    var sourceTitle: String?
    var quote: String?
    var difficulty: MemoryCardDifficulty?
    var seed: String?
    var ideaID: String?
    var draftedAt: Date?
    var origin: MemoryCardOrigin?
    var isRequested = false
    var frontImages: [MemoryCardImage] = []
    var backImages: [MemoryCardImage] = []
    /// Once a card's metadata starts, later prose is no longer its back.
    private var inMetadata = false
    /// Set once a line after the why is read, so a stray quote after it is
    /// not taken for more of the why.
    private var pastWhy = false

    init(front: String) {
        self.front = front
    }

    mutating func read(line: String) {
        let lower = line.lowercased()
        if line.hasPrefix(FlashcardDeck.cardLinePrefix), line.hasSuffix(FlashcardDeck.commentSuffix) {
            if cardID == nil {
                let id = line
                    .dropFirst(FlashcardDeck.cardLinePrefix.count)
                    .dropLast(FlashcardDeck.commentSuffix.count)
                    .trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { cardID = id }
            }
        } else if lower.hasPrefix("> why:") {
            whyLines.append(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            inMetadata = true
        } else if line.hasPrefix(">"), !whyLines.isEmpty, !pastWhy {
            whyLines.append(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
        } else if let value = Self.value(of: "source:", in: line, lower: lower) {
            readSource(value)
            markMetadata()
        } else if let value = Self.value(of: "difficulty:", in: line, lower: lower) {
            difficulty = MemoryCardDifficulty(rawValue: value.lowercased())
            markMetadata()
        } else if let value = Self.value(of: "seed:", in: line, lower: lower) {
            seed = value.isEmpty ? nil : value
            markMetadata()
        } else if let value = Self.value(of: "idea:", in: line, lower: lower) {
            ideaID = value.isEmpty ? nil : value
            markMetadata()
        } else if let value = Self.value(of: "drafted:", in: line, lower: lower) {
            draftedAt = try? Date(value, strategy: FlashcardDeck.dateStyle)
            markMetadata()
        } else if let value = Self.value(of: "origin:", in: line, lower: lower) {
            origin = value.isEmpty ? nil : MemoryCardOrigin(rawValue: value)
            markMetadata()
        } else if let value = Self.value(of: "requested:", in: line, lower: lower) {
            isRequested = value.lowercased() == "yes"
            markMetadata()
        } else if let value = Self.value(of: "front image:", in: line, lower: lower) {
            if let image = MemoryCardImage(reference: value), frontImages.count < MemoryCard.maximumImagesPerFace {
                frontImages.append(image)
            }
            markMetadata()
        } else if let value = Self.value(of: "back image:", in: line, lower: lower) {
            if let image = MemoryCardImage(reference: value), backImages.count < MemoryCard.maximumImagesPerFace {
                backImages.append(image)
            }
            markMetadata()
        } else if !inMetadata {
            backLines.append(line)
        }
    }

    private mutating func markMetadata() {
        inMetadata = true
        pastWhy = true
    }

    private static func value(of key: String, in line: String, lower: String) -> String? {
        guard lower.hasPrefix(key) else { return nil }
        return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }

    /// `[Title](foreverlm://source/<id> "quote")`, or a bare link.
    private mutating func readSource(_ text: String) {
        guard let open = text.firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]"),
              text.index(after: close) < text.endIndex,
              text[text.index(after: close)] == "(",
              let end = text.lastIndex(of: ")"),
              end > close else { return }
        sourceTitle = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        let inside = text[text.index(close, offsetBy: 2)..<end].trimmingCharacters(in: .whitespaces)
        let target: Substring
        if let space = inside.firstIndex(of: " ") {
            target = inside[..<space]
            let rest = inside[space...].trimmingCharacters(in: .whitespaces)
            if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
                quote = String(rest.dropFirst().dropLast())
            }
        } else {
            target = inside[...]
        }
        let prefix = "foreverlm://source/"
        if target.hasPrefix(prefix) {
            let id = target.dropFirst(prefix.count).split(separator: "?").first.map(String.init) ?? ""
            sourceID = id.isEmpty ? nil : id.removingPercentEncoding ?? id
        }
    }
}
