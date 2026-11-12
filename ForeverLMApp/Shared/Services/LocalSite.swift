import Foundation

/// Where a site's files were read from: a GitHub repository at a ref, under a
/// folder, at the commit the read saw. Reported with the save so the chat can
/// say what it read, and read the same place again.
struct SiteRepositorySource: Equatable, Sendable {
    var repository: String
    var ref: String?
    var path: String?
    var commit: String?

    var payload: [String: Any] {
        var object: [String: Any] = ["repository": repository]
        if let ref, !ref.isEmpty { object["ref"] = ref }
        if let path, !path.isEmpty { object["path"] = path }
        if let commit, !commit.isEmpty { object["commit"] = commit }
        return object
    }

    init(repository: String, ref: String? = nil, path: String? = nil, commit: String? = nil) {
        self.repository = repository
        self.ref = ref
        self.path = path
        self.commit = commit
    }
}

/// A site kept in the library: the author's files, scripts included, stored
/// under the record's folder, synced through the learner's own iCloud inside
/// the Artifact's body asset, and served in the app from `foreverlm-site://`
/// under a CSP sandbox. Nothing is put on the web: publishing to sites.foreverlm.com is retired
/// (product owner, 2026-10-10: "maybe we shouldn't quite
/// have sites that can be published to the web"). Spec: docs/docs-design.md → Sites.
enum LocalSite {
    static let maxFiles = 200
    /// One file passed inline in a tool call.
    static let maxInlineFileBytes = 2_000_000
    /// The inline files of one call together.
    static let maxInlineBytes = 10_000_000
    /// The whole site: its files travel between devices inside the record's
    /// CloudKit body asset, whose package is capped at
    /// `ArtifactBodyPackage.maxPackageBytes`; the rest is the text copy's room.
    static let maxBytes = ArtifactBodyPackage.maxPackageBytes - 3 * 1_024 * 1_024
    static let entryFile = SiteFilePath.entryFile

    /// A file's path inside the site, as the site will store and serve it, or
    /// nil when it cannot be one. A leading `./` or `/` is forgiven.
    static func normalizePath(_ input: String) -> String? {
        SiteFilePath.normalize(input)
    }


    // MARK: - The text copy

    /// The visible text of an HTML page, as the text copy a linked site keeps
    /// for chat: scripts, styles and tags dropped, entities decoded, block
    /// boundaries kept as line breaks. Good enough for a chat to know what a
    /// page says; the app refreshes it from the rendered page when the site is
    /// next opened.
    static func visibleText(ofHTML html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "template", "svg", "head"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</?(p|div|h[1-6]|li|ul|ol|tr|td|th|section|article|header|footer|nav|main|aside|blockquote|pre|table|figure|figcaption|dt|dd|hr)\\b[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        return LinkedPage.normalizedText(lines.joined(separator: "\n"))
    }

    /// The named entities a page's text is likely to carry, decoded. The
    /// numeric forms (`&#8217;`, `&#x2019;`) are decoded by rule.
    static let namedEntities: [String: Character] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "copy": "\u{00A9}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "middot": "\u{00B7}", "bull": "\u{2022}", "times": "\u{00D7}", "deg": "\u{00B0}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var index = 0
        while index < chars.count {
            if chars[index] == "&", let (char, length) = decodeEntity(in: chars, at: index) {
                out.append(char)
                index += length
            } else {
                out.append(chars[index])
                index += 1
            }
        }
        return out
    }

    /// The character an entity at `index` stands for and how many source
    /// characters it spans, or nil when the `&` there begins no entity.
    static func decodeEntity(in chars: [Character], at index: Int) -> (Character, Int)? {
        guard index < chars.count, chars[index] == "&" else { return nil }
        var end = index + 1
        let limit = min(chars.count, index + 12)
        while end < limit, chars[end] != ";" {
            let char = chars[end]
            guard char.isLetter || char.isNumber || char == "#" else { return nil }
            end += 1
        }
        guard end < limit, chars[end] == ";", end > index + 1 else { return nil }
        let body = String(chars[(index + 1)..<end])
        let length = end - index + 1
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (Character(scalar), length)
        }
        guard let char = namedEntities[body] else { return nil }
        return (char, length)
    }
}

// MARK: - Changing a passage in place

/// Finds the words a learner selected on a rendered site page in the page's
/// HTML source and replaces exactly them, so the app's **Change** action and
/// `replace_site_text` never rewrite a page to change one line of it.
///
/// The selection arrives as the browser gave it — one line per block it
/// crossed, entities decoded, whitespace as rendered — and the source is the
/// author's file, with its indentation, entities and inline markup. The two
/// meet on the text runs between tags. Each run's text is entity-decoded and
/// whitespace-collapsed; runs separated only by inline tags (`em`, `a`,
/// `span`…) join into one *visible line*, and a block tag, a `br`, or a
/// script or style ends the line, as it ends a line on the screen. A
/// one-line selection matches anywhere inside one visible line, so a word in
/// a paragraph is found and only that word changes. A selection of several
/// lines — the kicker and the heading under it, in two sibling elements —
/// matches the same number of consecutive visible lines: the first as their
/// tail (a drag may start mid-line), the last as their head, the ones between
/// whole. Runs inside `script`, `style`, `title`, `noscript` and `template`,
/// comments and attribute values never match; none of them is text the
/// learner could have selected.
///
/// Exactly one match is required. None means the passage is not in this
/// file's source (drawn by a script, or changed since the page was opened);
/// several mean the selection is too short to name one place. Neither is
/// guessed at.
///
/// The replacement follows the selection's shape: with as many lines as the
/// selection, each visible line's matched text takes its line; otherwise the
/// first matched run takes the whole new text and the other matched runs are
/// emptied, their tags kept. `&`, `<` and `>` in the new text are encoded.
enum SiteTextEdit {
    enum Failure: Error, Equatable, LocalizedError {
        case emptySelection
        case notFound
        case ambiguous(Int)

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "Select the text to change first."
            case .notFound:
                return "That passage was not found in the page's source."
            case .ambiguous(let count):
                return "That text appears \(count) times on the page; select a longer passage."
            }
        }
    }

    struct Change: Equatable {
        /// The file with the passage replaced.
        let html: String
        /// The passage as it was matched, lines joined by newlines.
        let found: String
        /// The new text as written into the file, before encoding.
        let replacement: String
    }

    /// Tags whose contents are not the page's text.
    static let rawTextTags: Set<String> = ["script", "style", "title", "noscript", "template", "textarea"]

    /// Tags that end a visible line, as they end one on the screen.
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "br", "caption", "dd", "details", "dialog", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "legend", "li", "main", "nav", "ol", "option", "p", "pre", "section", "summary", "table", "tbody", "td",
        "tfoot", "th", "thead", "tr", "ul",
    ]

    /// The selection as lines: entities decoded, whitespace collapsed, each
    /// line trimmed, blank lines dropped.
    static func lines(of text: String) -> [String] {
        LocalSite.decodeEntities(text)
            .split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .map { collapsed(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Whitespace runs to one space, trimmed.
    static func collapsed(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for char in text {
            if char.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(char)
            }
        }
        return out
    }

    /// The new text as it goes into the file: the three characters that would
    /// start markup encoded, nothing else touched.
    static func encoded(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(char)
            }
        }
        return out
    }

    static func apply(find: String, replace: String, toHTML html: String) throws -> Change {
        let selection = lines(of: find)
        guard !selection.isEmpty else { throw Failure.emptySelection }
        let chars = Array(html)
        let visible = visibleLines(of: chars)
        let matches = matches(for: selection, in: visible)
        guard !matches.isEmpty else { throw Failure.notFound }
        guard matches.count == 1 else { throw Failure.ambiguous(matches.count) }
        let match = matches[0]

        let newLines = lines(of: replace)
        let perLine: [String]
        if newLines.count == selection.count {
            perLine = newLines
        } else {
            perLine = [newLines.joined(separator: "\n")] + Array(repeating: "", count: selection.count - 1)
        }

        // Each selection line's cells, grouped by the run they came from: the
        // first group takes the line's new text, the rest are emptied.
        var edits: [(range: Range<Int>, text: String)] = []
        for (lineIndex, span) in match.enumerated() {
            let cells = visible[span.line].cells[span.range]
            var groups: [(run: Int, range: Range<Int>)] = []
            for cell in cells {
                if let last = groups.last, last.run == cell.run {
                    groups[groups.count - 1].range = last.range.lowerBound..<cell.source.upperBound
                } else {
                    groups.append((cell.run, cell.source))
                }
            }
            for (groupIndex, group) in groups.enumerated() {
                edits.append((group.range, groupIndex == 0 ? encoded(perLine[lineIndex]) : ""))
            }
        }
        var output = chars
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(edit.range, with: Array(edit.text))
        }
        return Change(
            html: String(output),
            found: selection.joined(separator: "\n"),
            replacement: perLine.filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    // MARK: The source, as visible lines

    /// One character of a visible line: what it reads as, the run it came
    /// from and the source characters it stands for — an entity's whole
    /// spelling, a whitespace run's every character.
    struct Cell: Equatable {
        let char: Character
        let run: Int
        let source: Range<Int>
    }

    struct VisibleLine: Equatable {
        var cells: [Cell] = []
        var text: String { String(cells.map(\.char)) }
        /// The cells between the first and the last that are not spaces.
        var trimmedRange: Range<Int> {
            guard let first = cells.firstIndex(where: { $0.char != " " }),
                  let last = cells.lastIndex(where: { $0.char != " " }) else { return 0..<0 }
            return first..<(last + 1)
        }
    }

    /// The text of the page as the lines it draws, each remembering where its
    /// characters live in the source.
    static func visibleLines(of chars: [Character]) -> [VisibleLine] {
        var lines: [VisibleLine] = []
        var current = VisibleLine()
        var runCount = 0
        func closeLine() {
            if current.cells.contains(where: { $0.char != " " }) { lines.append(current) }
            current = VisibleLine()
        }
        func startsTag(at index: Int) -> Bool {
            guard index + 1 < chars.count, chars[index] == "<" else { return false }
            let next = chars[index + 1]
            return next.isLetter || next == "/" || next == "!" || next == "?"
        }
        func matches(_ word: String, at index: Int) -> Bool {
            let needle = Array(word)
            guard index + needle.count <= chars.count else { return false }
            for (offset, char) in needle.enumerated() where chars[index + offset].lowercased() != String(char) { return false }
            return true
        }
        func tagEnd(from index: Int) -> Int {
            var i = index
            var quote: Character? = nil
            while i < chars.count {
                let char = chars[i]
                if let open = quote {
                    if char == open { quote = nil }
                } else if char == "\"" || char == "'" {
                    quote = char
                } else if char == ">" {
                    return i
                }
                i += 1
            }
            return chars.count - 1
        }

        var index = 0
        while index < chars.count {
            if startsTag(at: index) {
                if matches("<!--", at: index) {
                    var end = index + 4
                    while end < chars.count, !matches("-->", at: end) { end += 1 }
                    index = min(chars.count, end + 3)
                    continue
                }
                if chars[index + 1] == "!" || chars[index + 1] == "?" {
                    index = tagEnd(from: index) + 1
                    continue
                }
                var nameStart = index + 1
                let closing = chars[nameStart] == "/"
                if closing { nameStart += 1 }
                var nameEnd = nameStart
                while nameEnd < chars.count, chars[nameEnd].isLetter || chars[nameEnd].isNumber || chars[nameEnd] == "-" || chars[nameEnd] == ":" {
                    nameEnd += 1
                }
                let name = String(chars[nameStart..<nameEnd]).lowercased()
                let end = tagEnd(from: index)
                if !closing, rawTextTags.contains(name), !(end > index && chars[end - 1] == "/") {
                    // Skip to the matching close tag; its contents are not text.
                    var close = end + 1
                    while close < chars.count {
                        if matches("</\(name)", at: close) {
                            let after = close + name.count + 2
                            if after >= chars.count || chars[after] == ">" || chars[after].isWhitespace { break }
                        }
                        close += 1
                    }
                    closeLine()
                    index = close < chars.count ? tagEnd(from: close) + 1 : chars.count
                    continue
                }
                if blockTags.contains(name) { closeLine() }
                index = end + 1
                continue
            }

            // A text run, up to the next tag.
            var end = index
            while end < chars.count, !startsTag(at: end) { end += 1 }
            let run = runCount
            runCount += 1
            var i = index
            while i < end {
                let char = chars[i]
                if char.isWhitespace {
                    var j = i
                    while j < end, chars[j].isWhitespace { j += 1 }
                    // One space, unless the line already ends in one or is
                    // empty; the source characters then stay as they are.
                    if let last = current.cells.last, last.char != " " {
                        current.cells.append(Cell(char: " ", run: run, source: i..<j))
                    }
                    i = j
                    continue
                }
                if char == "&", let (decoded, length) = LocalSite.decodeEntity(in: chars, at: i) {
                    if decoded.isWhitespace {
                        if let last = current.cells.last, last.char != " " {
                            current.cells.append(Cell(char: " ", run: run, source: i..<(i + length)))
                        }
                    } else {
                        current.cells.append(Cell(char: decoded, run: run, source: i..<(i + length)))
                    }
                    i += length
                    continue
                }
                current.cells.append(Cell(char: char, run: run, source: i..<(i + 1)))
                i += 1
            }
            index = end
        }
        closeLine()
        return lines
    }

    // MARK: Matching

    /// Where a selection line's text sits in a visible line.
    struct Span: Equatable {
        let line: Int
        let range: Range<Int>
    }

    /// Every place the selection reads in the page: one span per selection
    /// line, on consecutive visible lines.
    static func matches(for selection: [String], in lines: [VisibleLine]) -> [[Span]] {
        var found: [[Span]] = []
        if selection.count == 1 {
            let needle = Array(selection[0])
            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmedRange
                let hay = Array(line.cells[trimmed].map(\.char))
                for start in occurrences(of: needle, in: hay) {
                    let from = trimmed.lowerBound + start
                    found.append([Span(line: lineIndex, range: from..<(from + needle.count))])
                }
            }
            return found
        }
        guard lines.count >= selection.count else { return [] }
        for start in 0...(lines.count - selection.count) {
            var spans: [Span] = []
            for (offset, wanted) in selection.enumerated() {
                let line = lines[start + offset]
                let trimmed = line.trimmedRange
                let text = Array(line.cells[trimmed].map(\.char))
                let needle = Array(wanted)
                let range: Range<Int>?
                if offset == 0 {
                    range = text.count >= needle.count && Array(text.suffix(needle.count)) == needle
                        ? (trimmed.upperBound - needle.count)..<trimmed.upperBound : nil
                } else if offset == selection.count - 1 {
                    range = text.count >= needle.count && Array(text.prefix(needle.count)) == needle
                        ? trimmed.lowerBound..<(trimmed.lowerBound + needle.count) : nil
                } else {
                    range = text == needle ? trimmed : nil
                }
                guard let range else { break }
                spans.append(Span(line: start + offset, range: range))
            }
            if spans.count == selection.count { found.append(spans) }
        }
        return found
    }

    /// Every start of `needle` in `hay`, overlapping ones included.
    static func occurrences(of needle: [Character], in hay: [Character]) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var starts: [Int] = []
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            var matched = true
            for offset in 1..<needle.count where hay[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { starts.append(start) }
        }
        return starts
    }
}
