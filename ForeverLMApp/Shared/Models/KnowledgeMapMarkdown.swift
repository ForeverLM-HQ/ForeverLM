import Foundation

// MARK: - A canvas as an outline
//
// Heptabase exports a selection's cards as Markdown; the Canvas does the same
// (docs/heptabase-canvas-parity.md, "Sharing, export, platforms"), and a
// published canvas shows the same outline under its picture
// (docs/knowledge-map-design.md, "Versions, export and publishing").
// `KnowledgeMapMarkdown.outline` reads the learner's layout and the cards'
// words once, and the outline writes itself as Markdown (Copy as Markdown) or
// as the HTML body of a published page, so the two never drift.
//
// Foundation only and pure: the layout, the cards' faces and the links to use
// come in, text comes out, so a test reads it as the Mac does.

/// A canvas, or the cards of it that were asked for, as the text it reads as:
/// cards outside any region first, then each region under its name (nested
/// regions deeper, outermost first, in reading order), then the arrows.
struct KnowledgeMapOutline: Equatable, Sendable {
    /// One card as a line of the outline.
    struct Entry: Equatable, Sendable {
        /// `source`, `doc`, `idea`, `clip`, `page`, `picture`, `chat`,
        /// `canvas`, or another kind's own word.
        var kind: String
        /// Its name on one line.
        var title: String
        /// What follows the name: a paper's authors · venue · year, the
        /// paper and page a figure was cut from.
        var detail: String? = nil
        /// An Idea's words, or the learner's note on a clip.
        var note: String? = nil
        /// A passage's quoted words.
        var quote: String? = nil
        /// Where the name leads: the app's own address (`foreverlm://…`) in
        /// Markdown for the pasteboard, a public address on a page.
        var link: String? = nil
        /// The learner's words about the card on this canvas ("why it is
        /// here"), under its note.
        var annotation: String? = nil
        /// An Idea whose title is a question, written with a box before it:
        /// ☐ while open, ☑ once the learner marked it answered.
        var isQuestion = false
        var isAnswered = false
    }

    /// A region, as a heading over its cards.
    struct Section: Equatable, Sendable {
        /// The heading's level: 2 for a region on the plane itself, one more
        /// for each region it sits inside, at most 6.
        var level: Int
        var name: String
        var entries: [Entry]
    }

    /// An arrow, as "A → B: label (supports)".
    struct Connection: Equatable, Sendable {
        var from: String
        var to: String
        var label: String
        /// The side of an argument the arrow is on, written after its label.
        var stance: KnowledgeMapEdgeStance? = nil
    }

    var loose: [Entry]
    var sections: [Section]
    var connections: [Connection]

    /// Nothing to write: no card, no region, no arrow.
    var isEmpty: Bool {
        loose.isEmpty && sections.isEmpty && connections.isEmpty
    }

    /// The heading the arrows are listed under.
    static let connectionsHeading = "Connections"

    // MARK: Markdown

    /// The outline as Markdown: the loose cards as a list, each region as a
    /// heading over its list, and the arrows last under "Connections". Empty
    /// text for an empty outline.
    var markdown: String {
        var blocks: [String] = []
        if !loose.isEmpty { blocks.append(Self.list(loose)) }
        for section in sections {
            var block = String(repeating: "#", count: section.level) + " " + KnowledgeMapMarkdown.inline(section.name)
            if !section.entries.isEmpty { block += "\n\n" + Self.list(section.entries) }
            blocks.append(block)
        }
        if !connections.isEmpty {
            let lines = connections.map { connection -> String in
                let ends = "\(KnowledgeMapMarkdown.inline(connection.from)) → \(KnowledgeMapMarkdown.inline(connection.to))"
                let line = connection.label.isEmpty ? "- \(ends)" : "- \(ends): \(KnowledgeMapMarkdown.inline(connection.label))"
                return line + (connection.stance.map { " (\($0.rawValue))" } ?? "")
            }
            blocks.append("## \(Self.connectionsHeading)\n\n" + lines.joined(separator: "\n"))
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    private static func list(_ entries: [Entry]) -> String {
        entries.map { $0.markdownLines.joined(separator: "\n") }.joined(separator: "\n")
    }

    // MARK: HTML

    /// The outline as the body of a page: the same headings and lists, every
    /// name a link only where the entry has a web address (`http` or `https`;
    /// the app's own addresses mean nothing in a browser).
    var html: String {
        var parts: [String] = []
        if !loose.isEmpty { parts.append(Self.htmlList(loose)) }
        for section in sections {
            let level = min(max(section.level, 2), 6)
            var block = "<h\(level)>\(KnowledgeMapMarkdown.escapedHTML(section.name))</h\(level)>"
            if !section.entries.isEmpty { block += "\n" + Self.htmlList(section.entries) }
            parts.append(block)
        }
        if !connections.isEmpty {
            let items = connections.map { connection -> String in
                let ends = "\(KnowledgeMapMarkdown.escapedHTML(connection.from)) → \(KnowledgeMapMarkdown.escapedHTML(connection.to))"
                let label = connection.label.isEmpty ? "" : ": \(KnowledgeMapMarkdown.escapedHTML(connection.label))"
                let stance = connection.stance.map { " <span class=\"detail\">(\($0.rawValue))</span>" } ?? ""
                return "<li>\(ends)\(label)\(stance)</li>"
            }
            parts.append("<h2>\(Self.connectionsHeading)</h2>\n<ul>\n" + items.joined(separator: "\n") + "\n</ul>")
        }
        return parts.joined(separator: "\n")
    }

    private static func htmlList(_ entries: [Entry]) -> String {
        "<ul>\n" + entries.map { "<li>\($0.htmlFragment)</li>" }.joined(separator: "\n") + "\n</ul>"
    }
}

extension KnowledgeMapOutline.Entry {
    /// What the line's text is: a passage's quoted words, else the name.
    private var label: String {
        if let quote, !quote.isEmpty { return "“\(quote)”" }
        return title
    }

    /// Whether the line's detail sits in brackets after the name (a figure
    /// and the paper it was cut from) rather than after a dash.
    private var detailInBrackets: Bool { kind == "clip" || kind == "page" }

    /// The lines of some words, trimmed, with the blank ones left out.
    private func wordLines(_ text: String?) -> [String] {
        (text ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The box a question is written with, or nothing for any other entry.
    private var questionBox: String {
        isQuestion ? (isAnswered ? "☑ " : "☐ ") : ""
    }

    /// The entry as lines of a Markdown list: the item, then its note and
    /// the learner's words about it indented under it, a line break kept
    /// between their lines.
    var markdownLines: [String] {
        var lines = [markdownItem]
        let words = (wordLines(note) + wordLines(annotation)).map(KnowledgeMapMarkdown.inline)
        for (index, line) in words.enumerated() {
            // Two spaces at the end of a line are Markdown's line break.
            lines.append("  " + line + (index < words.count - 1 ? "  " : ""))
        }
        return lines
    }

    /// The first line of the entry's list item.
    private var markdownItem: String {
        if kind == "picture" {
            let name = KnowledgeMapMarkdown.inline(title)
            guard let link, !link.isEmpty else { return "- ![\(name)]" }
            return "- ![\(name)](\(KnowledgeMapMarkdown.destination(link)))"
        }
        var text = KnowledgeMapMarkdown.inline(label)
        if kind == "idea" { text = "**\(text)**" }
        if let link, !link.isEmpty { text = "[\(text)](\(KnowledgeMapMarkdown.destination(link)))" }
        if let detail, !detail.isEmpty {
            text += detailInBrackets ? " (\(KnowledgeMapMarkdown.inline(detail)))" : " — \(KnowledgeMapMarkdown.inline(detail))"
        }
        return "- \(questionBox)\(text)"
    }

    /// The entry as the inside of a list item on a page.
    var htmlFragment: String {
        let escape = KnowledgeMapMarkdown.escapedHTML
        var text: String
        if kind == "picture" {
            text = "<em>\(escape(title))</em>"
        } else {
            text = escape(label)
            if kind == "idea" { text = "<strong>\(text)</strong>" }
            if let link, KnowledgeMapMarkdown.isWebAddress(link) {
                text = "<a href=\"\(escape(link))\">\(text)</a>"
            }
            if let detail, !detail.isEmpty {
                text += detailInBrackets ? " <span class=\"detail\">(\(escape(detail)))</span>" : " <span class=\"detail\">— \(escape(detail))</span>"
            }
        }
        let words = (wordLines(note) + wordLines(annotation)).map(escape)
        if !words.isEmpty { text += "<br>\n<span class=\"note\">" + words.joined(separator: "<br>\n") + "</span>" }
        return questionBox + text
    }
}

/// Reads a layout and its cards into a `KnowledgeMapOutline`.
enum KnowledgeMapMarkdown {
    /// Copy as Markdown: the canvas, or `refs` of it, as Markdown. With `refs`
    /// empty, every card on the plane. See `outline` for what is written.
    static func render(
        layout: KnowledgeMapLayout,
        nodes: [String: KnowledgeMapNode],
        refs: [String] = [],
        cardSize: ((String) -> (w: Double, h: Double))? = nil,
        linkFor: (KnowledgeMapNode) -> String? = KnowledgeMapMarkdown.appLink
    ) -> String {
        outline(layout: layout, nodes: nodes, refs: refs, cardSize: cardSize, linkFor: linkFor).markdown
    }

    /// The outline of a canvas.
    ///
    /// - Cards outside any region come first, under no heading; a card is in
    ///   the smallest region holding its middle, as the renderer reads it.
    /// - Each region is a heading (`##`, one more `#` for each region it sits
    ///   inside), outermost first, in reading order: rows from the top of the
    ///   plane, left to right within a row. Its cards follow, in reading
    ///   order, then its nested regions.
    /// - An arrow between two cards that are written is a line under
    ///   "Connections", in the order the cards are.
    /// - A card is written only when the library still holds it (it has a
    ///   node); `refs` limits the outline to those cards, and a region is
    ///   written only when it holds one of them or sits around one that does.
    ///
    /// `cardSize` is a card's width and height on the plane (a clip is as
    /// tall as its picture); without it, a card is the usual size.
    static func outline(
        layout: KnowledgeMapLayout,
        nodes: [String: KnowledgeMapNode],
        refs: [String] = [],
        cardSize: ((String) -> (w: Double, h: Double))? = nil,
        linkFor: (KnowledgeMapNode) -> String? = KnowledgeMapMarkdown.appLink
    ) -> KnowledgeMapOutline {
        let wanted = Set(refs)
        let size: (String) -> (w: Double, h: Double) = { ref in
            cardSize?(ref) ?? (KnowledgeMap.cardWidth, nodes[ref]?.h ?? KnowledgeMap.cardHeight)
        }
        // The cards to write, and the smallest region holding each one's middle.
        var included: Set<String> = []
        var cardsByRegion: [String: [String]] = [:]
        var loose: [String] = []
        for (ref, spot) in layout.placements where nodes[ref] != nil && (wanted.isEmpty || wanted.contains(ref)) {
            included.insert(ref)
            let box = size(ref)
            let cx = spot.x + box.w / 2, cy = spot.y + box.h / 2
            let home = layout.regions
                .filter { _, region in
                    cx >= region.x && cx <= region.x + region.w && cy >= region.y && cy <= region.y + region.h
                }
                .min { lhs, rhs in
                    let a = lhs.value.w * lhs.value.h, b = rhs.value.w * rhs.value.h
                    return a != b ? a < b : lhs.key < rhs.key
                }?.key
            if let home { cardsByRegion[home, default: []].append(ref) } else { loose.append(ref) }
        }
        let position: (String) -> (x: Double, y: Double) = { ref in
            let spot = layout.placements[ref]
            return (spot?.x ?? 0, spot?.y ?? 0)
        }
        let rowHeight = KnowledgeMap.cardHeight / 2
        func entries(_ list: [String]) -> [(ref: String, entry: KnowledgeMapOutline.Entry)] {
            readingOrder(list, position: position, rowHeight: rowHeight).compactMap { ref in
                guard let node = nodes[ref] else { return nil }
                return (ref, entry(for: node, link: linkFor(node), placement: layout.placements[ref]))
            }
        }

        // The regions to write: all of them for the whole canvas; for a
        // selection, those holding a chosen card or around one that does.
        var shown = Set(layout.regions.keys)
        if !wanted.isEmpty {
            shown = []
            for id in cardsByRegion.keys {
                shown.insert(id)
                for ancestor in layout.regionPath(of: id) { shown.insert(ancestor) }
            }
        }
        let regionPosition: (String) -> (x: Double, y: Double) = { id in
            let region = layout.regions[id]
            return (region?.x ?? 0, region?.y ?? 0)
        }
        // Which region each one sits inside, read once: it walks every region.
        var parents: [String: String] = [:]
        for id in layout.regions.keys {
            if let parent = layout.parentRegionID(of: id) { parents[id] = parent }
        }
        var sections: [KnowledgeMapOutline.Section] = []
        var order: [String: Int] = [:]
        var next = 0
        func noteOrder(_ key: String) {
            order[key] = next
            next += 1
        }
        let looseEntries = entries(loose)
        looseEntries.forEach { noteOrder($0.ref) }

        func visit(_ id: String, depth: Int) {
            guard shown.contains(id), let region = layout.regions[id] else { return }
            noteOrder("region:\(id)")
            let written = entries(cardsByRegion[id] ?? [])
            written.forEach { noteOrder($0.ref) }
            let name = region.name.trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(.init(
                level: min(2 + depth, 6),
                name: name.isEmpty ? "Untitled region" : singleLine(name),
                entries: written.map(\.entry)
            ))
            let children = layout.regions.keys.filter { parents[$0] == id }
            for child in readingOrder(children, position: regionPosition, rowHeight: KnowledgeMap.cardHeight) {
                visit(child, depth: depth + 1)
            }
        }
        let roots = layout.regions.keys.filter { parents[$0] == nil }
        for root in readingOrder(roots, position: regionPosition, rowHeight: KnowledgeMap.cardHeight) {
            visit(root, depth: 0)
        }

        // Arrows whose two ends are both written.
        func title(of end: String) -> String? {
            if end.hasPrefix("region:") {
                let id = String(end.dropFirst("region:".count))
                guard shown.contains(id), let region = layout.regions[id] else { return nil }
                let name = region.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Untitled region" : singleLine(name)
            }
            guard let node = nodes[end], included.contains(end) else { return nil }
            return singleLine(node.title)
        }
        let ends = layout.edges
            .compactMap { id, edge -> (id: String, edge: KnowledgeMapLayout.Edge, from: String, to: String)? in
                guard let from = title(of: edge.from), let to = title(of: edge.to) else { return nil }
                return (id, edge, from, to)
            }
            .sorted { lhs, rhs in
                let l = (order[lhs.edge.from] ?? .max, order[lhs.edge.to] ?? .max)
                let r = (order[rhs.edge.from] ?? .max, order[rhs.edge.to] ?? .max)
                if l != r { return l < r }
                if lhs.edge.label != rhs.edge.label { return lhs.edge.label < rhs.edge.label }
                return lhs.id < rhs.id
            }
        let connections = ends.map {
            KnowledgeMapOutline.Connection(from: $0.from, to: $0.to, label: singleLine($0.edge.label), stance: $0.edge.knownStance)
        }
        return KnowledgeMapOutline(loose: looseEntries.map(\.entry), sections: sections, connections: connections)
    }

    // MARK: One card

    /// A card as a line of the outline, from its words on the plane and, when
    /// it is placed, what the learner wrote about it on this canvas: the
    /// words under any card but an Idea, and whether a question is answered.
    static func entry(for node: KnowledgeMapNode, link: String?, placement: KnowledgeMapLayout.Placement? = nil) -> KnowledgeMapOutline.Entry {
        var written = plainEntry(for: node, link: link)
        if written.kind == "idea" {
            written.isQuestion = KnowledgeMap.isQuestion(node.title)
            written.isAnswered = written.isQuestion && placement?.isAnswered == true
        } else {
            written.annotation = placement?.annotation
        }
        return written
    }

    private static func plainEntry(for node: KnowledgeMapNode, link: String?) -> KnowledgeMapOutline.Entry {
        let title = singleLine(node.title)
        let sub = singleLine(node.sub)
        switch kind(of: node.ref) {
        case "idea":
            // An Idea with no note says "Idea" where its note would be.
            let note = node.sub.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(kind: "idea", title: title, note: note.isEmpty || note == "Idea" ? nil : note, link: link)
        case "source":
            return .init(kind: "source", title: title, detail: sub.isEmpty ? nil : sub, link: link)
        case "clip":
            // A figure: "Figure 2" cut from "Paper · p. 4"; a passage: the words, then the same.
            let note = (node.detail.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = node.quote.map { singleLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
            return .init(
                kind: "clip", title: title, detail: bracketed(sub), note: note.isEmpty ? nil : note,
                quote: quote, link: link
            )
        case "page":
            return .init(kind: "page", title: title, detail: sub.isEmpty ? nil : sub, link: link)
        case "picture":
            return .init(kind: "picture", title: title, link: link)
        default:
            // A Doc, a chat, a canvas: its name, and what its card says under it.
            return .init(kind: kind(of: node.ref), title: title, detail: sub.isEmpty ? nil : sub, link: link)
        }
    }

    /// "Paper · p. 4" as "Paper, p. 4".
    private static func bracketed(_ sub: String) -> String? {
        let text = sub.replacingOccurrences(of: " · p. ", with: ", p. ")
        return text.isEmpty ? nil : text
    }

    /// The word before a ref's first colon: `source`, `doc`, `idea`, `clip`,
    /// `page`, `picture`, `chat`, `canvas`.
    static func kind(of ref: String) -> String {
        guard let colon = ref.firstIndex(of: ":") else { return ref }
        return String(ref[..<colon])
    }

    // MARK: Addresses

    /// The app's own address for a card, written into Markdown so a pasted
    /// outline opens its cards in ForeverLM: a source (a figure or a page of
    /// it opens at its page), a Doc, a chat, and a picture in the image
    /// store. An Idea and a canvas have none.
    static func appLink(for node: KnowledgeMapNode) -> String? {
        let ref = node.ref
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        let id = String(ref[ref.index(after: colon)...])
        switch kind(of: ref) {
        case "source":
            return "foreverlm://source/\(ReportMarkdown.pathComponent(id))"
        case "doc":
            return StudioEntityLink.doc(id).markdownDestination
        case "chat":
            return StudioEntityLink.chat(id).markdownDestination
        case "picture":
            return GeneratedImageReference(id: id)?.urlString
        case "clip", "page":
            guard let src = node.src, src.hasPrefix("source:") else { return nil }
            let sourceID = String(src.dropFirst("source:".count))
            var link = "foreverlm://source/\(ReportMarkdown.pathComponent(sourceID))"
            if let page = pageNumber(of: node) { link += "?page=\(page)" }
            return link
        default:
            return nil
        }
    }

    /// The page a clip or page card sits on, from its card: a page card's
    /// ref ends in it, a clip's second line says "p. 4".
    private static func pageNumber(of node: KnowledgeMapNode) -> Int? {
        if let parts = KnowledgeMap.ItemRef(node.ref)?.pageParts { return parts.page }
        guard let range = node.sub.range(of: " · p. ", options: .backwards) else { return nil }
        let digits = node.sub[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    static func isWebAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    // MARK: Text

    /// One line: runs of whitespace folded to a space and trimmed.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Text as the inside of a Markdown line: on one line, with the
    /// characters that would start a style or end a link early escaped.
    static func inline(_ text: String) -> String {
        var out = ""
        for character in singleLine(text) {
            if "\\`*_[]<>".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// A link's address as it stands in `(…)`: spaces and brackets that
    /// could end it early percent-encoded.
    static func destination(_ address: String) -> String {
        var out = ""
        for character in address.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch character {
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "<": out += "%3C"
            case ">": out += "%3E"
            default: out.append(character)
            }
        }
        return out
    }

    static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Reading order

    /// `ids` in reading order: rows from the top of the plane, left to right
    /// within a row. A row takes everything within `rowHeight` of its first
    /// card's top, so cards a few points out of line still read left to
    /// right. Ties fall back on the id, so the order never wavers.
    static func readingOrder(
        _ ids: [String],
        position: (String) -> (x: Double, y: Double),
        rowHeight: Double
    ) -> [String] {
        let byTop = ids.sorted { lhs, rhs in
            let l = position(lhs), r = position(rhs)
            if l.y != r.y { return l.y < r.y }
            if l.x != r.x { return l.x < r.x }
            return lhs < rhs
        }
        var rows: [[String]] = []
        var anchor = 0.0
        for id in byTop {
            let y = position(id).y
            if rows.isEmpty || y - anchor >= rowHeight {
                rows.append([id])
                anchor = y
            } else {
                rows[rows.count - 1].append(id)
            }
        }
        return rows.flatMap { row in
            row.sorted { lhs, rhs in
                let l = position(lhs), r = position(rhs)
                if l.x != r.x { return l.x < r.x }
                if l.y != r.y { return l.y < r.y }
                return lhs < rhs
            }
        }
    }
}
