import Foundation

// MARK: - Adding to the canvas: what to offer
//
// docs/knowledge-map-design.md, "Adding to the canvas (2026-10-10)". The add
// box, the find field's dropdown and the Library sidebar all answer the same
// two questions about the cards the library holds: *what does this canvas point
// at* (`related`) and *what does this query find* (`matches`). They are
// answered here, from the cards and links the renderer draws from
// (`KnowledgeMapContent`) and the refs placed, with nothing but Foundation, so
// the order a learner sees is the order these tests pin.
//
// Nothing here invents a card: a ref that is not one of `content.nodes` is
// never listed, and a link of a kind with no weight counts for nothing.

enum KnowledgeMapAddSearch {
    // MARK: What the lists hold at most

    /// The first rows of Related the add box lists while nothing is typed.
    static let relatedInBox = 8
    /// The newest unplaced Ideas the add box lists under Related.
    static let recentIdeas = 5
    /// Cards of the canvas, cards of the library and notebooks a typed query lists.
    static let onCanvasShown = 4
    static let libraryShown = 12
    static let notebooksShown = 4
    /// The most cards Show All flies to and rings, and the most Related holds.
    static let showAllLimit = 40

    /// The line an Idea with no note wears as its card's `sub`
    /// (`KnowledgeMapModel.content`). It says nothing about the Idea, so a
    /// search never matches it and no row draws it.
    static let noteLessIdeaLine = "Idea"

    /// How near a link says its two ends are, by the link's kind: an Idea and
    /// its source or Doc, and a clip and its paper, are the nearest; a Doc and
    /// a source it cites next; two sources discussed in one chat the least.
    /// A kind not named here counts for nothing.
    static let linkWeights: [String: Int] = ["idea": 3, "clip": 3, "doc": 2, "chat": 1]

    // MARK: Related: what a canvas points at

    /// The cards Related starts from: the selected ones, else every placed
    /// one, and the paper (`src`) of each, which brings the Ideas written about
    /// it, the Docs that cite it and the other clips cut from it into reach.
    static func anchors(selection: [String], placed: Set<String>, content: KnowledgeMapContent) -> Set<String> {
        let chosen = selection.isEmpty ? placed : Set(selection)
        var result = chosen
        for node in content.nodes where chosen.contains(node.ref) {
            if let paper = node.src { result.insert(paper) }
        }
        return result
    }

    /// What hangs under a placed Idea as its evidence: the other end of each
    /// `idea` link whose Idea is placed. The plane draws these though nothing
    /// places them.
    static func evidence(content: KnowledgeMapContent, placed: Set<String>) -> Set<String> {
        var hanging: Set<String> = []
        for link in content.links where link.kind == "idea" && placed.contains(link.a) {
            hanging.insert(link.b)
        }
        return hanging
    }

    /// The unplaced cards the anchors point at, nearest first: the other end of
    /// every link that touches an anchor, its weight (`linkWeights`) summed per
    /// card. Placed cards, evidence already hanging under a placed Idea and
    /// pages are left out (a page is a card only once it is on a canvas, and a
    /// proposal is never a card at all). Ordered by weight, then by kind (Idea,
    /// clip, source, Doc, the rest), then, for Ideas, the order they were
    /// written (oldest first: the cards list them newest first) and, for the
    /// rest, the cards' own order. An Idea linked to nothing is in no canvas's
    /// Related.
    static func related(
        anchors: Set<String>,
        content: KnowledgeMapContent,
        placed: Set<String>,
        limit: Int = showAllLimit
    ) -> [String] {
        guard !anchors.isEmpty, limit > 0 else { return [] }
        var weights: [String: Int] = [:]
        for link in content.links {
            guard let weight = linkWeights[link.kind] else { continue }
            if anchors.contains(link.a) { weights[link.b, default: 0] += weight }
            if anchors.contains(link.b) { weights[link.a, default: 0] += weight }
        }
        guard !weights.isEmpty else { return [] }
        let hanging = evidence(content: content, placed: placed)
        var candidates: [(ref: String, weight: Int, rank: Int, order: Int)] = []
        for (index, node) in content.nodes.enumerated() {
            guard let weight = weights[node.ref], !placed.contains(node.ref),
                  !hanging.contains(node.ref), !isPage(node) else { continue }
            candidates.append((node.ref, weight, kindRank(node.kind), node.kind == "idea" ? -index : index))
        }
        candidates.sort { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.order < rhs.order
        }
        return candidates.prefix(limit).map(\.ref)
    }

    /// The newest unplaced Ideas, as the cards list them (newest first), apart
    /// from the ones `excluding` already shows.
    static func recentIdeas(
        content: KnowledgeMapContent,
        placed: Set<String>,
        excluding: Set<String>,
        limit: Int = recentIdeas
    ) -> [String] {
        let ideas = content.nodes.lazy
            .filter { $0.kind == "idea" && !placed.contains($0.ref) && !excluding.contains($0.ref) }
            .map(\.ref)
        return Array(ideas.prefix(limit))
    }

    // MARK: Search: what a query finds

    /// What a search reads of each card, lower-cased once: building it is the
    /// work a keystroke would otherwise repeat for every card of a large
    /// library. Made from `content` and good only for it
    /// (`KnowledgeMapModel.addSearchIndex` keeps one per change of the cards).
    struct Index {
        /// Each card's title, lower-cased, in `content.nodes` order.
        fileprivate(set) var titles: [String] = []
        /// What a query's words are looked for in: the title, and an Idea's note.
        fileprivate(set) var haystacks: [String] = []

        init(content: KnowledgeMapContent) {
            titles.reserveCapacity(content.nodes.count)
            haystacks.reserveCapacity(content.nodes.count)
            for node in content.nodes {
                let title = node.title.lowercased()
                titles.append(title)
                haystacks.append(node.kind == "idea" && node.sub != noteLessIdeaLine ? title + " " + node.sub.lowercased() : title)
            }
        }

        func describes(_ content: KnowledgeMapContent) -> Bool {
            titles.count == content.nodes.count
        }
    }

    /// What a query found, each list best first.
    struct Matches: Equatable {
        /// The cards on the plane: placed, or hanging under a placed Idea.
        var onCanvas: [String] = []
        /// The rest of the library's cards, without pages.
        var library: [String] = []
        /// The notebooks (`KnowledgeMapNotebook.id`) with something to set down.
        var notebookIDs: [String] = []

        var isEmpty: Bool { onCanvas.isEmpty && library.isEmpty && notebookIDs.isEmpty }
    }

    /// The cards whose title holds every word of `query`, lower-cased (an
    /// Idea's note counts as well). A title that starts with the query ranks
    /// first, then one with a word starting with the query's first word, then
    /// the rest, each in the cards' order. `onPlane` is what the plane draws:
    /// the placed cards and the evidence under them. A notebook is found by
    /// its title the same way, once it has cards to set down. An empty query
    /// finds nothing. `index` is the cards' words lower-cased once; without
    /// one (or one made for other cards) it is made here.
    static func matches(
        _ query: String,
        content: KnowledgeMapContent,
        placed: Set<String>,
        onPlane: Set<String>,
        index: Index? = nil
    ) -> Matches {
        let words = queryWords(query)
        guard !words.isEmpty else { return Matches() }
        let index = index.flatMap { $0.describes(content) ? $0 : nil } ?? Index(content: content)
        let needles = words.map { Array($0.utf8) }
        let phrase = Array(words.joined(separator: " ").utf8)
        var onCanvas: [(rank: Int, ref: String)] = []
        var library: [(rank: Int, ref: String)] = []
        for (position, node) in content.nodes.enumerated() {
            let haystack = index.haystacks[position]
            guard needles.allSatisfy({ holds(haystack, $0) }) else { continue }
            let rank = titleRank(index.titles[position], words: words, phrase: phrase, first: needles[0])
            if placed.contains(node.ref) || onPlane.contains(node.ref) {
                onCanvas.append((rank, node.ref))
            } else if !isPage(node) {
                library.append((rank, node.ref))
            }
        }
        var notebooks: [(rank: Int, ref: String)] = []
        for notebook in content.notebooks where !notebook.refs.isEmpty {
            let title = notebook.title.lowercased()
            guard words.allSatisfy({ title.contains($0) }) else { continue }
            notebooks.append((titleRank(title, words: words, phrase: phrase, first: needles[0]), notebook.id))
        }
        return Matches(onCanvas: ranked(onCanvas), library: ranked(library), notebookIDs: ranked(notebooks))
    }

    /// Whether `haystack` holds the UTF-8 bytes of a word. Byte for byte, which
    /// for text lower-cased once is what a letter-for-letter search finds, and
    /// fast enough for a keystroke over thousands of cards.
    private static func holds(_ haystack: String, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        let found = haystack.utf8.withContiguousStorageIfAvailable { bytes in
            needle.withUnsafeBufferPointer { word in
                bytes.count >= word.count && memmem(bytes.baseAddress, bytes.count, word.baseAddress, word.count) != nil
            }
        }
        return found ?? haystack.contains(String(decoding: needle, as: UTF8.self))
    }

    private static func queryWords(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 0 when the title (lower-cased) starts with the query, 1 when one of its
    /// words starts with the query's first word, 2 for any other match. Read
    /// byte for byte, as `holds` does: a match is thousands of titles for a
    /// common word, so no title is split into words to rank it.
    private static func titleRank(_ lowered: String, words: [String], phrase: [UInt8], first: [UInt8]) -> Int {
        let rank = lowered.utf8.withContiguousStorageIfAvailable { bytes -> Int in
            guard let start = bytes.baseAddress else { return 2 }
            let startsWithQuery = phrase.withUnsafeBufferPointer { query in
                bytes.count >= query.count && memcmp(start, query.baseAddress, query.count) == 0
            }
            if startsWithQuery { return 0 }
            return first.withUnsafeBufferPointer { word in
                var from = 0
                while from + word.count <= bytes.count,
                      let hit = memmem(start + from, bytes.count - from, word.baseAddress, word.count) {
                    let position = UnsafeRawPointer(start).distance(to: UnsafeRawPointer(hit))
                    if position == 0 || !isWordCharacter(endingBefore: position, in: bytes) { return 1 }
                    from = position + 1
                }
                return 2
            }
        }
        if let rank { return rank }
        if lowered.hasPrefix(words.joined(separator: " ")) { return 0 }
        let titleWords = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.first.map { first in titleWords.contains { $0.hasPrefix(first) } ? 1 : 2 } ?? 2
    }

    /// Whether the character that ends just before `position` is a letter or a
    /// digit, which is what a word is made of.
    private static func isWordCharacter(endingBefore position: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let previous = bytes[position - 1]
        if previous < 0x80 {
            switch previous {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"): return true
            default: return false
            }
        }
        // Step back over the continuation bytes to the start of the character.
        var start = position - 1
        while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        let character = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// The refs by rank, the input order kept within a rank (`sorted` is not
    /// stable, so the position breaks each tie).
    private static func ranked(_ entries: [(rank: Int, ref: String)]) -> [String] {
        entries.enumerated()
            .sorted { lhs, rhs in
                lhs.element.rank != rhs.element.rank ? lhs.element.rank < rhs.element.rank : lhs.offset < rhs.offset
            }
            .map(\.element.ref)
    }

    private static func kindRank(_ kind: String) -> Int {
        switch kind {
        case "idea": return 0
        case "clip": return 1
        case "source": return 2
        case "doc": return 3
        default: return 4
        }
    }

    private static func isPage(_ node: KnowledgeMapNode) -> Bool {
        node.kind == "page" || node.ref.hasPrefix("page:")
    }

    // MARK: The list the add box and the find field draw

    /// How the list is used: in the add box it offers a card to set down at a
    /// point; under the find field it also flies to what the canvas holds.
    enum Mode: Equatable {
        case box
        case find
    }

    /// One row of the list.
    enum Row: Equatable, Hashable, Identifiable {
        /// A library card, to set down.
        case place(String)
        /// A card on the canvas, to fly to.
        case show(String)
        /// The cards of the canvas that matched, flown to and ringed together.
        case showAll([String])
        /// A notebook, set down as its frame.
        case notebook(String)
        /// What was typed, written as a new Idea.
        case newIdea(String)

        var id: String {
            switch self {
            case .place(let ref): return "place:" + ref
            case .show(let ref): return "show:" + ref
            case .showAll: return "showAll"
            case .notebook(let id): return "notebook:" + id
            case .newIdea: return "newIdea"
            }
        }
    }

    struct Section: Equatable, Identifiable {
        var id: String
        /// Nil for the New idea row, which stands under no heading.
        var title: String?
        var rows: [Row]
    }

    struct Listing: Equatable {
        var sections: [Section] = []
        /// Words were typed and nothing in the library holds them: the list says
        /// so above its New idea row.
        var nothingMatched = false

        /// Every row in reading order, for ↑ ↓ and ↵.
        var rows: [Row] { sections.flatMap(\.rows) }
    }

    /// The rows for what is typed. With nothing typed the box offers Related
    /// (its first `relatedInBox`) and the newest Ideas not already in it; the
    /// find field offers nothing. Typing offers the cards on the canvas, the
    /// library's, the notebooks and, last, a new Idea. Under the find field,
    /// when more than one card of the canvas matched, the first row is Show
    /// All for up to `showAllLimit` of them.
    static func listing(
        query: String,
        mode: Mode,
        content: KnowledgeMapContent,
        placed: Set<String>,
        selection: [String],
        index: Index? = nil
    ) -> Listing {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var listing = Listing()
        guard !typed.isEmpty else {
            guard mode == .box else { return listing }
            let anchored = anchors(selection: selection, placed: placed, content: content)
            let near = Array(related(anchors: anchored, content: content, placed: placed).prefix(relatedInBox))
            let recent = recentIdeas(content: content, placed: placed, excluding: Set(near))
            if !near.isEmpty {
                listing.sections.append(Section(id: "related", title: "Related", rows: near.map(Row.place)))
            }
            if !recent.isEmpty {
                listing.sections.append(Section(id: "recent", title: "Recent ideas", rows: recent.map(Row.place)))
            }
            return listing
        }
        let onPlane = placed.union(evidence(content: content, placed: placed))
        let found = matches(typed, content: content, placed: placed, onPlane: onPlane, index: index)
        if !found.onCanvas.isEmpty {
            var rows: [Row] = []
            if mode == .find, found.onCanvas.count > 1 {
                rows.append(.showAll(Array(found.onCanvas.prefix(showAllLimit))))
            }
            rows += found.onCanvas.prefix(onCanvasShown).map(Row.show)
            listing.sections.append(Section(id: "onCanvas", title: "On this canvas", rows: rows))
        }
        if !found.library.isEmpty {
            listing.sections.append(Section(id: "library", title: "From your library", rows: found.library.prefix(libraryShown).map(Row.place)))
        }
        if !found.notebookIDs.isEmpty {
            listing.sections.append(Section(id: "notebooks", title: "Notebooks", rows: found.notebookIDs.prefix(notebooksShown).map(Row.notebook)))
        }
        listing.nothingMatched = found.isEmpty
        listing.sections.append(Section(id: "newIdea", title: nil, rows: [.newIdea(typed)]))
        return listing
    }
}
