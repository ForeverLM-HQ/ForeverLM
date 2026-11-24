import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Finding a place in a narration
//
// A narration is stored as chunks of text, one audio file each
// (`SyncedArticleAudioManifest.Chunk.text`). Going to a part of it — a paper's
// Results, or the paragraph the learner right-clicked in the Reader — means
// finding that part's opening words in the chunk texts. The narration is not
// the PDF's text: the preparation pass drops citations, headings and paragraph
// breaks, and joins hyphenated words. So both sides are compared as a bare run
// of letters and digits, and the passage is tried from several of its words in
// turn until one window of it is found.

/// A point in a narration: the chunk it falls in and how far into that chunk's
/// text, from 0 to 1. Audio time follows from the chunk's duration.
struct NarrationSpot: Equatable, Sendable {
    var chunkIndex: Int
    var fraction: Double

    /// Seconds into the chunk's audio, assuming speech runs evenly through it.
    func offset(inChunkOfDuration duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(duration * fraction, duration))
    }
}

/// A heading the narration can jump to.
struct NarrationSection: Equatable, Identifiable, Sendable {
    var id: Int
    var title: String
    var spot: NarrationSpot
}

/// A section as read from the paper itself, before it is found in the
/// narration: its heading and the words that follow it.
struct NarrationSectionCandidate: Equatable, Sendable {
    var title: String
    var opening: String
}

/// The narration's chunk texts, normalized once so many lookups stay cheap.
struct NarrationTextIndex: Sendable {
    /// Every chunk's letters and digits, end to end.
    let normalized: String
    /// `normalized`'s UTF-16 offset where each chunk starts; one more entry
    /// than there are chunks, the last being the total length.
    let chunkStarts: [Int]

    init(chunks: [String]) {
        var text = ""
        var starts: [Int] = []
        var length = 0
        for chunk in chunks {
            starts.append(length)
            let piece = NarrationTextIndex.normalize(chunk)
            text += piece
            length += piece.utf16.count
        }
        starts.append(length)
        normalized = text
        chunkStarts = starts
    }

    var isEmpty: Bool { normalized.isEmpty }
    var length: Int { chunkStarts.last ?? 0 }

    /// Lowercased letters and digits only, with ligatures and accents folded.
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// The spot a normalized offset falls on.
    func spot(atOffset offset: Int) -> NarrationSpot? {
        let chunkCount = chunkStarts.count - 1
        guard chunkCount > 0, offset >= 0, offset < length else { return nil }
        var low = 0
        var high = chunkCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chunkStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        let start = chunkStarts[low]
        let chunkLength = max(chunkStarts[low + 1] - start, 1)
        return NarrationSpot(chunkIndex: low, fraction: Double(offset - start) / Double(chunkLength))
    }
}

enum NarrationPassageLocator {
    /// Normalized characters a window must hold to count as a match. Long
    /// enough that a sentence fragment is all but unique in a paper.
    static let windowLength = 36
    /// Words of the passage tried as a window's first word before giving up.
    static let startsTried = 30

    /// Where the narration speaks `passage`, as early in the passage as can be
    /// found; nil when no window of its opening words is in the narration.
    static func spot(of passage: String, in chunks: [String]) -> NarrationSpot? {
        let index = NarrationTextIndex(chunks: chunks)
        return offset(of: passage, in: index).flatMap(index.spot(atOffset:))
    }

    /// The normalized offset of `passage` in `index`, at or after `from`.
    static func offset(of passage: String, in index: NarrationTextIndex, from: Int = 0) -> Int? {
        guard !index.isEmpty else { return nil }
        let words = searchWords(in: passage)
        guard !words.isEmpty else { return nil }
        let haystack = index.normalized as NSString
        let searchStart = max(0, min(from, haystack.length))
        for start in 0..<min(words.count, startsTried) {
            guard let window = window(from: start, in: words) else { break }
            let found = haystack.range(
                of: window,
                options: [.literal],
                range: NSRange(location: searchStart, length: haystack.length - searchStart)
            )
            if found.location != NSNotFound {
                return found.location
            }
        }
        return nil
    }

    /// The passage's words, normalized, with citations taken out: the
    /// narration never speaks "[12]" or "(Lane, 2011)".
    static func searchWords(in passage: String) -> [String] {
        let withoutCitations = citationPatterns.reduce(passage) { text, pattern in
            pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        // A line break after a hyphen is a word broken across lines.
        let joined = withoutCitations.replacingOccurrences(
            of: "-\\s*\\n\\s*",
            with: "",
            options: .regularExpression
        )
        return joined
            .split(whereSeparator: { $0.isWhitespace })
            .map { NarrationTextIndex.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func window(from start: Int, in words: [String]) -> String? {
        var window = ""
        var count = 0
        for word in words[start...] {
            window += word
            count += 1
            if window.utf16.count >= windowLength, count >= 3 { return window }
        }
        // The passage ran out: a shorter tail still identifies it if it is
        // not trivially short.
        return window.utf16.count >= windowLength * 2 / 3 && count >= 3 ? window : nil
    }

    private static let citationPatterns: [NSRegularExpression] = [
        // [12], [3,4], [5–9]
        #"\[[0-9,;\s–—-]+\]"#,
        // (Lane, 2011), (Smith et al., 2019a; Jones 2020)
        #"\([^()]{0,120}?(?:19|20)\d{2}[a-z]?\)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

enum NarrationSectionResolver {
    /// Sections closer than this many normalized characters to the one before
    /// are the same place: a heading over two lines, a title and its subtitle.
    static let minimumGap = 200
    static let beginningTitle = "Beginning"

    /// The candidates the narration speaks, in order, each at its place. A
    /// candidate whose opening cannot be found is dropped, and so is one found
    /// out of order (a running header matched somewhere random), by keeping
    /// the longest run of candidates whose places only move forward.
    static func sections(
        from candidates: [NarrationSectionCandidate],
        in chunks: [String]
    ) -> [NarrationSection] {
        let index = NarrationTextIndex(chunks: chunks)
        guard !index.isEmpty else { return [] }
        let found: [(title: String, offset: Int)] = candidates.compactMap { candidate in
            NarrationPassageLocator.offset(of: candidate.opening, in: index).map { (candidate.title, $0) }
        }
        var kept: [(title: String, offset: Int)] = []
        for entry in longestIncreasingRun(found) {
            if let last = kept.last, entry.offset - last.offset < minimumGap { continue }
            kept.append(entry)
        }
        guard !kept.isEmpty else { return [] }
        // What a PDF sets in large type above its first paragraph is a title
        // or a journal's banner more often than a section: call that place
        // the beginning, unless it is a section by name (Abstract, Summary).
        if kept[0].offset < minimumGap, !PaperPDFSections.isStandardSectionName(kept[0].title) {
            kept[0] = (beginningTitle, 0)
        } else if kept[0].offset >= minimumGap {
            kept.insert((beginningTitle, 0), at: 0)
        }
        return kept.enumerated().compactMap { position, entry in
            index.spot(atOffset: entry.offset).map {
                NarrationSection(id: position, title: entry.title, spot: $0)
            }
        }
    }

    private static func longestIncreasingRun(
        _ entries: [(title: String, offset: Int)]
    ) -> [(title: String, offset: Int)] {
        guard !entries.isEmpty else { return [] }
        var length = Array(repeating: 1, count: entries.count)
        var previous = Array(repeating: -1, count: entries.count)
        for i in entries.indices {
            for j in 0..<i where entries[j].offset < entries[i].offset && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var cursor = length.indices.max { length[$0] < length[$1] || (length[$0] == length[$1] && $0 > $1) } ?? 0
        var run: [(title: String, offset: Int)] = []
        while cursor >= 0 {
            run.append(entries[cursor])
            cursor = previous[cursor]
        }
        return run.reversed()
    }
}

// MARK: - A paper's sections, read from its PDF

enum PaperPDFSections {
    /// Characters of text kept after each heading to find it by.
    static let openingLength = 400

    /// The paper's headings with the text after each: its outline when the
    /// PDF has a useful one, otherwise its heading lines.
    static func candidates(in document: PDFDocument) -> [NarrationSectionCandidate] {
        let fromOutline = outlineCandidates(in: document)
        if fromOutline.count >= 2 { return fromOutline }
        return headingLineCandidates(in: document)
    }

    private static func pageText(_ index: Int, in texts: [String]) -> String? {
        texts.indices.contains(index) ? texts[index] : nil
    }

    /// Every page's text, read once.
    private static func pageTexts(in document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    // MARK: Outline

    static func outlineCandidates(in document: PDFDocument) -> [NarrationSectionCandidate] {
        guard var level = document.outlineRoot else { return [] }
        // Publishers often wrap the whole outline in one entry: the title.
        while level.numberOfChildren == 1, let only = level.child(at: 0), only.numberOfChildren > 0 {
            level = only
        }
        var entries: [PDFOutline] = (0..<level.numberOfChildren).compactMap { level.child(at: $0) }
        if entries.count < 3 {
            entries = entries.flatMap { entry in
                [entry] + (0..<entry.numberOfChildren).compactMap { entry.child(at: $0) }
            }
        }
        let texts = pageTexts(in: document)
        return entries.compactMap { entry in
            guard let label = entry.label.map(cleanTitle), !label.isEmpty, !isSkippedHeading(label),
                  let page = entry.destination?.page else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0, pageIndex < texts.count,
                  let opening = opening(after: label, onPage: pageIndex, texts: texts)
                    ?? opening(below: entry.destination, on: page) else { return nil }
            return NarrationSectionCandidate(title: label, opening: opening)
        }
    }

    /// The text after the label on its page, running onto the next page.
    private static func opening(after label: String, onPage pageIndex: Int, texts: [String]) -> String? {
        let text = texts[pageIndex]
        let bareLabel = label.replacingOccurrences(of: #"^[0-9IVX]+(\.[0-9]+)*\.?\s+"#, with: "", options: .regularExpression)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: label, options: options) ?? text.range(of: bareLabel, options: options) else {
            return nil
        }
        return opening(from: range.upperBound, in: text, nextPage: pageText(pageIndex + 1, in: texts))
    }

    private static func opening(below destination: PDFDestination?, on page: PDFPage) -> String? {
        guard let point = destination?.point, point.y.isFinite, point.y > 0 else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let below = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(point.y, bounds.maxY) - bounds.minY)
        let text = page.selection(for: below)?.string ?? ""
        let trimmed = String(text.prefix(openingLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func opening(from start: String.Index, in text: String, nextPage: String?) -> String? {
        var opening = String(text[start...].prefix(openingLength))
        if opening.count < openingLength, let nextPage {
            opening += "\n" + nextPage.prefix(openingLength - opening.count)
        }
        let trimmed = opening.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Heading lines

    /// Above this many styled lines the style rule is reading something other
    /// than headings, and only the standard section names are trusted.
    static let styledHeadingLimit = 30

    static func headingLineCandidates(in document: PDFDocument) -> [NarrationSectionCandidate] {
        // One read of each page's styled text: PDFKit builds it slowly.
        let pages: [NSAttributedString] = (0..<document.pageCount).map {
            document.page(at: $0)?.attributedString ?? NSAttributedString()
        }
        let texts = pages.map(\.string)
        let bodySize = bodyFontSize(in: pages)
        var named: [NarrationSectionCandidate] = []
        var all: [NarrationSectionCandidate] = []
        var styledTitles: [String: Int] = [:]

        for (pageIndex, attributed) in pages.enumerated() {
            let lines = headingLines(in: attributed, bodySize: bodySize)
            let text = texts[pageIndex]
            var lineIndex = 0
            while lineIndex < lines.count {
                let line = lines[lineIndex]
                guard line.startsHeading else {
                    lineIndex += 1
                    continue
                }
                // A heading set over several lines is one heading.
                var runEnd = lineIndex
                // "Introduction: Mitochondria are essential to" carries on
                // onto the next line; a bare "Results" does not.
                let continues = line.isStyled && (!line.isStandardName || line.text.contains(":"))
                if continues {
                    while runEnd + 1 < lines.count, lines[runEnd + 1].isStyled, !lines[runEnd + 1].isStandardName,
                          lines[runEnd + 1].lineNumber == lines[runEnd].lineNumber + 1 {
                        runEnd += 1
                    }
                }
                let run = lines[lineIndex...runEnd]
                lineIndex = runEnd + 1
                let title = cleanTitle(joinedHeading(run.map(\.text)))
                guard !title.isEmpty, !isSkippedHeading(title),
                      let end = run.last?.endOffset,
                      let start = text.utf16.index(text.startIndex, offsetBy: end, limitedBy: text.endIndex),
                      let opening = opening(from: start, in: text, nextPage: pageText(pageIndex + 1, in: texts)) else { continue }
                let candidate = NarrationSectionCandidate(title: title, opening: opening)
                if line.isStandardName {
                    named.append(candidate)
                } else {
                    styledTitles[title.lowercased(), default: 0] += 1
                }
                all.append(candidate)
            }
        }

        // A styled line on three or more pages is a running header.
        let repeated = Set(styledTitles.filter { $0.value >= 3 }.keys)
        let unrepeated = all.filter { !repeated.contains($0.title.lowercased()) }
        let styledCount = unrepeated.count - named.count
        return styledCount > styledHeadingLimit ? named : unrepeated
    }

    struct HeadingLine {
        var text: String
        var lineNumber: Int
        /// UTF-16 offset in the page's string just past the line.
        var endOffset: Int
        /// Set apart from the body: bold, or larger than body text.
        var isStyled: Bool
        /// Starts with a capital or a number, so it can open a heading; a
        /// lowercase styled line can only continue one.
        var startsHeading: Bool
        var isStandardName: Bool
    }

    /// A heading's lines as one title.
    static func joinedHeading(_ lines: [String]) -> String {
        lines.reduce("") { title, line in
            guard !title.isEmpty else { return line }
            // "age-" over "related": the hyphen of a compound, kept unspaced.
            if title.hasSuffix("-") { return title + line }
            return title + " " + line
        }
    }

    /// The font size most of the document's characters are set in.
    static func bodyFontSize(in pages: [NSAttributedString]) -> CGFloat {
        var counts: [Int: Int] = [:]
        for attributed in pages {
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let size = (value as? PlatformFont)?.pointSize, size > 0 else { return }
                counts[Int((size * 10).rounded()), default: 0] += range.length
            }
        }
        guard let mode = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        return CGFloat(mode) / 10
    }

    /// The lines that could be headings: short, starting with a capital or a
    /// section number, and either a standard section name or set apart from
    /// the body text.
    static func headingLines(in attributed: NSAttributedString, bodySize: CGFloat) -> [HeadingLine] {
        let string = attributed.string as NSString
        var result: [HeadingLine] = []
        var lineNumber = 0
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byLines]
        ) { substring, range, enclosing, _ in
            defer { lineNumber += 1 }
            guard let substring else { return }
            let text = substring.trimmingCharacters(in: .whitespaces)
            let words = text.split(whereSeparator: { $0.isWhitespace })
            guard (1...14).contains(words.count), let first = text.first else { return }
            let startsHeading = first.isUppercase || first.isNumber
            let isStandard = startsHeading && isStandardSectionName(text)
            let isStyled = text.count >= 4 && text.filter(\.isLetter).count >= 3
                && !text.hasSuffix(",") && isSetApart(attributed, range: range, bodySize: bodySize)
            guard isStandard || isStyled else { return }
            // Only the start of a heading needs its capital; a styled line
            // that does not open one is kept to continue the line before.
            result.append(HeadingLine(
                text: text,
                lineNumber: lineNumber,
                endOffset: NSMaxRange(enclosing),
                isStyled: isStyled,
                startsHeading: startsHeading,
                isStandardName: isStandard
            ))
        }
        return result
    }

    #if canImport(AppKit)
    private typealias PlatformFont = NSFont
    #else
    private typealias PlatformFont = UIFont
    #endif

    /// Every run with text in the line is bold, or every one is noticeably
    /// larger than body text (but not a page-sized ornament).
    private static func isSetApart(_ attributed: NSAttributedString, range: NSRange, bodySize: CGFloat) -> Bool {
        var sawText = false
        var allBold = true
        var allLarger = bodySize > 0
        attributed.enumerateAttribute(.font, in: range) { value, runRange, stop in
            let run = (attributed.string as NSString).substring(with: runRange)
            guard run.rangeOfCharacter(from: .alphanumerics) != nil else { return }
            sawText = true
            let font = value as? PlatformFont
            let name = font?.fontName.lowercased() ?? ""
            if !boldNameMarkers.contains(where: name.contains) { allBold = false }
            let size = font?.pointSize ?? 0
            if size < bodySize * 1.15 || size > bodySize * 3 { allLarger = false }
            if !allBold && !allLarger { stop.pointee = true }
        }
        return sawText && (allBold || allLarger)
    }

    private static let boldNameMarkers = ["bold", "semibold", "black", "heavy", "demi"]

    /// Introduction, 2. Results, METHODS, "Discussion:" — the names papers
    /// give their main sections, alone on a line or leading a run-in heading.
    static func isStandardSectionName(_ line: String) -> Bool {
        let unnumbered = line.replacingOccurrences(
            of: #"^([0-9]+(\.[0-9]+)*|[IVX]+)\.?\s+"#,
            with: "",
            options: .regularExpression
        )
        let lowered = unnumbered.lowercased().trimmingCharacters(in: .whitespaces)
        let bare = lowered.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        if standardSectionNames.contains(bare) { return true }
        return standardSectionNames.contains { name in
            lowered.hasPrefix(name + ":") || lowered.hasPrefix(name + ".")
        }
    }

    static let standardSectionNames: Set<String> = [
        "abstract", "summary", "introduction", "background", "results",
        "results and discussion", "discussion", "conclusion", "conclusions",
        "concluding remarks", "methods", "materials and methods", "methods and materials",
        "material and methods", "experimental procedures", "star methods", "star★methods",
        "online methods", "experimental section", "outlook", "perspectives",
        "future directions", "significance",
    ]

    /// Headings the narration does not read, or that are not places to go.
    static func isSkippedHeading(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return skippedHeadingPrefixes.contains { lowered.hasPrefix($0) }
    }

    private static let skippedHeadingPrefixes = [
        "references", "bibliography", "acknowledg", "figure", "fig.", "fig ", "table",
        "supplementa", "author contribution", "competing", "declaration", "conflict",
        "funding", "data availability", "code availability", "etoc", "graphical abstract",
        "highlights", "keywords", "key words", "abbreviations", "lead contact",
        "resource availability", "key resources", "correspondence", "article info",
        "open access", "copyright", "box ", "peer review", "additional information",
        "reporting summary", "extended data", "online content",
    ]

    /// Trimmed, entities decoded, numbering kept, a trailing colon dropped,
    /// and SHOUTED headings put in title case.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "&#x02019;", with: "\u{2019}")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix(":") || title.hasSuffix(".") { title.removeLast() }
        let letters = title.filter(\.isLetter)
        if letters.count >= 3, letters == letters.uppercased() {
            title = title.capitalized
        }
        if title.count > 80 {
            title = String(title.prefix(79)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return title
    }
}

// MARK: - The passage under the pointer

enum PDFListenPassage {
    /// The text from the start of the line at `point` on `page`, or from the
    /// start of `selection` when there is one, onward: what "Listen from Here"
    /// looks for in the narration.
    static func passage(at point: CGPoint?, on page: PDFPage?, selection: PDFSelection?) -> String? {
        if let selection, let first = selection.pages.first, let text = first.string {
            let range = selection.range(at: 0, on: first)
            if range.location != NSNotFound, range.length > 0 {
                return passage(from: range.location, in: text, page: first)
            }
        }
        guard let page, let point, let text = page.string else { return nil }
        let index = page.characterIndex(at: point)
        guard index >= 0, index < (text as NSString).length else { return nil }
        // Back to the start of the clicked line.
        let nsText = text as NSString
        let lineStart = nsText.lineRange(for: NSRange(location: index, length: 0)).location
        return passage(from: lineStart, in: text, page: page)
    }

    private static func passage(from location: Int, in text: String, page: PDFPage) -> String? {
        let nsText = text as NSString
        guard location < nsText.length else { return nil }
        var passage = nsText.substring(from: location)
        if passage.count < PaperPDFSections.openingLength,
           let document = page.document {
            let next = document.index(for: page) + 1
            if next < document.pageCount, let nextText = document.page(at: next)?.string {
                passage += "\n" + nextText
            }
        }
        let trimmed = String(passage.prefix(PaperPDFSections.openingLength * 2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
