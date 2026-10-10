import Foundation

// MARK: - What comes onto the Canvas from outside it
//
// The product owner, 2026-10-09: "please do it all", on the checklist against Heptabase's
// whiteboard (docs/heptabase-canvas-parity.md, "Getting things onto the plane"
// and "Nested whiteboards"). This is the Foundation-only half of that work, so
// the macOS unit tests read it as the Mac does: what a pasted line of text is,
// what a dropped file is, the first sentence of an answer, where a card added
// to a canvas that is not open goes, and what moves when a selection is moved
// from one canvas to another. The routes that import and write
// (`StudioViewModel+KnowledgeMapOutside`) and the views (`App/`) sit on it.

enum KnowledgeMapOutside {
    typealias Spot = KnowledgeMapArranging.Spot
    typealias Rect = KnowledgeMapArranging.Rect

    // MARK: A dropped file

    /// What the Canvas does with a file dropped from the Finder, by its
    /// extension.
    enum FileKind: Equatable, Sendable {
        /// A PDF: imported as a paper, then placed as its source card.
        case paper
        /// Markdown or plain text: imported as a text source, then placed.
        case textSource
        /// A picture: kept in the Images library, then placed as a picture card.
        case picture
        /// A Word document. ForeverLM has no importer for one, so it is said
        /// so rather than half-imported.
        case wordDocument
        /// A book (EPUB, Kindle): it comes in as chapters under a book, not as
        /// one card, so the Sources list takes it.
        case book
        case unsupported
    }

    static let pictureExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp",
    ]

    static func fileKind(forExtension raw: String) -> FileKind {
        let ext = raw.lowercased()
        switch ext {
        case "pdf": return .paper
        case "md", "markdown", "txt": return .textSource
        case "docx", "doc": return .wordDocument
        case "epub", "azw", "azw3", "mobi", "prc": return .book
        default: return pictureExtensions.contains(ext) ? .picture : .unsupported
        }
    }

    /// The largest picture the Images library keeps from a drop or a paste, in
    /// bytes (the limit `save_image` applies).
    static let maximumPictureBytes = 20 * 1024 * 1024

    /// What the user is told for a file the Canvas cannot place, one line,
    /// naming the file.
    static func refusal(forFileNamed name: String, kind: FileKind) -> String {
        switch kind {
        case .wordDocument:
            return "\(name): ForeverLM cannot read Word documents yet. Save it as PDF or Markdown and drop that."
        case .book:
            return "\(name): a book comes in as chapters. Add it from Sources, then place what you want."
        default:
            return "\(name): the Canvas takes PDFs, Markdown and text files, and pictures."
        }
    }

    // MARK: A line of text pasted on the Canvas

    /// A card named by an address: `foreverlm://source/<id>`, `doc`, `idea`,
    /// `canvas`, `chat` or `notebook`, as the app writes and reads them
    /// (`StudioEntityLink`, a chat's citation). The running build's own
    /// scheme (`foreverlm-dev`) names the same card.
    struct CardLink: Equatable, Sendable {
        /// `source`, `doc`, `idea`, `canvas`, `chat` or `notebook`.
        let kind: String
        let id: String

        static let kinds: Set<String> = ["source", "doc", "idea", "canvas", "chat", "notebook"]

        init(kind: String, id: String) {
            self.kind = kind
            self.id = id
        }

        /// The card a text is the address of, or nil for any other text: the
        /// whole of the text must be the one address.
        init?(_ text: String, schemes: Set<String> = ["foreverlm"]) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
                  let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
                  let host = url.host?.lowercased() else { return nil }
            // `project` is the address a notebook had before the word changed.
            let kind = host == "project" ? "notebook" : host
            guard Self.kinds.contains(kind),
                  let raw = url.pathComponents.dropFirst().first,
                  let id = raw.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            self.kind = kind
            self.id = id
        }
    }

    /// Words pasted on the Canvas that are written as one Idea, in words: up
    /// to this many a paste is the Idea's title as it stands; more, and the
    /// first sentence is its title and the whole text its note.
    static let wordsForATitle = 25

    /// The Idea a pasted text makes: its title and, when the text is longer
    /// than a few words, the whole text as its note.
    static func idea(fromPasted text: String) -> (title: String, notes: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        if words <= wordsForATitle { return (trimmed, nil) }
        return (firstSentence(of: trimmed, limit: titleLimit), trimmed)
    }

    /// What a text pasted on the Canvas is: addresses to import, cards named
    /// by `foreverlm://` addresses, or words.
    enum Pasted: Equatable, Sendable {
        case links([String])
        case cards([CardLink])
        case words(String)
    }

    /// Reads a pasted text. Every whitespace-separated piece an address to
    /// import (`importableLink`: a web address or a DOI, answering the address
    /// to fetch) makes it `.links`; every piece a card's address, `.cards`;
    /// anything else is `.words`. Nil for no text at all.
    static func classify(
        pasted text: String,
        schemes: Set<String> = ["foreverlm"],
        importableLink: (String) -> String?
    ) -> Pasted? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pieces = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let cards = pieces.compactMap { CardLink($0, schemes: schemes) }
        if cards.count == pieces.count { return .cards(cards) }
        let links = pieces.compactMap { importableLink($0) }
        if links.count == pieces.count { return .links(links) }
        return .words(trimmed)
    }

    // MARK: The first sentence of an answer

    /// The longest an Idea's title is made from an answer's first sentence.
    static let titleLimit = 120

    /// The first sentence of `markdown` as plain words, at most `limit`
    /// characters: the first line with words in it, without its heading, list
    /// or quote mark, emphasis, links (their text stays) and pictures, up to
    /// the end of its first sentence, cut at a word with "…" when still too
    /// long. Empty when the text has no words.
    static func firstSentence(of markdown: String, limit: Int = titleLimit) -> String {
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = plainWords(of: String(rawLine))
            guard !line.isEmpty else { continue }
            let sentence = endOfFirstSentence(in: line)
            return cut(sentence, limit: limit)
        }
        return ""
    }

    private static func plainWords(of line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // A fence or a rule is no sentence.
        if text.hasPrefix("```") || text.hasPrefix("~~~") { return "" }
        if text.allSatisfy({ "-*_=# ".contains($0) }) { return "" }
        // Heading, quote and list marks, an ordered list's number.
        while let first = text.first, first == ">" || first == "#" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        for mark in ["- ", "* ", "+ "] where text.hasPrefix(mark) {
            text = String(text.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if let digits = text.firstIndex(where: { !$0.isNumber }), digits > text.startIndex,
           text[digits...].hasPrefix(". ") || text[digits...].hasPrefix(") ") {
            text = String(text[text.index(digits, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
        }
        // Pictures vanish, a link keeps its words.
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[\^?\d+\]"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "~~", "`", "*"] {
            text = text.replacingOccurrences(of: mark, with: "")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Up to and including the first full stop, question or exclamation mark
    /// that ends a word and is followed by a space or the line's end. A stop
    /// inside a number or an abbreviation of one letter ("e.g.", "3.5") is not
    /// the end.
    private static func endOfFirstSentence(in line: String) -> String {
        let characters = Array(line)
        for (index, character) in characters.enumerated() where ".?!".contains(character) {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard next == nil || next == " " || next == "\"" || next == "\u{201D}" else { continue }
            if character == ".", index >= 1, index + 1 < characters.count {
                // "e.g. ", "i.e. ", "Fig. 2": a short word before the stop.
                let before = characters[..<index].reversed().prefix { $0.isLetter }
                if before.count == 1 { continue }
                let word = String(before.reversed()).lowercased()
                if ["fig", "figs", "eq", "al", "vs", "etc", "cf", "ca", "no", "dr", "mr", "mrs", "ms", "prof"].contains(word) { continue }
            }
            var end = index + 1
            if end < characters.count, characters[end] == "\"" || characters[end] == "\u{201D}" { end += 1 }
            return String(characters[..<end])
        }
        return line
    }

    private static func cut(_ sentence: String, limit: Int) -> String {
        guard sentence.count > limit else { return sentence }
        let head = sentence.prefix(limit)
        let atWord = sentence[head.endIndex] == " "
            ? Substring(head)
            : head.lastIndex(of: " ").map { head[..<$0] } ?? Substring(head)
        let trimmed = atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        return trimmed + "…"
    }

    // MARK: Where cards go on a canvas that is not open

    /// What a layout holds, as rects: the placed cards, each as tall as it is
    /// drawn (`height`), and the regions. Cards in `excluding` are left out.
    static func occupied(in layout: KnowledgeMapLayout, height: (String) -> Double, excluding: Set<String> = []) -> [Rect] {
        layout.placements.filter { !excluding.contains($0.key) }.map {
            Rect(x: $0.value.x, y: $0.value.y, w: KnowledgeMap.cardWidth, h: height($0.key))
        } + layout.regions.values.map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
    }

    /// The bounds of what a layout holds; nil for an empty canvas.
    static func bounds(of rects: [Rect]) -> Rect? {
        guard let minX = rects.map(\.x).min(), let minY = rects.map(\.y).min(),
              let maxX = rects.map({ $0.x + $0.w }).max(), let maxY = rects.map({ $0.y + $0.h }).max() else { return nil }
        return Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// The size of the block `heights` make when laid out as a drop lays them
    /// (`KnowledgeMapArranging.block`), without the margin a region would add.
    static func blockSize(heights: [Double]) -> (w: Double, h: Double) {
        let laid = KnowledgeMapArranging.block(heights: heights, origin: Spot(x: 0, y: 0))
        return (w: laid.frame.w - KnowledgeMapArranging.insetX * 2, h: laid.frame.h - KnowledgeMapArranging.insetY - KnowledgeMapArranging.insetX)
    }

    /// The spots for `refs` set down on `layout` as one block at a free place:
    /// as near `center` as it can be (the middle of the view, when the canvas
    /// is open and showing), else, with no `center` given, just right of what
    /// the canvas holds and level with its top (an empty canvas starts at the
    /// origin), where a later arrival lands beside this one rather than on it.
    /// A ref already placed on the layout is left where it is and not returned:
    /// a canvas holds one card per source.
    static func arrival(
        of refs: [String],
        on layout: KnowledgeMapLayout,
        height: (String) -> Double,
        near center: Spot? = nil
    ) -> [(ref: String, x: Double, y: Double)] {
        var seen: Set<String> = []
        let fresh = refs.filter { layout.placements[$0] == nil && seen.insert($0).inserted }
        guard !fresh.isEmpty else { return [] }
        let heights = fresh.map(height)
        let size = blockSize(heights: heights)
        let taken = occupied(in: layout, height: height)
        let middle: Spot
        if let center {
            middle = center
        } else if let content = bounds(of: taken) {
            middle = Spot(
                x: content.x + content.w + 120 + size.w / 2,
                y: content.y + size.h / 2
            )
        } else {
            middle = Spot(x: size.w / 2, y: size.h / 2)
        }
        let origin = KnowledgeMapArranging.freeOrigin(size: size, near: middle, occupied: taken)
        let laid = KnowledgeMapArranging.block(heights: heights, origin: origin)
        return zip(fresh, laid.spots).map { (ref: $0, x: $1.x, y: $1.y) }
    }

    // MARK: Moving a selection to another canvas

    /// What a move takes with it: the placed cards asked for, the regions
    /// fully inside the bounds of those cards (and the regions nested in
    /// them), and the arrows between two things that move.
    struct Moved: Equatable, Sendable {
        var refs: [String] = []
        var regionIDs: [String] = []
        var edgeIDs: [String] = []

        var isEmpty: Bool { refs.isEmpty }
    }

    /// What moving `refs` off `layout` takes along. Cards that are not placed
    /// there are ignored, as is a card named twice.
    static func moving(_ refs: [String], from layout: KnowledgeMapLayout, height: (String) -> Double) -> Moved {
        var seen: Set<String> = []
        let placed = refs.filter { layout.placements[$0] != nil && seen.insert($0).inserted }
        guard !placed.isEmpty else { return Moved() }
        let cards = placed.map { ref -> Rect in
            let spot = layout.placements[ref]!
            return Rect(x: spot.x, y: spot.y, w: KnowledgeMap.cardWidth, h: height(ref))
        }
        let box = bounds(of: cards)!
        let slack = 0.5
        var regionIDs = Set(layout.regions.filter { _, region in
            region.x >= box.x - slack && region.y >= box.y - slack
                && region.x + region.w <= box.x + box.w + slack && region.y + region.h <= box.y + box.h + slack
        }.keys)
        // A region inside a region that moves moves with it.
        var queue = Array(regionIDs)
        while let next = queue.popLast() {
            for nested in layout.nestedRegionIDs(in: next) where regionIDs.insert(nested).inserted { queue.append(nested) }
        }
        let ends = Set(placed).union(regionIDs.map { "region:" + $0 })
        let edgeIDs = layout.edges.filter { _, edge in ends.contains(edge.from) && ends.contains(edge.to) }.keys.sorted()
        return Moved(refs: placed, regionIDs: regionIDs.sorted(), edgeIDs: edgeIDs)
    }

    /// Writes what `moved` is into `destination`, keeping the cards, regions
    /// and arrows where they are relative to each other, with their top left
    /// at a free place there (the same spot as on the source when the
    /// destination is empty). A card the destination holds already stays where
    /// it is there, and an arrow it already has between the same two ends is
    /// not drawn twice. Every entry is written at `stamp`, so it wins a merge.
    /// Returns the refs now on the destination, the moved ones included.
    @discardableResult
    static func write(
        _ moved: Moved,
        from source: KnowledgeMapLayout,
        into destination: inout KnowledgeMapLayout,
        height: (String) -> Double,
        at stamp: Double
    ) -> [String] {
        guard !moved.isEmpty else { return [] }
        let cards = moved.refs.map { ref -> Rect in
            let spot = source.placements[ref]!
            return Rect(x: spot.x, y: spot.y, w: KnowledgeMap.cardWidth, h: height(ref))
        }
        let regions = moved.regionIDs.compactMap { source.regions[$0] }.map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
        let box = bounds(of: cards + regions)!
        let taken = occupied(in: destination, height: height)
        var dx = 0.0, dy = 0.0
        if let content = bounds(of: taken) {
            let middle = Spot(x: content.x + content.w + 120 + box.w / 2, y: content.y + box.h / 2)
            let origin = KnowledgeMapArranging.freeOrigin(size: (box.w, box.h), near: middle, occupied: taken)
            dx = origin.x - box.x
            dy = origin.y - box.y
        }
        for ref in moved.refs where destination.placements[ref] == nil {
            var placement = source.placements[ref]!
            placement.x += dx
            placement.y += dy
            placement.at = stamp
            destination.placements[ref] = placement
            destination.removed.removeValue(forKey: "p:" + ref)
        }
        for id in moved.regionIDs {
            guard var region = source.regions[id] else { continue }
            region.x += dx
            region.y += dy
            region.at = stamp
            destination.setRegion(id, region)
        }
        for id in moved.edgeIDs {
            guard var edge = source.edges[id] else { continue }
            let drawn = destination.edges.values.contains { $0.from == edge.from && $0.to == edge.to }
            guard !drawn else { continue }
            edge.at = stamp
            destination.setEdge(id, edge)
        }
        return moved.refs
    }

    /// The canvases of `layouts` (by id) that hold `ref`.
    static func canvasIDs(holding ref: String, in layouts: [String: KnowledgeMapLayout]) -> [String] {
        layouts.filter { $0.value.placements[ref] != nil }.map(\.key).sorted()
    }
}

// MARK: - A drop or a paste, as the Canvas's web view reads it

/// What came onto the Canvas from outside it, besides the app's own cards: the
/// Finder's files, pictures (raw, or promised by an app such as Screenshots),
/// chats dragged from a list, addresses and words pasted. The web view
/// (`KnowledgeMapWebView`) fills it from the pasteboard and
/// `StudioViewModel.knowledgeMapOutsideRefs` makes cards of it.
struct KnowledgeMapOutsideDrop: Equatable, Sendable {
    /// A picture as bytes, from the pasteboard or a promised file, with the
    /// name it should be kept under.
    struct Picture: Equatable, Sendable {
        var data: Data
        var name: String
    }

    var fileURLs: [URL] = []
    var pictures: [Picture] = []
    /// Review sessions (chats) dragged from a list: `chat:<id>` cards.
    var chatIDs: [String] = []
    /// Web addresses and DOIs, each imported as a source.
    var links: [String] = []
    /// Cards named by a `foreverlm://` address that the drop fields above do
    /// not already carry (an Idea, a canvas or a chat), as item refs.
    var cardRefs: [String] = []
    /// Words pasted: written as an Idea at the middle of the view.
    var text: String?
    /// A folder the web view had promised files delivered into; removed when
    /// the import is done.
    var stagingDirectory: URL?

    var isEmpty: Bool {
        fileURLs.isEmpty && pictures.isEmpty && chatIDs.isEmpty && links.isEmpty && cardRefs.isEmpty
            && (text?.isEmpty ?? true)
    }

    /// Takes the notebooks out of `cardRefs` (`notebook:<id>`) and returns
    /// their ids: a notebook is set down by the drop the app's own notebook
    /// drags use (its sources and what it made inside a frame), not as a card.
    mutating func takeNotebookIDs() -> [String] {
        let prefix = "notebook:"
        let ids = cardRefs.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        cardRefs.removeAll { $0.hasPrefix(prefix) }
        return ids
    }

    /// What a pasted text adds: the addresses to import, the cards it names,
    /// or the words as an Idea. `schemes` are the URL schemes the running
    /// build reads as its own.
    mutating func add(pastedText text: String, schemes: Set<String>, importableLink: (String) -> String?) {
        switch KnowledgeMapOutside.classify(pasted: text, schemes: schemes, importableLink: importableLink) {
        case .links(let addresses): links.append(contentsOf: addresses)
        case .cards(let named): cardRefs.append(contentsOf: named.map { "\($0.kind):\($0.id)" })
        case .words(let words): self.text = words
        case nil: break
        }
    }
}
