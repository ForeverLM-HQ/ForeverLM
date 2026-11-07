import Foundation

// MARK: - A notebook's report

/// A notebook's report (docs/notebooks-design.md, "Reports"): Gemini
/// Notebook's report formats — Briefing, Study guide, Questions for a
/// meeting, Feedback on a document, and the learner's own — written over the
/// notebook's ticked sources by the learner's Report Writing model and saved
/// as an ordinary Doc homed in the notebook.
///
/// The writer cites each source by its number (`[S2]`); the app, never the
/// model, turns every marker into the Doc's own citation form — grounding on
/// the passage it supports (`foreverlm://grounding/<id>,<id>`, the shape the
/// editor writes when a source is attached) — and closes the Doc with its
/// Sources: the recipe it was made from in one line, and a card for each
/// source (`[Title](foreverlm://source/<id>)` standing alone). An id the model
/// was never given cannot reach the Doc.
///
/// Foundation-only: the formats, the options, the recipe, the writer's turn
/// and the citations. Reading and writing are `ReportGeneratorService`'s.

/// What kind of report to write. Raw values are the MCP words.
enum ReportFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case briefing
    case studyGuide = "study_guide"
    case meetingQuestions = "meeting_questions"
    case documentFeedback = "document_feedback"
    case custom

    var id: String { rawValue }

    static let `default` = ReportFormat.briefing

    /// The format's name, as the sheet, the recipe and the Report menu say it.
    var label: String {
        switch self {
        case .briefing: return "Briefing"
        case .studyGuide: return "Study guide"
        case .meetingQuestions: return "Questions for a meeting"
        case .documentFeedback: return "Feedback on a document"
        case .custom: return "Custom"
        }
    }

    /// The Report menu's word for it (the Studio's Report tile, the Notebook
    /// menu's Make ▸ Report): Custom asks for the learner's own words next.
    var title: String { self == .custom ? "Custom…" : label }

    /// The glyph a menu item and a pending row show: none of them another
    /// Studio tile's (the Course tile's cap, the Note tile's pencil), since
    /// the Report menu opens among those tiles.
    var symbolName: String {
        switch self {
        case .briefing: return "doc.text.magnifyingglass"
        case .studyGuide: return "book.closed"
        case .meetingQuestions: return "questionmark.bubble"
        case .documentFeedback: return "text.badge.checkmark"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// What a run is writing, for its pending row ("Writing the briefing").
    var writingNoun: String {
        switch self {
        case .briefing: return "the briefing"
        case .studyGuide: return "the study guide"
        case .meetingQuestions: return "the questions"
        case .documentFeedback: return "the feedback"
        case .custom: return "the report"
        }
    }

    /// Feedback is about one chosen document: a source of the notebook, or
    /// one of its Docs.
    var needsSubject: Bool { self == .documentFeedback }

    /// A custom report is the learner's instruction, which says what to write.
    var needsInstruction: Bool { self == .custom }

    /// Every format but the custom one takes an optional focus line; the
    /// instruction of a custom report says it all.
    var takesFocus: Bool { self != .custom }

    /// Words the report runs to. A custom instruction may ask for another.
    var wordRange: ClosedRange<Int> {
        switch self {
        case .briefing: return 900...1_600
        case .studyGuide: return 1_400...2_400
        case .meetingQuestions: return 700...1_300
        case .documentFeedback: return 1_000...1_800
        case .custom: return 800...2_000
        }
    }

    /// What the writer is asked to make, in the turn.
    var writerBrief: String {
        switch self {
        case .briefing:
            return "Briefing: a briefing document for someone who must understand these sources quickly and act on them. Open with a short executive summary of what the sources establish, in three to five sentences. Then the key themes or findings, a section each, with the evidence behind each and whose claim it is; the most important quotations, copied exactly; where the sources agree and where they conflict; and the open questions and what follows from them. Specific facts, numbers and names over generalities."
        case .studyGuide:
            return "Study guide: a guide for reviewing these sources and testing one's understanding of them, in five sections with these headings, in this order. Overview: the main ideas in a few short paragraphs. Quiz: ten short-answer questions, numbered, each answerable in two or three sentences from the sources. Answer key: each quiz answer in two or three sentences, numbered to match, citing the sources. Essay questions: five questions that ask the learner to connect, compare or evaluate ideas across the sources, with no answers. Glossary: the key terms, each in bold and defined in one or two sentences as the sources use it."
        case .meetingQuestions:
            return "Questions for a meeting: questions to bring to a meeting about these sources, with their authors or speakers, a colleague, a team or an advisor. Open with what to know going in, in a few bullets. Then the questions, grouped by theme, the most important first; under each, one line on why it matters or what an answer would change. Ask about the weakest evidence, where the sources disagree, what they leave open, how their claims would hold up in practice, and the next steps. Close with the three questions to ask if there is time for only three."
        case .documentFeedback:
            return "Feedback on a document: constructive, specific feedback on the document marked as the one the feedback is about; the other sources are context to judge it against. Open with a short summary of what the document argues or proposes and an overall assessment. Then its strengths; its major concerns (claims its evidence does not support, gaps in the argument or method, risks, omissions); minor issues (clarity, structure, wording); and concrete suggestions. Tie each point to a passage of the document, quoted exactly or named by its section. Say where the context sources support it, contradict it or add to it. Close with questions for its authors. Fair to the authors, never vague."
        case .custom:
            return "Custom: the report the learner's instruction above describes, in the structure, tone and length it asks for. Where the instruction is silent, write a clear, well-organised report."
        }
    }
}

/// The document a feedback report is about: one of the notebook's sources,
/// or one of its Docs.
struct ReportSubject: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case source
        case doc
    }

    let kind: Kind
    let id: String
    let title: String
}

/// What the learner asked for: a format, an optional focus, the instruction
/// of a custom report, and the document a feedback report is about.
struct ReportOptions: Equatable, Sendable {
    /// What still has to be given before these options can make a report.
    enum Gap: Equatable, Sendable {
        case instruction
        case subject
    }

    var format: ReportFormat = .default
    var focus: String = ""
    var instruction: String = ""
    var subject: ReportSubject? = nil
    /// What the learner thought mattered most, written before asking for the
    /// report (Think first, `ReportTake`). Empty when they skipped it or were
    /// not asked.
    var take: String = ""

    init(format: ReportFormat = .default, focus: String = "", instruction: String = "", subject: ReportSubject? = nil, take: String = "") {
        self.format = format
        self.focus = focus
        self.instruction = instruction
        self.subject = subject
        self.take = take
    }

    /// The focus as the writer reads it; nil when there is none, and for a
    /// custom report, whose instruction says it all.
    var trimmedFocus: String? {
        guard format.takesFocus else { return nil }
        return Self.trimmed(focus)
    }

    /// The custom report's instruction; nil for every other format.
    var trimmedInstruction: String? {
        guard format.needsInstruction else { return nil }
        return Self.trimmed(instruction)
    }

    /// The learner's take, as written; nil when there is none.
    var trimmedTake: String? {
        Self.trimmed(take)
    }

    /// The document the feedback is about; nil for every other format.
    var effectiveSubject: ReportSubject? {
        format.needsSubject ? subject : nil
    }

    /// What is missing, or nil when these options can make a report.
    var gap: Gap? {
        if format.needsInstruction, trimmedInstruction == nil { return .instruction }
        if format.needsSubject, subject == nil { return .subject }
        return nil
    }

    private static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - The recipe

/// What a report was made from, kept with it: the Doc closes with this one
/// line under a rule, "Made from 6 sources · Briefing · why complex I
/// matters", which every client shows as it shows any Doc, which a published
/// page keeps, and which the outputs row's menu and `read_doc` read back.
/// The sources it cites are its footnotes' notes, and the record names every
/// source it was made from (`ArtifactRecord.sourceIDs`).
struct ReportRecipe: Equatable, Sendable {
    var format: ReportFormat
    /// How many of the notebook's sources it was written from.
    var sourceCount: Int
    /// The document a feedback report is about, by title; nil otherwise.
    var subjectTitle: String?
    /// Whether that document is a Doc, read beside the sources rather than
    /// one of them.
    var subjectIsDocument: Bool
    /// The focus, or a custom report's instruction.
    var note: String?

    init(format: ReportFormat, sourceCount: Int, subjectTitle: String? = nil, subjectIsDocument: Bool = false, note: String? = nil) {
        self.format = format
        self.sourceCount = sourceCount
        self.subjectTitle = subjectTitle.map(Self.recipeText)
        self.subjectIsDocument = subjectIsDocument
        self.note = note.map(Self.recipeText).flatMap { $0.isEmpty ? nil : $0 }
    }

    static let linePrefix = "Made from "

    /// "6 sources", "1 source", "the document and 3 sources", "the document".
    var madeFrom: String {
        let count = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        guard subjectIsDocument else { return count }
        return sourceCount == 0 ? "the document" : "the document and \(count)"
    }

    /// "Briefing", or "Feedback on “Whitepaper”".
    var formatSegment: String {
        switch format {
        case .documentFeedback: return "Feedback on \u{201C}\(subjectTitle ?? "")\u{201D}"
        default: return format.label
        }
    }

    /// "Made from 6 sources · Briefing · why complex I matters"
    var line: String {
        var parts = [Self.linePrefix + madeFrom, formatSegment]
        if let note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    /// The recipe a line says, or nil for a line that is not one.
    static func parse(line raw: String) -> ReportRecipe? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(linePrefix) else { return nil }
        var rest = Substring(line.dropFirst(linePrefix.count))
        guard let firstBreak = rest.range(of: " · ") else { return nil }
        var phrase = String(rest[..<firstBreak.lowerBound])
        rest = rest[firstBreak.upperBound...]

        var subjectIsDocument = false
        var count = 0
        if phrase.hasPrefix("the document") {
            subjectIsDocument = true
            phrase = String(phrase.dropFirst("the document".count))
            if phrase.hasPrefix(" and ") {
                phrase = String(phrase.dropFirst(" and ".count))
            } else if !phrase.isEmpty {
                return nil
            }
        }
        if !phrase.isEmpty {
            let words = phrase.split(separator: " ")
            guard words.count == 2, let number = Int(words[0]),
                  words[1] == (number == 1 ? "source" : "sources") else { return nil }
            count = number
        } else if !subjectIsDocument {
            return nil
        }

        let feedbackOpening = "Feedback on \u{201C}"
        let format: ReportFormat
        var subjectTitle: String?
        var note: Substring?
        if rest.hasPrefix(feedbackOpening) {
            let title = rest.dropFirst(feedbackOpening.count)
            guard let close = title.firstIndex(of: "\u{201D}") else { return nil }
            subjectTitle = String(title[..<close])
            let after = title[title.index(after: close)...]
            if after.hasPrefix(" · ") {
                note = after.dropFirst(" · ".count)
            } else if !after.isEmpty {
                return nil
            }
            format = .documentFeedback
        } else {
            let label: Substring
            if let next = rest.range(of: " · ") {
                label = rest[..<next.lowerBound]
                note = rest[next.upperBound...]
            } else {
                label = rest
            }
            guard let named = ReportFormat.allCases.first(where: { $0 != .documentFeedback && $0.label == label }) else {
                return nil
            }
            format = named
        }
        guard !subjectIsDocument || format == .documentFeedback else { return nil }
        return ReportRecipe(
            format: format,
            sourceCount: count,
            subjectTitle: subjectTitle,
            subjectIsDocument: subjectIsDocument,
            note: note.map(String.init)
        )
    }

    /// The recipe a report's body carries: its last line that reads as one,
    /// written by the app under the closing rule. Nil for a Doc
    /// that is not a report, or one whose recipe line the learner removed.
    static func parse(fromMarkdown markdown: String) -> ReportRecipe? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let text = ReportMarkdown.unescaped(line.trimmingCharacters(in: .whitespaces))
            guard text.hasPrefix(linePrefix) else { continue }
            if let recipe = parse(line: text) { return recipe }
        }
        return nil
    }

    /// A title or a note as one recipe line holds it: one line, and the
    /// closing quote that ends a subject's title kept for that alone.
    private static func recipeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{201D}", with: "\"")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

// MARK: - The writer's turn

/// One source as the writer is handed it, numbered for its marker.
struct ReportTurnSource: Equatable, Sendable {
    /// Its marker's number: cited as `[S<number>]`.
    var number: Int
    var title: String
    /// What the source is, in words: "research paper", "book chapter".
    var kind: String
    var author: String?
    var venue: String?
    var year: String?
    var readAs: NotebookSourceReadAs
    /// Whether this is the document a feedback report is about.
    var isSubject: Bool = false
    var text: String
}

/// The Doc a feedback report is about, read whole beside the sources.
struct ReportSubjectDocument: Equatable, Sendable {
    let id: String
    let title: String
    let text: String
}

enum ReportWriterTurn {
    /// The note every turn with sources carries about how they were read.
    static let readingNote = "Each source below is read whole unless its header says otherwise. \"Read: from its ideas\" means only the ideas stored for it were given, each a statement and what a good recall of it holds; \"Read: condensed\" means a condensed account of its whole text, written for this report, was given. Write about those sources only as far as what was given, and quote only a source read whole."

    /// The writer's turn: the learner's instruction or focus first, then the
    /// Notebook (model-facing text keeps the word), the format and its length, the document a feedback report is
    /// about when it is a Doc, how the sources were read, and each source
    /// with its marker, its header and its text.
    static func userMessage(
        notebookTitle: String,
        instructions: String?,
        options: ReportOptions,
        subjectDocument: ReportSubjectDocument?,
        sources: [ReportTurnSource]
    ) -> String {
        var lines: [String] = []
        if let instruction = options.trimmedInstruction {
            lines.append("Instruction: \(instruction)")
        }
        if let focus = options.trimmedFocus {
            lines.append("Focus: \(focus)")
        }
        if let take = options.trimmedTake {
            lines.append(ReportTake.writerInstruction(take))
        }
        lines.append("Notebook: \(notebookTitle)")
        if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            lines.append("Notebook instructions: \(instructions)")
        }
        lines.append("Format: \(options.format.writerBrief)")
        let range = options.format.wordRange
        lines.append(options.format.needsInstruction
            ? "Target length: \(range.lowerBound) to \(range.upperBound) words, unless the instruction asks for another."
            : "Target length: \(range.lowerBound) to \(range.upperBound) words.")
        if let document = subjectDocument {
            lines.append("")
            lines.append("The document the feedback is about is \"\(document.title)\", given whole below. It is not a numbered source: quote it or name its sections, and give it no marker.")
            lines.append("=== The document ===")
            lines.append(document.text)
        }
        lines.append("")
        switch sources.count {
        case 0:
            lines.append("Sources (0). There is no numbered source, so cite nothing.")
        case 1:
            lines.append("Sources (1). Cite it as [S1].")
            lines.append(readingNote)
        default:
            lines.append("Sources (\(sources.count)). Cite each by its marker, [S1] to [S\(sources.count)].")
            lines.append(readingNote)
        }
        for source in sources {
            lines.append("")
            lines.append("=== [S\(source.number)] Source \(source.number) of \(sources.count) ===")
            lines.append(contentsOf: header(for: source))
            lines.append(source.text)
        }
        return lines.joined(separator: "\n")
    }

    /// A source's header lines, without its text.
    static func header(for source: ReportTurnSource) -> [String] {
        var lines = ["Title: \(source.title)", "Kind: \(source.kind)"]
        if let author = source.author, !author.isEmpty { lines.append("Authors: \(author)") }
        var venue: [String] = []
        if let journal = source.venue, !journal.isEmpty { venue.append(journal) }
        if let year = source.year, !year.isEmpty { venue.append(year) }
        if !venue.isEmpty { lines.append("Published: \(venue.joined(separator: ", "))") }
        if source.isSubject { lines.append("This is the document the feedback is about.") }
        lines.append("Read: \(source.readAs.label)")
        switch source.readAs {
        case .whole: lines.append("Full text:")
        case .ideas: lines.append("Its ideas:")
        case .condensed: lines.append("Condensed account:")
        }
        return lines
    }
}

/// Think first on a Studio report (docs/fences-and-think-first-design.md,
/// "Think first"): the learner's take on what matters most, asked before the
/// report is made. The report opens with it under **Your take**, written by
/// the app in the learner's words, and the writer ends the report with
/// **Where this differs from your take**, which names what the take saw that
/// the report did not as well as the other way round. Never a grade.
///
/// The web writes the same section and gives its writer the same words
/// (`docs-site/website/library`), so a report reads alike wherever it was made.
enum ReportTake {
    static let heading = "Your take"
    static let differenceHeading = "Where this differs from your take"

    /// What the writer is told, in its turn, after the focus.
    static func writerInstruction(_ take: String) -> String {
        "The learner wrote their own take before asking for this report, in their words: \u{201C}\(take)\u{201D}. ForeverLM puts it at the top of the report under \"\(heading)\"; do not repeat it there or rewrite it. Write the report as you would have anyway, then end it with a section headed \"\(differenceHeading)\", that says plainly and briefly what their take saw that your report does not, and what your report found that their take left out. Do not grade or praise the take."
    }

    /// The report's Markdown with the take's section at its top, or as it
    /// was when there is no take.
    static func prefixed(_ markdown: String, take: String?) -> String {
        guard let take, let section = section(take) else { return markdown }
        return section + "\n\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// `## Your take` and the take's lines, each reading as written: the
    /// inline Markdown characters escaped (`ReportMarkdown.escaped`), and a
    /// line that would open a heading, a quote or a list escaped at its start.
    /// Nil for a take with no words.
    static func section(_ take: String) -> String? {
        var lines: [String] = []
        for raw in take.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
                continue
            }
            lines.append(escapingBlockStart(ReportMarkdown.escaped(line)))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return "## \(heading)\n\n" + lines.joined(separator: "\n")
    }

    /// A backslash before what would make the line a heading, a quote, a
    /// bullet or a numbered item.
    private static func escapingBlockStart(_ line: String) -> String {
        if let first = line.first, "#>-+=".contains(first) {
            return "\\" + line
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if let marker = rest.first, marker == "." || marker == ")",
               rest.dropFirst().first.map({ $0 == " " }) ?? true {
                return String(digits) + "\\" + rest
            }
        }
        return line
    }
}

/// What the writer returns: the report's title and its Markdown, its claims
/// carrying `[S<n>]` markers.
struct ReportDraft: Codable, Equatable, Sendable {
    var title: String
    var markdown: String

    var isUsable: Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Markdown the app writes

enum ReportMarkdown {
    /// The characters escaped where the app writes learner text into a line
    /// of Markdown: what would otherwise open emphasis, code, a link, raw
    /// HTML, strikethrough or math.
    private static let escapedCharacters: Set<Character> = ["\\", "*", "_", "`", "[", "]", "<", "~", "$"]

    /// `text` as one line of Markdown that reads as written.
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if escapedCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A line read back as text: every backslash escape of ASCII punctuation
    /// undone, as CommonMark reads it, whatever an editor chose to escape.
    static func unescaped(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else {
                result.append(character)
                break
            }
            if next.isASCII, next.isPunctuation || next.isSymbol {
                result.append(next)
            } else {
                result.append(character)
                result.append(next)
            }
        }
        return result
    }

    /// A title as a link's text: on one line, a bracket unable to end the
    /// link early.
    static func linkText(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (line.isEmpty ? "Source" : line)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// An id as it stands in a `foreverlm://` path: anything but letters,
    /// digits and `-._~` percent-encoded, so a comma or a bracket in an id can
    /// never end the address. Both readers decode it.
    static func pathComponent(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}

// MARK: - Citations

/// The writer's `[S<n>]` markers turned into the Doc's own citations: each
/// cited passage stands on its sources (grounding, for Chat) and carries a
/// footnote whose note links them, the way every Page cites (product owner,
/// 2026-11-07: a report needs no Sources list at the end). Deterministic: the
/// model names a number it was given, and the app writes the address.
enum ReportCitations {
    /// One source of the report, in marker order: `[S1]` is the first.
    struct Source: Equatable, Sendable {
        let id: String
        let title: String
        let readAs: NotebookSourceReadAs
    }

    struct Result: Equatable, Sendable {
        var markdown: String
        /// The sources the report cites, in order of first citation.
        var citedSourceIDs: [String]
        /// Markers naming a number no source has, as written; dropped.
        var unresolvedMarkers: [String]
        /// The notes the footnotes point at, in label order:
        /// `[^1]: [Title](foreverlm://source/<id>)`, one line each.
        var notes: [String] = []
    }

    /// A marker: `[S3]`, `[S1, S4]`, `[S2-S5]`, `[S2][S3]`, never a link's
    /// text (`[S1](…)`). A report defines no link references, so a marker
    /// followed by another is two markers, not a reference link.
    static let markerPattern = #"\[\s*[Ss]\d{1,3}(?:\s*(?:[,;]|[-\x{2013}\x{2014}])\s*[Ss]?\d{1,3})*\s*\](?!\()"#

    /// The report's Doc body: the written Markdown with every marker turned
    /// into a footnote on the passage it follows, a rule and the recipe line,
    /// then the notes.
    static func compose(written: String, recipe: ReportRecipe, sources: [Source]) -> Result {
        let normalized = written
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ground(normalized, sources: sources)
        let body = result.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = body.isEmpty ? [] : [body]
        parts.append("---")
        parts.append(ReportMarkdown.escaped(recipe.line))
        parts.append(contentsOf: result.notes)
        result.markdown = parts.joined(separator: "\n\n") + "\n"
        return result
    }

    /// One source as a note names it: its title linked to it, and how it was
    /// read when it was not read whole.
    static func noteText(_ source: Source) -> String {
        var text = "[\(ReportMarkdown.linkText(source.title))](foreverlm://source/\(ReportMarkdown.pathComponent(source.id)))"
        switch source.readAs {
        case .whole: break
        case .ideas: text += " \u{2014} read from its ideas"
        case .condensed: text += " \u{2014} condensed"
        }
        return text
    }

    /// The address a passage standing on these sources carries.
    static func groundingDestination(_ ids: [String]) -> String {
        "foreverlm://grounding/" + ids.map(ReportMarkdown.pathComponent).joined(separator: ",")
    }

    // MARK: Grounding

    /// Every marker in `markdown` turned into grounding on the passage before
    /// it — the text since the previous marker on its line — and removed. A
    /// heading's markers are only removed (a heading is a title, not a claim);
    /// a table cell's passages are grounded within the cell; fenced code is
    /// left alone. Every cited passage is followed by a footnote, `[^n]`,
    /// whose note (in `Result.notes`) links its sources; passages citing the
    /// same sources share one note. A passage that cannot safely become a
    /// link's text (it holds a link, raw HTML or emphasis begun elsewhere)
    /// stays plain prose with its footnote, and a marker inside a link's own
    /// text is taken out, the link kept whole and the footnote after it.
    static func ground(_ markdown: String, sources: [Source]) -> Result {
        var resolver = Resolver(sources: sources)
        var lines: [String] = []
        var fence: String?
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                lines.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                lines.append(line)
                continue
            }
            lines.append(groundLine(line, resolver: &resolver))
        }
        return Result(
            markdown: lines.joined(separator: "\n"),
            citedSourceIDs: resolver.cited,
            unresolvedMarkers: resolver.unresolved,
            notes: resolver.notes
        )
    }

    private struct Resolver {
        let sources: [Source]
        var cited: [String] = []
        var citedSet: Set<String> = []
        var unresolved: [String] = []
        /// The footnote label of each set of sources cited together.
        var labels: [[String]: Int] = [:]
        var notes: [String] = []

        /// The footnote for a passage standing on `ids`: the same note for the
        /// same sources, a new one numbered on otherwise.
        mutating func footnote(for ids: [String]) -> String {
            guard !ids.isEmpty else { return "" }
            if let label = labels[ids] { return "[^\(label)]" }
            let label = notes.count + 1
            labels[ids] = label
            let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let text = ids.compactMap { byID[$0].map(ReportCitations.noteText) }.joined(separator: "; ")
            notes.append("[^\(label)]: \(text)")
            return "[^\(label)]"
        }

        init(sources: [Source]) {
            self.sources = sources
        }

        /// The source ids a marker names, in its order, each once.
        mutating func ids(forMarker marker: String) -> [String] {
            var numbers: [Int] = []
            let inner = marker.dropFirst().dropLast()
            for piece in inner.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let term = piece.trimmingCharacters(in: .whitespaces)
                let bounds = term
                    .split(whereSeparator: { $0 == "-" || $0 == "\u{2013}" || $0 == "\u{2014}" })
                    .map { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " Ss"))) }
                if bounds.count == 2, let low = bounds[0], let high = bounds[1], low <= high, high - low <= 50 {
                    numbers.append(contentsOf: low...high)
                } else if bounds.count == 1, let number = bounds[0] {
                    numbers.append(number)
                } else {
                    unresolved.append(term)
                }
            }
            var ids: [String] = []
            for number in numbers {
                guard number >= 1, number <= sources.count else {
                    unresolved.append("S\(number)")
                    continue
                }
                let id = sources[number - 1].id
                if !ids.contains(id) { ids.append(id) }
                if citedSet.insert(id).inserted { cited.append(id) }
            }
            return ids
        }
    }

    private enum Segment {
        case plain(String)
        case grounded(String, [String])
        /// Prose that cites but cannot be a link's text: kept as written,
        /// its footnote after it.
        case cited(String, [String])
    }

    private static let markerExpression = try? NSRegularExpression(pattern: markerPattern)
    private static let headingExpression = try? NSRegularExpression(pattern: #"^([ ]{0,3}#{1,6}[ \t]+)(.*)$"#)
    private static let blockPrefixExpression = try? NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?)"#
    )
    private static let htmlOpening = try? NSRegularExpression(pattern: #"<[A-Za-z/!?]"#)
    /// A link or a picture, `[text](destination)`, its text allowed one
    /// level of brackets inside (`[a [b] c](…)`).
    private static let linkExpression = try? NSRegularExpression(
        pattern: #"!?\[(?:[^\[\]\\]|\\.|\[(?:[^\[\]\\]|\\.)*\])*\]\([^)]*\)"#
    )

    private static func groundLine(_ line: String, resolver: inout Resolver) -> String {
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        if let heading = headingExpression?.firstMatch(in: line, range: whole),
           let prefixRange = Range(heading.range(at: 1), in: line),
           let contentRange = Range(heading.range(at: 2), in: line) {
            let content = String(line[contentRange])
            return String(line[prefixRange]) + removingMarkers(content, resolver: &resolver)
        }
        if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("|") {
            return groundTableRow(line, resolver: &resolver)
        }
        var prefixEnd = line.startIndex
        if let block = blockPrefixExpression?.firstMatch(in: line, range: whole),
           let range = Range(block.range(at: 1), in: line) {
            prefixEnd = range.upperBound
        }
        return String(line[..<prefixEnd]) + groundInline(String(line[prefixEnd...]), resolver: &resolver)
    }

    /// A heading's text without its markers.
    private static func removingMarkers(_ content: String, resolver: inout Resolver) -> String {
        let markers = markerRanges(in: content)
        guard !markers.isEmpty else { return content }
        var text = ""
        var cursor = content.startIndex
        for marker in markers {
            text += content[cursor..<marker.lowerBound]
            _ = resolver.ids(forMarker: String(content[marker]))
            cursor = marker.upperBound
        }
        text += content[cursor...]
        return text
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// A table row with each cell grounded in place: a cell's passage never
    /// leaves its cell, and a pipe never enters a link.
    private static func groundTableRow(_ line: String, resolver: inout Resolver) -> String {
        let cells = tableCells(line)
        let inner = Array(cells.dropFirst())
        let endsWithPipe = line.trimmingCharacters(in: .whitespaces).hasSuffix("|")
        let delimiter = (endsWithPipe ? inner.dropLast() : inner[...]).allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
        guard !delimiter else { return line }
        var out: [String] = []
        for (index, cell) in cells.enumerated() {
            let isOutside = index == 0 || (endsWithPipe && index == cells.count - 1)
            guard !isOutside else {
                out.append(cell)
                continue
            }
            let leading = cell.prefix(while: { $0 == " " || $0 == "\t" })
            let rest = cell.dropFirst(leading.count)
            let trailingCount = rest.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
            let core = String(rest.dropLast(trailingCount))
            out.append(String(leading) + groundInline(core, resolver: &resolver) + String(rest.suffix(trailingCount)))
        }
        return out.joined(separator: "|")
    }

    /// A row split at every pipe that is not escaped or inside a code span;
    /// the first piece is what precedes the first pipe.
    private static func tableCells(_ line: String) -> [String] {
        let characters = Array(line)
        var cells: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                current.append(character)
                current.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`" {
                var run = 0
                while index + run < characters.count, characters[index + run] == "`" { run += 1 }
                if let close = closingBacktickRun(characters, from: index + run, length: run) {
                    current.append(contentsOf: characters[index..<(close + run)])
                    index = close + run
                } else {
                    current.append(contentsOf: characters[index..<(index + run)])
                    index += run
                }
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current)
        return cells
    }

    /// One line of inline Markdown with its passages grounded.
    private static func groundInline(_ line: String, resolver: inout Resolver) -> String {
        let content = removingMarkersInLinks(line, resolver: &resolver)
        let markers = markerRanges(in: content)
        guard !markers.isEmpty else { return content }
        var segments: [Segment] = []
        var pending: [String] = []
        var cursor = content.startIndex
        for marker in markers {
            let passage = String(content[cursor..<marker.lowerBound])
            let ids = resolver.ids(forMarker: String(content[marker]))
            cursor = marker.upperBound
            place(passage, ids: ids, into: &segments, pending: &pending)
        }
        let trailing = String(content[cursor...])
        if !pending.isEmpty, trailing.contains(where: { !$0.isWhitespace }) {
            place(trailing, ids: [], into: &segments, pending: &pending, keepsTrailingSpace: true)
        } else if !trailing.isEmpty {
            segments.append(.plain(trailing))
        } else if case .plain(let last)? = segments.last {
            // The line ended on a marker: the space before it went with it.
            let kept = last.reversed().drop(while: \.isWhitespace).reversed()
            segments[segments.count - 1] = .plain(String(kept))
        }
        return segments.map { segment -> String in
            switch segment {
            case .plain(let text):
                return text
            case .grounded(let text, let ids):
                return "[\(escapingBrackets(text))](\(groundingDestination(ids)))" + resolver.footnote(for: ids)
            case .cited(let text, let ids):
                return text + resolver.footnote(for: ids)
            }
        }.joined()
    }

    /// The line with every marker inside a link's or a picture's text taken
    /// out, with the space before it: links never nest, so the grounding a
    /// marker becomes cannot sit there, and grounding the text around it
    /// would split the link. Such a marker still counts as a citation.
    private static func removingMarkersInLinks(_ content: String, resolver: inout Resolver) -> String {
        guard content.contains("]("), let linkExpression else { return content }
        let whole = NSRange(content.startIndex..<content.endIndex, in: content)
        let links = linkExpression.matches(in: content, range: whole).compactMap { Range($0.range, in: content) }
        let inside = markerRanges(in: content).filter { marker in
            links.contains { $0.lowerBound < marker.lowerBound && marker.upperBound < $0.upperBound }
        }
        guard !inside.isEmpty else { return content }
        var text = ""
        var cursor = content.startIndex
        for link in links {
            let markers = inside.filter { link.lowerBound < $0.lowerBound && $0.upperBound < link.upperBound }
            guard !markers.isEmpty else { continue }
            var ids: [String] = []
            for marker in markers {
                for id in resolver.ids(forMarker: String(content[marker])) where !ids.contains(id) { ids.append(id) }
                var end = marker.lowerBound
                if end > cursor, content[content.index(before: end)] == " " {
                    end = content.index(before: end)
                }
                text += content[cursor..<end]
                cursor = marker.upperBound
            }
            text += content[cursor..<link.upperBound]
            text += resolver.footnote(for: ids)
            cursor = link.upperBound
        }
        text += content[cursor...]
        return text
    }

    /// Characters a passage may start with that belong to the text before
    /// the marker, never to the claim after it. Straight quotes are left out:
    /// one may as well open the next claim.
    private static let closingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "\u{2026}", ")", "\u{201D}", "\u{2019}", "\u{00BB}",
    ]

    private static func place(
        _ passage: String,
        ids: [String],
        into segments: inout [Segment],
        pending: inout [String],
        keepsTrailingSpace: Bool = false
    ) {
        let lead = passage.prefix(while: { $0.isWhitespace || closingPunctuation.contains($0) })
        let body = passage.dropFirst(lead.count)
        let trailingSpace = body.reversed().prefix(while: \.isWhitespace).count
        let core = String(body.dropLast(trailingSpace))
        var all = pending
        for id in ids where !all.contains(id) { all.append(id) }
        pending = []

        if core.isEmpty {
            // Markers in a row ("… [S1] [S2]", "… [S1]. [S2]"): the later ones
            // join the passage the first grounded. Only space or punctuation
            // stands between them, and the space goes with the markers.
            let groundedIndex = segments.lastIndex { segment in
                switch segment {
                case .grounded, .cited: return true
                case .plain: return false
                }
            }
            let onlyPunctuationSince = groundedIndex.map { index in
                segments[(index + 1)...].allSatisfy { segment in
                    guard case .plain(let text) = segment else { return false }
                    return text.allSatisfy { $0.isWhitespace || closingPunctuation.contains($0) }
                }
            } ?? false
            let previous = groundedIndex.flatMap { index -> (String, [String], Bool)? in
                switch segments[index] {
                case .grounded(let text, let ids): return (text, ids, true)
                case .cited(let text, let ids): return (text, ids, false)
                case .plain: return nil
                }
            }
            guard let index = groundedIndex, onlyPunctuationSince, let (text, existing, isGrounded) = previous else {
                // A marker before any claim on its line: it grounds the next.
                if !lead.isEmpty { segments.append(.plain(String(lead))) }
                pending = all
                return
            }
            var merged = existing
            for id in all where !merged.contains(id) { merged.append(id) }
            segments[index] = isGrounded ? .grounded(text, merged) : .cited(text, merged)
            if lead.contains(where: { !$0.isWhitespace }) {
                segments.append(.plain(String(lead)))
            }
            return
        }
        // Space before the first claim on a line went with the marker there.
        if !lead.isEmpty, !(segments.isEmpty && lead.allSatisfy(\.isWhitespace)) {
            segments.append(.plain(String(lead)))
        }
        if all.isEmpty {
            segments.append(.plain(core))
        } else if isSafeLinkText(core) {
            segments.append(.grounded(core, all))
        } else {
            segments.append(.cited(core, all))
        }
        if keepsTrailingSpace, trailingSpace > 0 {
            segments.append(.plain(String(body.suffix(trailingSpace))))
        }
    }

    /// The markers in a line, outside its code spans.
    private static func markerRanges(in content: String) -> [Range<String.Index>] {
        guard let markerExpression else { return [] }
        let spans = codeSpanRanges(in: content)
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return markerExpression.matches(in: content, range: range).compactMap { match in
            guard let found = Range(match.range, in: content) else { return nil }
            return spans.contains(where: { $0.overlaps(found) }) ? nil : found
        }
    }

    /// Where a line's code spans are: a run of backticks to the next run of
    /// the same length, as CommonMark pairs them.
    private static func codeSpanRanges(in content: String) -> [Range<String.Index>] {
        let characters = Array(content)
        var offsets: [(Int, Int)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var run = 0
            while index + run < characters.count, characters[index + run] == "`" { run += 1 }
            if let close = closingBacktickRun(characters, from: index + run, length: run) {
                offsets.append((index, close + run))
                index = close + run
            } else {
                index += run
            }
        }
        return offsets.map { start, end in
            content.index(content.startIndex, offsetBy: start)..<content.index(content.startIndex, offsetBy: end)
        }
    }

    private static func closingBacktickRun(_ characters: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var run = 0
            while index + run < characters.count, characters[index + run] == "`" { run += 1 }
            if run == length { return index }
            index += run
        }
        return nil
    }

    /// Whether a passage can be a link's text as it is: no link, picture,
    /// raw HTML or bare address inside it (links never nest), no trailing
    /// backslash to eat the bracket that closes it, and emphasis, code and
    /// strikethrough that open and close within it. A lone dollar sign is
    /// prose ("a $20 million round"): inside a link's text it can pair with
    /// nothing outside it.
    static func isSafeLinkText(_ text: String) -> Bool {
        var outsideCode = text
        for span in codeSpanRanges(in: text).reversed() {
            outsideCode.replaceSubrange(span, with: "x")
        }
        if outsideCode.contains("](") || outsideCode.contains("![") { return false }
        let lowered = outsideCode.lowercased()
        if lowered.contains("http://") || lowered.contains("https://") || lowered.contains("www.") { return false }
        let range = NSRange(outsideCode.startIndex..<outsideCode.endIndex, in: outsideCode)
        if htmlOpening?.firstMatch(in: outsideCode, range: range) != nil { return false }
        if outsideCode.contains("`") { return false }
        if outsideCode.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 { return false }
        let characters = Array(outsideCode)
        func runs(of delimiter: Character, intrawordCounts: Bool) -> Int {
            var count = 0
            var index = 0
            while index < characters.count {
                guard characters[index] == delimiter, index == 0 || characters[index - 1] != "\\" else {
                    index += 1
                    continue
                }
                var end = index
                while end < characters.count, characters[end] == delimiter { end += 1 }
                let before = index > 0 ? characters[index - 1] : " "
                let after = end < characters.count ? characters[end] : " "
                let intraword = (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
                if intrawordCounts || !intraword { count += 1 }
                index = end
            }
            return count
        }
        if runs(of: "*", intrawordCounts: true) % 2 == 1 { return false }
        if runs(of: "_", intrawordCounts: false) % 2 == 1 { return false }
        if runs(of: "~", intrawordCounts: true) % 2 == 1 { return false }
        return true
    }

    /// A passage's square brackets escaped outside its code spans, so a
    /// bracket in the prose cannot end the link early.
    private static func escapingBrackets(_ text: String) -> String {
        let spans = codeSpanRanges(in: text)
        var result = ""
        var index = text.startIndex
        var backslashes = 0
        while index < text.endIndex {
            if let span = spans.first(where: { $0.lowerBound == index }) {
                result += text[span]
                index = span.upperBound
                backslashes = 0
                continue
            }
            let character = text[index]
            if (character == "[" || character == "]"), backslashes % 2 == 0 {
                result.append("\\")
            }
            result.append(character)
            backslashes = character == "\\" ? backslashes + 1 : 0
            index = text.index(after: index)
        }
        return result
    }
}
