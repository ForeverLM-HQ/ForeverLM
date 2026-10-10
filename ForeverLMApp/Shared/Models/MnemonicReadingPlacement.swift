import Foundation

// MARK: - Where a mnemonic reading's questions stand in the text
//
// docs/memory-design.md, "Mnemonic reading". A reading's body holds its
// questions; each client reads the sources' own stored text and sets it as
// the Reader's prose form sets it — a line a paragraph, a heading, a list item
// — with each question after the paragraph that holds its quote, found by the
// matcher a Memory anchor is grounded with (`MemoryGroundingText`). A question
// whose quote the text no longer prints (the source was fetched again) goes
// to the end of its source's text rather than vanishing. And what the reading
// shows of the learner's answers is read from Memory, per learner.
//
// Pure and Foundation only, so the Mac and the iPhone place and count alike
// (project.yml), and the tests pin it without a window.

/// One block of a source's text as the reading sets it.
struct MnemonicReadingBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph
        /// A Markdown heading, `#` to `######`.
        case heading(level: Int)
        /// A list item, with its bullet or number as the text wrote it.
        case listItem(marker: String)
        /// A picture's line (`![caption](…)`), shown as its caption.
        case figure
        /// A thematic break (`* * *`, `---`).
        case rule
    }

    /// The block's place in its source, from zero.
    let index: Int
    let kind: Kind
    /// What the block shows: a paragraph's lines run together, a heading or
    /// list item without its marker, a figure's caption.
    let text: String
    /// The block's lines as stored, which the questions' quotes are found in.
    let stored: String

    var id: Int { index }
}

/// A source's text with its questions in it.
struct MnemonicReadingLayout: Equatable, Sendable {
    let blocks: [MnemonicReadingBlock]
    /// The questions after each block, by block index, in reading order.
    let questionsAfter: [Int: [MnemonicQuestion]]
    /// Questions whose quote the text does not print, shown at its end.
    let unplaced: [MnemonicQuestion]

    /// The questions as they stand on screen: block by block, then the
    /// unplaced at the end.
    var orderedQuestions: [MnemonicQuestion] {
        questionsAfter.keys.sorted().flatMap { questionsAfter[$0] ?? [] } + unplaced
    }
}

enum MnemonicReadingPlacement {

    // MARK: Setting the text

    /// The text's lines: a CRLF, a CR and a form feed (a PDF's page break)
    /// each end a line.
    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0C}", with: "\n")
            .components(separatedBy: "\n")
    }

    /// The text as the reading sets it. Every line is a block of its own, as
    /// the Reader's prose form reads stored text, with one exception: a line
    /// a PDF's typesetting broke — one that ends mid-sentence, or in a word's
    /// hyphen, before a line that starts in lower case — runs on into the
    /// next, so a hard-wrapped page reads as its paragraphs. Blank lines set
    /// nothing.
    static func blocks(of text: String) -> [MnemonicReadingBlock] {
        var blocks: [MnemonicReadingBlock] = []
        var paragraph: [String] = []

        func append(_ kind: MnemonicReadingBlock.Kind, text: String, stored: String) {
            blocks.append(MnemonicReadingBlock(index: blocks.count, kind: kind, text: text, stored: stored))
        }
        func flush() {
            guard !paragraph.isEmpty else { return }
            var shown = ""
            for line in paragraph {
                if shown.isEmpty {
                    shown = line
                } else if shown.hasSuffix("-") {
                    shown += line
                } else {
                    shown += " " + line
                }
            }
            append(.paragraph, text: shown, stored: paragraph.joined(separator: "\n"))
            paragraph = []
        }

        for raw in lines(of: text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flush()
                continue
            }
            if let heading = heading(line) {
                flush()
                append(.heading(level: heading.level), text: heading.text, stored: line)
            } else if isRule(line) {
                flush()
                append(.rule, text: "", stored: line)
            } else if let caption = figureCaption(line) {
                flush()
                append(.figure, text: caption, stored: line)
            } else if let item = listItem(line) {
                flush()
                append(.listItem(marker: item.marker), text: item.text, stored: line)
            } else if let last = paragraph.last, runsOn(last, into: line) {
                paragraph.append(line)
            } else {
                flush()
                paragraph = [line]
            }
        }
        flush()
        return blocks
    }

    /// Whether a line a PDF broke runs on into the next: it ends in a word's
    /// hyphen, or mid-sentence, and the next starts in lower case.
    static func runsOn(_ line: String, into next: String) -> Bool {
        guard let last = line.last, let first = next.first, first.isLowercase else { return false }
        if last == "-" { return true }
        return !".!?:;\u{2026}\"\u{201D}\u{2019})]".contains(last)
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func figureCaption(_ line: String) -> String? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let close = line.range(of: "](") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let marker = String(line[..<space])
        let text = line[space...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if ["-", "*", "+", "\u{2022}"].contains(marker) { return (marker, text) }
        if let terminator = marker.last, ".)".contains(terminator) {
            let number = marker.dropLast()
            if (1...3).contains(number.count), number.allSatisfy({ $0.isASCII && $0.isNumber }) { return (marker, text) }
        }
        return nil
    }

    // MARK: Placing the questions

    /// The source's text with its questions in it: each after the block
    /// holding its quote's last word, found from where the question before
    /// it stands (so a phrase the text repeats lands at the right place) or,
    /// failing that, from the start; questions whose quote the text does not
    /// print go to the end, in their order.
    static func layout(text: String, questions: [MnemonicQuestion]) -> MnemonicReadingLayout {
        let blocks = blocks(of: text)
        var ends: [Int] = []
        var total = 0
        for block in blocks {
            total += MemoryGroundingText(block.stored).letterCount
            ends.append(total)
        }
        let grounding = MemoryGroundingText(text)
        var after: [Int: [MnemonicQuestion]] = [:]
        var unplaced: [MnemonicQuestion] = []
        var cursor = 0
        // A text's letters are its blocks' letters, so an offset in the one
        // is an offset in the other; were they ever to differ, each block is
        // searched on its own instead.
        let offsetsAgree = grounding.letterCount == total
        var blockCursor = 0
        for question in questions {
            let length = MemoryGroundingText(question.quote).letterCount
            guard length > 0 else {
                unplaced.append(question)
                continue
            }
            if offsetsAgree {
                guard let start = grounding.offset(of: question.quote, from: cursor)
                    ?? grounding.offset(of: question.quote) else {
                    unplaced.append(question)
                    continue
                }
                cursor = start
                let lastLetter = start + length - 1
                let index = ends.firstIndex { $0 > lastLetter } ?? max(0, blocks.count - 1)
                after[index, default: []].append(question)
            } else {
                let found = (blockCursor..<blocks.count).first { MemoryGroundingText(blocks[$0].stored).contains(question.quote) }
                    ?? blocks.indices.first { MemoryGroundingText(blocks[$0].stored).contains(question.quote) }
                guard let index = found else {
                    unplaced.append(question)
                    continue
                }
                blockCursor = index
                after[index, default: []].append(question)
            }
        }
        return MnemonicReadingLayout(blocks: blocks, questionsAfter: after, unplaced: unplaced)
    }
}

// MARK: - The learner's answers, read from Memory

/// Where a reading's question stands in the learner's Memory: read from the
/// item its first answer kept (`MnemonicQuestion.memoryItemID`) and that
/// item's attempts, never written into the reading. Absent while the
/// question is unanswered.
struct MnemonicQuestionMemory: Equatable, Sendable {
    let itemID: String
    /// The latest grade the learner gave it, here or in the card review:
    /// true for Remembered.
    let lastRemembered: Bool?
    /// When the card review asks it next.
    let dueAt: Date
    let isRetired: Bool

    init(itemID: String, lastRemembered: Bool?, dueAt: Date, isRetired: Bool) {
        self.itemID = itemID
        self.lastRemembered = lastRemembered
        self.dueAt = dueAt
        self.isRetired = isRetired
    }

    /// The question's standing from its item and the item's attempts, by the
    /// schedule every surface derives (`MemoryTutorScheduler`).
    init(item: MemoryItem, attempts: [MemoryAttempt], calendar: Calendar = .current) {
        let schedule = MemoryTutorScheduler.schedule(item: item, attempts: attempts, calendar: calendar)
        let latest = attempts
            .filter { $0.memoryItemID == item.id && $0.gradeState == .graded && $0.scheduleRating != nil }
            .max {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }
        self.init(
            itemID: item.id,
            lastRemembered: latest.map { $0.scheduleRating != .again },
            dueAt: schedule.dueAt,
            isRetired: item.status == .retired
        )
    }

    /// Whether the card review asks it now: a later grade in the reading is
    /// written only then (`MemoryCardQueue.answerCounts`).
    func isDue(at now: Date) -> Bool {
        !isRetired && dueAt <= now
    }
}

enum MnemonicReadingProgress {
    struct Counts: Equatable, Sendable {
        let questions: Int
        let answered: Int
        /// Answered questions the card review asks now.
        let due: Int
    }

    /// How the reading stands: its questions, those answered (kept in
    /// Memory), and those of them due now. `memory` is keyed by question id.
    static func counts(
        of reading: MnemonicReading,
        memory: [String: MnemonicQuestionMemory],
        now: Date
    ) -> Counts {
        let questions = reading.questions
        let kept = questions.compactMap { memory[$0.id] }
        return Counts(
            questions: questions.count,
            answered: kept.count,
            due: kept.filter { $0.isDue(at: now) }.count
        )
    }

    /// The header's line: "24 questions · 6 answered · 2 due", the due part
    /// only when some are.
    static func line(_ counts: Counts) -> String {
        var parts = [counts.questions == 1 ? "1 question" : "\(counts.questions) questions"]
        parts.append("\(counts.answered) answered")
        if counts.due > 0 { parts.append("\(counts.due) due") }
        return parts.joined(separator: " · ")
    }

    /// The next question not answered yet after `current`, in `order` (the
    /// questions as they stand on screen), going round to the start; nil when
    /// every one is answered.
    static func nextUnanswered(in order: [String], answered: Set<String>, after current: String?) -> String? {
        let start = current.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = order[min(start, order.count)...] + order[..<min(start, order.count)]
        return rotated.first { !answered.contains($0) }
    }
}

// MARK: - The reading as rows

/// How one of a reading's sources stands on screen.
enum MnemonicReadingSourceText: Equatable, Sendable {
    /// Its text is not read yet: it is read when its place scrolls into view.
    case loading
    case loaded(MnemonicReadingLayout)
    /// It cannot be read here, and why: not in the library, or no text yet.
    case unavailable(String)
}

/// One row of a reading as a list draws it, top to bottom.
enum MnemonicReadingRow: Identifiable, Equatable, Sendable {
    /// A source's title, starting its part of the reading.
    case heading(sourceID: String, title: String)
    /// The source's questions are not written yet.
    case pending(sourceID: String)
    /// The source's text is being read.
    case loading(sourceID: String)
    /// The source cannot be read, and why; its questions follow it, if any.
    case unavailable(sourceID: String, reason: String)
    case block(sourceID: String, block: MnemonicReadingBlock)
    /// A question, after the block its quote closes; `isUnplaced` when its
    /// source's text does not print the quote (or cannot be read), and it
    /// stands at the end of that source instead.
    case question(MnemonicQuestion, isUnplaced: Bool)

    var id: String {
        switch self {
        case .heading(let sourceID, _): return "heading:\(sourceID)"
        case .pending(let sourceID): return "pending:\(sourceID)"
        case .loading(let sourceID): return "loading:\(sourceID)"
        case .unavailable(let sourceID, _): return "unavailable:\(sourceID)"
        case .block(let sourceID, let block): return "block:\(sourceID):\(block.index)"
        case .question(let question, _): return Self.questionRowID(question.id)
        }
    }

    static func questionRowID(_ questionID: String) -> String {
        "question:\(questionID)"
    }

    static func headingRowID(_ sourceID: String) -> String {
        "heading:\(sourceID)"
    }
}

enum MnemonicReadingRows {
    /// The reading as rows: each source in reading order under its title
    /// (`titles`, the library's, else the one the body keeps), a note while
    /// its questions are not written, then its text a block at a time with
    /// each question after its block and the unplaced ones at its end — or,
    /// before its text is read, one loading row, and for a source that cannot
    /// be read, why, then its questions.
    static func rows(
        of reading: MnemonicReading,
        texts: [String: MnemonicReadingSourceText],
        titles: [String: String] = [:]
    ) -> [MnemonicReadingRow] {
        var rows: [MnemonicReadingRow] = []
        for section in reading.sections {
            let sourceID = section.sourceID
            rows.append(.heading(sourceID: sourceID, title: titles[sourceID] ?? section.title))
            if !section.isWritten { rows.append(.pending(sourceID: sourceID)) }
            switch texts[sourceID] ?? .loading {
            case .loading:
                rows.append(.loading(sourceID: sourceID))
            case .unavailable(let reason):
                rows.append(.unavailable(sourceID: sourceID, reason: reason))
                rows += section.questions.map { .question($0, isUnplaced: true) }
            case .loaded(let layout):
                for block in layout.blocks {
                    rows.append(.block(sourceID: sourceID, block: block))
                    rows += (layout.questionsAfter[block.index] ?? []).map { .question($0, isUnplaced: false) }
                }
                rows += layout.unplaced.map { .question($0, isUnplaced: true) }
            }
        }
        return rows
    }

    /// The questions in the order the reading shows them: a read source's as
    /// its text places them, one not read yet in the body's order.
    static func questionOrder(of reading: MnemonicReading, texts: [String: MnemonicReadingSourceText]) -> [String] {
        reading.sections.flatMap { section -> [String] in
            if case .loaded(let layout) = texts[section.sourceID] {
                return layout.orderedQuestions.map(\.id)
            }
            return section.questions.map(\.id)
        }
    }
}
