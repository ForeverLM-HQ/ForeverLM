import Foundation

/// A small, deterministic Markdown-to-HTML renderer for handing a Doc's body
/// to something that reads HTML — today Google Drive, which turns HTML into a
/// Google Doc on upload.
///
/// This is structure, not prose: headings, paragraphs, emphasis, lists, links,
/// code, quotes, rules and tables, the grammar the Docs editor writes. What
/// the editor stores in ForeverLM's own addresses means nothing outside it,
/// so it is translated or unwrapped rather than sent along:
///
/// - A grounded passage (`foreverlm://grounding/<id>,<id>`) is a claim that
///   stands on sources, and a document outside the app says so the way papers
///   do: the passage keeps its words, a superscript number follows it, and a
///   numbered References list closes the document, one entry per source in
///   the order first cited (product owner, 2026-10-12: attached sources "would
///   need to be converted to proper citations"). The caller says what each
///   source is (`references`); a source it cannot name is dropped, and a
///   passage left with none is its words alone.
/// - A source link (`foreverlm://source/<id>`, a source card or the retired
///   chip) links to where the source lives on the web when it has an address,
///   and is its text alone when it has none.
/// - Every other `foreverlm://…` link renders as its text alone: the address
///   opens nothing in Google Docs.
/// - `foreverlm://attachment/…` images render as their alt text, or nothing.
///   The picture's bytes live in the doc's body package, and a multipart create
///   carries one HTML part; shipping them would be a second upload per image.
///
/// The same input always gives the same output; there is no state and no
/// randomness, so a test can pin a whole document.
enum MarkdownHTML {
    /// A complete HTML document with `title` in its head and the rendered body.
    /// `references` names the sources the body's passages stand on, by the
    /// token their addresses carry (a source id or `book:<id>`).
    static func document(title: String, markdown: String, references: [String: Reference] = [:]) -> String {
        var html = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
        html += "<title>\(escape(title))</title>\n</head>\n<body>\n"
        html += body(markdown, references: references)
        html += "</body>\n</html>\n"
        return html
    }

    /// The rendered blocks alone, one per line, without a document wrapper,
    /// followed by the References list when a passage cites a source.
    static func body(_ markdown: String, references: [String: Reference] = [:]) -> String {
        let cited = citing(markdown, references: references)
        let lines = cited.markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return renderBlocks(lines) + referencesSection(cited.references)
    }

    // MARK: - Citations

    /// A source a Doc's passages stand on, the way a reference list prints it.
    struct Reference: Equatable, Sendable {
        var title: String
        /// One name per entry, in the source's own order.
        var authors: [String] = []
        var year: String?
        /// Where it appeared: a journal, a show, a site, the book a chapter is in.
        var container: String?
        /// Where a reader outside the app finds it: a DOI's address or a web page.
        var url: String?
    }

    /// The heading the References list opens with.
    static let referencesHeading = "References"

    /// More authors than this print as the first one and "et al.", as Nature's
    /// reference style does.
    static let listedAuthorLimit = 5

    /// The Markdown with each grounded passage's address turned into the
    /// numbers its sources are cited by (`foreverlm://cite/1,3`, read back by
    /// `renderLink`), and each source link's into the source's web address;
    /// with the sources cited, in number order. A source is numbered where it
    /// is first cited and keeps that number. A token `references` does not
    /// name is not cited, and an address left citing nothing is not touched,
    /// so the passage renders as its words.
    static func citing(_ markdown: String, references: [String: Reference]) -> (markdown: String, references: [Reference]) {
        guard !references.isEmpty, let expression = productAddressExpression else { return (markdown, []) }
        var numbers: [String: Int] = [:]
        var cited: [Reference] = []
        var out = ""
        let text = markdown as NSString
        var cursor = 0
        for match in expression.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            out += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let address = text.substring(with: match.range)
            let kind = text.substring(with: match.range(at: 1)).lowercased()
            let raw = text.substring(with: match.range(at: 2))
            if kind == "grounding" {
                var passage: [Int] = []
                for token in addressTokens(raw, list: true) {
                    guard let reference = references[token] else { continue }
                    let number: Int
                    if let known = numbers[token] {
                        number = known
                    } else {
                        cited.append(reference)
                        number = cited.count
                        numbers[token] = number
                    }
                    if !passage.contains(number) { passage.append(number) }
                }
                out += passage.isEmpty ? address : citationAddressPrefix + passage.map(String.init).joined(separator: ",")
            } else if let token = addressTokens(raw, list: false).first,
                      let url = references[token]?.url.flatMap(webAddress) {
                out += url
            } else {
                out += address
            }
        }
        out += text.substring(from: cursor)
        return (out, cited)
    }

    /// The References list for the sources cited, nothing when none is.
    static func referencesSection(_ cited: [Reference]) -> String {
        guard !cited.isEmpty else { return "" }
        var html = "<h2>\(referencesHeading)</h2>\n<ol>\n"
        for reference in cited { html += "<li>\(referenceHTML(reference))</li>\n" }
        html += "</ol>\n"
        return html
    }

    /// One entry of the list: authors, title, where and when it appeared, and
    /// its address, each a sentence, the venue in italics. A field the source
    /// does not have is left out rather than written as unknown.
    static func referenceHTML(_ reference: Reference) -> String {
        var parts: [String] = []
        let names = authorList(reference.authors)
        if !names.isEmpty { parts.append(escape(sentence(names))) }
        let title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = reference.url.flatMap(webAddress)
        if !title.isEmpty {
            parts.append(escape(sentence(title)))
        } else if url == nil {
            parts.append("Untitled source.")
        }
        var place = ""
        if let container = reference.container?.trimmingCharacters(in: .whitespacesAndNewlines), !container.isEmpty {
            place = "<em>\(escape(container))</em>"
        }
        if let year = reference.year?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty {
            place += place.isEmpty ? "(\(escape(year)))" : " (\(escape(year)))"
        }
        if !place.isEmpty { parts.append(place + ".") }
        if let url { parts.append("<a href=\"\(escape(url))\">\(escape(url))</a>") }
        return parts.joined(separator: " ")
    }

    /// "A", "A & B", "A, B & C", up to the limit; past it "A et al.".
    static func authorList(_ authors: [String]) -> String {
        let names = authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = names.first else { return "" }
        if names.count > listedAuthorLimit { return first + " et al." }
        if names.count == 1 { return first }
        return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
    }

    /// The citation a passage carries: its numbers in order, a run of three
    /// or more as a range, as `1–3,5`.
    static func citationLabel(_ numbers: [Int]) -> String {
        let sorted = Array(Set(numbers)).sorted()
        var pieces: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            if end - index >= 2 {
                pieces.append("\(sorted[index])\u{2013}\(sorted[end])")
            } else {
                pieces.append(contentsOf: sorted[index...end].map(String.init))
            }
            index = end + 1
        }
        return pieces.joined(separator: ",")
    }

    /// The address a cited passage carries between `citing` and `renderLink`.
    private static let citationAddressPrefix = "foreverlm://cite/"

    /// A grounded passage's or a source link's address, the way the editor
    /// writes it into a link's destination.
    private static let productAddressExpression = try? NSRegularExpression(
        pattern: #"foreverlm://(grounding|source)/([^\)\s\]"'<>]+)"#,
        options: [.caseInsensitive]
    )

    /// The tokens an address's path carries: a grounding's list, or a source
    /// link's one id without its query (`?book=`) or fragment.
    private static func addressTokens(_ raw: String, list: Bool) -> [String] {
        var path = raw
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<end]) }
        let parts = list ? path.split(separator: ",").map(String.init) : [path]
        var tokens: [String] = []
        for part in parts {
            let token = (part.removingPercentEncoding ?? part).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, !tokens.contains(token) { tokens.append(token) }
        }
        return tokens
    }

    /// An http(s) address as a Markdown destination can carry it, or nil for
    /// anything else (a file path, an app's own scheme). Spaces and
    /// parentheses are escaped so the address cannot end the link early.
    private static func webAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return nil }
        return trimmed
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Text closed as a sentence: a full stop unless it already ends in one,
    /// or in a question or exclamation mark.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".?!".contains(last) ? text : text + "."
    }

    // MARK: - Blocks

    private static func renderBlocks(_ lines: [String]) -> String {
        var out = ""
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceOpening(trimmed) {
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker), candidate.allSatisfy({ $0 == fence.marker.first! }) {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                let classAttribute = fence.language.isEmpty ? "" : " class=\"language-\(escape(fence.language))\""
                out += "<pre><code\(classAttribute)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            if let heading = headingLevel(trimmed) {
                let text = trimmed.dropFirst(heading).trimmingCharacters(in: .whitespaces)
                let stripped = stripClosingHashes(text)
                out += "<h\(heading)>\(inline(stripped))</h\(heading)>\n"
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                out += "<hr>\n"
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var inner = String(candidate.dropFirst())
                    if inner.hasPrefix(" ") { inner.removeFirst() }
                    quoted.append(inner)
                    index += 1
                }
                out += "<blockquote>\n\(renderBlocks(quoted))</blockquote>\n"
                continue
            }

            if let item = listItem(line) {
                let (html, consumed) = renderList(lines, from: index, ordered: item.ordered, indent: item.indent)
                out += html
                index += consumed
                continue
            }

            if index + 1 < lines.count,
               isTableRow(trimmed),
               isTableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                let (html, consumed) = renderTable(lines, from: index)
                out += html
                index += consumed
                continue
            }

            // A paragraph runs until a blank line or the start of another block.
            // Lines keep their trailing spaces here: two of them are a hard
            // break, which `inlineParagraph` reads before trimming.
            var paragraph: [String] = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty
                    || fenceOpening(candidateTrimmed) != nil
                    || headingLevel(candidateTrimmed) != nil
                    || isThematicBreak(candidateTrimmed)
                    || candidateTrimmed.hasPrefix(">")
                    || listItem(candidate) != nil {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            let rendered = inlineParagraph(paragraph)
            // An attachment image with no alt text renders to nothing; an empty
            // paragraph would only add a blank line to the Google Doc.
            if !rendered.isEmpty {
                out += "<p>\(rendered)</p>\n"
            }
        }
        return out
    }

    /// Lines of one paragraph joined the way Markdown reads them: a soft break
    /// is a space, a line ending in two spaces or a backslash is a hard break.
    private static func inlineParagraph(_ lines: [String]) -> String {
        var pieces: [String] = []
        for (offset, raw) in lines.enumerated() {
            var line = raw
            var hardBreak = false
            if line.hasSuffix("\\") {
                line.removeLast()
                hardBreak = true
            } else if raw.hasSuffix("  ") {
                hardBreak = true
            }
            var rendered = inline(line.trimmingCharacters(in: .whitespaces))
            if hardBreak, offset < lines.count - 1 { rendered += "<br>" }
            pieces.append(rendered)
        }
        return pieces.joined(separator: pieces.count > 1 ? "\n" : "")
    }

    private struct Fence {
        let marker: String
        let language: String
    }

    private static func fenceOpening(_ trimmed: String) -> Fence? {
        for character in ["`", "~"] {
            let run = trimmed.prefix(while: { String($0) == character })
            guard run.count >= 3 else { continue }
            let rest = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A language tag holding the fence character is not a fence.
            guard !rest.contains(character) else { continue }
            let language = rest.split(separator: " ").first.map(String.init) ?? ""
            return Fence(marker: String(run), language: language)
        }
        return nil
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return hashes
    }

    private static func stripClosingHashes(_ text: String) -> String {
        var value = text
        while value.hasSuffix("#") { value.removeLast() }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let compact = trimmed.filter { $0 != " " }
        return compact.count >= 3 && compact.allSatisfy { $0 == first }
    }

    // MARK: - Lists

    private struct ListItem {
        let indent: Int
        let ordered: Bool
        /// Where the item's text starts on its first line; continuation lines
        /// indented to here belong to the item.
        let contentColumn: Int
        let text: String
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            let text = String(after.drop(while: { $0 == " " }))
            return ListItem(indent: indent, ordered: false, contentColumn: indent + 2, text: text)
        }
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.isEmpty || after.first == " " else { return nil }
        let text = String(after.drop(while: { $0 == " " }))
        return ListItem(indent: indent, ordered: true, contentColumn: indent + digits.count + 2, text: text)
    }

    /// Render one list starting at `start`, returning the HTML and how many
    /// lines it consumed. Deeper-indented lines are the item's own content and
    /// are rendered recursively, so nested lists and multi-paragraph items work.
    private static func renderList(_ lines: [String], from start: Int, ordered: Bool, indent: Int) -> (String, Int) {
        var items: [String] = []
        var index = start
        var startNumber: Int?

        while index < lines.count {
            guard let item = listItem(lines[index]),
                  item.indent == indent,
                  item.ordered == ordered else { break }
            if ordered, startNumber == nil {
                let digits = lines[index].dropFirst(indent).prefix(while: { $0.isNumber })
                startNumber = Int(digits) ?? 1
            }
            var content: [String] = [item.text]
            index += 1
            var pendingBlank = false
            while index < lines.count {
                let candidate = lines[index]
                let candidateIndent = candidate.prefix(while: { $0 == " " }).count
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                    pendingBlank = true
                    index += 1
                    continue
                }
                if candidateIndent >= item.contentColumn {
                    if pendingBlank { content.append("") }
                    pendingBlank = false
                    content.append(String(candidate.dropFirst(item.contentColumn)))
                    index += 1
                    continue
                }
                // A blank line followed by something at the list's own indent
                // that is not an item ends the list; the blank is not consumed
                // twice, so the outer loop sees it.
                if pendingBlank {
                    index -= 1
                }
                break
            }
            items.append(renderListItem(content))
        }

        let tag = ordered ? "ol" : "ul"
        let startAttribute = (ordered && startNumber.map { $0 != 1 } == true) ? " start=\"\(startNumber!)\"" : ""
        var html = "<\(tag)\(startAttribute)>\n"
        for item in items { html += "<li>\(item)</li>\n" }
        html += "</\(tag)>\n"
        return (html, index - start)
    }

    private static func renderListItem(_ content: [String]) -> String {
        var lines = content
        if let first = lines.first {
            // GitHub task items: the box is a glyph Google Docs can hold.
            if first.hasPrefix("[ ] ") || first == "[ ]" {
                lines[0] = "☐ " + first.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if first.lowercased().hasPrefix("[x] ") || first.lowercased() == "[x]" {
                lines[0] = "☑ " + first.dropFirst(3).trimmingCharacters(in: .whitespaces)
            }
        }
        let rendered = renderBlocks(lines)
        // One paragraph reads as the item itself, not a paragraph inside it.
        let trimmed = rendered.trimmingCharacters(in: .newlines)
        if trimmed.hasPrefix("<p>"), trimmed.hasSuffix("</p>"),
           !trimmed.dropFirst(3).contains("<p>") {
            return String(trimmed.dropFirst(3).dropLast(4))
        }
        return "\n" + rendered
    }

    // MARK: - Tables

    private static func isTableRow(_ trimmed: String) -> Bool {
        trimmed.contains("|")
    }

    private static func isTableDelimiter(_ trimmed: String) -> Bool {
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return false }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.trimmingCharacters(in: .whitespaces)
            guard !compact.isEmpty else { return false }
            let core = compact.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ trimmed: String) -> [String] {
        var row = trimmed
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        // Split on unescaped pipes; `\|` is a literal pipe inside a cell.
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells
    }

    private static func renderTable(_ lines: [String], from start: Int) -> (String, Int) {
        let header = tableCells(lines[start].trimmingCharacters(in: .whitespaces))
        var index = start + 2
        var rows: [[String]] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isTableRow(trimmed) else { break }
            rows.append(tableCells(trimmed))
            index += 1
        }
        var html = "<table>\n<thead>\n<tr>"
        for cell in header { html += "<th>\(inline(cell.trimmingCharacters(in: .whitespaces)))</th>" }
        html += "</tr>\n</thead>\n"
        if !rows.isEmpty {
            html += "<tbody>\n"
            for row in rows {
                html += "<tr>"
                for column in 0..<header.count {
                    let cell = column < row.count ? row[column] : ""
                    html += "<td>\(inline(cell.trimmingCharacters(in: .whitespaces)))</td>"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        html += "</table>\n"
        return (html, index - start)
    }

    // MARK: - Inline

    /// The index just past a `<br>`, `<br/>` or `<br />` tag starting at
    /// `start`, in any letter case; nil when the characters there are not one.
    private static func lineBreakTagEnd(_ characters: [Character], from start: Int) -> Int? {
        var cursor = start + 1
        for expected in ["b", "r"] {
            guard cursor < characters.count, characters[cursor].lowercased() == expected else { return nil }
            cursor += 1
        }
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        if cursor < characters.count, characters[cursor] == "/" { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == ">" else { return nil }
        return cursor + 1
    }

    /// Inline Markdown to HTML: code spans, images, links, strong, emphasis
    /// and strikethrough, with everything else escaped as text.
    static func inline(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var index = 0

        func closing(_ delimiter: [Character], after position: Int) -> Int? {
            // A closer follows non-whitespace and is not itself the opener's
            // immediate neighbour, so `**` alone and `a ** b` stay literal.
            var cursor = position
            while cursor + delimiter.count <= characters.count {
                if Array(characters[cursor..<cursor + delimiter.count]) == delimiter,
                   cursor > position,
                   !characters[cursor - 1].isWhitespace {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }

        func emphasis(_ delimiter: [Character], tag: String) -> Bool {
            let openEnd = index + delimiter.count
            guard openEnd < characters.count,
                  Array(characters[index..<openEnd]) == delimiter,
                  !characters[openEnd].isWhitespace,
                  let close = closing(delimiter, after: openEnd) else { return false }
            let innerText = String(characters[openEnd..<close])
            out += "<\(tag)>\(inline(innerText))</\(tag)>"
            index = close + delimiter.count
            return true
        }

        while index < characters.count {
            let character = characters[index]

            // The one piece of inline HTML the editor and the chat both write
            // for a line break inside a paragraph. Escaping it as text put a
            // literal "<br />" line into a converted Google Doc; it is a break.
            if character == "<", let end = lineBreakTagEnd(characters, from: index) {
                out += "<br>"
                index = end
                continue
            }

            if character == "\\", index + 1 < characters.count, characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                out += escape(String(characters[index + 1]))
                index += 2
                continue
            }

            if character == "`" {
                let run = characters[index...].prefix(while: { $0 == "`" }).count
                let opener = Array(repeating: Character("`"), count: run)
                var cursor = index + run
                var found: Int?
                while cursor + run <= characters.count {
                    if Array(characters[cursor..<cursor + run]) == opener,
                       cursor + run == characters.count || characters[cursor + run] != "`" {
                        found = cursor
                        break
                    }
                    cursor += 1
                }
                if let found {
                    var code = String(characters[(index + run)..<found])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 1 {
                        code = String(code.dropFirst().dropLast())
                    }
                    out += "<code>\(escape(code))</code>"
                    index = found + run
                } else {
                    out += String(repeating: "`", count: run)
                    index += run
                }
                continue
            }

            if character == "!", index + 1 < characters.count, characters[index + 1] == "[",
               let link = parseLink(characters, from: index + 1) {
                out += renderImage(alt: link.text, destination: link.destination)
                index = link.end
                continue
            }

            if character == "[", let link = parseLink(characters, from: index) {
                out += renderLink(text: link.text, destination: link.destination, title: link.title)
                index = link.end
                continue
            }

            if character == "*" || character == "_" {
                if emphasis([character, character], tag: "strong") { continue }
                if emphasis([character], tag: "em") { continue }
            }

            if character == "~", emphasis(["~", "~"], tag: "s") { continue }

            out += escape(String(character))
            index += 1
        }
        return out
    }

    private struct Link {
        let text: String
        let destination: String
        let title: String?
        let end: Int
    }

    /// `[text](destination "title")` starting at the `[`; nil when the
    /// brackets or parentheses do not close on this line.
    private static func parseLink(_ characters: [Character], from start: Int) -> Link? {
        guard start < characters.count, characters[start] == "[" else { return nil }
        var depth = 0
        var cursor = start
        var closeBracket: Int?
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" { cursor += 2; continue }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { closeBracket = cursor; break }
            }
            cursor += 1
        }
        guard let closeBracket, closeBracket + 1 < characters.count, characters[closeBracket + 1] == "(" else {
            return nil
        }
        var parenDepth = 0
        cursor = closeBracket + 1
        var closeParen: Int?
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" { cursor += 2; continue }
            if character == "(" { parenDepth += 1 }
            if character == ")" {
                parenDepth -= 1
                if parenDepth == 0 { closeParen = cursor; break }
            }
            cursor += 1
        }
        guard let closeParen else { return nil }
        let text = String(characters[(start + 1)..<closeBracket])
        let inside = String(characters[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
        var destination = inside
        var title: String?
        if let quote = inside.firstIndex(of: "\""), inside.hasSuffix("\"") {
            destination = String(inside[..<quote]).trimmingCharacters(in: .whitespaces)
            title = String(inside[inside.index(after: quote)..<inside.index(before: inside.endIndex)])
        }
        if destination.hasPrefix("<"), destination.hasSuffix(">") {
            destination = String(destination.dropFirst().dropLast())
        }
        return Link(text: text, destination: destination, title: title, end: closeParen + 1)
    }

    /// Whether a link target is one of ForeverLM's own addresses, meaningful
    /// only inside the app.
    static func isInternalDestination(_ destination: String) -> Bool {
        destination.lowercased().hasPrefix("foreverlm://")
    }

    private static func renderLink(text: String, destination: String, title: String?) -> String {
        let label = inline(text)
        if destination.lowercased().hasPrefix(citationAddressPrefix) {
            let numbers = destination.dropFirst(citationAddressPrefix.count)
                .split(separator: ",")
                .compactMap { Int($0) }
            return numbers.isEmpty ? label : label + "<sup>\(citationLabel(numbers))</sup>"
        }
        guard !isInternalDestination(destination), !destination.isEmpty else { return label }
        var attributes = " href=\"\(escape(destination))\""
        if let title, !title.isEmpty { attributes += " title=\"\(escape(title))\"" }
        return "<a\(attributes)>\(label)</a>"
    }

    private static func renderImage(alt: String, destination: String) -> String {
        guard !isInternalDestination(destination), !destination.isEmpty else {
            let label = alt.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? "" : "<em>\(escape(label))</em>"
        }
        return "<img src=\"\(escape(destination))\" alt=\"\(escape(alt))\">"
    }

    // MARK: - Escaping

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}
