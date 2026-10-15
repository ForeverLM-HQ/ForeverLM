import CryptoKit
import Foundation

// MARK: - A mnemonic reading: a book read with its questions in it
//
// docs/memory-design.md, "Mnemonic reading (2026-10-03)". The product owner, 2026-10-03,
// pointing at quantum.country: "when I read a book, I want to have those like
// questions interspersed as a potential artifact." A mnemonic reading is a
// book's chapters (or any chapter, paper or article) read as their own stored
// text, with a recall question after the passage it tests. Answering one keeps
// it as a Memory card at once, which then comes back in the card review.
//
// The record is an ordinary Artifact (`ArtifactKind.mnemonicReading`, on the
// Mac) whose body holds the questions only — never a copy of the sources'
// text — in the Markdown this file writes and reads. Each client reads the
// sources' text from its own library and places the questions in it
// (`MnemonicReadingPlacement`). What the learner answered lives in Memory, per
// learner, and never in the body.
//
// Compiled into the iPhone app too (project.yml), so the phone reads, places
// and answers the same questions. Foundation only.

/// One question of a mnemonic reading: asked after the passage of its source
/// that `quote` closes, answered from memory, then graded by the learner.
struct MnemonicQuestion: Identifiable, Equatable, Sendable {
    /// Minted from the question's content when it is written
    /// (`id(sourceID:quote:question:)`), never by a model, and kept in the
    /// body: the question's Memory item is `memoryItemID`, so two devices
    /// answering it before they sync keep one card.
    let id: String
    /// The source the question tests: a book's chapter, a paper, an article.
    var sourceID: String
    /// The words of the source the question follows — the last sentence of
    /// the passage it tests — as its text prints them.
    var quote: String
    var question: String
    var answer: String
    var why: String?

    init(
        id: String,
        sourceID: String,
        quote: String,
        question: String,
        answer: String,
        why: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.quote = quote
        self.question = question
        self.answer = answer
        self.why = why
    }

    /// A newly written question, in the form the body writes it, under the
    /// id its content mints.
    static func mint(
        sourceID: String,
        quote: String,
        question: String,
        answer: String,
        why: String? = nil
    ) -> MnemonicQuestion {
        let written = MnemonicQuestion(
            id: "",
            sourceID: sourceID,
            quote: quote,
            question: question,
            answer: answer,
            why: why
        ).asWritten
        return MnemonicQuestion(
            id: id(sourceID: written.sourceID, quote: written.quote, question: written.question),
            sourceID: written.sourceID,
            quote: written.quote,
            question: written.question,
            answer: written.answer,
            why: written.why
        )
    }

    /// The question's identity, from its source, its quote and its words —
    /// case and spacing aside — so the same question written twice, by two
    /// runs or two Macs, is one question with one Memory item.
    static func id(sourceID: String, quote: String, question: String) -> String {
        let fields = [
            sourceID.trimmingCharacters(in: .whitespacesAndNewlines),
            normalized(quote),
            normalized(question),
        ]
        var bytes = Data("mnemonic-question-v1".utf8)
        for field in fields {
            bytes.append(0)
            bytes.append(contentsOf: field.utf8)
        }
        let digest = SHA256.hash(data: bytes)
        return "mq-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The Memory item answering the question keeps: one per question id
    /// (`MemoryTutorIdentity.cardItemID`), the same on every device.
    var memoryItemID: String {
        MemoryTutorIdentity.cardItemID(cardID: id)
    }

    /// The card the question is kept as: the question its front, the answer
    /// its back, the why its why, from a reading.
    var card: MemoryCard {
        MemoryCard(
            cardID: id,
            front: question,
            back: answer,
            why: why.map { [$0] } ?? [],
            origin: .reading
        )
    }

    /// The question in the form the body writes its parts: a one-line
    /// question, quote and why, and the answer's lines trimmed. What still
    /// differs on reading back is a question the format cannot carry
    /// (`MnemonicReading.readBack`).
    var asWritten: MnemonicQuestion {
        var question = self
        question.sourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        question.quote = MnemonicReading.singleLine(quote)
        question.question = MnemonicReading.singleLine(self.question)
        question.answer = answer
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let why = why.map(MnemonicReading.singleLine) ?? ""
        question.why = why.isEmpty ? nil : why
        return question
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension MemoryCardOrigin {
    /// A mnemonic reading's question, kept when the learner first graded it
    /// in the reading — remembered or not (docs/memory-design.md, "Mnemonic
    /// reading").
    static let reading = MemoryCardOrigin(rawValue: "reading")
}

/// How many questions a reading asks of its text. Raw values are the MCP words.
enum MnemonicReadingDensity: String, CaseIterable, Identifiable, Sendable {
    case fewer
    case auto
    case more

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fewer: return "Fewer"
        case .auto: return "Auto"
        case .more: return "More"
        }
    }

    /// About one question for this many words of text.
    var wordsPerQuestion: Int {
        switch self {
        case .fewer: return 700
        case .auto: return 350
        case .more: return 200
        }
    }

    /// The most questions one source is asked, however long: a chapter's
    /// questions stay a few minutes of answering.
    var capPerSource: Int {
        switch self {
        case .fewer: return 12
        case .auto: return 24
        case .more: return 40
        }
    }

    /// The questions asked of a text this many words long: one for every
    /// `wordsPerQuestion` words, at least one, at most `capPerSource`.
    func questionCount(words: Int) -> Int {
        let count = Int((Double(max(0, words)) / Double(wordsPerQuestion)).rounded())
        return min(capPerSource, max(1, count))
    }
}

/// A mnemonic reading's body: its title and its sources in reading order,
/// each with the questions written for it.
///
/// ```
/// <!-- foreverlm:mnemonic-reading v1 -->
/// # Thinking, Fast and Slow with questions
///
/// ## The Characters of the Story
/// <!-- source:src_1 -->
///
/// ### In Kahneman's account, which system operates automatically and quickly?
/// <!-- question:mq-6f1c2a9e3b0d4d1e9c557a2f4d0e8b11 -->
/// System 1.
///
/// > Why: It works with little or no effort and no sense of voluntary control.
///
/// Asked after: “System 1 operates automatically and quickly.”
///
/// ## Attention and Effort
/// <!-- source:src_2 pending -->
/// ```
///
/// Every `## ` heading starts a source's section, named by the
/// `<!-- source:<id> -->` line under it, `pending` until its questions are
/// written (a run still writing, stopped, or failed for that source). Every
/// `### ` heading under it is a question; its minted id is the
/// `<!-- question:<id> -->` line, then come its answer, its `> Why:`, the
/// `Asked after:` quote. The sections are the reading
/// order, whatever order the record's grounding lists them in (a team's copy
/// sorts it). A build that does not know the kind reads the body as a Doc
/// listing the questions under their chapters.
///
/// Sections only grow: a section's questions are added to, never dropped
/// (`writing(_:in:)`), and two copies merge question by question (`union`),
/// so a question the learner may have answered never leaves the reading.
struct MnemonicReading: Equatable, Sendable {
    static let formatMarker = "<!-- foreverlm:mnemonic-reading v1 -->"
    static let sourceLinePrefix = "<!-- source:"
    static let questionLinePrefix = "<!-- question:"
    static let pendingWord = "pending"
    static let commentSuffix = "-->"
    static let quoteLabel = "Asked after:"
    /// What a tile, a row and a kind label call one.
    static let kindLabel = "Mnemonic reading"

    /// One source of the reading, in its place in the reading order.
    struct Section: Identifiable, Equatable, Sendable {
        let sourceID: String
        /// The source's title when the section was written; a client shows
        /// its library's own title when it holds the source.
        var title: String
        /// Whether the source's questions are written. A pending section is
        /// waiting for its run, or its run stopped or failed for it, and it
        /// can be written again.
        var isWritten: Bool
        var questions: [MnemonicQuestion]

        var id: String { sourceID }

        init(sourceID: String, title: String, isWritten: Bool = false, questions: [MnemonicQuestion] = []) {
            self.sourceID = sourceID
            self.title = title
            self.isWritten = isWritten
            self.questions = questions
        }
    }

    var title: String
    var sections: [Section]

    init(title: String, sections: [Section] = []) {
        self.title = title
        self.sections = sections
    }

    /// A reading's title, from what it reads: "<book or source> with questions".
    static func title(forSubject subject: String) -> String {
        let name = singleLine(subject)
        return name.isEmpty ? kindLabel : "\(name) with questions"
    }

    /// Every question, in reading order.
    var questions: [MnemonicQuestion] {
        sections.flatMap(\.questions)
    }

    func question(id: String) -> MnemonicQuestion? {
        for section in sections {
            if let question = section.questions.first(where: { $0.id == id }) { return question }
        }
        return nil
    }

    func section(sourceID: String) -> Section? {
        sections.first { $0.sourceID == sourceID }
    }

    /// The sources whose questions are still to be written, in reading order.
    var pendingSourceIDs: [String] {
        sections.filter { !$0.isWritten }.map(\.sourceID)
    }

    // MARK: Recognizing a body

    /// Whether a body is a mnemonic reading's: its first non-empty line is
    /// the marker. An older build that does not know the kind saves the
    /// record back with none, and the body still says what it is.
    static func isReadingMarkdown(_ markdown: String) -> Bool {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) == formatMarker
    }

    // MARK: Reading

    /// Reads a body. A section with no source line is not the reading's and
    /// is left out; a question with no quote or no answer is dropped rather
    /// than shown with nothing to place it by or nothing to show; a question
    /// with no question line (written by hand) takes the id its content
    /// mints. Of two sections for one source, or two questions under one
    /// id, only the first is read: everything that keys on them would take
    /// them for one.
    static func parse(_ markdown: String, fallbackTitle: String) -> MnemonicReading {
        var title: String?
        var drafts: [SectionLines] = []

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                drafts.append(SectionLines(title: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard var section = drafts.popLast() else {
                if title == nil, line.hasPrefix("# ") {
                    title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            section.read(line: line)
            drafts.append(section)
        }

        var sections: [Section] = []
        var sourceIDs = Set<String>()
        var questionIDs = Set<String>()
        for draft in drafts {
            guard let sourceID = draft.sourceID, sourceIDs.insert(sourceID).inserted else { continue }
            var questions: [MnemonicQuestion] = []
            for lines in draft.questions {
                guard let question = lines.question(sourceID: sourceID),
                      questionIDs.insert(question.id).inserted else { continue }
                questions.append(question)
            }
            sections.append(Section(
                sourceID: sourceID,
                title: draft.title,
                isWritten: !draft.isPending,
                questions: questions
            ))
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespaces) ?? ""
        return MnemonicReading(title: trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle, sections: sections)
    }

    // MARK: Writing

    /// The body in the fixed shape `parse` reads back.
    var markdown: String {
        var lines: [String] = [Self.formatMarker, "# \(Self.singleLine(title))"]
        for section in sections {
            lines.append("")
            let heading = Self.singleLine(section.title)
            lines.append("## \(heading.isEmpty ? "Source" : heading)")
            lines.append(Self.sourceLine(sourceID: section.sourceID, isWritten: section.isWritten))
            for question in section.questions {
                lines.append("")
                lines.append("### \(Self.singleLine(question.question))")
                lines.append("\(Self.questionLinePrefix)\(question.id) \(Self.commentSuffix)")
                lines.append(question.answer.trimmingCharacters(in: .whitespacesAndNewlines))
                if let why = question.why.map(Self.singleLine), !why.isEmpty {
                    lines.append("")
                    lines.append("> Why: \(why)")
                }
                lines.append("")
                lines.append("\(Self.quoteLabel) \u{201C}\(Self.singleLine(question.quote))\u{201D}")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sourceLine(sourceID: String, isWritten: Bool) -> String {
        "\(sourceLinePrefix)\(sourceID)\(isWritten ? "" : " \(pendingWord)") \(commentSuffix)"
    }

    /// The question as the body gives it back, or nil when it does not come
    /// back whole — an answer line that reads as a heading or as the
    /// question's own metadata — so it is refused rather than saved changed.
    static func readBack(_ question: MnemonicQuestion) -> MnemonicQuestion? {
        let written = question.asWritten
        let body = MnemonicReading(title: "Reading", sections: [
            Section(sourceID: written.sourceID, title: "Source", isWritten: true, questions: [written]),
        ]).markdown
        let parsed = parse(body, fallbackTitle: "Reading")
        guard parsed.questions.count == 1, let read = parsed.questions.first, read == written else { return nil }
        return read
    }

    // MARK: Growing

    /// What `writing(_:in:)` did with the questions it was given.
    struct Written: Equatable, Sendable {
        /// The reading with the source's section written.
        var reading: MnemonicReading
        /// The questions added, as the body now holds them.
        var added: [MnemonicQuestion] = []
        /// Questions the section already held, under the same id.
        var alreadyWritten: [MnemonicQuestion] = []
        /// Questions the body would not give back whole; not saved.
        var unreadable: [MnemonicQuestion] = []
    }

    /// The reading with `sourceID`'s section written: its questions added at
    /// the end, in their order, those whose id the reading already holds left
    /// as they are, and the section marked written. A source the reading does
    /// not list yet gets a section at the end, titled `title`. Nothing else
    /// changes.
    func writing(_ questions: [MnemonicQuestion], in sourceID: String, title: String? = nil) -> Written {
        var result = Written(reading: self)
        var known = Set(self.questions.map(\.id))
        var added: [MnemonicQuestion] = []
        for question in questions {
            guard let read = Self.readBack(question) else {
                result.unreadable.append(question)
                continue
            }
            guard known.insert(read.id).inserted else {
                result.alreadyWritten.append(read)
                continue
            }
            added.append(read)
        }
        if let index = result.reading.sections.firstIndex(where: { $0.sourceID == sourceID }) {
            result.reading.sections[index].questions.append(contentsOf: added)
            result.reading.sections[index].isWritten = true
            if let title, !Self.singleLine(title).isEmpty { result.reading.sections[index].title = Self.singleLine(title) }
        } else {
            result.reading.sections.append(Section(
                sourceID: sourceID,
                title: Self.singleLine(title ?? ""),
                isWritten: true,
                questions: added
            ))
        }
        result.added = added
        return result
    }

    // MARK: Two copies

    /// Two copies of a reading as one, for a body that arrived from another
    /// device while this one held a newer body of its own: this copy, with a
    /// section the other wrote marked written, the other's questions this one
    /// lacks appended to their section in their order, and the other's
    /// sections this one lacks appended. Nothing is held for a choice, which
    /// a reading, never edited as a Doc, could not offer. `mine` itself when
    /// the other adds nothing; nil unless both are reading bodies.
    static func union(mine: String, theirs: String) -> String? {
        guard isReadingMarkdown(mine), isReadingMarkdown(theirs) else { return nil }
        let other = parse(theirs, fallbackTitle: Self.kindLabel)
        var merged = parse(mine, fallbackTitle: other.title)
        var changed = false
        var ids = Set(merged.questions.map(\.id))
        for section in other.sections {
            let missing = section.questions.filter { ids.insert($0.id).inserted }
            if let index = merged.sections.firstIndex(where: { $0.sourceID == section.sourceID }) {
                if section.isWritten, !merged.sections[index].isWritten {
                    merged.sections[index].isWritten = true
                    changed = true
                }
                if !missing.isEmpty {
                    merged.sections[index].questions.append(contentsOf: missing)
                    changed = true
                }
            } else {
                var appended = section
                appended.questions = missing
                merged.sections.append(appended)
                changed = true
            }
        }
        return changed ? merged.markdown : mine
    }

    // MARK: Text

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// One section's lines while a body is read.
private struct SectionLines {
    var title: String
    var sourceID: String?
    var isPending = false
    var questions: [QuestionLines] = []

    init(title: String) {
        self.title = title
    }

    mutating func read(line: String) {
        if line.hasPrefix("### ") {
            questions.append(QuestionLines(question: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
            return
        }
        if var question = questions.popLast() {
            question.read(line: line)
            questions.append(question)
            return
        }
        guard sourceID == nil,
              line.hasPrefix(MnemonicReading.sourceLinePrefix),
              line.hasSuffix(MnemonicReading.commentSuffix) else { return }
        let words = line
            .dropFirst(MnemonicReading.sourceLinePrefix.count)
            .dropLast(MnemonicReading.commentSuffix.count)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard let id = words.first, !id.isEmpty else { return }
        sourceID = id
        isPending = words.dropFirst().contains(MnemonicReading.pendingWord)
    }
}

/// One question's lines while a body is read.
private struct QuestionLines {
    var question: String
    var questionID: String?
    var answerLines: [String] = []
    var whyLines: [String] = []
    var quote: String?
    /// Once the question's metadata starts, later prose is no longer its answer.
    private var inMetadata = false
    /// Set once a line after the why is read, so a stray quote after it is
    /// not taken for more of the why.
    private var pastWhy = false

    init(question: String) {
        self.question = question
    }

    mutating func read(line: String) {
        let lower = line.lowercased()
        if line.hasPrefix(MnemonicReading.questionLinePrefix), line.hasSuffix(MnemonicReading.commentSuffix) {
            if questionID == nil, answerLines.isEmpty {
                let id = line
                    .dropFirst(MnemonicReading.questionLinePrefix.count)
                    .dropLast(MnemonicReading.commentSuffix.count)
                    .trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { questionID = id }
            }
        } else if lower.hasPrefix("> why:") {
            whyLines.append(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            inMetadata = true
        } else if line.hasPrefix(">"), !whyLines.isEmpty, !pastWhy {
            whyLines.append(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix(MnemonicReading.quoteLabel.lowercased()) {
            quote = Self.unquoted(String(line.dropFirst(MnemonicReading.quoteLabel.count)))
            markMetadata()
        } else if lower.hasPrefix("difficulty:") {
            // A reading written before questions stopped carrying a drafted
            // difficulty has the line; it is read past, and never kept.
            markMetadata()
        } else if !inMetadata {
            answerLines.append(line)
        }
    }

    private mutating func markMetadata() {
        inMetadata = true
        pastWhy = true
    }

    /// The quote between its marks: curly, straight, or none.
    private static func unquoted(_ text: String) -> String {
        var quote = text.trimmingCharacters(in: .whitespaces)
        if let first = quote.first, "\u{201C}\"".contains(first) { quote.removeFirst() }
        if let last = quote.last, "\u{201D}\"".contains(last) { quote.removeLast() }
        return quote.trimmingCharacters(in: .whitespaces)
    }

    func question(sourceID: String) -> MnemonicQuestion? {
        let front = MnemonicReading.singleLine(question)
        let answer = answerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = MnemonicReading.singleLine(self.quote ?? "")
        guard !front.isEmpty, !answer.isEmpty, !quote.isEmpty else { return nil }
        let why = whyLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return MnemonicQuestion(
            id: questionID ?? MnemonicQuestion.id(sourceID: sourceID, quote: quote, question: front),
            sourceID: sourceID,
            quote: quote,
            question: front,
            answer: answer,
            why: why.isEmpty ? nil : why
        )
    }
}
