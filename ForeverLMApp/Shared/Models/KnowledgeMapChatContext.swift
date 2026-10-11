import Foundation

// MARK: - The canvas as a chat's context (docs/knowledge-map-design.md, "Add to Chat and the chips")
//
// A chat opened from a canvas, or given cards with Add to Chat, carries the
// canvas and those cards as chips over its composer, and tells the model about
// them. The context lives on the session in memory, as the Docs attached to a
// chat do; this file holds the plain values and the rules that need no view
// model: what a card says, what a chat holds at most, how many chips show, and
// the paragraph the system prompt gets.

/// One card of a canvas as a chat holds it: what its chip names and what the
/// model is told of it. The words are taken when the card is added, so the
/// chat keeps what it was shown even when the card is written again after.
struct KnowledgeMapChatCard: Equatable, Identifiable, Sendable {
    /// The card's ref (`source:<id>`, `idea:<id>`…): the `item_id` the Canvas's
    /// tools know it by.
    let ref: String
    /// The card's kind as the Canvas draws it: `source`, `doc`, `idea`, `clip`,
    /// `page`, `canvas`, `chat` or `picture` (`KnowledgeMapNode.kind`).
    let kind: String
    let title: String
    /// What the card says, as one line of at most `wordsLimit` characters;
    /// empty for a card that says nothing beyond its title.
    let words: String

    var id: String { ref }

    /// The most characters of words one card carries into a chat.
    static let wordsLimit = 600

    /// The library source this card brings its paper from: a source card is
    /// the source, a page card is a page of one. Nil for every other kind.
    var librarySourceID: String? {
        guard let item = KnowledgeMap.ItemRef(ref) else { return nil }
        if item.kind == .source { return item.id }
        return item.pageParts?.sourceID
    }

    /// What `node` says, written as the learner would read it off the card, in
    /// the order the card shows it: the learner's annotation first (why the
    /// card is on this canvas), then what the kind itself holds. An Idea's
    /// words are its note, which is also where an annotation would go, so an
    /// Idea takes none. Whitespace is folded to single spaces and the whole is
    /// cut to `wordsLimit` characters, ending in "…" when it was cut.
    static func words(of node: KnowledgeMapNode, annotation: String?) -> String {
        var parts: [String] = []
        if node.kind != "idea", let annotation { parts.append(annotation) }
        switch node.kind {
        case "idea":
            if node.sub != KnowledgeMapAddSearch.noteLessIdeaLine { parts.append(node.sub) }
        case "clip":
            if let quote = node.quote, !quote.isEmpty { parts.append("\u{201C}\(quote)\u{201D}") }
            if let caption = node.caption { parts.append(caption) }
            parts.append(contentsOf: node.detail)
            parts.append("From \(node.sub).")
        case "page":
            parts.append("\(node.title) of \(node.sub).")
        case "chat":
            parts.append(node.sub)
        case "picture":
            parts.append(node.title)
        default:
            break
        }
        return cut(parts.map(folded).filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// The card as a chat holds it, from the node the Canvas draws and the
    /// words the learner wrote under it.
    static func card(of node: KnowledgeMapNode, annotation: String?) -> KnowledgeMapChatCard {
        KnowledgeMapChatCard(
            ref: node.ref,
            kind: node.kind,
            title: folded(node.title),
            words: words(of: node, annotation: annotation)
        )
    }

    /// One line: runs of whitespace and newlines become one space.
    private static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func cut(_ text: String) -> String {
        guard text.count > wordsLimit else { return text }
        return String(text.prefix(wordsLimit - 1)) + "\u{2026}"
    }
}

/// The canvas a chat is open beside and the cards the learner added to it, in
/// the order added.
struct KnowledgeMapChatContext: Equatable, Sendable {
    /// How many cards one chat holds. Past it the later ones are left out:
    /// the paragraph the model reads names every card, so it stays short.
    static let cardLimit = 24

    let canvasID: String
    /// The canvas's name when its cards were last added.
    var name: String
    var cards: [KnowledgeMapChatCard]

    /// Adds `added` after the cards held. A card the chat holds already keeps
    /// its place and takes the newer words; no more than `cardLimit` are held
    /// in all. Returns how many of `added` were left out for want of room.
    @discardableResult
    mutating func add(_ added: [KnowledgeMapChatCard]) -> Int {
        var leftOut = 0
        var seen: Set<String> = []
        for card in added where seen.insert(card.ref).inserted {
            if let index = cards.firstIndex(where: { $0.ref == card.ref }) {
                cards[index] = card
            } else if cards.count < Self.cardLimit {
                cards.append(card)
            } else {
                leftOut += 1
            }
        }
        return leftOut
    }

    mutating func remove(_ ref: String) {
        cards.removeAll { $0.ref == ref }
    }

    /// Whether one of the cards is a question Idea (its title ends in "?"):
    /// what Break Into Questions, in the empty chat, takes apart.
    var holdsQuestion: Bool {
        cards.contains { $0.kind == "idea" && KnowledgeMap.isQuestion($0.title) }
    }

    /// The paragraph of the system prompt: the canvas, the cards and where
    /// the rest of the canvas can be read. `canReadCanvas` is whether this
    /// chat carries `get_knowledge_map`; a chat without it is told so rather
    /// than invited to call a tool it does not have.
    func instruction(canReadCanvas: Bool) -> String {
        let canvas = "the canvas \u{201C}\(Self.line(name))\u{201D} (canvas_id: \(canvasID))"
        var text = "\n\n"
        if cards.isEmpty {
            text += "The learner is working on \(canvas) and opened this chat from it."
        } else {
            let lines = cards.map { card -> String in
                var line = "- \(card.kind) \u{201C}\(card.title)\u{201D} (item_id: \(card.ref))"
                if !card.words.isEmpty, card.words != card.title { line += ": \(card.words)" }
                return line
            }
            text += """
            The learner is working on \(canvas) and added these cards to this chat:
            <canvas_cards>
            \(lines.joined(separator: "\n"))
            </canvas_cards>

            When they say "these cards", "this one" or the like without naming anything else, they mean these.
            """
        }
        text += canReadCanvas
            ? " Call get_knowledge_map to read the rest of the canvas: its other cards, its regions and its arrows (it reads the canvas open on the Mac; its canvas field says which)."
            : " The rest of the canvas cannot be read in this chat; say so rather than guessing at it."
        return text
    }

    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Cards on their way to the chat pane: what Add to Chat and Ask in Chat hand
/// over through `StudioViewModel.pendingChatCanvasCards`, consumed by the pane
/// of the window they were asked in as a Doc to attach is.
struct KnowledgeMapChatCards: Equatable, Identifiable, Sendable {
    let id = UUID()
    /// The Studio window whose chat takes them.
    let windowID: UUID
    let canvasID: String
    let canvasName: String
    let cards: [KnowledgeMapChatCard]
    /// Whether they are the chat's cards from here on (Ask in Chat, a fresh
    /// chat) rather than joining those it holds (Add to Chat).
    let replaces: Bool
}

/// The chips over the composer, as numbers and words: no views, so the rules
/// are checked on their own.
enum KnowledgeMapChatChips {
    /// How many card chips one row draws. With more cards than this the last
    /// of the row is "+N" and the rest wait behind it.
    static let visibleLimit = 6
    /// A chip's title is cut at this many characters.
    static let titleCharacters = 24

    struct Split: Equatable {
        /// The cards that get a chip of their own.
        var shown: [KnowledgeMapChatCard]
        /// The cards behind "+N", in the order added; empty when all show.
        var overflow: [KnowledgeMapChatCard]
    }

    /// Up to `visibleLimit` cards draw a chip each. Past that the sixth chip
    /// is "+N", so five cards show and N, the rest, wait in its popover.
    static func split(_ cards: [KnowledgeMapChatCard]) -> Split {
        guard cards.count > visibleLimit else { return Split(shown: cards, overflow: []) }
        return Split(
            shown: Array(cards.prefix(visibleLimit - 1)),
            overflow: Array(cards.dropFirst(visibleLimit - 1))
        )
    }

    /// A card's chip title: its title, at most `titleCharacters` long, cut
    /// with "…" (so the whole stays that long).
    static func title(of card: KnowledgeMapChatCard) -> String {
        card.title.count > titleCharacters ? String(card.title.prefix(titleCharacters - 1)) + "\u{2026}" : card.title
    }

    /// The library sources a chip already shows: the source cards.
    static func sourceIDs(shownBy cards: [KnowledgeMapChatCard]) -> Set<String> {
        Set(cards.compactMap { card in
            guard let item = KnowledgeMap.ItemRef(card.ref), item.kind == .source else { return nil }
            return item.id
        })
    }

    /// The Docs a chip already shows: the Doc cards.
    static func docIDs(shownBy cards: [KnowledgeMapChatCard]) -> Set<String> {
        Set(cards.compactMap { card in
            guard let item = KnowledgeMap.ItemRef(card.ref), item.kind == .doc else { return nil }
            return item.id
        })
    }

    /// What the "N in context" pill counts: the sources whose text the chat
    /// holds and the Docs attached to it, less those a chip already shows.
    static func pillCount(loadedSourceIDs: [String], docIDs: [String], cards: [KnowledgeMapChatCard]) -> Int {
        let shownSources = sourceIDs(shownBy: cards)
        let shownDocs = Self.docIDs(shownBy: cards)
        return loadedSourceIDs.filter { !shownSources.contains($0) }.count
            + docIDs.filter { !shownDocs.contains($0) }.count
    }
}
