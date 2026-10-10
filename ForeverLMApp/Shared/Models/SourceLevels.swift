import Foundation

// MARK: - Levels in the Reader (docs/sensemaking-design.md, "Levels in the Reader")
//
// A source zoomed out, read in a panel beside the real PDF or article rather
// than in a copy of it: its gist, a line for each section and for each
// paragraph, and the key terms a newcomer needs first. The model writes the
// lines and refers to paragraphs only by the numbers the app gave them
// (¶1…¶N); every anchor — the opening words the Reader finds and flashes —
// is taken from the stored text by the app, never from the model. A source's
// levels are written once for one version of its text (its SHA-256) and kept
// in `source_levels`; a different text makes them stale.

/// A source's reading levels, as stored (`source_levels.payload_json`).
struct SourceLevels: Codable, Equatable, Sendable {
    /// One key finding, with the section that establishes it.
    struct Finding: Codable, Equatable, Sendable {
        var text: String
        /// Index into `sections`, from 0.
        var sectionIndex: Int?
    }

    /// One paragraph's line.
    struct Paragraph: Codable, Equatable, Sendable {
        /// Its ¶ number, from 1, in the numbering of `SourceLevelsText`.
        var index: Int
        /// Its point in a line; empty when the model wrote none for it, and
        /// the panel then shows its opening words.
        var line: String
        /// Its opening words, verbatim from the stored text: what the Reader
        /// finds and flashes.
        var anchor: String
    }

    struct Section: Codable, Equatable, Sendable {
        var title: String
        /// What it establishes, in a sentence.
        var line: String
        /// Its paragraphs in order; every paragraph of the text is in one
        /// section.
        var paragraphs: [Paragraph]

        /// Where the section begins: its first paragraph's opening words.
        var anchor: String? { paragraphs.first?.anchor }
        var firstParagraph: Int? { paragraphs.first?.index }
    }

    struct Term: Codable, Equatable, Sendable {
        var term: String
        var definition: String
        /// The paragraph the source defines it in, or first uses it in.
        var paragraphIndex: Int?
        /// The words the Reader flashes for it, verbatim from the text.
        var anchor: String?
    }

    static let currentVersion = 1

    var sourceID: String
    /// The SHA-256 of the stored text the levels were written from
    /// (`PaperContentPreparationService.sha256`).
    var contentSHA256: String
    /// The source's point, in one sentence.
    var gist: String
    /// Why it matters, in one line.
    var why: String
    /// Up to four.
    var findings: [Finding]
    var sections: [Section]
    var terms: [Term]
    var model: String?
    var createdAt: Date
    var version: Int = SourceLevels.currentVersion

    /// Whether the text has changed since these levels were written.
    func isStale(currentSHA256: String) -> Bool {
        contentSHA256 != currentSHA256
    }

    var paragraphCount: Int { sections.reduce(0) { $0 + $1.paragraphs.count } }

    /// The section a paragraph is in.
    func sectionIndex(ofParagraph index: Int) -> Int? {
        sections.firstIndex { section in section.paragraphs.contains { $0.index == index } }
    }

    func paragraph(_ index: Int) -> Paragraph? {
        for section in sections {
            if let paragraph = section.paragraphs.first(where: { $0.index == index }) { return paragraph }
        }
        return nil
    }
}

// MARK: - The text as the levels number it

/// The stored text cut into the blocks the levels are written over: the
/// source's own headings, and its paragraphs numbered ¶1…¶N in order.
/// Deterministic, so the same text always gives the same numbers: the
/// numbering is the identity every stored line and anchor refers to.
///
/// Stored text comes in two shapes. A web article or EPUB chapter holds a
/// paragraph a line (or blank lines between paragraphs). A paper's PDF text
/// keeps the page's physical lines, wrapped at the column, with no blank
/// lines between paragraphs; there a paragraph ends at a line that finishes a
/// sentence well short of the column, and a short line with no closing
/// punctuation that a capitalised line follows is a heading.
enum SourceLevelsText {
    struct Block: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case heading
            case paragraph
        }

        var kind: Kind
        /// The block's words, its lines joined with single spaces.
        var text: String
        /// Its ¶ number, from 1, for a paragraph; nil for a heading.
        var number: Int?
        /// The page it starts on, from 0, counted by the text's form feeds
        /// (a PDF's stored page boundaries); nil when the text has none.
        var page: Int?
        /// Where it starts in the text, as a share of the text's length.
        var position: Double
    }

    /// Paragraphs longer than this are cut at sentence ends.
    static let maximumParagraphWords = 220
    /// The words an anchor takes from the start of its paragraph.
    static let anchorWords = 12

    private struct Line {
        var text: String
        var page: Int
        var offset: Int
    }

    static func blocks(of text: String) -> [Block] {
        let hasPages = text.contains("\u{000C}")
        var lines: [Line] = []
        var offset = 0
        for (pageIndex, pageText) in text.split(separator: "\u{000C}", omittingEmptySubsequences: false).enumerated() {
            for raw in pageText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let lineText = raw.trimmingCharacters(in: .whitespaces)
                lines.append(Line(text: lineText, page: pageIndex, offset: offset))
                offset += raw.utf16.count + 1
            }
        }
        let total = Double(max(1, text.utf16.count))

        let content = lines.filter { !$0.text.isEmpty }
        guard !content.isEmpty else { return [] }
        let lengths = content.map(\.text.count).sorted()
        let median = lengths[lengths.count / 2]
        let endingSentences = content.filter { endsSentence($0.text) }.count
        // Wrapped: a PDF's column lines, most of which stop mid-sentence.
        let wrapped = content.count >= 8 && median <= 120 && Double(endingSentences) < Double(content.count) * 0.5
        let fullWidth = Double(lengths[Int(Double(lengths.count - 1) * 0.8)])
        let blankLines = lines.count - content.count
        // Blank lines already part the paragraphs; nothing is guessed then.
        let blankSeparated = blankLines >= max(3, content.count / 8)

        var blocks: [Block] = []
        var buffer: [Line] = []
        var bufferWords = 0

        /// A heading's shape; in a PDF's column, also well short of the
        /// column, which a full line of a paragraph never is.
        func headingLike(_ text: String) -> Bool {
            looksLikeHeading(text) && (!wrapped || Double(text.count) < fullWidth * 0.75)
        }

        func appendParagraph(_ words: [Substring], from line: Line) {
            guard !words.isEmpty else { return }
            blocks.append(Block(
                kind: .paragraph,
                text: words.joined(separator: " "),
                number: nil,
                page: hasPages ? line.page : nil,
                position: Double(line.offset) / total
            ))
        }

        /// Whether the lines now read are a list's items: short lines after
        /// a line that ends with a colon, until a line of prose. Their shape
        /// is a heading's, but they are the paragraph's words.
        var inList = false

        func flush() {
            guard let first = buffer.first else { return }
            // One heading's line alone — a title above "Introduction" — heads.
            if buffer.count == 1, !inList, headingLike(first.text) {
                buffer = []
                bufferWords = 0
                appendHeading(first.text, from: first)
                return
            }
            var joined = ""
            for line in buffer {
                if joined.isEmpty {
                    joined = line.text
                } else if joined.hasSuffix("-"), let next = line.text.first, next.isLowercase {
                    // A word hyphenated at the column's edge reads whole.
                    joined += line.text
                } else {
                    joined += " " + line.text
                }
            }
            buffer = []
            bufferWords = 0
            let words = joined.split(whereSeparator: \.isWhitespace)
            if words.count <= maximumParagraphWords + maximumParagraphWords / 2 {
                appendParagraph(words, from: first)
                return
            }
            // A run with no paragraph break found in it — a transcript, a
            // page of text set without breaks — is cut at sentence ends.
            var piece: [Substring] = []
            for sentence in sentences(in: joined) {
                var sentenceWords = sentence.split(whereSeparator: \.isWhitespace)[...]
                if !piece.isEmpty, piece.count + sentenceWords.count > maximumParagraphWords {
                    appendParagraph(piece, from: first)
                    piece = []
                }
                // A "sentence" longer than a paragraph — a table's rows, a
                // list with no stops — is cut by words.
                while sentenceWords.count > maximumParagraphWords {
                    appendParagraph(Array(sentenceWords.prefix(maximumParagraphWords)), from: first)
                    sentenceWords = sentenceWords.dropFirst(maximumParagraphWords)
                }
                piece += sentenceWords
            }
            appendParagraph(piece, from: first)
        }

        func appendHeading(_ heading: String, from line: Line) {
            let words = heading.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return }
            blocks.append(Block(
                kind: .heading,
                text: words.joined(separator: " "),
                number: nil,
                page: hasPages ? line.page : nil,
                position: Double(line.offset) / total
            ))
        }

        for (index, line) in lines.enumerated() {
            if line.text.isEmpty {
                flush()
                continue
            }
            // A page number on a line of its own is not prose.
            if isPageNumber(line.text) { continue }
            if let heading = markdownHeading(line.text) {
                flush()
                appendHeading(heading, from: line)
                continue
            }
            let next = lines[(index + 1)...].first { !$0.text.isEmpty && !isPageNumber($0.text) }
            if inList, !headingLike(line.text) { inList = false }
            // A heading opens a block: nothing waits, the line before ended a
            // sentence, or only heading lines wait (a title above it). The
            // line after it starts a sentence and is no heading itself, so a
            // list of short items stays the paragraph it is.
            let opensBlock = buffer.isEmpty
                || buffer.last.map { endsSentence($0.text) } == true
                || buffer.allSatisfy { headingLike($0.text) }
            if !inList, opensBlock, headingLike(line.text), let next, startsSentence(next.text), !headingLike(next.text) {
                flush()
                appendHeading(line.text, from: line)
                continue
            }
            if line.text.hasSuffix(":") { inList = true }
            buffer.append(line)
            bufferWords += line.text.split(whereSeparator: \.isWhitespace).count
            if !wrapped {
                // Unwrapped text holds a paragraph a line.
                flush()
            } else if !blankSeparated, endsSentence(line.text), Double(line.text.count) < fullWidth * 0.75 {
                flush()
            } else if bufferWords >= maximumParagraphWords, endsSentence(line.text) {
                flush()
            }
        }
        flush()

        // Every block is kept, so the model reads every word of the text;
        // only the paragraphs are numbered.
        var number = 0
        return blocks.map { block in
            var block = block
            if block.kind == .paragraph {
                number += 1
                block.number = number
            }
            return block
        }
    }

    /// The numbered paragraphs alone, in order.
    static func paragraphs(_ blocks: [Block]) -> [Block] {
        blocks.filter { $0.kind == .paragraph }
    }

    /// A paragraph's opening words, which the Reader finds and flashes.
    static func anchor(of paragraph: String, words count: Int = anchorWords) -> String {
        paragraph.split(whereSeparator: \.isWhitespace).prefix(count).joined(separator: " ")
    }

    /// The sentence of `paragraph` that names `term`, verbatim; nil when no
    /// sentence of it does.
    static func sentence(naming term: String, in paragraph: String) -> String? {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return sentences(in: paragraph).first { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The blocks as the model reads them: headings as `# …` lines, each
    /// paragraph led by its number.
    static func numberedText(_ blocks: [Block]) -> String {
        blocks.map { block in
            switch block.kind {
            case .heading: return "# " + block.text
            case .paragraph: return "¶\(block.number ?? 0) " + block.text
            }
        }
        .joined(separator: "\n\n")
    }

    // MARK: Line shapes

    private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}"]

    /// Whether a line ends a sentence: closing punctuation, perhaps behind a
    /// quote or bracket, or a citation number set after the full stop.
    static func endsSentence(_ line: String) -> Bool {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        // "…in cells.12" or "…in cells.12,13": a citation number after the
        // stop. "…was 5.4" is a number, not a citation: a digit stands before
        // its stop.
        let citation = trimmed.reversed().prefix { $0.isNumber || $0 == "," || $0 == "\u{2013}" || $0 == "-" }
        if !citation.isEmpty, citation.count < trimmed.count {
            let before = trimmed.dropLast(citation.count)
            if let mark = before.last, ".?!)]".contains(mark) || closers.contains(mark),
               !(mark == "." && before.dropLast().last?.isNumber == true) {
                trimmed = before
            }
        }
        while let last = trimmed.last, closers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return last == "." || last == "?" || last == "!" || last == ":"
    }

    private static func startsSentence(_ line: String) -> Bool {
        guard let first = line.first(where: { !$0.isWhitespace && !closers.contains($0) && $0 != "\u{201C}" && $0 != "\u{2018}" }) else { return false }
        return first.isUppercase || first.isNumber
    }

    /// A short line with no closing punctuation that starts with a capital or
    /// a section number: "Introduction", "2.1 Cell culture", "RESULTS",
    /// "What is the energy of a hydrogen bond?". A figure or table legend's
    /// label is not one.
    static func looksLikeHeading(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard (1...12).contains(words.count), line.count <= 90 else { return false }
        guard let first = line.first, first.isUppercase || first.isNumber else { return false }
        guard let last = line.last, !".,;:!-\u{2013}\u{2014}(".contains(last) else { return false }
        let lowered = line.lowercased()
        for label in ["figure", "fig.", "table", "supplementary figure", "extended data"] where lowered.hasPrefix(label) {
            return false
        }
        let letters = line.filter(\.isLetter).count
        return Double(letters) >= Double(line.count) * 0.6
    }

    private static func markdownHeading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let stripped = line.drop { $0 == "#" }
        guard stripped.first == " " else { return nil }
        let heading = stripped.trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    private static func isPageNumber(_ line: String) -> Bool {
        line.count <= 4 && line.allSatisfy(\.isNumber)
    }

    /// `text` cut after each sentence's closing punctuation, where the next
    /// word starts with a capital, a digit or an opening quote.
    static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard character == "." || character == "!" || character == "?" else { continue }
            while index < characters.count, closers.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            guard index + 1 < characters.count, characters[index] == " " else { continue }
            let next = characters[index + 1]
            guard next.isUppercase || next.isNumber || next == "\u{201C}" || next == "\"" else { continue }
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            // "e.g." and "Fig." do not end a sentence.
            if character == ".", let lastWord = trimmed.split(separator: " ").last,
               ["e.g.", "i.e.", "fig.", "figs.", "et al.", "al.", "vs.", "cf.", "ref.", "refs.", "no.", "eq.", "approx."].contains(lastWord.lowercased()) {
                continue
            }
            result.append(trimmed)
            current = ""
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}

// MARK: - Where the learner is

/// Where the Reader on a source stands, as its reader reports it: a PDF's
/// page, or how far down a web page or EPUB chapter.
enum ReaderLevelsPosition: Equatable, Sendable {
    /// A page of the source's own, from 0.
    case page(Int)
    /// How far down, 0…1.
    case fraction(Double)
}

/// What the panel marks for a position: the sections it expands (focus and
/// context, Wattenberger's fisheye on text) and the paragraph lines under it.
struct SourceLevelsFocus: Equatable, Sendable {
    var sections: Set<Int> = []
    var paragraphs: Set<Int> = []

    static let none = SourceLevelsFocus()

    /// The first section in focus, which the panel scrolls to.
    var primarySection: Int? { sections.min() }

    /// The focus a position gives: on a page, every paragraph that page holds
    /// (or, on a page with none — a figure — the last one before it), and the
    /// sections they are in; down a web page, the paragraph whose start is
    /// the last one above that depth. `pages` maps a ¶ number to its page;
    /// `positions` to where it starts as a share of the text.
    static func of(
        _ position: ReaderLevelsPosition?,
        levels: SourceLevels,
        pages: [Int: Int],
        positions: [Int: Double]
    ) -> SourceLevelsFocus {
        guard let position else { return .none }
        var paragraphs: Set<Int> = []
        switch position {
        case .page(let page):
            guard !pages.isEmpty else { return .none }
            let onPage = pages.filter { $0.value == page }.map(\.key)
            if !onPage.isEmpty {
                paragraphs = Set(onPage)
            } else if let before = pages.filter({ $0.value < page }).max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
                paragraphs = [before.key]
            } else if let after = pages.filter({ $0.value > page }).min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
                paragraphs = [after.key]
            }
        case .fraction(let fraction):
            guard !positions.isEmpty else { return .none }
            let above = positions.filter { $0.value <= fraction + 0.0001 }
            if let last = above.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
                paragraphs = [last.key]
            } else if let first = positions.min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
                paragraphs = [first.key]
            }
        }
        let sections = Set(paragraphs.compactMap { levels.sectionIndex(ofParagraph: $0) })
        return SourceLevelsFocus(sections: sections, paragraphs: paragraphs)
    }
}

/// Which page of a PDF each paragraph starts on, found by searching each
/// paragraph's anchor in the pages' own text the way the Reader finds a
/// passage (`ReaderPassageLocator`): both sides folded to their letters, the
/// whole anchor tried first, then runs of its words. Paragraphs come in
/// reading order, so each is looked for from the page the one before it was
/// found on; one found nowhere takes the page of the paragraph before it.
enum SourceLevelsPageLocator {
    /// How many pages past the last find a run of an anchor's words is
    /// looked for; the whole anchor is looked for everywhere.
    static let partialReach = 3

    static func pages(for anchors: [(number: Int, anchor: String)], pageTexts: [String]) -> [Int: Int] {
        guard !pageTexts.isEmpty else { return [:] }
        let projections = pageTexts.map { ReaderPassageLocator.project($0).text }
        var found: [Int: Int] = [:]
        var cursor = 0
        for (number, anchor) in anchors {
            if Task.isCancelled { return [:] }
            let candidates = ReaderPassageLocator.candidates(for: anchor)
            guard let whole = candidates.first.map({ ReaderPassageLocator.compact($0.needle) }), !whole.isEmpty else { continue }
            let order = Array(cursor..<projections.count) + Array(0..<cursor)
            if let page = order.first(where: { projections[$0].contains(whole) }) {
                found[number] = page
                cursor = page
                continue
            }
            let near = max(0, cursor - 1)...min(projections.count - 1, cursor + partialReach)
            partial: for candidate in candidates.dropFirst() {
                let needle = ReaderPassageLocator.compact(candidate.needle)
                guard !needle.isEmpty else { continue }
                for page in near where projections[page].contains(needle) {
                    found[number] = page
                    cursor = page
                    break partial
                }
            }
        }
        // One not found reads on the page of the paragraph before it, and
        // those before the first one found on that one's page.
        var result: [Int: Int] = [:]
        var last: Int?
        for (number, _) in anchors {
            if let page = found[number] { last = page }
            if let last { result[number] = last }
        }
        if let firstFound = anchors.lazy.compactMap({ found[$0.number] }).first {
            for (number, _) in anchors where result[number] == nil {
                result[number] = firstFound
            }
        }
        return result
    }
}
