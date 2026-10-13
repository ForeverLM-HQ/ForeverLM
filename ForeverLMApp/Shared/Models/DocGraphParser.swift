import Foundation

// MARK: - Reading a Doc as blocks (docs/notes-graph-design.md, "Grammar")
//
// The notes graph reads a Doc's stored Markdown, never the editor's document,
// so the rules below are what the editor, the Mac host and MCP rely on when
// they name a block. `DocGraphParser.parse` is pure: the same text gives the
// same blocks and the same keys on every Mac.
//
// **What is a block.** A paragraph; an ATX (`## Title`) or setext heading; a
// paragraph inside a block quote (kind `quote`; every level of `>` reads as
// one quote); and a list item (`-`, `*`, `+`, `1.`, `1)`, task items `- [ ]`
// and `- [x]`), nested by indentation the way CommonMark nests them, lazy
// continuation lines included. A list item's own text is its first paragraph
// (or a heading written on its line); a later paragraph in the same item is a
// block of its own. An empty list item is a block with empty text, so the
// items under it keep their places.
//
// **What is not a block, and never grammar.** Fenced code (``` and ~~~),
// indented code, display math (`$$` lines), HTML blocks and front matter
// (`---` … `---` at the very top, holding `key: value` lines): nothing inside
// them is read, and nothing inside an inline code span is either. Tables,
// thematic breaks and paragraphs that are only pictures are not blocks; a
// table's grammar is not read for the graph, though `docGraphResolvedMarkdown`
// still turns it into words for a reader.
//
// **Keys.** A block's key names it at one revision. The top-level blocks of
// the Doc are numbered from 0 in order (code, tables and rules count too);
// a list is one of them. A list item's key is its list's key followed by its
// index among the items of that list, and an item nested in another by the
// outer item's key and its index among the items directly under that item
// ("4", "4.2", "4.2.0"). A container's later text blocks — a list item's second
// paragraph, a quote's second paragraph — add `~n`, n counting the container's
// own text blocks from 0 ("4.2~1", "6~1"). A quote nested in a list item is
// part of that item.
//
// **Breadcrumbs** read outermost first: the heading of the section the block
// stands in (the nearest heading above it at the top level of the Doc; for a
// heading, the nearest one of a higher level), then the list items it is
// nested in, outermost first. Empty texts are left out.
//
// **markdown** is the block's own inline Markdown with its structure taken
// off — the list marker, the heading's hashes and closing hashes, the `>`, the
// indentation — and its ` ^id` marker removed. A task item keeps its box
// (`[ ] Buy milk`); text spread over lines keeps its line breaks.
// **plainText** is that text as a reader sees it: link and code text kept;
// emphasis, code marks, pictures, HTML tags, backslash escapes and a task's box
// dropped; whitespace collapsed. The notes grammar stays as written —
// `[[Title]]`, `#tag`, `((id))` — because the editor holds it as text too.
// **childrenMarkdown** is everything nested in a list item after its own text,
// unindented to stand alone, with any ` ^id` markers of its own blocks kept.
// **line** is the 0-based line the block's own text starts on.

/// What one block points at, read from its own text.
struct DocGraphBlockLinks: Equatable, Sendable {
    /// Docs linked by id, `[…](foreverlm://doc/<id>)`, once each, in order.
    var docIDs: [String] = []
    /// Ideas linked by id, `[…](foreverlm://idea/<id>)`.
    var ideaIDs: [String] = []
    /// The source ids and `book:` tokens its `foreverlm://source` and
    /// `foreverlm://grounding` addresses carry (`StorageService.groundingTokens`).
    var sourceTokens: [String] = []
    /// The web addresses it cites (`StorageService.webReferences`).
    var webReferences: [String] = []
    /// Blocks it references inline, `((id))`.
    var blockReferences: [String] = []
    /// The block a paragraph that is only `{{embed: ((id))}}` embeds.
    var embeds: [String] = []
    /// The pages it names by title — `[[Title]]`, `#tag`, `#[[Two words]]` —
    /// as `DocGraphSyntax.normalizedTitle` writes them.
    var titles: [String] = []
    /// The days among those titles: `[[October 6th, 2026]]` names that day's
    /// daily note whether or not it exists.
    var dayKeys: [String] = []

    var isEmpty: Bool {
        docIDs.isEmpty && ideaIDs.isEmpty && sourceTokens.isEmpty && webReferences.isEmpty
            && blockReferences.isEmpty && embeds.isEmpty && titles.isEmpty
    }
}

/// One block as the graph remembers it: the answer shape, what the block
/// points at, and where its text stands in the Doc.
struct DocGraphParsedBlock: Equatable, Sendable {
    /// One line of the block's own text in the Doc.
    struct Segment: Equatable, Sendable {
        /// The line, 0-based.
        let line: Int
        /// The UTF-16 offset in that line where the block's text on it begins.
        let column: Int
        /// The UTF-16 length of that line's part of `block.markdown`.
        let length: Int
    }

    var block: DocGraphBlock
    var links: DocGraphBlockLinks
    /// 1–6 for a heading; nil for any other block.
    var headingLevel: Int?
    /// Whether the paragraph is nothing but `{{embed: ((id))}}`.
    var isEmbedOnly: Bool
    /// `block.markdown` line by line: the first segment holds its first line.
    var segments: [Segment]
    /// `block.plainText` folded for matching (case, accents and width), what
    /// search and unlinked mentions compare against.
    var searchText: String
}

/// A Doc read as blocks.
struct DocGraphParse: Equatable, Sendable {
    var blocks: [DocGraphParsedBlock]
    /// The lines no grammar is read in or written to: code, display math, HTML
    /// blocks, front matter, thematic breaks.
    var verbatimLines: IndexSet

    static let empty = DocGraphParse(blocks: [], verbatimLines: IndexSet())

    func block(atKey key: String) -> DocGraphParsedBlock? {
        blocks.first { $0.block.key == key }
    }

    func block(withID blockID: String) -> DocGraphParsedBlock? {
        blocks.first { $0.block.blockID == blockID }
    }
}

enum DocGraphParser {
    /// The blocks of a Doc's Markdown, in the order they stand.
    static func parse(_ markdown: String, docID: String) -> DocGraphParse {
        let lines = DocGraphLines(markdown)
        let builder = DocGraphTreeBuilder(lines: lines)
        let refs = (0..<lines.count).map { DocGraphLineRef(line: $0, column: 0) }
        let nodes = builder.parse(refs, atDocumentStart: true)
        var emitter = DocGraphEmitter(lines: lines, docID: docID)
        emitter.emitDocument(nodes)
        return DocGraphParse(blocks: emitter.blocks, verbatimLines: emitter.verbatim)
    }
}

// MARK: - Lines

/// A Markdown text as lines, with where each starts in the whole, so a block's
/// text can be found again in it.
struct DocGraphLines {
    let text: String
    /// Each line's UTF-16 units, without its "\n" or a "\r" before it.
    let units: [[UInt16]]
    /// The UTF-16 offset each line starts at in `text`.
    let starts: [Int]
    /// Whether the line ended in "\r\n".
    let carriageReturns: [Bool]

    init(_ text: String) {
        self.text = text
        var units: [[UInt16]] = [[]]
        var starts: [Int] = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 {
                units.append([])
                starts.append(offset)
            } else {
                units[units.count - 1].append(unit)
            }
        }
        var carriageReturns = Array(repeating: false, count: units.count)
        for index in units.indices where units[index].last == 13 {
            units[index].removeLast()
            carriageReturns[index] = true
        }
        self.units = units
        self.starts = starts
        self.carriageReturns = carriageReturns
    }

    var count: Int { units.count }

    /// A line's text from a UTF-16 column on.
    func string(_ line: Int, from column: Int = 0) -> String {
        let all = units[line]
        return String(decoding: all[min(max(column, 0), all.count)...], as: UTF16.self)
    }

    /// Where a line's text (without its "\r") stands in `text`.
    func range(ofLine line: Int) -> NSRange {
        NSRange(location: starts[line], length: units[line].count)
    }
}

// MARK: - Block structure

private struct DocGraphLineRef: Equatable {
    let line: Int
    /// The UTF-16 offset in the line where this container's view of it starts.
    let column: Int
}

private struct DocGraphTreeItem {
    let markerLine: Int
    /// Where the item's content begins on its marker line.
    let contentColumn: Int
    /// The item's lines, each seen from the item's content column (a lazy
    /// continuation line from its first character).
    let content: [DocGraphLineRef]
    let children: [DocGraphTreeNode]
}

private enum DocGraphTreeNode {
    case paragraph([DocGraphLineRef])
    case heading(level: Int, lines: [DocGraphLineRef], atx: Bool)
    case list([DocGraphTreeItem])
    case quote([DocGraphTreeNode])
    /// Lines that are not blocks and hold no grammar.
    case verbatim([Int])
    /// Not a block, but not verbatim either: a table.
    case other
}

private struct DocGraphListMarker {
    let ordered: Bool
    /// The bullet, or an ordered list's `.` or `)`.
    let symbol: UInt16
    let number: Int
    /// UTF-16 units from the view's start to the item's content.
    let contentOffset: Int
    /// The indentation, from the view's start, a line needs to be inside the item.
    let contentWidth: Int
    let isEmpty: Bool

    func continues(_ other: DocGraphListMarker) -> Bool {
        ordered == other.ordered && symbol == other.symbol
    }
}

private struct DocGraphFence {
    /// A backtick, a tilde, or `$` for display math.
    let mark: UInt16
    /// The run's length; 0 for display math opened and closed on one line.
    let length: Int
}

private enum Unit {
    static let tab: UInt16 = 9
    static let space: UInt16 = 32
    static let bang: UInt16 = 33
    static let hash: UInt16 = 35
    static let dollar: UInt16 = 36
    static let rightParen: UInt16 = 41
    static let star: UInt16 = 42
    static let plus: UInt16 = 43
    static let dash: UInt16 = 45
    static let period: UInt16 = 46
    static let slash: UInt16 = 47
    static let colon: UInt16 = 58
    static let lessThan: UInt16 = 60
    static let equals: UInt16 = 61
    static let greaterThan: UInt16 = 62
    static let question: UInt16 = 63
    static let backslash: UInt16 = 92
    static let underscore: UInt16 = 95
    static let backtick: UInt16 = 96
    static let pipe: UInt16 = 124
    static let tilde: UInt16 = 126

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    static func isLetter(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) }
    static func isSpace(_ unit: UInt16) -> Bool { unit == space || unit == tab }
}

/// CommonMark's block structure, as much of it as the graph needs.
private struct DocGraphTreeBuilder {
    let lines: DocGraphLines

    // MARK: Lines

    /// The indentation of a line seen from `column`, in columns (a tab
    /// reaching the next multiple of four), and where its text begins.
    func indentation(_ units: [UInt16], from column: Int) -> (width: Int, end: Int) {
        var width = 0
        var index = column
        while index < units.count {
            if units[index] == Unit.space {
                width += 1
            } else if units[index] == Unit.tab {
                width += 4 - (width % 4)
            } else {
                break
            }
            index += 1
        }
        return (width, index)
    }

    func isBlank(_ ref: DocGraphLineRef) -> Bool {
        let units = lines.units[ref.line]
        return indentation(units, from: ref.column).end >= units.count
    }

    /// The line seen `width` columns further in, or from its text when it is
    /// indented less than that.
    func stripping(_ width: Int, from ref: DocGraphLineRef) -> DocGraphLineRef {
        let units = lines.units[ref.line]
        var consumed = 0
        var index = ref.column
        while index < units.count, consumed < width {
            if units[index] == Unit.space {
                consumed += 1
            } else if units[index] == Unit.tab {
                consumed += 4 - (consumed % 4)
            } else {
                break
            }
            index += 1
        }
        return DocGraphLineRef(line: ref.line, column: index)
    }

    // MARK: Recognizing lines

    func atxHeading(_ units: [UInt16], at start: Int) -> (level: Int, textStart: Int)? {
        var index = start
        while index < units.count, units[index] == Unit.hash { index += 1 }
        let level = index - start
        guard (1...6).contains(level) else { return nil }
        if index == units.count { return (level, index) }
        guard Unit.isSpace(units[index]) else { return nil }
        while index < units.count, Unit.isSpace(units[index]) { index += 1 }
        return (level, index)
    }

    func isThematicBreak(_ units: [UInt16], at start: Int) -> Bool {
        guard start < units.count else { return false }
        let mark = units[start]
        guard mark == Unit.star || mark == Unit.dash || mark == Unit.underscore else { return false }
        var count = 0
        for unit in units[start...] {
            if unit == mark {
                count += 1
            } else if !Unit.isSpace(unit) {
                return false
            }
        }
        return count >= 3
    }

    func setextLevel(_ units: [UInt16], at start: Int) -> Int? {
        guard start < units.count else { return nil }
        let mark = units[start]
        guard mark == Unit.equals || mark == Unit.dash else { return nil }
        var index = start
        while index < units.count, units[index] == mark { index += 1 }
        while index < units.count, Unit.isSpace(units[index]) { index += 1 }
        guard index == units.count else { return nil }
        return mark == Unit.equals ? 1 : 2
    }

    func fenceOpening(_ units: [UInt16], at start: Int) -> DocGraphFence? {
        guard start < units.count else { return nil }
        let mark = units[start]
        if mark == Unit.backtick || mark == Unit.tilde {
            var index = start
            while index < units.count, units[index] == mark { index += 1 }
            guard index - start >= 3 else { return nil }
            if mark == Unit.backtick, units[index...].contains(Unit.backtick) { return nil }
            return DocGraphFence(mark: mark, length: index - start)
        }
        if mark == Unit.dollar, start + 1 < units.count, units[start + 1] == Unit.dollar {
            var rest = Array(units[(start + 2)...])
            while let last = rest.last, Unit.isSpace(last) { rest.removeLast() }
            let closesOnSameLine = rest.count >= 2 && rest[rest.count - 1] == Unit.dollar && rest[rest.count - 2] == Unit.dollar
            return DocGraphFence(mark: Unit.dollar, length: closesOnSameLine ? 0 : 2)
        }
        return nil
    }

    func closesFence(_ units: [UInt16], at start: Int, indentWidth: Int, fence: DocGraphFence) -> Bool {
        guard start < units.count else { return false }
        if fence.mark == Unit.dollar {
            var end = units.count
            while end > start, Unit.isSpace(units[end - 1]) { end -= 1 }
            return end - start >= 2 && units[end - 1] == Unit.dollar && units[end - 2] == Unit.dollar
        }
        guard indentWidth <= 3 else { return false }
        var index = start
        while index < units.count, units[index] == fence.mark { index += 1 }
        guard index - start >= fence.length else { return false }
        return units[index...].allSatisfy(Unit.isSpace)
    }

    func listMarker(_ units: [UInt16], from column: Int) -> DocGraphListMarker? {
        let (indentWidth, start) = indentation(units, from: column)
        guard indentWidth <= 3, start < units.count else { return nil }
        var index = start
        var ordered = false
        var symbol: UInt16 = 0
        var number = 0
        if units[index] == Unit.dash || units[index] == Unit.star || units[index] == Unit.plus {
            symbol = units[index]
            index += 1
        } else if Unit.isDigit(units[index]) {
            var digits = 0
            while index < units.count, Unit.isDigit(units[index]), digits < 10 {
                number = number * 10 + Int(units[index] - 48)
                digits += 1
                index += 1
            }
            guard digits <= 9, index < units.count,
                  units[index] == Unit.period || units[index] == Unit.rightParen else { return nil }
            symbol = units[index]
            ordered = true
            index += 1
        } else {
            return nil
        }
        let markerWidth = indentWidth + (index - start)
        var after = index
        var spaces = 0
        while after < units.count, Unit.isSpace(units[after]) {
            spaces += units[after] == Unit.tab ? 4 - ((markerWidth + spaces) % 4) : 1
            after += 1
        }
        if after >= units.count {
            return DocGraphListMarker(
                ordered: ordered, symbol: symbol, number: number,
                contentOffset: units.count - column, contentWidth: markerWidth + 1, isEmpty: true
            )
        }
        guard spaces > 0 else { return nil }
        if spaces >= 5 {
            // Indented code inside the item: its content starts one space in.
            return DocGraphListMarker(
                ordered: ordered, symbol: symbol, number: number,
                contentOffset: index + 1 - column, contentWidth: markerWidth + 1, isEmpty: false
            )
        }
        return DocGraphListMarker(
            ordered: ordered, symbol: symbol, number: number,
            contentOffset: after - column, contentWidth: markerWidth + spaces, isEmpty: false
        )
    }

    private static let blockTagNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td",
        "tfoot", "th", "thead", "title", "tr", "track", "ul", "script", "pre", "style", "textarea",
    ]
    private static let rawTagNames: Set<String> = ["script", "pre", "style", "textarea"]

    enum HTMLBlock {
        /// `<!--`: ends at the line holding `-->`.
        case comment
        /// `<script>`, `<pre>`, `<style>`, `<textarea>`: ends at the closing tag.
        case raw(String)
        /// Any other block tag, or a line that is one whole tag: ends at a blank line.
        case tag(canInterruptParagraph: Bool)
    }

    func htmlBlock(_ units: [UInt16], at start: Int) -> HTMLBlock? {
        guard start + 1 < units.count, units[start] == Unit.lessThan else { return nil }
        let rest = String(decoding: units[start...], as: UTF16.self)
        if rest.hasPrefix("<!--") { return .comment }
        if units[start + 1] == Unit.question || (units[start + 1] == Unit.bang && start + 2 < units.count && Unit.isLetter(units[start + 2])) {
            return .tag(canInterruptParagraph: true)
        }
        var index = start + 1
        if units[index] == Unit.slash { index += 1 }
        let nameStart = index
        while index < units.count, Unit.isLetter(units[index]) || Unit.isDigit(units[index]) || units[index] == Unit.dash { index += 1 }
        guard index > nameStart, Unit.isLetter(units[nameStart]) else { return nil }
        let name = String(decoding: units[nameStart..<index], as: UTF16.self).lowercased()
        let ends = index == units.count || Unit.isSpace(units[index]) || units[index] == Unit.greaterThan
            || (units[index] == Unit.slash && index + 1 < units.count && units[index + 1] == Unit.greaterThan)
        guard ends else { return nil }
        if Self.rawTagNames.contains(name), units[start + 1] != Unit.slash { return .raw(name) }
        if Self.blockTagNames.contains(name) { return .tag(canInterruptParagraph: true) }
        // Any other tag starts an HTML block only when it is the whole line.
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(">"), trimmed.dropFirst().firstIndex(of: "<") == nil else { return nil }
        return .tag(canInterruptParagraph: false)
    }

    // swiftlint:disable:next force_try
    private static let tableDelimiter = try! NSRegularExpression(pattern: #"^\s{0,3}\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    func isTableDelimiter(_ ref: DocGraphLineRef) -> Bool {
        let units = lines.units[ref.line]
        guard ref.column < units.count, units[ref.column...].contains(Unit.dash) else { return false }
        let text = lines.string(ref.line, from: ref.column)
        return Self.tableDelimiter.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    func isTableStart(_ refs: [DocGraphLineRef], at index: Int) -> Bool {
        guard index + 1 < refs.count else { return false }
        let header = refs[index]
        guard lines.units[header.line][header.column...].contains(Unit.pipe) else { return false }
        return isTableDelimiter(refs[index + 1])
    }

    /// Whether a line begins a block of its own, so it cannot continue a
    /// paragraph lazily.
    func startsBlock(_ ref: DocGraphLineRef) -> Bool {
        let units = lines.units[ref.line]
        let (width, start) = indentation(units, from: ref.column)
        guard width <= 3, start < units.count else { return false }
        return atxHeading(units, at: start) != nil
            || fenceOpening(units, at: start) != nil
            || units[start] == Unit.greaterThan
            || isThematicBreak(units, at: start)
            || listMarker(units, from: ref.column) != nil
            || htmlBlock(units, at: start) != nil
    }

    /// Whether a line ends the paragraph above it, as CommonMark lets it.
    func interruptsParagraph(_ ref: DocGraphLineRef) -> Bool {
        let units = lines.units[ref.line]
        let (width, start) = indentation(units, from: ref.column)
        guard width <= 3, start < units.count else { return false }
        if atxHeading(units, at: start) != nil || fenceOpening(units, at: start) != nil
            || units[start] == Unit.greaterThan || isThematicBreak(units, at: start) {
            return true
        }
        if let marker = listMarker(units, from: ref.column), !marker.isEmpty, !marker.ordered || marker.number == 1 {
            return true
        }
        switch htmlBlock(units, at: start) {
        case .comment?, .raw?: return true
        case .tag(let canInterrupt)?: return canInterrupt
        case nil: return false
        }
    }

    // MARK: Parsing

    /// How deep quotes and list items nest before the rest is read as no
    /// block: each level is a call, and a line of a thousand `>` must not
    /// run the storage actor's thread out of stack.
    static let depthLimit = 48

    func parse(_ refs: [DocGraphLineRef], atDocumentStart: Bool = false, depth: Int = 0) -> [DocGraphTreeNode] {
        guard depth < Self.depthLimit else { return [.other] }
        var nodes: [DocGraphTreeNode] = []
        var index = 0
        if atDocumentStart, let end = frontMatterEnd(refs) {
            nodes.append(.verbatim(refs[0...end].map(\.line)))
            index = end + 1
        }
        while index < refs.count {
            let ref = refs[index]
            let units = lines.units[ref.line]
            let (width, start) = indentation(units, from: ref.column)
            if start >= units.count {
                index += 1
                continue
            }
            if width >= 4 {
                index = indentedCode(refs, from: index, into: &nodes)
                continue
            }
            if let fence = fenceOpening(units, at: start) {
                index = fencedCode(refs, from: index, fence: fence, into: &nodes)
                continue
            }
            if let heading = atxHeading(units, at: start) {
                nodes.append(.heading(level: heading.level, lines: [DocGraphLineRef(line: ref.line, column: heading.textStart)], atx: true))
                index += 1
                continue
            }
            if isThematicBreak(units, at: start) {
                nodes.append(.verbatim([ref.line]))
                index += 1
                continue
            }
            if units[start] == Unit.greaterThan {
                let (content, next) = gatherQuote(refs, from: index)
                nodes.append(.quote(parse(content, depth: depth + 1)))
                index = next
                continue
            }
            if let marker = listMarker(units, from: ref.column) {
                let (items, next) = gatherList(refs, from: index, first: marker, depth: depth)
                nodes.append(.list(items))
                index = next
                continue
            }
            if let html = htmlBlock(units, at: start) {
                index = htmlBlock(refs, from: index, kind: html, into: &nodes)
                continue
            }
            if isTableStart(refs, at: index) {
                var next = index + 2
                while next < refs.count, !isBlank(refs[next]), !startsBlock(refs[next]) { next += 1 }
                nodes.append(.other)
                index = next
                continue
            }
            index = paragraph(refs, from: index, into: &nodes)
        }
        return nodes
    }

    /// `---` on the first line, `key: value` lines, and a closing `---` or `...`.
    private func frontMatterEnd(_ refs: [DocGraphLineRef]) -> Int? {
        guard refs.count > 2, refs[0].line == 0,
              lines.string(0).trimmingCharacters(in: .whitespaces) == "---",
              lines.string(refs[1].line).contains(":") else { return nil }
        for index in 1..<refs.count {
            let text = lines.string(refs[index].line).trimmingCharacters(in: .whitespaces)
            if text == "---" || text == "..." { return index }
        }
        return nil
    }

    private func indentedCode(_ refs: [DocGraphLineRef], from start: Int, into nodes: inout [DocGraphTreeNode]) -> Int {
        var last = start
        var index = start + 1
        while index < refs.count {
            let ref = refs[index]
            let units = lines.units[ref.line]
            let (width, end) = indentation(units, from: ref.column)
            if end >= units.count {
                index += 1
                continue
            }
            guard width >= 4 else { break }
            last = index
            index += 1
        }
        nodes.append(.verbatim(refs[start...last].map(\.line)))
        return last + 1
    }

    private func fencedCode(_ refs: [DocGraphLineRef], from start: Int, fence: DocGraphFence, into nodes: inout [DocGraphTreeNode]) -> Int {
        guard fence.length > 0 else {
            nodes.append(.verbatim([refs[start].line]))
            return start + 1
        }
        var index = start + 1
        while index < refs.count {
            let ref = refs[index]
            let units = lines.units[ref.line]
            let (width, end) = indentation(units, from: ref.column)
            if closesFence(units, at: end, indentWidth: width, fence: fence) { break }
            index += 1
        }
        let end = min(index, refs.count - 1)
        nodes.append(.verbatim(refs[start...end].map(\.line)))
        return end + 1
    }

    private func htmlBlock(_ refs: [DocGraphLineRef], from start: Int, kind: HTMLBlock, into nodes: inout [DocGraphTreeNode]) -> Int {
        var index = start
        switch kind {
        case .comment, .raw:
            let closer: String
            if case .raw(let name) = kind { closer = "</\(name)" } else { closer = "-->" }
            while index < refs.count {
                let text = lines.string(refs[index].line, from: refs[index].column)
                let searchFrom = index == start ? text.index(text.startIndex, offsetBy: min(4, text.count)) : text.startIndex
                if text[searchFrom...].range(of: closer, options: .caseInsensitive) != nil { break }
                index += 1
            }
            let end = min(index, refs.count - 1)
            nodes.append(.verbatim(refs[start...end].map(\.line)))
            return end + 1
        case .tag:
            while index < refs.count, !isBlank(refs[index]) { index += 1 }
            nodes.append(.verbatim(refs[start..<index].map(\.line)))
            return index
        }
    }

    private func paragraph(_ refs: [DocGraphLineRef], from start: Int, into nodes: inout [DocGraphTreeNode]) -> Int {
        var text = [refs[start]]
        var index = start + 1
        var setext: Int?
        while index < refs.count {
            let ref = refs[index]
            let units = lines.units[ref.line]
            let (width, end) = indentation(units, from: ref.column)
            if end >= units.count { break }
            if width <= 3, let level = setextLevel(units, at: end) {
                setext = level
                index += 1
                break
            }
            if interruptsParagraph(ref) { break }
            text.append(ref)
            index += 1
        }
        if let setext {
            nodes.append(.heading(level: setext, lines: text, atx: false))
        } else {
            nodes.append(.paragraph(text))
        }
        return index
    }

    private func gatherQuote(_ refs: [DocGraphLineRef], from start: Int) -> ([DocGraphLineRef], Int) {
        var content: [DocGraphLineRef] = []
        var index = start
        var lastHadText = false
        while index < refs.count {
            let ref = refs[index]
            let units = lines.units[ref.line]
            let (width, end) = indentation(units, from: ref.column)
            if width <= 3, end < units.count, units[end] == Unit.greaterThan {
                var column = end + 1
                if column < units.count, Unit.isSpace(units[column]) { column += 1 }
                let inner = DocGraphLineRef(line: ref.line, column: column)
                content.append(inner)
                lastHadText = !isBlank(inner) && !startsBlock(inner)
                index += 1
                continue
            }
            if end >= units.count { break }
            if lastHadText, !startsBlock(ref) {
                content.append(DocGraphLineRef(line: ref.line, column: end))
                index += 1
                continue
            }
            break
        }
        return (content, index)
    }

    private func gatherList(_ refs: [DocGraphLineRef], from start: Int, first: DocGraphListMarker, depth: Int) -> ([DocGraphTreeItem], Int) {
        var items: [DocGraphTreeItem] = []
        var index = start
        var marker = first
        while true {
            let (item, next) = gatherItem(refs, from: index, marker: marker, depth: depth)
            items.append(item)
            var following = next
            while following < refs.count, isBlank(refs[following]) { following += 1 }
            guard following < refs.count else { return (items, next) }
            let ref = refs[following]
            let units = lines.units[ref.line]
            let (_, textStart) = indentation(units, from: ref.column)
            guard !isThematicBreak(units, at: textStart),
                  let nextMarker = listMarker(units, from: ref.column),
                  nextMarker.continues(first) else { return (items, next) }
            marker = nextMarker
            index = following
        }
    }

    private func gatherItem(_ refs: [DocGraphLineRef], from start: Int, marker: DocGraphListMarker, depth: Int) -> (DocGraphTreeItem, Int) {
        let first = refs[start]
        let firstUnits = lines.units[first.line]
        let contentColumn = min(first.column + marker.contentOffset, firstUnits.count)
        var content = [DocGraphLineRef(line: first.line, column: contentColumn)]
        var index = start + 1
        if marker.isEmpty, index < refs.count, isBlank(refs[index]) {
            // An item that starts with a blank line and has nothing under it is empty.
            return (DocGraphTreeItem(markerLine: first.line, contentColumn: contentColumn, content: content, children: []), index)
        }
        var fence: DocGraphFence?
        var lastHadText = !marker.isEmpty
        if !marker.isEmpty, let opened = fenceOpening(firstUnits, at: contentColumn), opened.length > 0 {
            fence = opened
            lastHadText = false
        }
        var trailingBlanks = 0
        while index < refs.count {
            let ref = refs[index]
            let units = lines.units[ref.line]
            let (width, end) = indentation(units, from: ref.column)
            if end >= units.count {
                content.append(stripping(marker.contentWidth, from: ref))
                trailingBlanks += 1
                index += 1
                continue
            }
            if width >= marker.contentWidth {
                let inner = stripping(marker.contentWidth, from: ref)
                content.append(inner)
                trailingBlanks = 0
                let (innerWidth, innerStart) = indentation(units, from: inner.column)
                if let open = fence {
                    if closesFence(units, at: innerStart, indentWidth: innerWidth, fence: open) { fence = nil }
                    lastHadText = false
                } else if innerWidth < 4, let opened = fenceOpening(units, at: innerStart), opened.length > 0 {
                    fence = opened
                    lastHadText = false
                } else if innerWidth < 4 {
                    lastHadText = atxHeading(units, at: innerStart) == nil && !isThematicBreak(units, at: innerStart)
                }
                index += 1
                continue
            }
            if trailingBlanks == 0, lastHadText, fence == nil, !startsBlock(ref) {
                content.append(DocGraphLineRef(line: ref.line, column: end))
                index += 1
                continue
            }
            break
        }
        // Blank lines after the item's last line are the gap after it.
        while trailingBlanks > 0, content.count > 1 {
            content.removeLast()
            index -= 1
            trailingBlanks -= 1
        }
        return (
            DocGraphTreeItem(markerLine: first.line, contentColumn: contentColumn, content: content, children: parse(content, depth: depth + 1)),
            index
        )
    }
}

// MARK: - Blocks from the structure

private struct DocGraphEmitter {
    let lines: DocGraphLines
    let docID: String
    private(set) var blocks: [DocGraphParsedBlock] = []
    private(set) var verbatim = IndexSet()
    /// The headings whose sections the reading is in, outermost first.
    private var sections: [(level: Int, text: String)] = []

    init(lines: DocGraphLines, docID: String) {
        self.lines = lines
        self.docID = docID
    }

    struct Container {
        let path: [Int]
        /// The container's own text blocks so far.
        var textBlocks = 0
        /// The list items directly in it so far.
        var items = 0

        var key: String {
            let base = path.map(String.init).joined(separator: ".")
            return textBlocks == 0 ? base : "\(base)~\(textBlocks)"
        }
    }

    mutating func emitDocument(_ nodes: [DocGraphTreeNode]) {
        for (index, node) in nodes.enumerated() {
            var container = Container(path: [index])
            emit(node, in: &container, ancestors: [], inQuote: false, atTop: true)
        }
    }

    private mutating func emit(_ node: DocGraphTreeNode, in container: inout Container, ancestors: [String], inQuote: Bool, atTop: Bool) {
        switch node {
        case .paragraph(let refs):
            if let block = textBlock(refs, kind: inQuote ? .quote : .paragraph, headingLevel: nil, atx: false, key: container.key, ancestors: ancestors, keepEmpty: false) {
                blocks.append(block)
                container.textBlocks += 1
            }
        case .heading(let level, let refs, let atx):
            let opensSection = atTop && !inQuote
            if opensSection {
                while let last = sections.last, last.level >= level { sections.removeLast() }
            }
            let block = textBlock(refs, kind: .heading, headingLevel: level, atx: atx, key: container.key, ancestors: ancestors, keepEmpty: false)
            if let block {
                blocks.append(block)
                container.textBlocks += 1
            }
            if opensSection { sections.append((level, block?.block.plainText ?? "")) }
        case .list(let items):
            for item in items {
                emit(item, in: &container, ancestors: ancestors, inQuote: inQuote)
            }
        case .quote(let children):
            for child in children {
                emit(child, in: &container, ancestors: ancestors, inQuote: true, atTop: false)
            }
        case .verbatim(let numbers):
            for number in numbers { verbatim.insert(number) }
        case .other:
            break
        }
    }

    private mutating func emit(_ item: DocGraphTreeItem, in container: inout Container, ancestors: [String], inQuote: Bool) {
        var itemContainer = Container(path: container.path + [container.items])
        container.items += 1
        var children = item.children[...]
        var own: DocGraphParsedBlock?
        switch children.first {
        case .paragraph(let refs)?:
            own = textBlock(refs, kind: .listItem, headingLevel: nil, atx: false, key: itemContainer.key, ancestors: ancestors, keepEmpty: true)
            children = children.dropFirst()
        case .heading(_, let refs, let atx)?:
            own = textBlock(refs, kind: .listItem, headingLevel: nil, atx: atx, key: itemContainer.key, ancestors: ancestors, keepEmpty: true)
            children = children.dropFirst()
        default:
            break
        }
        var block = own ?? emptyItem(item, key: itemContainer.key, ancestors: ancestors)
        let nested: [DocGraphLineRef]
        if let lastOwnLine = own?.segments.last?.line {
            nested = item.content.filter { $0.line > lastOwnLine }
        } else {
            nested = item.content
        }
        block.block.childrenMarkdown = childrenMarkdown(nested)
        blocks.append(block)
        itemContainer.textBlocks = 1
        let crumbs = ancestors + [block.block.plainText]
        for child in children {
            emit(child, in: &itemContainer, ancestors: crumbs, inQuote: inQuote, atTop: false)
        }
    }

    private func emptyItem(_ item: DocGraphTreeItem, key: String, ancestors: [String]) -> DocGraphParsedBlock {
        DocGraphParsedBlock(
            block: DocGraphBlock(
                docID: docID, key: key, kind: .listItem, blockID: nil, markdown: "", plainText: "",
                breadcrumbs: breadcrumbs(ancestors), childrenMarkdown: "", line: item.markerLine
            ),
            links: DocGraphBlockLinks(),
            headingLevel: nil,
            isEmbedOnly: false,
            segments: [DocGraphParsedBlock.Segment(line: item.markerLine, column: item.contentColumn, length: 0)],
            searchText: ""
        )
    }

    private func breadcrumbs(_ ancestors: [String]) -> [String] {
        var crumbs: [String] = []
        if let section = sections.last?.text, !section.isEmpty { crumbs.append(section) }
        crumbs += ancestors.filter { !$0.isEmpty }
        return crumbs
    }

    private func childrenMarkdown(_ refs: [DocGraphLineRef]) -> String {
        var texts = refs.map { lines.string($0.line, from: $0.column) }
        while let first = texts.first, first.allSatisfy(\.isWhitespace) { texts.removeFirst() }
        while let last = texts.last, last.allSatisfy(\.isWhitespace) { texts.removeLast() }
        return texts.joined(separator: "\n")
    }

    private func textBlock(
        _ refs: [DocGraphLineRef],
        kind: DocGraphBlock.Kind,
        headingLevel: Int?,
        atx: Bool,
        key: String,
        ancestors: [String],
        keepEmpty: Bool
    ) -> DocGraphParsedBlock? {
        guard !refs.isEmpty else { return nil }
        var segments: [DocGraphParsedBlock.Segment] = []
        var text: [UInt16] = []
        var blockID: String?
        for (index, ref) in refs.enumerated() {
            let units = lines.units[ref.line]
            var start = min(ref.column, units.count)
            while start < units.count, Unit.isSpace(units[start]) { start += 1 }
            var end = units.count
            if index == refs.count - 1 {
                if let marker = DocGraphText.trailingBlockID(units[start..<end]) {
                    blockID = marker.id
                    end = marker.textEnd
                }
                while end > start, Unit.isSpace(units[end - 1]) { end -= 1 }
                if atx, end > start, units[end - 1] == Unit.hash {
                    // The closing sequence: hashes at the end after a space, or alone.
                    var run = end
                    while run > start, units[run - 1] == Unit.hash { run -= 1 }
                    if run == start || Unit.isSpace(units[run - 1]) {
                        end = run
                        while end > start, Unit.isSpace(units[end - 1]) { end -= 1 }
                    }
                }
            }
            if index > 0 { text.append(10) }
            text.append(contentsOf: units[start..<end])
            segments.append(DocGraphParsedBlock.Segment(line: ref.line, column: start, length: end - start))
        }
        let markdown = String(decoding: text, as: UTF16.self)
        let scan = DocGraphText.scan(units: text)
        let plainText = DocGraphText.plainText(units: kind == .listItem ? DocGraphText.removingTaskBox(text) : text)
        if !keepEmpty, plainText.isEmpty, blockID == nil, scan.links.isEmpty { return nil }
        let block = DocGraphBlock(
            docID: docID,
            key: key,
            kind: kind,
            blockID: blockID,
            markdown: markdown,
            plainText: plainText,
            breadcrumbs: breadcrumbs(ancestors),
            childrenMarkdown: "",
            line: refs[0].line
        )
        return DocGraphParsedBlock(
            block: block,
            links: scan.links,
            headingLevel: kind == .heading ? headingLevel : nil,
            isEmbedOnly: scan.isEmbedOnly,
            segments: segments,
            searchText: DocGraphText.folded(plainText)
        )
    }
}

// MARK: - Inline text

/// A block's own text, read inline: what it links, how it reads, and where
/// the graph's grammar stands in it. Works on UTF-16 units, the offsets every
/// answer is given in, and keeps regular expressions to text that could match.
enum DocGraphText {
    struct InlineLink: Equatable {
        /// The whole link, `[text](destination)` or `![alt](source)`.
        let range: Range<Int>
        /// The text between the brackets.
        let text: Range<Int>
        /// The parenthesized part after the brackets, parentheses included.
        let target: Range<Int>
        let destination: String
        let isImage: Bool
    }

    struct Scan: Equatable {
        var links: DocGraphBlockLinks
        var isEmbedOnly: Bool
        /// The text with code spans, links, pictures, autolinks, web
        /// addresses, HTML tags and every piece of the graph's own grammar
        /// blanked out (`mask`), offset for offset: what is left is prose.
        var prose: [UInt16]
    }

    /// The UTF-16 unit that stands in for text that is not prose.
    static let mask: UInt16 = 1

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let tagExpression = regex(DocGraphSyntax.tagPattern)
    static let titleLinkExpression = regex(DocGraphSyntax.titleLinkPattern)
    static let blockReferenceExpression = regex(DocGraphSyntax.blockReferencePattern)
    static let embedExpression = regex(DocGraphSyntax.blockEmbedPattern)
    /// An embed written inside a sentence, which reads as a reference.
    static let inlineEmbedExpression = regex(#"\{\{\s*(?:\[\[)?embed(?:\]\])?\s*:\s*\(\(([a-z0-9]{9})\)\)\s*\}\}"#)
    static let autolinkExpression = regex(#"<([A-Za-z][A-Za-z0-9.+\-]{1,31}:[^\s<>]*)>"#)
    static let bareAddressExpression = regex(#"(?<![\w(\]])https?://[^\s<>()\]]+"#)
    static let htmlTagExpression = regex(#"<!--[\s\S]*?-->|</?[A-Za-z][A-Za-z0-9\-]*(?:\s[^<>]*)?/?>"#)
    private static let dayTitleHint = regex(#"\d{4}\s*$"#)
    private static let numericEntityExpression = regex(#"&#(?:([0-9]{1,7})|[xX]([0-9A-Fa-f]{1,6}));"#)
    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]
    private static let foldLocale = Locale(identifier: "en_US_POSIX")

    private static let addressUnits = Array("http".utf16)
    private static let productAddressUnits = Array("foreverlm://".utf16)
    private static let referenceOpenUnits = Array("((".utf16)
    private static let titleOpenUnits = Array("[[".utf16)
    private static let escapedTitleOpenUnits = Array(#"\[\["#.utf16)

    // MARK: Code spans and links

    /// The code spans, backticks included: a run of n backticks up to the next
    /// run of exactly n. A backslash before a backtick outside code escapes it.
    static func codeSpans(_ units: [UInt16]) -> [Range<Int>] {
        guard units.contains(Unit.backtick) else { return [] }
        var spans: [Range<Int>] = []
        var index = 0
        while index < units.count {
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            guard units[index] == Unit.backtick else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < units.count, units[runEnd] == Unit.backtick { runEnd += 1 }
            let length = runEnd - index
            var probe = runEnd
            var close: Int?
            while probe < units.count {
                if units[probe] == Unit.backtick {
                    var end = probe
                    while end < units.count, units[end] == Unit.backtick { end += 1 }
                    if end - probe == length {
                        close = end
                        break
                    }
                    probe = end
                } else {
                    probe += 1
                }
            }
            if let close {
                spans.append(index..<close)
                index = close
            } else {
                index = runEnd
            }
        }
        return spans
    }

    /// Inline links and pictures, outermost only: `[text](destination "title")`
    /// with brackets nested in the text and parentheses balanced in the
    /// destination. Reference-style links are left as text.
    static func inlineLinks(_ units: [UInt16], code: [Range<Int>]) -> [InlineLink] {
        guard units.contains(91) else { return [] }
        func codeSpan(at position: Int) -> Range<Int>? {
            code.first { $0.contains(position) }
        }
        var links: [InlineLink] = []
        var index = 0
        while index < units.count {
            if let span = codeSpan(at: index) {
                index = span.upperBound
                continue
            }
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            let isImage = units[index] == Unit.bang && index + 1 < units.count && units[index + 1] == 91
            guard units[index] == 91 || isImage else {
                index += 1
                continue
            }
            let open = isImage ? index + 1 : index
            var depth = 0
            var probe = open
            var close: Int?
            while probe < units.count {
                if let span = codeSpan(at: probe) {
                    probe = span.upperBound
                    continue
                }
                if units[probe] == Unit.backslash {
                    probe += 2
                    continue
                }
                if units[probe] == 91 {
                    depth += 1
                } else if units[probe] == 93 {
                    depth -= 1
                    if depth == 0 {
                        close = probe
                        break
                    }
                }
                probe += 1
            }
            guard let close, close + 1 < units.count, units[close + 1] == 40 else {
                index = open + 1
                continue
            }
            var cursor = close + 2
            var parens = 1
            var inAngle = false
            var end: Int?
            while cursor < units.count {
                let unit = units[cursor]
                if unit == Unit.backslash {
                    cursor += 2
                    continue
                }
                if inAngle {
                    if unit == Unit.greaterThan { inAngle = false }
                } else if unit == Unit.lessThan, units[(close + 2)..<cursor].allSatisfy(Unit.isSpace) {
                    inAngle = true
                } else if unit == 40 {
                    parens += 1
                } else if unit == Unit.rightParen {
                    parens -= 1
                    if parens == 0 {
                        end = cursor
                        break
                    }
                }
                cursor += 1
            }
            guard let end else {
                index = open + 1
                continue
            }
            var destinationStart = close + 2
            while destinationStart < end, Unit.isSpace(units[destinationStart]) { destinationStart += 1 }
            var destinationEnd = destinationStart
            if destinationStart < end, units[destinationStart] == Unit.lessThan {
                destinationStart += 1
                destinationEnd = destinationStart
                while destinationEnd < end, units[destinationEnd] != Unit.greaterThan { destinationEnd += 1 }
            } else {
                while destinationEnd < end, !Unit.isSpace(units[destinationEnd]) { destinationEnd += 1 }
            }
            links.append(InlineLink(
                range: index..<(end + 1),
                text: (open + 1)..<close,
                target: (close + 1)..<(end + 1),
                destination: String(decoding: units[destinationStart..<destinationEnd], as: UTF16.self),
                isImage: isImage
            ))
            index = end + 1
        }
        return links
    }

    // MARK: Units

    static func blank(_ units: inout [UInt16], _ range: Range<Int>) {
        let lower = max(0, range.lowerBound)
        let upper = min(units.count, range.upperBound)
        guard lower < upper else { return }
        for index in lower..<upper { units[index] = mask }
    }

    static func blank(_ units: inout [UInt16], _ range: NSRange) {
        guard range.location != NSNotFound else { return }
        blank(&units, range.location..<(range.location + range.length))
    }

    /// An expression's matches in UTF-16 units, through an `NSString` made
    /// from them, so no Swift string is bridged to UTF-16 on the way.
    static func matches(_ expression: NSRegularExpression, in units: [UInt16]) -> [NSTextCheckingResult] {
        guard !units.isEmpty else { return [] }
        let text = units.withUnsafeBufferPointer { buffer in
            NSString(characters: buffer.baseAddress!, length: buffer.count)
        }
        return expression.matches(in: text as String, range: NSRange(location: 0, length: units.count))
    }

    static func string(_ units: [UInt16], _ range: NSRange) -> String? {
        guard range.location != NSNotFound, range.location + range.length <= units.count else { return nil }
        return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
    }

    /// Whether `needle` stands in `units`.
    static func contains(_ units: [UInt16], _ needle: [UInt16]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard units.count >= needle.count else { return false }
        let first = needle[0]
        let last = units.count - needle.count
        var index = 0
        while index <= last {
            if units[index] == first {
                var offset = 1
                while offset < needle.count, units[index + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }

    /// The ` ^id` marker a block's text ends with — `(?:^|[ \t])\^([a-z0-9]{9})[ \t]*$`,
    /// `DocGraphSyntax.blockIDMarkerPattern`, read without an expression — with
    /// where the text before it ends (the space before the caret is the
    /// marker's).
    static func trailingBlockID(_ units: ArraySlice<UInt16>) -> (id: String, textEnd: Int)? {
        var end = units.endIndex
        while end > units.startIndex, Unit.isSpace(units[end - 1]) { end -= 1 }
        let length = DocGraphSyntax.blockIDLength
        guard end - units.startIndex >= length + 1 else { return nil }
        let caret = end - length - 1
        guard units[caret] == 94 else { return nil }
        for index in (caret + 1)..<end {
            let unit = units[index]
            guard (unit >= 97 && unit <= 122) || Unit.isDigit(unit) else { return nil }
        }
        let id = String(decoding: units[(caret + 1)..<end], as: UTF16.self)
        if caret == units.startIndex { return (id, caret) }
        guard Unit.isSpace(units[caret - 1]) else { return nil }
        return (id, caret - 1)
    }

    /// A line without the ` ^id` marker it ends with, if it ends with one.
    static func removingTrailingBlockID(_ line: String) -> String {
        let units = Array(line.utf16)
        guard units.contains(94), let marker = trailingBlockID(units[...]) else { return line }
        return String(decoding: units[..<marker.textEnd], as: UTF16.self)
    }

    // MARK: What a block points at

    /// What a block's own Markdown links, references, embeds and names, and
    /// its prose with everything else blanked out.
    static func scan(_ markdown: String) -> Scan {
        scan(units: Array(markdown.utf16))
    }

    static func scan(units: [UInt16]) -> Scan {
        var links = DocGraphBlockLinks()
        var prose = units
        let code = codeSpans(units)
        for span in code { blank(&prose, span) }
        // Addresses as the Notepad and the cards read them, never inside code.
        let hasProductAddress = contains(prose, productAddressUnits)
        let hasAddress = contains(prose, addressUnits)
        if hasProductAddress || hasAddress {
            let codeless = String(decoding: prose, as: UTF16.self)
            if hasProductAddress { links.sourceTokens = unique(StorageService.groundingTokens(in: codeless)) }
            if hasAddress { links.webReferences = StorageService.webReferences(in: codeless) }
        }

        func noteEntity(_ destination: String) {
            switch StudioEntityLink.parse(destination: destination) {
            case .doc(let id)?:
                if !links.docIDs.contains(id) { links.docIDs.append(id) }
            case .idea(let id)?:
                if !links.ideaIDs.contains(id) { links.ideaIDs.append(id) }
            default:
                break
            }
        }
        for link in inlineLinks(units, code: code) {
            if !link.isImage { noteEntity(link.destination) }
            blank(&prose, link.range)
        }
        if prose.contains(Unit.lessThan) {
            for match in matches(autolinkExpression, in: prose) {
                if let destination = string(units, match.range(at: 1)) { noteEntity(destination) }
                blank(&prose, match.range)
            }
            for match in matches(htmlTagExpression, in: prose) { blank(&prose, match.range) }
        }
        if hasAddress {
            for match in matches(bareAddressExpression, in: prose) { blank(&prose, match.range) }
        }

        let embedded = embedID(units)
        if let embedded {
            links.embeds = [embedded]
            blank(&prose, 0..<prose.count)
        }
        // Tags before title links: `#[[Two words]]` is one tag, not a `#`
        // before a title link.
        var titles: [String] = []
        func noteTitle(_ raw: String?) {
            guard let raw else { return }
            let title = DocGraphSyntax.normalizedTitle(DocGraphSyntax.unescapedTitle(raw))
            if !title.isEmpty, !titles.contains(title) { titles.append(title) }
        }
        if prose.contains(Unit.hash) {
            for match in matches(tagExpression, in: prose) {
                noteTitle(string(units, match.range(at: 1)) ?? string(units, match.range(at: 2)))
                blank(&prose, match.range)
            }
        }
        if contains(prose, titleOpenUnits) || contains(prose, escapedTitleOpenUnits) {
            for match in matches(titleLinkExpression, in: prose) {
                noteTitle(string(units, match.range(at: 1)))
                blank(&prose, match.range)
            }
        }
        if contains(prose, referenceOpenUnits) {
            for match in matches(blockReferenceExpression, in: prose) {
                if let id = string(units, match.range(at: 1)), !links.blockReferences.contains(id) {
                    links.blockReferences.append(id)
                }
                blank(&prose, match.range)
            }
        }
        links.titles = titles
        links.dayKeys = unique(titles.compactMap(dayKey(fromTitle:)))
        return Scan(links: links, isEmbedOnly: embedded != nil, prose: prose)
    }

    /// The block a paragraph that is only an embed embeds.
    static func embedID(_ units: [UInt16]) -> String? {
        var start = 0
        var end = units.count
        while start < end, Unit.isSpace(units[start]) || units[start] == 10 || units[start] == 13 { start += 1 }
        while end > start, Unit.isSpace(units[end - 1]) || units[end - 1] == 10 || units[end - 1] == 13 { end -= 1 }
        guard end - start >= 4, units[start] == 123, units[start + 1] == 123,
              units[end - 1] == 125, units[end - 2] == 125 else { return nil }
        let trimmed = Array(units[start..<end])
        guard let match = matches(embedExpression, in: trimmed).first else { return nil }
        return string(trimmed, match.range(at: 1))
    }

    /// The day a title names, read only when it ends in a year.
    static func dayKey(fromTitle title: String) -> String? {
        guard !matches(dayTitleHint, in: Array(title.utf16)).isEmpty else { return nil }
        return DailyNote.dayKey(fromTitle: title)
    }

    /// A list item's text without its task box (`[ ]`, `[x]`).
    static func removingTaskBox(_ markdown: String) -> String {
        String(decoding: removingTaskBox(Array(markdown.utf16)), as: UTF16.self)
    }

    static func removingTaskBox(_ units: [UInt16]) -> [UInt16] {
        guard units.count >= 3, units[0] == 91, units[2] == 93,
              units[1] == Unit.space || units[1] == 120 || units[1] == 88 else { return units }
        guard units.count == 3 || Unit.isSpace(units[3]) else { return units }
        var start = 3
        while start < units.count, Unit.isSpace(units[start]) { start += 1 }
        return Array(units[start...])
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var units = Array(text.utf16)
        while let last = units.last, Unit.isSpace(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Plain text

    /// The text as a reader sees it (see the rules at the top of this file).
    static func plainText(_ markdown: String) -> String {
        plainText(units: Array(markdown.utf16))
    }

    /// The units that can make Markdown text read differently from how it is
    /// written: backticks, brackets, `<`, `*`, `_`, `~`, backslashes and `&`.
    private static func isMark(_ unit: UInt16) -> Bool {
        unit == 96 || unit == 91 || unit == 60 || unit == 42 || unit == 95 || unit == 126 || unit == 92 || unit == 38
    }

    static func plainText(units: [UInt16]) -> String {
        guard !units.isEmpty else { return "" }
        guard units.contains(where: isMark) else { return collapsingWhitespace(units) }
        let code = codeSpans(units)
        let links = inlineLinks(units, code: code)
        var specials: [(range: Range<Int>, text: [UInt16])] = []
        var covered = units
        for span in code {
            specials.append((span, codeText(units[span])))
            blank(&covered, span)
        }
        for link in links {
            let text = link.isImage ? [] : Array(plainText(units: Array(units[link.text])).utf16)
            specials.append((link.range, text))
            blank(&covered, link.range)
        }
        if covered.contains(Unit.lessThan) {
            for match in matches(autolinkExpression, in: covered) {
                let address = string(units, match.range(at: 1)).map { Array($0.utf16) } ?? []
                specials.append((match.range.location..<(match.range.location + match.range.length), address))
                blank(&covered, match.range)
            }
            for match in matches(htmlTagExpression, in: covered) {
                specials.append((match.range.location..<(match.range.location + match.range.length), []))
            }
        }
        specials.sort { $0.range.lowerBound < $1.range.lowerBound }

        // One pass: specials become their text; a backslash before ASCII
        // punctuation gives the punctuation; emphasis runs (`*`, `_`, `~~`)
        // go unless they stand alone between spaces, and an `_` inside a
        // word stays.
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var index = 0
        var next = 0
        while index < units.count {
            while next < specials.count, specials[next].range.lowerBound < index { next += 1 }
            if next < specials.count, specials[next].range.lowerBound == index {
                output.append(contentsOf: specials[next].text)
                index = specials[next].range.upperBound
                next += 1
                continue
            }
            let unit = units[index]
            if unit == Unit.backslash, index + 1 < units.count, isASCIIPunctuation(units[index + 1]) {
                output.append(units[index + 1])
                index += 2
                continue
            }
            if unit == Unit.star || unit == Unit.underscore || unit == Unit.tilde {
                var end = index
                while end < units.count, units[end] == unit { end += 1 }
                let before: UInt16? = index > 0 ? units[index - 1] : nil
                let after: UInt16? = end < units.count ? units[end] : nil
                let spaced = (before.map(isWhitespaceUnit) ?? true) && (after.map(isWhitespaceUnit) ?? true)
                let keep: Bool
                if unit == Unit.underscore {
                    keep = spaced || (before.map(isWordUnit) ?? false) && (after.map(isWordUnit) ?? false)
                } else if unit == Unit.tilde {
                    keep = spaced || end - index < 2
                } else {
                    keep = spaced
                }
                if keep { output.append(contentsOf: units[index..<end]) }
                index = end
                continue
            }
            output.append(unit)
            index += 1
        }
        guard output.contains(38) else { return collapsingWhitespace(output) }
        return collapsingWhitespace(Array(decodingEntities(String(decoding: output, as: UTF16.self)).utf16))
    }

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (unit >= 33 && unit <= 47) || (unit >= 58 && unit <= 64) || (unit >= 91 && unit <= 96) || (unit >= 123 && unit <= 126)
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        unit >= 0x80 || Unit.isDigit(unit) || Unit.isLetter(unit)
    }

    /// Runs of whitespace as one space, none at either end.
    static func collapsingWhitespace(_ units: [UInt16]) -> String {
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var pendingSpace = false
        for unit in units {
            if isWhitespaceUnit(unit) {
                pendingSpace = !output.isEmpty
                continue
            }
            if pendingSpace {
                output.append(Unit.space)
                pendingSpace = false
            }
            output.append(unit)
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// Unicode's White_Space (all of it in the Basic Multilingual Plane).
    static func isWhitespaceUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Whether `needle` stands in `haystack`, byte for byte: for text
    /// already folded, without Foundation's search.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        firstByteOffset(of: needle, in: haystack, from: 0) != nil
    }

    /// The UTF-8 offset of `needle` in `haystack` at or after `start`.
    static func firstByteOffset(of needle: String, in haystack: String, from start: Int) -> Int? {
        var haystack = haystack
        var needle = needle
        haystack.makeContiguousUTF8()
        needle.makeContiguousUTF8()
        return haystack.utf8.withContiguousStorageIfAvailable { hay -> Int? in
            needle.utf8.withContiguousStorageIfAvailable { pin -> Int? in
                guard !pin.isEmpty else { return start <= hay.count ? start : nil }
                guard hay.count >= pin.count, start <= hay.count - pin.count else { return nil }
                let first = pin[0]
                var index = start
                let last = hay.count - pin.count
                while index <= last {
                    if hay[index] == first, memcmp(hay.baseAddress! + index, pin.baseAddress!, pin.count) == 0 {
                        return index
                    }
                    index += 1
                }
                return nil
            } ?? nil
        } ?? nil
    }

    /// Whether `word` begins a word somewhere in `text` (both folded): at the
    /// start, or after a character that is not a letter, digit or `_`.
    static func startsWord(_ word: String, in text: String) -> Bool {
        let bytes = Array(text.utf8)
        var start = 0
        while let offset = firstByteOffset(of: word, in: text, from: start) {
            if offset == 0 { return true }
            let before = bytes[offset - 1]
            let isWordByte = before >= 0x80 || before == 95
                || (before >= 48 && before <= 57) || (before >= 65 && before <= 90) || (before >= 97 && before <= 122)
            if !isWordByte { return true }
            start = offset + 1
        }
        return false
    }

    private static func codeText(_ units: ArraySlice<UInt16>) -> [UInt16] {
        var start = units.startIndex
        while start < units.endIndex, units[start] == Unit.backtick { start += 1 }
        var end = units.endIndex
        while end > start, units[end - 1] == Unit.backtick { end -= 1 }
        var inner = Array(units[start..<end])
        if inner.count >= 2, inner.first == Unit.space, inner.last == Unit.space, !inner.allSatisfy({ $0 == Unit.space }) {
            inner.removeFirst()
            inner.removeLast()
        }
        return inner
    }

    private static func decodingEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in namedEntities where result.contains(entity) {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        let units = Array(result.utf16)
        let found = matches(numericEntityExpression, in: units)
        guard !found.isEmpty else { return result }
        let mutable = NSMutableString(string: result)
        for match in found.reversed() {
            let decimal = string(units, match.range(at: 1)).flatMap { UInt32($0) }
            let hex = string(units, match.range(at: 2)).flatMap { UInt32($0, radix: 16) }
            guard let value = decimal ?? hex, let scalar = UnicodeScalar(value) else { continue }
            mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
        }
        return mutable as String
    }

    // MARK: Folding

    /// One character as titles and search compare it: lowercased, its accents
    /// and width folded away.
    static func fold(_ character: Character) -> String {
        if let ascii = character.asciiValue {
            return String(UnicodeScalar(ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii))
        }
        return String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: foldLocale)
    }

    static func folded(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 128 }) {
            return String(decoding: text.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: foldLocale)
    }

    /// A title or a query as the words matching compares, folded.
    static func foldedWords(_ text: String) -> [String] {
        folded(text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Whether a page holds every one of `words` (folded, `foldedWords`)
    /// somewhere in its blocks' search text, each word in any block: the
    /// Space's search into what pages say (Codex's "Search spaces and
    /// content"). No words is no match.
    static func holdsEveryWord(_ words: [String], inBlocks texts: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in texts.contains { contains($0, word) } }
    }
}

// MARK: - Finding words in prose

/// Where some words stand in a block's prose — whole words, any case, any
/// accents, any whitespace between them — outside code, links, pictures, web
/// addresses, HTML and the graph's own grammar. How a Doc's title is found
/// written but not linked (Unlinked References), and how a mention is found
/// again in a Doc that changed.
struct DocGraphWordMatcher {
    let words: [String]
    private let expression: NSRegularExpression?

    init(_ text: String) {
        words = DocGraphText.foldedWords(text)
        guard !words.isEmpty else {
            expression = nil
            return
        }
        let body = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s+"#)
        expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_])"# + body + #"(?![\p{L}\p{N}_])"#,
            options: [.caseInsensitive]
        )
    }

    /// The words joined as `DocGraphParsedBlock.searchText` holds them: a
    /// block whose search text lacks this cannot hold the words.
    var phrase: String { words.joined(separator: " ") }

    /// Every place the words stand in a block's Markdown, as UTF-16 ranges of it.
    func occurrences(in markdown: String) -> [Range<Int>] {
        guard let expression else { return [] }
        let prose = String(decoding: DocGraphText.scan(markdown).prose, as: UTF16.self)
        var folded = ""
        var starts: [Int] = []
        var ends: [Int] = []
        var offset = 0
        for character in prose {
            let length = character.utf16.count
            let piece = DocGraphText.fold(character)
            for _ in 0..<piece.utf16.count {
                starts.append(offset)
                ends.append(offset + length)
            }
            folded += piece
            offset += length
        }
        let length = (folded as NSString).length
        guard length == starts.count else { return [] }
        return expression.matches(in: folded, range: NSRange(location: 0, length: length)).compactMap { match in
            guard match.range.length > 0 else { return nil }
            let first = match.range.location
            let last = match.range.location + match.range.length - 1
            return starts[first]..<ends[last]
        }
    }
}
