import Foundation
import OSLog

// MARK: - Writing a source's reading levels
//
// docs/sensemaking-design.md, "Levels in the Reader". The learner presses
// Write Levels in the Reader's Levels panel (or an assistant asks for them
// with `get_source_levels`): the source's whole stored text is read on the
// Reading Levels task's model (`AITask.sourceLevels`, Settings › AI Models ›
// Background, Text), its paragraphs numbered ¶1…¶N by the app
// (`SourceLevelsText`). A text that fits the model's window and a modest
// number of paragraphs is one request; a longer one is written in
// consecutive parts, cut at the source's own headings where one is near,
// and a last request writes the gist, the findings and the terms from the
// parts (map, then reduce). The model names paragraphs only by number: every
// anchor is the app's, taken from the text. The levels are kept against the
// text's SHA-256 and written again only when the learner asks.

/// A source as the levels writer reads it: its whole stored text.
struct SourceLevelsSource: Sendable {
    let sourceID: String
    let title: String
    /// Its source type's raw value, for the usage ledger.
    let sourceType: String
    /// What it is in the writer's words: "research paper", "book chapter".
    let kindLabel: String
    let text: String
    let contentSHA256: String

    init(sourceID: String, title: String, sourceType: String, kindLabel: String, text: String) {
        self.sourceID = sourceID
        self.title = title
        self.sourceType = sourceType
        self.kindLabel = kindLabel
        self.text = text
        self.contentSHA256 = PaperContentPreparationService.sha256(text)
    }
}

enum SourceLevelsError: LocalizedError, Equatable {
    /// Signed out, no key or plan, or a broken route for the task.
    case noModelConfigured(String)
    case noText(String)
    /// A request would not fit the model's window as built, so the central
    /// trim would cut the text; refused instead.
    case wouldBeCut(model: String)
    /// The model's answer was not the JSON asked for, or held no gist.
    case unreadableAnswer(String)
    case notInLibrary(String)
    case keptFromAI

    var errorDescription: String? {
        switch self {
        case .noModelConfigured(let message):
            return message
        case .noText(let title):
            return "\u{201C}\(title)\u{201D} has no text yet to write levels from."
        case .wouldBeCut(let model):
            return "This source does not fit \(model)'s context window, and nothing is cut. Choose a model with a larger window for Reading Levels in Settings › AI Models › Background."
        case .unreadableAnswer(let detail):
            return "The model's answer could not be read as levels (\(detail)). Try again, or choose another Background text model."
        case .notInLibrary(let id):
            return "No library source answers to \(id)."
        case .keptFromAI:
            return "This source is kept from AI in Settings, so no levels are written for it."
        }
    }

    static var noModel: SourceLevelsError {
        .noModelConfigured(
            KeychainService.backgroundAIUnavailableMessage(for: .sourceLevels)
                ?? "No model is configured for Reading Levels. Sign in and check Settings › AI Models › Background."
        )
    }
}

/// How far a run has come, for the panel's progress line.
struct SourceLevelsProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    var label: String {
        total <= 1 ? "Writing levels…" : "Writing levels (part \(min(done + 1, total)) of \(total))…"
    }
}

// MARK: - The model, behind a protocol

/// The writing model, behind a protocol so a run is pinned in tests with
/// canned answers.
protocol SourceLevelsBackend: Sendable {
    /// The model's name, stored with the levels.
    var modelLabel: String? { get }
    /// Characters one request may carry, or nil when the model publishes no
    /// window.
    func inputBudget(requestedMaxTokens: Int) -> Int?
    /// One request's answer, as text.
    func write(system: String, user: String, maxTokens: Int, source: AIUsageSource) async throws -> String
}

/// Writes on the learner's Reading Levels route.
struct LiveSourceLevelsBackend: SourceLevelsBackend {
    let aiService: AIService
    let config: AITaskConfig

    var modelLabel: String? { KeychainService.routedTextConfig(config).model }

    func inputBudget(requestedMaxTokens: Int) -> Int? {
        let routed = KeychainService.routedTextConfig(config)
        return AIService.inputCharacterBudget(provider: routed.provider, model: routed.model, requestedMaxTokens: requestedMaxTokens)
    }

    func write(system: String, user: String, maxTokens: Int, source: AIUsageSource) async throws -> String {
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = AIService.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: system,
            user: user,
            requestedMaxTokens: maxTokens
        )
        guard budgeted.system == system, budgeted.user == user else {
            throw SourceLevelsError.wouldBeCut(model: routed.model)
        }
        return try await AIUsageAttribution.withSource(source, activityID: AIUsageAttribution.activityID ?? UUID().uuidString) {
            try await aiService.call(
                config: config,
                system: system,
                user: user,
                maxTokens: maxTokens,
                temperature: 0.2,
                // The learner waits in the Reader for these. Hidden thinking
                // was five sixths of a paper's answer and two of its three
                // minutes, for lines that summarize what the text says.
                disablesReasoning: true,
                // Rewrite asks again; a kept reply would answer it with the
                // levels the learner is replacing.
                allowsResponseCache: false,
                jsonMode: true
            )
        }
    }
}

// MARK: - The builder

enum SourceLevelsBuilder {
    typealias Block = SourceLevelsText.Block

    /// The most paragraphs one request writes lines for: about 4,000 tokens
    /// of answer, which every Background model can give.
    static let maximumParagraphsPerRequest = 110
    static let maximumSections = 60
    static let maximumFindings = 4
    static let maximumTerms = 12
    /// A line past this is cut at a word.
    static let maximumLineCharacters = 320
    /// How many parts are written at once.
    static let partConcurrency = 3
    static let requestOverheadCharacters = AIService.perMessageOverheadChars
    /// Below this much room for its text a request is no reading of it.
    static let minimumPartCharacters = 4_000

    private static let logger = Logger(subsystem: "com.foreverlm", category: "SourceLevels")

    // MARK: Plan

    /// The answer one request asks room for.
    static func maxTokens(paragraphs: Int, whole: Bool) -> Int {
        min(16_000, (whole ? 1_400 : 700) + max(1, paragraphs) * 36)
    }

    /// The most any request asks for, which the route's window is sized by.
    static var largestMaxTokens: Int {
        maxTokens(paragraphs: maximumParagraphsPerRequest, whole: true)
    }

    /// The blocks as the requests that write them: all in one when the
    /// paragraphs are few enough and the text fits the window, else
    /// consecutive parts of about equal size, each cut before a heading near
    /// its mark when there is one. Nil when the window has no room for a
    /// part at all. `fixedCharacters` is what a request carries besides the
    /// numbered text (the system prompt and the message's head).
    static func parts(of blocks: [Block], fixedCharacters: Int, inputBudget: Int?) -> [[Block]]? {
        let paragraphCount = blocks.filter { $0.kind == .paragraph }.count
        guard paragraphCount > 0 else { return [] }
        func size(_ slice: ArraySlice<Block>) -> Int {
            slice.reduce(0) { $0 + $1.text.count + 8 }
        }
        func fits(_ slice: ArraySlice<Block>) -> Bool {
            guard let inputBudget else { return true }
            return fixedCharacters + size(slice) + requestOverheadCharacters <= inputBudget
        }
        if paragraphCount <= maximumParagraphsPerRequest, fits(blocks[...]) { return [blocks] }
        if let inputBudget, inputBudget - fixedCharacters - requestOverheadCharacters < minimumPartCharacters { return nil }

        var count = max(2, Int((Double(paragraphCount) / Double(maximumParagraphsPerRequest)).rounded(.up)))
        if let inputBudget {
            let room = Double(inputBudget - fixedCharacters - requestOverheadCharacters) * 0.85
            count = max(count, Int((Double(size(blocks[...])) / room).rounded(.up)))
        }
        let most = count * 3 + 8
        while count <= most {
            let pieces = split(blocks, into: count)
            if pieces.allSatisfy({ fits($0[...]) && $0.filter { $0.kind == .paragraph }.count <= maximumParagraphsPerRequest }) {
                return pieces
            }
            count += 1
        }
        return nil
    }

    /// `blocks` in `count` consecutive parts of about equal numbers of
    /// paragraphs, each cut before the heading nearest its mark within a
    /// quarter of a part either side, else at the mark. A heading stays with
    /// the paragraphs it heads, and no part is empty of paragraphs.
    static func split(_ blocks: [Block], into count: Int) -> [[Block]] {
        let paragraphIndexes = blocks.indices.filter { blocks[$0].kind == .paragraph }
        guard count > 1, paragraphIndexes.count >= count else { return [blocks] }
        let perPart = Double(paragraphIndexes.count) / Double(count)
        let reach = max(1, Int(perPart / 4))
        var cuts: [Int] = []
        var previous = 0
        for part in 1..<count {
            let markParagraph = Int((Double(part) * perPart).rounded())
            let low = max(1, markParagraph - reach)
            let high = min(paragraphIndexes.count - 1, markParagraph + reach)
            guard low <= high else { continue }
            // A cut is a paragraph's block index: the part starts there, or at
            // the heading right above it.
            func start(ofParagraph ordinal: Int) -> Int {
                var index = paragraphIndexes[ordinal]
                while index > 0, blocks[index - 1].kind == .heading { index -= 1 }
                return index
            }
            let headed = (low...high).filter { ordinal in
                let index = paragraphIndexes[ordinal]
                return index > 0 && blocks[index - 1].kind == .heading
            }
            let chosen = headed.min { abs($0 - markParagraph) < abs($1 - markParagraph) } ?? min(max(markParagraph, low), high)
            let cut = start(ofParagraph: chosen)
            guard cut > previous else { continue }
            cuts.append(cut)
            previous = cut
        }
        var pieces: [[Block]] = []
        var start = 0
        for cut in cuts + [blocks.count] where cut > start {
            pieces.append(Array(blocks[start..<cut]))
            start = cut
        }
        return pieces.filter { $0.contains { $0.kind == .paragraph } }
    }

    // MARK: Turns

    private static func head(_ source: SourceLevelsSource) -> [String] {
        ["Source: \(singleLine(source.title))", "Kind: \(source.kindLabel)"]
    }

    static func wholeMessage(_ source: SourceLevelsSource, blocks: [Block]) -> String {
        let numbers = blocks.compactMap(\.number)
        var lines = head(source)
        lines.append("Write: the whole source")
        lines.append("Paragraphs: ¶\(numbers.first ?? 1) to ¶\(numbers.last ?? 1)")
        lines.append("Answer as: {\"gist\", \"why\", \"findings\": [{\"text\", \"section\"}], \"sections\": [{\"start\", \"title\", \"line\"}], \"paragraphs\": [{\"n\", \"line\"}], \"terms\": [{\"term\", \"definition\", \"paragraph\"}]}")
        lines.append("")
        lines.append("Text:")
        lines.append(SourceLevelsText.numberedText(blocks))
        return lines.joined(separator: "\n")
    }

    static func partMessage(_ source: SourceLevelsSource, part: Int, of count: Int, blocks: [Block]) -> String {
        let numbers = blocks.compactMap(\.number)
        var lines = head(source)
        lines.append("Write: part \(part) of \(count)")
        lines.append("Paragraphs in this part: ¶\(numbers.first ?? 1) to ¶\(numbers.last ?? 1)")
        lines.append("Answer as: {\"summary\", \"sections\": [{\"start\", \"title\", \"line\"}], \"paragraphs\": [{\"n\", \"line\"}], \"terms\": [{\"term\", \"definition\", \"paragraph\"}]}")
        lines.append("")
        lines.append("Text [part \(part) of \(count)]:")
        lines.append(SourceLevelsText.numberedText(blocks))
        return lines.joined(separator: "\n")
    }

    static func mergeMessage(
        _ source: SourceLevelsSource,
        sections: [WrittenSection],
        summaries: [String],
        candidates: [WrittenTerm]
    ) -> String {
        var lines = head(source)
        lines.append("Write: the whole source from its parts")
        lines.append("Answer as: {\"gist\", \"why\", \"findings\": [{\"text\", \"section\"}], \"terms\": [{\"term\", \"definition\"}]}")
        lines.append("")
        lines.append("Sections:")
        for (index, section) in sections.enumerated() {
            lines.append("S\(index + 1) \(singleLine(section.title)) — \(singleLine(section.line))")
        }
        lines.append("")
        lines.append("Parts:")
        for (index, summary) in summaries.enumerated() {
            lines.append("Part \(index + 1): \(singleLine(summary))")
        }
        lines.append("")
        lines.append("Candidate terms:")
        for term in candidates {
            lines.append("- \(singleLine(term.term)): \(singleLine(term.definition))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: The model's answers

    struct WrittenSection: Equatable, Sendable {
        var start: Int
        var title: String
        var line: String
    }

    struct WrittenTerm: Equatable, Sendable {
        var term: String
        var definition: String
        var paragraph: Int?
    }

    struct WrittenFinding: Equatable, Sendable {
        var text: String
        /// As the model numbered it, from 1.
        var section: Int?
    }

    /// One request for the whole source.
    struct WrittenWhole: Equatable, Sendable {
        var gist: String
        var why: String
        var findings: [WrittenFinding]
        var sections: [WrittenSection]
        var lines: [Int: String]
        var terms: [WrittenTerm]
    }

    /// One part of a long source.
    struct WrittenPart: Equatable, Sendable {
        var summary: String
        var sections: [WrittenSection]
        var lines: [Int: String]
        var terms: [WrittenTerm]
    }

    /// The last request of a long source.
    struct WrittenMerge: Equatable, Sendable {
        var gist: String
        var why: String
        var findings: [WrittenFinding]
        var terms: [WrittenTerm]
    }

    static func parseWhole(_ response: String, paragraphs: ClosedRange<Int>) throws -> WrittenWhole {
        let object = try jsonObject(response)
        let gist = text(object["gist"])
        guard !gist.isEmpty else { throw SourceLevelsError.unreadableAnswer("no gist") }
        return WrittenWhole(
            gist: gist,
            why: text(object["why"]),
            findings: findings(object["findings"]),
            sections: sections(object["sections"], within: paragraphs),
            lines: lines(object["paragraphs"], within: paragraphs),
            terms: terms(object["terms"], within: paragraphs)
        )
    }

    static func parsePart(_ response: String, paragraphs: ClosedRange<Int>) throws -> WrittenPart {
        let object = try jsonObject(response)
        let part = WrittenPart(
            summary: text(object["summary"]),
            sections: sections(object["sections"], within: paragraphs),
            lines: lines(object["paragraphs"], within: paragraphs),
            terms: terms(object["terms"], within: paragraphs)
        )
        guard !part.lines.isEmpty || !part.sections.isEmpty else {
            throw SourceLevelsError.unreadableAnswer("no paragraph lines")
        }
        return part
    }

    static func parseMerge(_ response: String) throws -> WrittenMerge {
        let object = try jsonObject(response)
        let gist = text(object["gist"])
        guard !gist.isEmpty else { throw SourceLevelsError.unreadableAnswer("no gist") }
        return WrittenMerge(
            gist: gist,
            why: text(object["why"]),
            findings: findings(object["findings"]),
            // A chosen term with no definition keeps its candidate's.
            terms: terms(object["terms"], within: nil, requiresDefinition: false)
        )
    }

    private static func jsonObject(_ response: String) throws -> [String: Any] {
        guard let object = ModelJSON.object(response) else {
            throw SourceLevelsError.unreadableAnswer("not JSON")
        }
        return object
    }

    /// A number the model wrote as 12, 12.0, "12" or "¶12". (A JSON 1 also
    /// reads as `true` through NSNumber, so no Bool test comes first.)
    static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String {
            let digits = value.filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }
        return nil
    }

    private static func text(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        return singleLine(value)
    }

    private static func findings(_ value: Any?) -> [WrittenFinding] {
        (value as? [Any] ?? []).compactMap { item in
            if let string = item as? String {
                let line = singleLine(string)
                return line.isEmpty ? nil : WrittenFinding(text: line, section: nil)
            }
            guard let entry = item as? [String: Any] else { return nil }
            let line = text(entry["text"])
            guard !line.isEmpty else { return nil }
            return WrittenFinding(text: line, section: number(entry["section"]))
        }
    }

    private static func sections(_ value: Any?, within range: ClosedRange<Int>) -> [WrittenSection] {
        (value as? [Any] ?? []).compactMap { item in
            guard let entry = item as? [String: Any],
                  let start = number(entry["start"]), range.contains(start) else { return nil }
            let title = text(entry["title"])
            let line = text(entry["line"])
            guard !title.isEmpty || !line.isEmpty else { return nil }
            return WrittenSection(start: start, title: title, line: line)
        }
    }

    private static func lines(_ value: Any?, within range: ClosedRange<Int>) -> [Int: String] {
        var lines: [Int: String] = [:]
        for item in value as? [Any] ?? [] {
            guard let entry = item as? [String: Any],
                  let index = number(entry["n"] ?? entry["paragraph"] ?? entry["index"]),
                  range.contains(index), lines[index] == nil else { continue }
            let line = text(entry["line"])
            if !line.isEmpty { lines[index] = line }
        }
        return lines
    }

    private static func terms(_ value: Any?, within range: ClosedRange<Int>?, requiresDefinition: Bool = true) -> [WrittenTerm] {
        var seen = Set<String>()
        return (value as? [Any] ?? []).compactMap { item in
            guard let entry = item as? [String: Any] else { return nil }
            let term = text(entry["term"])
            let definition = text(entry["definition"])
            guard !term.isEmpty, !definition.isEmpty || !requiresDefinition, seen.insert(term.lowercased()).inserted else { return nil }
            var paragraph = number(entry["paragraph"])
            if let found = paragraph, let range, !range.contains(found) { paragraph = nil }
            return WrittenTerm(term: term, definition: definition, paragraph: paragraph)
        }
    }

    /// One line: whitespace runs to one space, trimmed, cut at a word past
    /// `maximumLineCharacters`.
    static func singleLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > maximumLineCharacters else { return collapsed }
        var cut = String(collapsed.prefix(maximumLineCharacters))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut + "\u{2026}"
    }

    // MARK: Assembly

    /// The levels from what was written: sections ordered and cut to cover
    /// every paragraph from the first, each paragraph with its line and the
    /// anchor taken from the text, findings and terms checked against them.
    /// `findingSectionStart` turns a finding's written section number into the
    /// ¶ number that section starts at.
    static func assemble(
        source: SourceLevelsSource,
        paragraphs: [Block],
        sections written: [WrittenSection],
        lines: [Int: String],
        gist: String,
        why: String,
        findings: [WrittenFinding],
        findingSectionStart: (Int) -> Int?,
        terms: [WrittenTerm],
        model: String?,
        now: Date = Date()
    ) -> SourceLevels {
        let numbers = paragraphs.compactMap(\.number)
        let textByNumber = Dictionary(paragraphs.compactMap { block in block.number.map { ($0, block.text) } }, uniquingKeysWith: { first, _ in first })
        guard let first = numbers.first else {
            return SourceLevels(sourceID: source.sourceID, contentSHA256: source.contentSHA256, gist: gist, why: why,
                                findings: [], sections: [], terms: [], model: model, createdAt: now)
        }

        // Ordered, one section a start, the first at the first paragraph.
        var ordered: [WrittenSection] = []
        for section in written.sorted(by: { $0.start < $1.start }) where textByNumber[section.start] != nil {
            if ordered.last?.start == section.start { continue }
            ordered.append(section)
        }
        if ordered.count > maximumSections { ordered = Array(ordered.prefix(maximumSections)) }
        if ordered.isEmpty {
            ordered = [WrittenSection(start: first, title: source.title, line: gist)]
        } else {
            ordered[0].start = first
        }

        var sections: [SourceLevels.Section] = []
        for (index, section) in ordered.enumerated() {
            let end = index + 1 < ordered.count ? ordered[index + 1].start : Int.max
            let members = numbers.filter { $0 >= section.start && $0 < end }
            sections.append(SourceLevels.Section(
                title: section.title.isEmpty ? "Section \(index + 1)" : section.title,
                line: section.line,
                paragraphs: members.map { number in
                    SourceLevels.Paragraph(
                        index: number,
                        line: lines[number] ?? "",
                        anchor: SourceLevelsText.anchor(of: textByNumber[number] ?? "")
                    )
                }
            ))
        }

        func sectionIndex(containing paragraph: Int) -> Int? {
            sections.firstIndex { $0.paragraphs.contains { $0.index == paragraph } }
        }
        let checkedFindings = findings.prefix(maximumFindings).map { finding in
            SourceLevels.Finding(
                text: finding.text,
                sectionIndex: finding.section.flatMap(findingSectionStart).flatMap(sectionIndex(containing:))
            )
        }

        var seen = Set<String>()
        var checkedTerms: [SourceLevels.Term] = []
        for term in terms where checkedTerms.count < maximumTerms && seen.insert(term.term.lowercased()).inserted {
            // The paragraph the model named, when it is one of the text's and
            // names the term; else the first paragraph that does.
            var paragraph = term.paragraph.flatMap { textByNumber[$0] != nil ? $0 : nil }
            if paragraph.flatMap({ textByNumber[$0] }).flatMap({ SourceLevelsText.sentence(naming: term.term, in: $0) }) == nil,
               let named = numbers.first(where: { SourceLevelsText.sentence(naming: term.term, in: textByNumber[$0] ?? "") != nil }) {
                paragraph = named
            }
            let anchor = paragraph.flatMap { number -> String? in
                guard let text = textByNumber[number] else { return nil }
                if let sentence = SourceLevelsText.sentence(naming: term.term, in: text) {
                    return SourceLevelsText.anchor(of: sentence, words: 24)
                }
                return SourceLevelsText.anchor(of: text)
            }
            checkedTerms.append(SourceLevels.Term(
                term: term.term,
                definition: term.definition,
                paragraphIndex: paragraph,
                anchor: anchor
            ))
        }

        return SourceLevels(
            sourceID: source.sourceID,
            contentSHA256: source.contentSHA256,
            gist: gist,
            why: why,
            findings: Array(checkedFindings),
            sections: sections,
            terms: checkedTerms,
            model: model,
            createdAt: now
        )
    }

    /// The levels of a source written in one request.
    static func levels(whole: WrittenWhole, source: SourceLevelsSource, paragraphs: [Block], model: String?, now: Date = Date()) -> SourceLevels {
        let starts = whole.sections.map(\.start)
        return assemble(
            source: source,
            paragraphs: paragraphs,
            sections: whole.sections,
            lines: whole.lines,
            gist: whole.gist,
            why: whole.why,
            findings: whole.findings,
            findingSectionStart: { number in number >= 1 && number <= starts.count ? starts[number - 1] : nil },
            terms: whole.terms,
            model: model,
            now: now
        )
    }

    /// The sections of a long source's parts, in order: a part whose first
    /// section carries on the last section of the part before it (the same
    /// title, starting at the part's first paragraph) adds no new section.
    static func mergedSections(_ parts: [(firstParagraph: Int, written: WrittenPart)]) -> [WrittenSection] {
        var merged: [WrittenSection] = []
        for part in parts {
            for section in part.written.sections.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last {
                    if section.start <= last.start { continue }
                    if section.start == part.firstParagraph,
                       section.title.caseInsensitiveCompare(last.title) == .orderedSame { continue }
                }
                merged.append(section)
            }
        }
        return merged
    }

    /// The candidate terms of a long source's parts, the first of each name.
    static func candidateTerms(_ parts: [WrittenPart]) -> [WrittenTerm] {
        var seen = Set<String>()
        return parts.flatMap(\.terms).filter { seen.insert($0.term.lowercased()).inserted }
    }

    /// The levels of a long source from its parts and the last request. A
    /// term the last request chose keeps the paragraph its part found it in;
    /// its definition is the last request's when it wrote one.
    static func levels(
        parts: [(firstParagraph: Int, written: WrittenPart)],
        merge: WrittenMerge,
        source: SourceLevelsSource,
        paragraphs: [Block],
        model: String?,
        now: Date = Date()
    ) -> SourceLevels {
        let sections = mergedSections(parts)
        var lines: [Int: String] = [:]
        for part in parts {
            lines.merge(part.written.lines) { first, _ in first }
        }
        let candidates = candidateTerms(parts.map(\.written))
        let byName = Dictionary(candidates.map { ($0.term.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = merge.terms.isEmpty ? candidates : merge.terms.map { term -> WrittenTerm in
            let candidate = byName[term.term.lowercased()]
            return WrittenTerm(
                term: candidate?.term ?? term.term,
                definition: term.definition.isEmpty ? (candidate?.definition ?? "") : term.definition,
                paragraph: candidate?.paragraph
            )
        }
        let starts = sections.map(\.start)
        return assemble(
            source: source,
            paragraphs: paragraphs,
            sections: sections,
            lines: lines,
            gist: merge.gist,
            why: merge.why,
            findings: merge.findings,
            findingSectionStart: { number in number >= 1 && number <= starts.count ? starts[number - 1] : nil },
            terms: chosen.filter { !$0.definition.isEmpty },
            model: model,
            now: now
        )
    }

    // MARK: The run

    /// One part's request, built before any is sent.
    struct PartRequest: Sendable {
        let index: Int
        let user: String
        let maxTokens: Int
        let paragraphs: ClosedRange<Int>
    }

    private static func writePart(
        _ request: PartRequest,
        system: String,
        backend: any SourceLevelsBackend,
        usage: AIUsageSource
    ) async throws -> WrittenPart {
        let response = try await backend.write(system: system, user: request.user, maxTokens: request.maxTokens, source: usage)
        try Task.checkCancellation()
        return try parsePart(response, paragraphs: request.paragraphs)
    }

    /// Writes `source`'s levels: one request, or its parts a few at a time
    /// and then the request that joins them. Throws for cancellation, a
    /// failed request, or an answer that cannot be read; nothing is saved
    /// here (`SourceLevelsWriter.write` saves).
    static func write(
        _ source: SourceLevelsSource,
        system: String,
        backend: any SourceLevelsBackend,
        onProgress: @escaping @Sendable (SourceLevelsProgress) async -> Void = { _ in }
    ) async throws -> SourceLevels {
        let blocks = SourceLevelsText.blocks(of: source.text)
        let paragraphs = SourceLevelsText.paragraphs(blocks)
        guard let firstNumber = paragraphs.first?.number, let lastNumber = paragraphs.last?.number else {
            throw SourceLevelsError.noText(source.title)
        }
        let usage = AIUsageSource(id: source.sourceID, type: source.sourceType.isEmpty ? "source" : source.sourceType, title: source.title)
        // A part's head is a few words longer than the whole's.
        let fixed = system.count + wholeMessage(source, blocks: []).count + 200
        guard let pieces = parts(of: blocks, fixedCharacters: fixed, inputBudget: backend.inputBudget(requestedMaxTokens: largestMaxTokens)) else {
            throw SourceLevelsError.wouldBeCut(model: backend.modelLabel ?? "The model")
        }

        if pieces.count <= 1 {
            await onProgress(SourceLevelsProgress(done: 0, total: 1))
            let response = try await backend.write(
                system: system,
                user: wholeMessage(source, blocks: blocks),
                maxTokens: maxTokens(paragraphs: paragraphs.count, whole: true),
                source: usage
            )
            try Task.checkCancellation()
            let whole = try parseWhole(response, paragraphs: firstNumber...lastNumber)
            return levels(whole: whole, source: source, paragraphs: paragraphs, model: backend.modelLabel)
        }

        let total = pieces.count + 1
        await onProgress(SourceLevelsProgress(done: 0, total: total))
        let requests: [PartRequest] = pieces.enumerated().map { index, piece in
            let numbers = piece.compactMap(\.number)
            return PartRequest(
                index: index,
                user: partMessage(source, part: index + 1, of: pieces.count, blocks: piece),
                maxTokens: maxTokens(paragraphs: numbers.count, whole: false),
                paragraphs: (numbers.first ?? firstNumber)...(numbers.last ?? lastNumber)
            )
        }
        var written: [Int: WrittenPart] = [:]
        try await withThrowingTaskGroup(of: (Int, WrittenPart).self) { group in
            var next = 0
            while next < min(partConcurrency, requests.count) {
                let request = requests[next]
                group.addTask {
                    // Bound before the tuple is built: a tuple around a `try
                    // await` in a task closure miscompiles at -O (AGENTS.md).
                    let part = try await writePart(request, system: system, backend: backend, usage: usage)
                    return (request.index, part)
                }
                next += 1
            }
            while let (index, part) = try await group.next() {
                written[index] = part
                await onProgress(SourceLevelsProgress(done: written.count, total: total))
                if next < requests.count {
                    let request = requests[next]
                    group.addTask {
                        let part = try await writePart(request, system: system, backend: backend, usage: usage)
                        return (request.index, part)
                    }
                    next += 1
                }
            }
        }
        try Task.checkCancellation()
        let ordered: [(firstParagraph: Int, written: WrittenPart)] = pieces.indices.compactMap { index in
            guard let part = written[index] else { return nil }
            return (pieces[index].compactMap(\.number).first ?? firstNumber, part)
        }
        let sections = mergedSections(ordered)
        let response = try await backend.write(
            system: system,
            user: mergeMessage(
                source,
                sections: sections,
                summaries: ordered.map(\.written.summary),
                candidates: candidateTerms(ordered.map(\.written))
            ),
            maxTokens: 2_400,
            source: usage
        )
        try Task.checkCancellation()
        let merge = try parseMerge(response)
        logger.notice("Wrote reading levels in \(pieces.count) part(s) for a source of \(paragraphs.count) paragraph(s)")
        return levels(parts: ordered, merge: merge, source: source, paragraphs: paragraphs, model: backend.modelLabel)
    }
}

// MARK: - Reading the source and saving

enum SourceLevelsWriter {
    /// Reads a source the way the levels are written from it: its whole
    /// stored text. Refuses one the learner keeps from AI.
    static func load(sourceID: String, storage: StorageService) async throws -> SourceLevelsSource {
        guard let article = try await storage.loadSourceWithoutContent(sourceID) else {
            throw SourceLevelsError.notInLibrary(sourceID)
        }
        let excluded = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !KnowledgeStore.isBlockedFromOpening(sourceID, excluded: excluded) else { throw SourceLevelsError.keptFromAI }
        let text = await storage.loadSourceContent(sourceID) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceLevelsError.noText(article.title)
        }
        return SourceLevelsSource(
            sourceID: sourceID,
            title: article.title,
            sourceType: article.sourceType.rawValue,
            kindLabel: NotebookSourceKind.label(article.sourceType),
            text: text
        )
    }

    /// Writes a source's levels on the learner's Reading Levels route and
    /// saves them against its text. `backend` stands in for the model in
    /// tests.
    static func write(
        sourceID: String,
        storage: StorageService,
        backend: (any SourceLevelsBackend)? = nil,
        onProgress: @escaping @Sendable (SourceLevelsProgress) async -> Void = { _ in }
    ) async throws -> SourceLevels {
        let source = try await load(sourceID: sourceID, storage: storage)
        let writer: any SourceLevelsBackend
        if let backend {
            writer = backend
        } else {
            guard let config = KeychainService.resolveConfig(for: .sourceLevels) else { throw SourceLevelsError.noModel }
            writer = LiveSourceLevelsBackend(aiService: AIService(), config: config)
        }
        let system = AITask.sourceLevels.effectivePrompt ?? Prompts.sourceLevels
        // A long source's requests are one piece of work in the usage ledger.
        let levels = try await AIUsageAttribution.$activityID.withValue(UUID().uuidString) {
            try await SourceLevelsBuilder.write(source, system: system, backend: writer, onProgress: onProgress)
        }
        try Task.checkCancellation()
        try await storage.saveSourceLevels(levels)
        return levels
    }
}
