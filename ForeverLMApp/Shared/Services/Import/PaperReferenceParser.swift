import Foundation

/// Reads a paper's reference list out of the text of its PDF, with no model.
///
/// The list is a structural thing: numbered entries run 1, 2, 3 in order, and the entry a
/// citation names is the one with its number. So the read is a chain: from the line that opens
/// entry 1, each line that opens the next number starts the next entry and every other line
/// continues the one before. A paper whose list is not numbered (Cell, APA) is split where a
/// line opens with a surname and initials after an entry that looks finished.
///
/// What is not read here is what an entry is *about*: the DOI, the address and the matching
/// catalog record come from `PaperReferenceIdentity` and `PaperReferenceCatalogMatch`, which
/// work from what the entry prints. A model never decides what an entry is.
///
/// Checked against the journals in a real library (NEJM, Nature, Science, Cell Press, PNAS,
/// Elsevier, Springer, Frontiers, BMC): a list set in a column of its own numbers, which PDFKit
/// reads apart from their text, yields no entries rather than wrong ones; the reader's
/// annotation route (`PDFReferenceEntries`) covers those where the PDF links them.
enum PaperReferenceParser {

    /// Bumped when a better read should be taken again: a paper whose list was read under an
    /// older version is queued once more (`paper_reference_reads.parser_version`).
    /// 2 (2026-11-08): initials-first authors, a year set against a journal's full stop, an
    /// author list broken after initials, notes under a numbered entry, a list resumed past
    /// another column's headings. A paper version 1 found no list in is read again.
    /// 3 (2026-11-08): a lone author printed with no comma is labelled by that author, not by a
    /// word before the first comma of the title ("Schmidt-Nielsen K. 1970. Energy metabolism,
    /// …" was "metabolism 1970"); OpenAlex is searched by the printed title and a record PubMed
    /// alone indexes links to PubMed. Every list the app read under an older version is read
    /// again, and its entries left without a link are asked of the catalogs again.
    /// 4 (2026-11-11): an author-year list set as "Authors (year) Title" (EMBO, Springer) is
    /// split at every entry: a lone author's entry ("Gould SJ (1981)"), the entry after a book's
    /// (which ends on its publisher, not a page), a line of authors the PDF reads with no
    /// spaces, and a title no longer cut from its authors where the line ends on the year.
    static let version = 4

    struct Entry: Equatable, Sendable {
        /// The citation number of a numbered list; the position of an author-year one.
        let ordinal: Int
        /// What a citation calls it: "12", or "Smith 2019".
        let label: String
        let text: String
    }

    /// The most an entry may run to. A reference is a few lines; more ran on into something
    /// that is not the list (the acknowledgements under the last entry).
    static let maximumEntryLength = 1_200
    /// A list shorter than this is not read as one: three lines that happen to start 1, 2, 3.
    static let minimumEntries = 3

    /// The entries of the reference list in `text`, which is the PDF's text with a form feed
    /// between its pages (`PDFTextExtractor.embeddedText`). Empty when no list can be read.
    static func entries(inPaperText text: String) -> [Entry] {
        let lines = bodyLines(of: text)
        guard !lines.isEmpty else { return [] }
        let sections = referenceSections(in: lines)
        // A paper may print its list in two parts, the second under the Methods (Nature):
        // each part is read for its own numbers and the entries joined by number.
        var byNumber: [Int: Entry] = [:]
        for section in sections {
            for entry in numberedEntries(in: section) ?? [] { byNumber[entry.ordinal] = entry }
        }
        var numbered = byNumber.values.sorted { $0.ordinal < $1.ordinal }
        // A heading that is not the list's (the "References" of a reporting summary stapled
        // to the end) hides a list that has none: the longest numbered run anywhere wins.
        if sections.count != 1 || sections[0].count != lines.count,
           let wholeText = numberedEntries(in: lines), wholeText.count > numbered.count {
            numbered = wholeText
        }
        if numbered.count >= minimumEntries { return numbered }
        return authorYearEntries(in: sections.last ?? lines)
    }

    // MARK: Lines

    /// Every line of the paper in order, less what the journal prints on every page: the
    /// running heads and feet that would otherwise land in the middle of an entry that runs
    /// over a page, and the page numbers.
    ///
    /// A running line is one whose letters recur among the first or last few lines of at least
    /// three pages. Only page edges are looked at, and only lines with ten letters or more: a
    /// "Nature 2019; 576:" that ends an entry on several pages is not a running foot.
    static func bodyLines(of text: String) -> [String] {
        let pages: [[String]] = text.components(separatedBy: "\u{000C}").map { page in
            page.components(separatedBy: .newlines)
                .map { ReferenceEntryShape.unglued($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        let headDepth = 3
        let footDepth = 4
        var pagesHolding: [String: Int] = [:]
        for page in pages {
            var keys = Set<String>()
            for (index, line) in page.enumerated() where index < headDepth || index >= page.count - footDepth {
                if let key = runningKey(of: line) { keys.insert(key) }
            }
            for key in keys { pagesHolding[key, default: 0] += 1 }
        }
        let minimumPages = 3
        let running = Set(pagesHolding.filter { $0.value >= minimumPages }.keys)

        var kept: [String] = []
        for page in pages {
            for (index, line) in page.enumerated() {
                let atEdge = index < headDepth || index >= page.count - footDepth
                // A page number: digits and nothing else, where the journal prints it. An
                // entry's own number is never bare, it carries its full stop or brackets.
                if atEdge, line.allSatisfy(\.isNumber) { continue }
                // A running head set as "524 | Nature | Vol 604 | 21 April 2022".
                if atEdge, line.count <= 90, line.filter({ $0 == "|" }).count >= 2 { continue }
                if atEdge, let key = runningKey(of: line), running.contains(key) { continue }
                kept.append(line)
            }
        }
        return kept
    }

    /// A line's letters, lower-cased with its digits and punctuation gone, so "1562 n engl j
    /// med 383;16" and "1563 n engl j med 383;16" are one line. Nil for a line too short to
    /// be a running head.
    private static func runningKey(of line: String) -> String? {
        let letters = line.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
        let key = String(String.UnicodeScalarView(letters))
        let count = key.filter(\.isLetter).count
        return count >= 10 ? key : nil
    }

    /// The runs of lines from each bibliography heading to the next, or all the lines when
    /// there is no heading to be found (the chain read then picks the longest numbered run
    /// itself). A heading with next to nothing under it is a running head, not a list.
    private static func referenceSections(in lines: [String]) -> [[String]] {
        let headings = lines.indices.filter { SlideCitationService.isReferenceHeadingLine(lines[$0]) }
        var sections: [[String]] = []
        for (position, heading) in headings.enumerated() {
            let end = position + 1 < headings.count ? headings[position + 1] : lines.count
            let section = Array(lines[heading..<end])
            if section.joined(separator: "\n").count > 200 { sections.append(section) }
        }
        return sections.isEmpty ? [lines] : sections
    }

    // MARK: Numbered lists

    private enum NumberStyle: CaseIterable {
        case dot       // "12. Smith J, ..."
        case bracket   // "[12] Smith J, ..."
        case paren     // "(12) Smith J, ..."
        case bare      // "12 Smith J, ..."
    }

    private static let startExpressions: [NumberStyle: NSRegularExpression] = {
        let patterns: [NumberStyle: String] = [
            .dot: #"^(\d{1,3})\.(?:\s+|(?=\p{Lu})|$)(.*)$"#,
            .bracket: #"^\[(\d{1,3})\]\s*(.*)$"#,
            .paren: #"^\((\d{1,3})\)\s*(.*)$"#,
            .bare: #"^(\d{1,3})\s+(?=\p{Lu})(.*)$"#,
        ]
        return patterns.compactMapValues { try? NSRegularExpression(pattern: $0) }
    }()

    /// The number a line opens an entry with, and what follows it on the line.
    private static func start(of line: String, style: NumberStyle) -> NumberedStart? {
        guard let expression = startExpressions[style] else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges == 3,
              let numberRange = Range(match.range(at: 1), in: line),
              let restRange = Range(match.range(at: 2), in: line),
              let number = Int(line[numberRange]) else { return nil }
        return (number, String(line[restRange]).trimmingCharacters(in: .whitespaces))
    }

    private struct RawEntry {
        let number: Int
        var lines: [String]
    }

    typealias NumberedStart = (number: Int, rest: String)
    typealias NumberRun = (numbers: [Int], rest: String)

    /// Every line read once for what it opens, so the many chains one text is tried with do
    /// not each read it again.
    private struct LineTable {
        let lines: [String]
        let starts: [NumberStyle: [NumberedStart?]]
        let runs: [NumberRun?]
        /// Whether each line is a heading that ends the list.
        let endsList: [Bool]

        init(_ lines: [String]) {
            self.lines = lines
            self.endsList = lines.map { PaperReferenceParser.isAfterListHeading($0) }
            var starts: [NumberStyle: [NumberedStart?]] = [:]
            for style in NumberStyle.allCases {
                starts[style] = lines.map { PaperReferenceParser.start(of: $0, style: style) }
            }
            self.starts = starts
            self.runs = lines.map { PaperReferenceParser.numberRun(in: $0) }
        }

        func start(_ index: Int, _ style: NumberStyle) -> NumberedStart? { starts[style]?[index] ?? nil }
    }

    /// The longest numbered chain in `lines`, read in the style that gives the most entries.
    /// A chain opens at entry 1, or at the first numbered line of the part when the part is the
    /// second half of a list.
    private static func numberedEntries(in lines: [String]) -> [Entry]? {
        let table = LineTable(lines)
        var best: [RawEntry] = []
        for style in NumberStyle.allCases {
            var openers: [(index: Int, number: Int)] = []
            for index in lines.indices {
                guard let opened = table.start(index, style) else { continue }
                if opened.number == 1 || openers.isEmpty { openers.append((index, opened.number)) }
            }
            for opener in openers {
                let chained = chain(table, from: opener.index, startingAt: opener.number, style: style)
                if chained.count > best.count { best = chained }
            }
        }
        guard best.count >= minimumEntries else { return nil }
        let entries: [Entry] = best.compactMap { raw in
            let text = entryText(raw.lines)
            return text.isEmpty ? nil : Entry(ordinal: raw.number, label: String(raw.number), text: text)
        }
        // A chain of one-word lines is a column of numbers read apart from its text, or the
        // sections of the paper itself ("1. Introduction"), not a reference list.
        guard entries.count >= minimumEntries else { return nil }
        let averageLength = entries.reduce(0) { $0 + $1.text.count } / entries.count
        // More than a few lines on average is the paper's own sections, not entries.
        guard averageLength >= 30, averageLength <= 700 else { return nil }
        // A reference prints the year it appeared in; the numbered affiliations under the
        // authors' names, or a numbered list of methods, do not.
        let dated = entries.filter { !PaperReferenceIdentity.years(in: $0.text).isEmpty }.count
        guard dated * 10 >= entries.count * 6 else { return nil }
        return entries
    }

    /// Entry 1 opens at `first`; each following line that opens the next number starts that
    /// entry, and every other line continues the entry open. A number that jumps one or two
    /// ahead starts an entry too when the one before looks finished (a misread number must not
    /// merge the rest of the list into one entry). A run of numbers on one line ("22. 23. 24.")
    /// is a column of numbers set apart from its entries (Nature, BMC, Science Advances): the
    /// entries that follow are taken in order, and only when there are as many as numbers.
    private static func chain(_ table: LineTable, from first: Int, startingAt firstNumber: Int, style: NumberStyle) -> [RawEntry] {
        var entries: [RawEntry] = []
        var current: RawEntry?
        var expected = firstNumber
        var index = first
        while index < table.lines.count {
            let line = table.lines[index]
            if table.endsList[index] {
                // Nature prints the Methods' references after the Methods: the list goes on at
                // the next run of numbers that continues it.
                if style == .dot, let resume = nextRun(in: table, after: index, numbered: expected) {
                    if let finished = current { entries.append(finished) }
                    current = nil
                    index = resume
                    continue
                }
                // A two-column page read across its columns (Frontiers) puts the other
                // column's closing sections ("Author contributions") inside the list, and the
                // list goes on after them with the next number. The entry left open took the
                // other column's text up to the heading: only its own lines are kept.
                if let resume = nextOpener(in: table, after: index, numbered: expected, style: style) {
                    if var finished = current {
                        finished.lines = linesBeforeRunOn(finished.lines)
                        entries.append(finished)
                    }
                    current = nil
                    index = resume
                    continue
                }
                break
            }
            if style == .dot, let run = table.runs[index], run.numbers.first == expected {
                if let finished = current { entries.append(finished) }
                current = nil
                var block = entriesBesideNumberRun(table, runIndex: index, run: run)
                // The run set beside the last entry's run-on from the page before ("14. 15. …
                // G., Carey, D., …"): when the entries do not count out with those words as
                // the first, and the entry before is unfinished ("… Guo, S.,"), they finish it.
                // Tried second, since an entry with no authors ("Recognizing the importance of
                // …") opens with words too.
                if block == nil, !run.rest.isEmpty, let previous = entries.last, !looksFinished(previous.lines),
                   let continued = entriesBesideNumberRun(table, runIndex: index, run: run, carriesOver: true) {
                    entries[entries.count - 1].lines += continued.carried
                    block = continued
                }
                guard let block else { break }
                entries += block.entries
                expected = (run.numbers.last ?? expected) + 1
                index = block.nextIndex
                continue
            }
            if let opened = table.start(index, style) {
                let isNext = opened.number == expected
                let jumpsAhead = opened.number > expected && opened.number <= expected + 2
                    && style != .bare && !opened.rest.isEmpty
                    && (current.map { looksFinished($0.lines) } ?? false)
                if isNext || jumpsAhead {
                    if let finished = current { entries.append(finished) }
                    current = RawEntry(number: opened.number, lines: opened.rest.isEmpty ? [] : [opened.rest])
                    expected = opened.number + 1
                    index += 1
                    continue
                }
            }
            current?.lines.append(line)
            index += 1
        }
        if let current { entries.append(current) }
        return entries
    }

    /// The next line, within the next 3,000, that is a run of numbers starting at `number`.
    private static func nextRun(in table: LineTable, after index: Int, numbered number: Int) -> Int? {
        let end = min(table.lines.count, index + 3_000)
        guard index + 1 < end else { return nil }
        return (index + 1..<end).first { table.runs[$0]?.numbers.first == number }
    }

    /// The next line, within the next 400, that opens entry `number` in `style` with a few words
    /// of an entry after it (not "3. Results", a section of the paper).
    private static func nextOpener(in table: LineTable, after index: Int, numbered number: Int, style: NumberStyle) -> Int? {
        let end = min(table.lines.count, index + 400)
        guard index + 1 < end else { return nil }
        return (index + 1..<end).first { candidate in
            guard let opened = table.start(candidate, style), opened.number == number else { return false }
            return opened.rest.split(whereSeparator: \.isWhitespace).count >= 3
        }
    }

    /// An entry's lines up to where it looks finished, when they run on past what any reference
    /// holds (another column's prose read into it). An entry of a reference's length is kept
    /// whole.
    static func linesBeforeRunOn(_ lines: [String]) -> [String] {
        guard lines.reduce(0, { $0 + $1.count + 1 }) > 400 else { return lines }
        for end in lines.indices where looksFinished(Array(lines[...end])) {
            return Array(lines[...end])
        }
        return lines
    }

    private static let numberRunExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^((?:\d{1,3}\.\s*){2,})(.*)$"#
    )

    /// A line that is a run of consecutive numbers with a full stop each, and what follows the
    /// run on the line.
    static func numberRun(in line: String) -> NumberRun? {
        guard let expression = numberRunExpression,
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let runRange = Range(match.range(at: 1), in: line),
              let restRange = Range(match.range(at: 2), in: line) else { return nil }
        let numbers = line[runRange].split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 2, zip(numbers, numbers.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return nil }
        return (numbers, String(line[restRange]).trimmingCharacters(in: .whitespaces))
    }

    /// The entries that follow a run of numbers, one for each, in order: the lines up to the
    /// next run, the next inline-numbered entry or a heading after the list, split where an
    /// entry looks finished and another opens. Nil unless that gives exactly as many entries as
    /// numbers: guessing which number an entry has is worse than not reading it. With
    /// `carriesOver`, the first lines up to the first entry finish the entry before the run
    /// (`carried`), and the rest must count out.
    private static func entriesBesideNumberRun(
        _ table: LineTable,
        runIndex: Int,
        run: NumberRun,
        carriesOver: Bool = false
    ) -> (entries: [RawEntry], nextIndex: Int, carried: [String])? {
        var body: [String] = run.rest.isEmpty ? [] : [run.rest]
        var index = runIndex + 1
        let resumes = (run.numbers.last ?? 0) + 1
        while index < table.lines.count {
            let line = table.lines[index]
            if table.endsList[index] || table.runs[index] != nil { break }
            if let opened = table.start(index, .dot), opened.number == resumes { break }
            body.append(line)
            index += 1
        }
        var groups = splitIntoEntries(body)
        var carried: [String] = []
        if carriesOver {
            guard groups.count > 1 else { return nil }
            carried = groups.removeFirst()
        }
        // A list that says what each paper showed (Nature's News & Views, Nature Reviews) sets a
        // note under an entry ("The papers in references 1, 2 and 3 report …"). A note prints no
        // year and opens with no author; an entry does one or the other.
        if groups.count > run.numbers.count {
            groups = groups.filter { group in
                guard let first = group.first else { return false }
                return opensWithAuthor(first) || !PaperReferenceIdentity.years(in: entryText(group)).isEmpty
            }
        }
        guard groups.count == run.numbers.count else { return nil }
        let entries = zip(run.numbers, groups).map { RawEntry(number: $0, lines: $1) }
        return (entries, index, carried)
    }

    private static let pageTags: Set<String> = [
        "Article", "Review", "Letter", "Resource", "Research", "Report", "Analysis", "Perspective",
        "Comment", "News", "Brief Report", "Short Report", "Original Article",
    ]

    /// Lines split into entries where one looks finished and the next opens with an author, or
    /// where one ends in its parenthesised year (Nature's style) whoever the next begins with.
    static func splitIntoEntries(_ lines: [String]) -> [[String]] {
        var groups: [[String]] = []
        // The last lines of the entry being read are all the checks below look at. They are kept
        // apart: holding the whole entry while appending to it would copy it every line.
        var tail: [String] = []
        // Whether the entry being read has printed its year after its authors ("Authors (year)
        // Title", the author-year style of EMBO and Springer). Its authors are then behind it,
        // so a line that opens with an author opens the next entry, whether or not the entry
        // looks finished: a book's ends on its publisher ("W. W. Norton"), not on a page.
        var pastYear = false
        for (index, line) in lines.enumerated() {
            // The article-type tag a journal prints at the top of each page ("Article") is
            // no part of the entry it falls inside.
            if pageTags.contains(line) { continue }
            if groups.isEmpty {
                groups.append([line])
                tail = [line]
                pastYear = ReferenceEntryShape.printsYearAfterAuthors(line)
                continue
            }
            // A line of fewer than three words ("Article", a section tag a journal prints on
            // every page) does not open an entry on the strength of the one before it ending.
            let opensByEnding = endsWithParenthesisedYear(tail)
                && !(tail.last.map(ReferenceEntryShape.endsWithYearAfterAuthors) ?? false)
                && line.first?.isLetter == true
                && line.split(whereSeparator: \.isWhitespace).count >= 3
            // Authors printed with their first names (natbib's plain style: "Karel HM van Wely,
            // Jelto Swaving, …") open an entry only after one that closed on its year or its
            // address, since a line inside an author list opens the same way.
            let opensByFullName = endsWithYearOrAddress(tail) && opensWithFullName(line)
            let opensAfterYear = pastYear && opensWithAuthor(line)
                && !(tail.last.map(ReferenceEntryShape.leavesEntryOpen) ?? false)
                && reachesYearAsAuthors(lines, from: index)
            if opensAfterYear || (looksFinished(tail) && (opensWithAuthor(line) || opensByEnding || opensByFullName)) {
                groups.append([line])
                tail = [line]
                pastYear = ReferenceEntryShape.printsYearAfterAuthors(line)
            } else {
                groups[groups.count - 1].append(line)
                tail.append(line)
                if tail.count > 3 { tail.removeFirst() }
                // The year may sit on a line of its own start ("(2000a) Gender, age …"), its
                // author's initials on the line before.
                if !pastYear {
                    pastYear = ReferenceEntryShape.printsYearAfterAuthors(tail.suffix(2).joined(separator: " "))
                }
            }
        }
        return groups
    }

    /// Whether the lines from `start` run as a list of names up to a year in brackets, as an
    /// entry of the "Authors (year) Title" style opens. The editors of a chapter's book open
    /// like authors too ("Herder, K. Dhatariya, … et al., eds.") and reach no year of their own.
    private static func reachesYearAsAuthors(_ lines: [String], from start: Int) -> Bool {
        var joined = ""
        for line in lines[start..<min(start + 7, lines.count)] {
            joined += joined.isEmpty ? line : " " + line
            if ReferenceEntryShape.printsYearAfterAuthors(joined) { return true }
            guard line.contains(","),
                  line.range(of: #"\b(?:[Ee]ds?|In)\b"#, options: .regularExpression) == nil else { return false }
        }
        return false
    }

    static func opensWithAuthor(_ line: String) -> Bool { ReferenceEntryShape.opensWithAuthor(line) }
    static func opensWithFullName(_ line: String) -> Bool { ReferenceEntryShape.opensWithFullName(line) }
    static func endsWithYearOrAddress(_ lines: [String]) -> Bool { ReferenceEntryShape.endsWithYearOrAddress(lines) }
    static func looksFinished(_ lines: [String]) -> Bool { ReferenceEntryShape.looksFinished(lines) }

    private static func endsWithParenthesisedYear(_ lines: [String]) -> Bool {
        let text = lines.suffix(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.range(of: #"\((?:19|20)\d{2}[a-z]?\)\.?$"#, options: .regularExpression) != nil
    }

    /// The headings a paper prints after its list, which end the last entry.
    private static let headingsAfterList: Set<String> = [
        "acknowledgements", "acknowledgments", "acknowledgement", "acknowledgment",
        "author contributions", "authors' contributions", "competing interests",
        "additional information", "supplementary information", "supplementary material",
        "extended data", "funding", "data availability", "code availability",
        "conflict of interest", "conflicts of interest", "declaration of interests",
        "disclosure", "supporting information", "appendix", "figure legends",
        "author information", "reporting summary", "peer review information",
        "ethics declarations", "correspondence", "online content", "methods",
    ]

    /// Headings a journal runs straight into their text ("Acknowledgements We thank …",
    /// "Publisher’s note Springer Nature …"), so the line starts with them.
    private static let runInHeadingsAfterList: [String] = [
        "acknowledgements", "acknowledgments", "acknowledgement", "acknowledgment",
        "publisher\u{2019}s note", "publisher's note", "author contributions",
        "competing interests", "additional information", "reporting summary",
        "online content", "data availability", "code availability", "extended data",
        "supplementary information", "peer review information", "reprints and permissions",
    ]

    static func isAfterListHeading(_ line: String) -> Bool {
        if line.count <= 40 {
            let key = line.trimmingCharacters(in: CharacterSet(charactersIn: " .:")).lowercased()
            if headingsAfterList.contains(key) { return true }
        }
        let lowered = line.lowercased()
        return runInHeadingsAfterList.contains { heading in
            guard lowered.hasPrefix(heading) else { return false }
            guard let next = lowered.dropFirst(heading.count).first else { return true }
            return next == " " || next == ":" || next == "."
        }
    }

    /// The text of an entry's lines. Only as many lines as the length limit can hold are joined
    /// (joining closes up hyphenated words and is quadratic in the lines it is given), so a run
    /// of lines that is not an entry at all costs no more than one that is.
    static func entryText(_ lines: [String]) -> String {
        var kept: [String] = []
        var length = 0
        for line in lines {
            kept.append(line)
            length += line.count + 1
            if length > maximumEntryLength * 2 { break }
        }
        return cleaned(PDFReferenceEntries.joined(kept))
    }

    /// An entry's text: whitespace folded, the notice a journal prints under the last entry
    /// cut, and the length held.
    static func cleaned(_ text: String) -> String {
        var cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A page range the line broke after its dash ("189- 201").
        cleaned = cleaned.replacingOccurrences(of: #"(?<=\d)-\s+(?=\d)"#, with: "-", options: .regularExpression)
        if let notice = cleaned.range(
            of: #"(?:\s*(?:Copyright\s*©|©\s*\d{4}|Downloaded from)|\s+(?:All rights reserved|(?:Acknowledg(?:e)?ments?|Funding|Author contributions|Competing interests|Data and materials availability|Supplementary Materials)\s*[:.]))"#,
            options: [.regularExpression, .caseInsensitive]
        ), cleaned.distance(from: cleaned.startIndex, to: notice.lowerBound) >= 20 {
            cleaned = String(cleaned[..<notice.lowerBound])
        }
        // A PubMed Central entry ends in its catalog tags ("[PubMed: 25418158]"); whatever a
        // manuscript sets after the last one (a box, a table) is not the entry.
        if let tags = cleaned.range(
            of: #"\[PubMed(?::\s*\d+)?\](?:\s*\[(?:PMC free article|Google Scholar|CrossRef|Ref list)\])*"#,
            options: .regularExpression
        ) {
            cleaned = String(cleaned[..<tags.upperBound])
        }
        return cleaned.count > maximumEntryLength ? String(cleaned.prefix(maximumEntryLength)) : cleaned
    }

    // MARK: Author-year lists

    private static let yearExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b((?:1[89]|20)\d{2})([a-z]?)\b"#
    )

    /// An unnumbered list split where a line opens with an author after an entry that looks
    /// finished. Read only when at least five entries come out and most print a year, so a
    /// paper that merely has some surnames in its tail is not mistaken for a list.
    private static func authorYearEntries(in lines: [String]) -> [Entry] {
        var kept: [String] = []
        for line in lines.drop(while: { SlideCitationService.isReferenceHeadingLine($0) }) {
            if isAfterListHeading(line) { break }
            kept.append(line)
        }
        // Lines before the first author belong to no entry.
        let firstAuthor = kept.firstIndex(where: { opensWithAuthor($0) || opensWithFullName($0) }) ?? kept.count
        let groups = splitIntoEntries(Array(kept[firstAuthor...]))
        var entries: [Entry] = []
        for group in groups {
            let text = entryText(group)
            guard text.count >= 30, let label = authorYearLabel(of: text) else { continue }
            entries.append(Entry(ordinal: entries.count + 1, label: label, text: text))
        }
        guard entries.count >= 5, entries.count * 10 >= groups.count * 8 else { return [] }
        return entries
    }

    /// "Smith 2019" (or "Smith 2019a") for an author-year entry: its first author's surname and
    /// the first year it prints. Nil for an entry that prints no year.
    static func authorYearLabel(of text: String) -> String? {
        guard let head = PaperReferenceSummary.firstAuthorHead(in: text), let year = yearExpression,
              let surname = SlideCitationService.surname(inAuthorEntry: PaperReferenceSummary.firstName(in: head)),
              surname.count <= 40 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = year.firstMatch(in: text, range: range),
              let yearRange = Range(match.range(at: 1), in: text),
              let suffixRange = Range(match.range(at: 2), in: text) else { return nil }
        return "\(surname) \(text[yearRange])\(text[suffixRange])"
    }
}
