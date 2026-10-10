import Foundation

/// A small, deterministic Markdown-to-HTML renderer for handing a Doc's body
/// to something that reads HTML — today Google Drive, which turns HTML into a
/// Google Doc on upload.
///
/// This is structure, not prose: headings, paragraphs, emphasis, lists, links,
/// code, quotes, rules and tables, the grammar the Docs editor writes. Two
/// things the editor stores are ForeverLM's own and have no meaning outside
/// it, so they are unwrapped rather than sent along:
///
/// - `foreverlm://…` links (grounding over a passage, the retired source chip)
///   render as their text alone — the attachment is invisible in the prose by
///   design, and the address opens nothing in Google Docs.
/// - `foreverlm://attachment/…` images render as their alt text, or nothing.
///   The picture's bytes live in the doc's body package, and a multipart create
///   carries one HTML part; shipping them would be a second upload per image.
///
/// The same input always gives the same output; there is no state and no
/// randomness, so a test can pin a whole document.
enum MarkdownHTML {
    /// A complete HTML document with `title` in its head and the rendered body.
    static func document(title: String, markdown: String) -> String {
        var html = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
        html += "<title>\(escape(title))</title>\n</head>\n<body>\n"
        html += body(markdown)
        html += "</body>\n</html>\n"
        return html
    }

    /// The rendered blocks alone, one per line, without a document wrapper.
    static func body(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return renderBlocks(lines)
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
