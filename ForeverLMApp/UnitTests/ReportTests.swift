import Foundation
import Testing
@testable import ForeverLM

/// What the writer and the condensing pass were handed.
private final class ReportCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWrites: [(system: String, user: String)] = []
    private var storedParts: [ReportCondensePart] = []

    var writes: [(system: String, user: String)] {
        lock.lock(); defer { lock.unlock() }
        return storedWrites
    }

    var parts: [ReportCondensePart] {
        lock.lock(); defer { lock.unlock() }
        return storedParts
    }

    func recordWrite(system: String, user: String) {
        lock.lock(); defer { lock.unlock() }
        storedWrites.append((system, user))
    }

    func recordPart(_ part: ReportCondensePart) {
        lock.lock(); defer { lock.unlock() }
        storedParts.append(part)
    }
}

/// Answers with canned text, so the storage side and the planner can be
/// pinned without a provider.
private struct CannedReportBackend: ReportModelBackend {
    var draft = ReportDraft(
        title: "Briefing: complex I",
        markdown: "## Overview\n\nComplex I pumps protons. [S1] Its supercomplexes are still debated [S2].\n\n- **Respirasome**: complexes I, III and IV together [S1, S2]"
    )
    var recorder: ReportCallRecorder? = nil
    /// What each condensing call answers; nil for a short canned account.
    var account: (@Sendable (ReportCondensePart) -> String)? = nil

    func condense(_ part: ReportCondensePart, route: NotebookWritingRoute) async throws -> String {
        recorder?.recordPart(part)
        return account?(part) ?? "Condensed account of \(part.sourceTitle), part \(part.index)."
    }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: NotebookWritingRoute
    ) async throws -> ReportDraft {
        recorder?.recordWrite(system: system, user: user)
        return draft
    }
}

/// A writer whose answer has no report.
private struct FailingReportBackend: ReportModelBackend {
    func condense(_ part: ReportCondensePart, route: NotebookWritingRoute) async throws -> String { "Condensed." }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: NotebookWritingRoute
    ) async throws -> ReportDraft {
        throw ReportGenerationError.emptyReport
    }
}

/// A provider that answers after the run was cancelled.
private struct LateReportBackend: ReportModelBackend {
    func condense(_ part: ReportCondensePart, route: NotebookWritingRoute) async throws -> String { "Condensed." }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: NotebookWritingRoute
    ) async throws -> ReportDraft {
        while !Task.isCancelled { await Task.yield() }
        return ReportDraft(title: "Late", markdown: "Arrived anyway. [S1]")
    }
}

private func makeTemporaryStorage() -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReportTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

@discardableResult
private func seedSource(
    _ storage: StorageService,
    url: String,
    title: String,
    type: StudioSourceType = .article,
    content: String?
) async throws -> StudioArticle {
    var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual)
    if let content {
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
    }
    try await storage.saveSource(article)
    return article
}

private func makeNotebook(_ storage: StorageService, title: String, sourceIDs: [String]) async throws -> LearningGoalRecord {
    try await storage.createCompanionGoal(
        title: title,
        topic: title,
        startAt: Date(),
        endAt: LearningGoalRecord.openEndedEndAt,
        dailyTarget: 3,
        discoveryEnabled: false,
        seedSourceIDs: sourceIDs
    )
}

/// A route with the window and price the test names; the model is unknown to
/// every catalog, so the run's own window check has nothing to trim against.
private func testRoute(
    writerBudget: Int? = nil,
    condenserBudget: Int? = nil,
    input: Double? = 1,
    output: Double? = 2
) -> NotebookWritingRoute {
    NotebookWritingRoute(
        provider: .openRouter,
        model: "test/report-writer",
        writerInputBudget: writerBudget,
        condenserInputBudget: condenserBudget,
        inputUSDPerMillion: input,
        outputUSDPerMillion: output
    )
}

private func candidate(id: String, title: String, text: String, ideas: String? = nil) -> NotebookSourceSet.Candidate {
    var source = StudioArticle(url: "https://example.org/\(id)", title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
    source.state = .ready
    return NotebookSourceSet.Candidate(source: source, text: text, ideas: ideas)
}

private func notebook(
    _ candidates: [NotebookSourceSet.Candidate],
    skipped: [NotebookSourceSet.Skipped] = [],
    documents: [ReportNotebook.Document] = [],
    title: String = "Mitochondria"
) -> ReportNotebook {
    ReportNotebook(
        sources: NotebookSourceSet(notebookID: "p", title: title, instructions: nil, candidates: candidates, skipped: skipped),
        documents: documents
    )
}

private let citationSources = [
    ReportCitations.Source(id: "src_a", title: "Paper A", readAs: .whole),
    ReportCitations.Source(id: "src_b", title: "Book [B]", readAs: .condensed),
    ReportCitations.Source(id: "src c", title: "Talk C", readAs: .ideas),
]

@Suite("Report")
struct ReportTests {

    // MARK: - Formats and options

    @Test("The five formats: their words, what each needs, and a study guide's quiz and glossary")
    func formats() {
        #expect(ReportFormat.allCases.map(\.rawValue) == ["briefing", "study_guide", "meeting_questions", "document_feedback", "custom"])
        #expect(ReportFormat.allCases.map(\.label) == ["Briefing", "Study guide", "Questions for a meeting", "Feedback on a document", "Custom"])
        // The Report menu's words, as the Studio column's tile and the
        // Notebook menu list them (`ReportEntry.Format`).
        #expect(ReportEntry.Format.allCases.map(\.title)
            == ["Briefing", "Study guide", "Questions for a meeting", "Feedback on a document", "Custom…"])
        #expect(ReportFormat.default == .briefing)
        #expect(ReportFormat.allCases.filter(\.needsSubject) == [.documentFeedback])
        #expect(ReportFormat.allCases.filter(\.needsInstruction) == [.custom])
        #expect(ReportFormat.allCases.filter { !$0.takesFocus } == [.custom])
        for format in ReportFormat.allCases {
            #expect(format.wordRange.lowerBound < format.wordRange.upperBound)
            #expect(format.writerBrief.hasPrefix(format.label))
        }
        let guide = ReportFormat.studyGuide.writerBrief
        for heading in ["Overview", "Quiz", "Answer key", "Essay questions", "Glossary"] {
            #expect(guide.contains(heading), "\(heading)")
        }
        #expect(guide.contains("ten short-answer questions"))
        #expect(ReportFormat.documentFeedback.writerBrief.contains("quoted exactly"))
        #expect(ReportFormat.meetingQuestions.writerBrief.contains("three questions"))
        #expect(ReportStage.writing(.studyGuide).label == "Writing the study guide")
        #expect(ReportStage.condensing(done: 1, total: 3, sourceCount: 1).label == "Condensing 1 long source (2 of 3)")
    }

    @Test("A focus is for every format but custom, an instruction only for custom, a document only for feedback")
    func options() {
        let subject = ReportSubject(kind: .source, id: "a", title: "A")
        let briefing = ReportOptions(format: .briefing, focus: " complex I ", instruction: "ignored", subject: subject)
        #expect(briefing.trimmedFocus == "complex I")
        #expect(briefing.trimmedInstruction == nil)
        #expect(briefing.effectiveSubject == nil)
        #expect(briefing.gap == nil)

        let custom = ReportOptions(format: .custom, focus: "ignored", instruction: "  ")
        #expect(custom.trimmedFocus == nil)
        #expect(custom.gap == .instruction)
        #expect(ReportOptions(format: .custom, instruction: " A memo ").trimmedInstruction == "A memo")

        #expect(ReportOptions(format: .documentFeedback).gap == .subject)
        let feedback = ReportOptions(format: .documentFeedback, subject: subject)
        #expect(feedback.gap == nil)
        #expect(feedback.effectiveSubject == subject)
    }

    // MARK: - The writer's turn

    @Test("The turn leads with the instruction or focus, numbers each source for its marker, and says how each was read")
    func writerTurn() {
        let turn = ReportWriterTurn.userMessage(
            notebookTitle: "Mitochondria",
            instructions: "For a physiologist.",
            options: ReportOptions(format: .briefing, focus: "complex I"),
            subjectDocument: nil,
            sources: [
                ReportTurnSource(number: 1, title: "Paper A", kind: "research paper", author: "Lane N", venue: "Cell", year: "2024", readAs: .whole, text: "Whole text."),
                ReportTurnSource(number: 2, title: "Book B", kind: "book chapter", readAs: .ideas, text: "- An idea."),
                ReportTurnSource(number: 3, title: "Talk C", kind: "video transcript", readAs: .condensed, text: "An account."),
            ]
        )
        #expect(turn.components(separatedBy: "\n").first == "Focus: complex I")
        #expect(turn.contains("Notebook: Mitochondria"))
        #expect(turn.contains("Notebook instructions: For a physiologist."))
        #expect(turn.contains("Format: \(ReportFormat.briefing.writerBrief)"))
        #expect(turn.contains("Target length: 900 to 1600 words."))
        #expect(turn.contains("Sources (3). Cite each by its marker, [S1] to [S3]."))
        #expect(turn.contains(ReportWriterTurn.readingNote))
        #expect(turn.contains("=== [S1] Source 1 of 3 ===\nTitle: Paper A"))
        #expect(turn.contains("Published: Cell, 2024"))
        #expect(turn.contains("Read: whole\nFull text:\nWhole text."))
        #expect(turn.contains("Read: from its ideas\nIts ideas:\n- An idea."))
        #expect(turn.contains("Read: condensed\nCondensed account:\nAn account."))

        let custom = ReportWriterTurn.userMessage(
            notebookTitle: "N",
            instructions: nil,
            options: ReportOptions(format: .custom, focus: "dropped", instruction: "A one-page memo"),
            subjectDocument: ReportSubjectDocument(id: "d", title: "Draft", text: "The draft's text."),
            sources: [ReportTurnSource(number: 1, title: "Paper A", kind: "research paper", readAs: .whole, isSubject: true, text: "T.")]
        )
        #expect(custom.hasPrefix("Instruction: A one-page memo\nNotebook: N"))
        #expect(!custom.contains("Focus:"))
        #expect(custom.contains("unless the instruction asks for another"))
        #expect(custom.contains("=== The document ===\nThe draft's text."))
        #expect(custom.contains("Sources (1). Cite it as [S1]."))
        #expect(custom.contains("This is the document the feedback is about.\nRead: whole"))
    }

    // MARK: - Citations

    @Test("Each marker grounds the passage before it and leaves a footnote after it whose note links its sources")
    func citationsGroundClaims() {
        var result = ReportCitations.ground("Complex I pumps protons. [S1] It also leaks electrons [S2].", sources: citationSources)
        #expect(result.markdown == "[Complex I pumps protons.](foreverlm://grounding/src_a)[^1] [It also leaks electrons](foreverlm://grounding/src_b)[^2].")
        #expect(result.citedSourceIDs == ["src_a", "src_b"])
        #expect(result.unresolvedMarkers.isEmpty)
        #expect(result.notes == [
            "[^1]: [Paper A](foreverlm://source/src_a)",
            "[^2]: [Book \\[B\\]](foreverlm://source/src_b) \u{2014} condensed",
        ])

        // Passages citing the same sources share one note; several sources are one note.
        result = ReportCitations.ground("One. [S1] Two. [S1] Three. [S1, S3]", sources: citationSources)
        #expect(result.markdown == "[One.](foreverlm://grounding/src_a)[^1] [Two.](foreverlm://grounding/src_a)[^1] [Three.](foreverlm://grounding/src_a,src%20c)[^2]")
        #expect(result.notes == [
            "[^1]: [Paper A](foreverlm://source/src_a)",
            "[^2]: [Paper A](foreverlm://source/src_a); [Talk C](foreverlm://source/src%20c) \u{2014} read from its ideas",
        ])

        // Markers in a row join the passage the first grounds; an id is
        // percent-encoded in the address.
        result = ReportCitations.ground("Claim. [S1] [S3]", sources: citationSources)
        #expect(result.markdown == "[Claim.](foreverlm://grounding/src_a,src%20c)[^1]")
        result = ReportCitations.ground("2. Second [S2][S3]", sources: citationSources)
        #expect(result.markdown == "2. [Second](foreverlm://grounding/src_b,src%20c)[^1]")
        result = ReportCitations.ground("Claim [S1]. [S2]", sources: citationSources)
        #expect(result.markdown == "[Claim](foreverlm://grounding/src_a,src_b)[^1].")

        // A list item keeps its bullet and its bold term inside the passage.
        result = ReportCitations.ground("- **Term**: a definition [S2]", sources: citationSources)
        #expect(result.markdown == "- [**Term**: a definition](foreverlm://grounding/src_b)[^1]")
        // A heading is a title: its marker goes, nothing is grounded.
        result = ReportCitations.ground("## Key findings [S1]", sources: citationSources)
        #expect(result.markdown == "## Key findings")
        // A table cell's passage stays in its cell; the delimiter row is left alone.
        result = ReportCitations.ground("| Term | Definition [S1] |\n|---|---|", sources: citationSources)
        #expect(result.markdown == "| Term | [Definition](foreverlm://grounding/src_a)[^1] |\n|---|---|")
        // A marker before any claim grounds the next one.
        result = ReportCitations.ground("[S1] A claim at the start.", sources: citationSources)
        #expect(result.markdown == "[A claim at the start.](foreverlm://grounding/src_a)[^1]")
        // A bracket in the prose cannot end the link.
        result = ReportCitations.ground("Brackets [sic] here [S2].", sources: citationSources)
        #expect(result.markdown == "[Brackets \\[sic\\] here](foreverlm://grounding/src_b)[^1].")
        // A range names each source in it once.
        result = ReportCitations.ground("All three agree [S1-S3].", sources: citationSources)
        #expect(result.markdown == "[All three agree](foreverlm://grounding/src_a,src_b,src%20c)[^1].")
    }

    @Test("A number no source has is dropped and reported, and what cannot be a link's text stays plain prose with its footnote")
    func citationsLeaveWhatCannotBeALink() {
        var result = ReportCitations.ground("A claim [S9] stands.", sources: citationSources)
        #expect(result.markdown == "A claim stands.")
        #expect(result.unresolvedMarkers == ["S9"])
        #expect(result.citedSourceIDs.isEmpty)

        // Emphasis begun before the marker would break: the prose is kept, the marker goes.
        result = ReportCitations.ground("**Bold [S1] continues** here.", sources: citationSources)
        #expect(result.markdown == "**Bold[^1] continues** here.")
        #expect(result.citedSourceIDs == ["src_a"])
        // Links never nest.
        result = ReportCitations.ground("See [the site](https://x.org) for more [S1].", sources: citationSources)
        #expect(result.markdown == "See [the site](https://x.org) for more[^1].")
        // A link's text is not a marker, and fenced code is never touched.
        result = ReportCitations.ground("A [S1](https://x) link-like", sources: citationSources)
        #expect(result.markdown == "A [S1](https://x) link-like")
        result = ReportCitations.ground("```\ncode [S1]\n```", sources: citationSources)
        #expect(result.markdown == "```\ncode [S1]\n```")
        // A marker inside a code span is code.
        result = ReportCitations.ground("Written `x [S2]` here [S1].", sources: citationSources)
        #expect(result.markdown == "[Written `x [S2]` here](foreverlm://grounding/src_a)[^1].")
        // A marker inside a link's own text is taken out and the link kept
        // whole, never split around a grounding link; its footnote follows the link.
        result = ReportCitations.ground("See [the review [S1]](https://x.org) for more.", sources: citationSources)
        #expect(result.markdown == "See [the review](https://x.org)[^1] for more.")
        #expect(result.citedSourceIDs == ["src_a"])
        result = ReportCitations.ground("Two [one [S1]](u) and [two [S3]](v) links, then a claim [S2].", sources: citationSources)
        #expect(result.markdown == "Two [one](u)[^1] and [two](v)[^2] links, then a claim[^3].")
        #expect(result.citedSourceIDs == ["src_a", "src c", "src_b"])
        result = ReportCitations.ground("| [cell link [S1]](u) | x [S2] |", sources: citationSources)
        #expect(result.markdown == "| [cell link](u)[^1] | [x](foreverlm://grounding/src_b)[^2] |")

        #expect(ReportCitations.isSafeLinkText("It costs $20 million"))
        #expect(!ReportCitations.isSafeLinkText("**open"))
        #expect(!ReportCitations.isSafeLinkText("a <b>tag</b>"))
        #expect(!ReportCitations.isSafeLinkText("ends with a backslash \\"))
        #expect(ReportCitations.isSafeLinkText("snake_case words and *both* sides"))
    }

    @Test("The Doc closes with a rule and its recipe line, then its notes; no Sources list")
    func closingAndNotes() {
        let recipe = ReportRecipe(format: .briefing, sourceCount: 3, note: "why complex I matters")
        let composed = ReportCitations.compose(written: "  Intro [S1].\r\n", recipe: recipe, sources: citationSources)
        #expect(composed.markdown == """
        [Intro](foreverlm://grounding/src_a)[^1].

        ---

        Made from 3 sources · Briefing · why complex I matters

        [^1]: [Paper A](foreverlm://source/src_a)

        """)
        #expect(composed.citedSourceIDs == ["src_a"])
        #expect(ReportRecipe.parse(fromMarkdown: composed.markdown) == recipe)

        // Feedback on a Doc and nothing else: a rule and the recipe alone.
        let alone = ReportRecipe(format: .documentFeedback, sourceCount: 0, subjectTitle: "Draft", subjectIsDocument: true)
        let closing = ReportCitations.compose(written: "", recipe: alone, sources: []).markdown
        #expect(closing == "---\n\nMade from the document · Feedback on \u{201C}Draft\u{201D}\n")
    }

    // MARK: - The recipe

    @Test("The recipe line reads back as it was written, whatever the focus or title holds")
    func recipeRoundTrip() {
        let cases = [
            ReportRecipe(format: .briefing, sourceCount: 6, note: "why complex I · matters"),
            ReportRecipe(format: .studyGuide, sourceCount: 1),
            ReportRecipe(format: .meetingQuestions, sourceCount: 2, note: "for Vamsi"),
            ReportRecipe(format: .documentFeedback, sourceCount: 2, subjectTitle: "My \u{201C}draft\u{201D} · v2", subjectIsDocument: true, note: "methods"),
            ReportRecipe(format: .documentFeedback, sourceCount: 4, subjectTitle: "Whitepaper"),
            ReportRecipe(format: .custom, sourceCount: 3, note: "A memo *for* [me], $5 and `code`"),
        ]
        for recipe in cases {
            #expect(ReportRecipe.parse(line: recipe.line) == recipe, "\(recipe.line)")
            let body = ReportCitations.compose(written: "Text.", recipe: recipe, sources: [citationSources[0]]).markdown
            #expect(ReportRecipe.parse(fromMarkdown: body) == recipe, "\(recipe.line)")
        }
        #expect(cases[0].line == "Made from 6 sources · Briefing · why complex I · matters")
        #expect(cases[1].line == "Made from 1 source · Study guide")
        #expect(cases[3].line.hasPrefix("Made from the document and 2 sources · Feedback on \u{201C}My \u{201C}draft\" · v2\u{201D}"))
        #expect(ReportRecipe(format: .briefing, sourceCount: 2, note: "  two\nlines ").note == "two lines")

        #expect(ReportRecipe.parse(line: "Made from 3 sources") == nil)
        #expect(ReportRecipe.parse(line: "Made from 3 sources · Essay") == nil)
        #expect(ReportRecipe.parse(line: "Made from 1 sources · Briefing") == nil)
        #expect(ReportRecipe.parse(line: "Made from the document · Briefing") == nil)
        #expect(ReportRecipe.parse(fromMarkdown: "# A doc\n\nNothing like a recipe.") == nil)
    }

    // MARK: - The plan

    @Test("Everything is read whole when the window takes it; the largest give way to ideas or condensing, every character in a part")
    func planFits() throws {
        let short = candidate(id: "a", title: "Short", text: "A short text.")
        let paragraph = String(repeating: "Mitochondria make most of the cell's energy. ", count: 40)
        let longText = (1...60).map { "Section \($0). \(paragraph)" }.joined(separator: "\n\n")
        let long = candidate(id: "b", title: "Long", text: longText)
        let withIdeas = candidate(id: "c", title: "Ideas", text: String(repeating: "x", count: 30_000), ideas: "- An idea.")
        let request = ReportRequest(notebookID: "p", options: ReportOptions())

        let roomy = try ReportGeneratorService.plan(notebook([short, long, withIdeas]), request: request, route: testRoute(), system: "S")
        #expect(roomy.sources.map(\.readAs) == [.whole, .whole, .whole])
        #expect(roomy.sources.map(\.number) == [1, 2, 3])
        #expect(roomy.sourcesSummary == "3 sources")
        #expect(roomy.recipe == ReportRecipe(format: .briefing, sourceCount: 3))

        // Condensing the longest still leaves too little room, so the one with
        // ideas gives way too; the shortest stays whole.
        let tight = try ReportGeneratorService.plan(
            notebook([short, long, withIdeas]),
            request: request,
            route: testRoute(writerBudget: 20_000, condenserBudget: 30_000),
            system: "S"
        )
        let byID = Dictionary(uniqueKeysWithValues: tight.sources.map { ($0.candidate.source.id, $0) })
        #expect(byID["a"]?.readAs == .whole)
        #expect(byID["b"]?.readAs == .condensed)
        #expect(byID["c"]?.readAs == .ideas)
        let parts = try #require(byID["b"]?.parts)
        #expect(parts.map(\.text).joined() == longText)
        #expect(parts.allSatisfy { $0.userMessage.contains("Source: Long") })
        #expect(tight.condensingCallCount == parts.count)
        #expect(tight.sourcesSummary == "3 sources · 1 read from its ideas · 1 condensed")
        #expect(tight.writingCost.requestCount == 1 + parts.count)

        let empty = notebook([], title: "Empty")
        #expect(throws: ReportGenerationError.noSources("Empty")) {
            _ = try ReportGeneratorService.plan(empty, request: request, route: testRoute(), system: "S")
        }
        #expect(throws: ReportGenerationError.doesNotFit(model: "test/report-writer", sourceCount: 1)) {
            _ = try ReportGeneratorService.plan(
                notebook([candidate(id: "z", title: "Z", text: String(repeating: "y", count: 30_000))]),
                request: request,
                route: testRoute(writerBudget: 5_000),
                system: String(repeating: "s", count: 4_000)
            )
        }
    }

    @Test("The writing is priced honestly: unpriced reads unknown, a free route free, a priced one about and at most")
    func planPrices() throws {
        let book = notebook([candidate(id: "a", title: "A", text: String(repeating: "word ", count: 2_000))])
        let request = ReportRequest(notebookID: "p", options: ReportOptions(format: .studyGuide))
        let unpriced = try ReportGeneratorService.plan(book, request: request, route: testRoute(input: nil, output: nil), system: "S")
        #expect(unpriced.writingCost.label == "price unknown")
        #expect(!unpriced.writingCost.isFree)
        let free = try ReportGeneratorService.plan(book, request: request, route: testRoute(input: 0, output: 0), system: "S")
        #expect(free.writingCost.label == "free")
        #expect(free.writingCost.isFree)
        let priced = try ReportGeneratorService.plan(book, request: request, route: testRoute(input: 1, output: 2), system: "S")
        let expected = try #require(priced.writingCost.expectedUSD)
        let maximum = try #require(priced.writingCost.maximumUSD)
        #expect(expected > 0 && maximum >= expected)
        #expect(priced.writingCost.label.hasPrefix("about $"))
        // The study guide's upper length, its Markdown and markers.
        #expect(priced.writingCost.expectedOutputTokens == Int(Double(2_400) * 1.6) + 300)
    }

    @Test("Feedback's document is read whole and first; a Doc is read beside the sources; one too long for the window is refused")
    func subjectIsReadWhole() throws {
        let longText = String(repeating: "A line of the whitepaper's argument.\n", count: 900)
        let whitepaper = candidate(id: "w", title: "Whitepaper", text: longText)
        let context = candidate(id: "c", title: "Context", text: String(repeating: "Context line.\n", count: 900))
        let book = notebook([context, whitepaper])
        let subject = ReportSubject(kind: .source, id: "w", title: "Whitepaper")
        let request = ReportRequest(notebookID: "p", options: ReportOptions(format: .documentFeedback, subject: subject))
        let plan = try ReportGeneratorService.plan(book, request: request, route: testRoute(writerBudget: 45_000, condenserBudget: 30_000), system: "S")
        #expect(plan.sources.map(\.candidate.source.id) == ["w", "c"])
        #expect(plan.sources.first?.isSubject == true)
        #expect(plan.sources.first?.readAs == .whole)
        #expect(plan.sources.last?.readAs == .condensed)
        #expect(plan.recipe.line == "Made from 2 sources · Feedback on \u{201C}Whitepaper\u{201D}")

        #expect(throws: ReportGenerationError.subjectTooLong(model: "test/report-writer", title: "Whitepaper")) {
            _ = try ReportGeneratorService.plan(book, request: request, route: testRoute(writerBudget: 20_000), system: "S")
        }
        let missing = ReportRequest(notebookID: "p", options: ReportOptions(format: .documentFeedback, subject: ReportSubject(kind: .source, id: "x", title: "X")))
        #expect(throws: ReportGenerationError.subjectNotInNotebook("x")) {
            _ = try ReportGeneratorService.plan(book, request: missing, route: testRoute(), system: "S")
        }
        let textless = notebook([context], skipped: [.init(sourceID: "t", title: "Textless", reason: "It has no text yet.")])
        let noText = ReportRequest(notebookID: "p", options: ReportOptions(format: .documentFeedback, subject: ReportSubject(kind: .source, id: "t", title: "Textless")))
        #expect(throws: ReportGenerationError.subjectSetAside(title: "Textless", reason: "It has no text yet.")) {
            _ = try ReportGeneratorService.plan(textless, request: noText, route: testRoute(), system: "S")
        }

        // A Doc: read whole beside the sources, which keep their numbers.
        let draft = ReportSubjectDocument(id: "d", title: "Draft", text: "The draft's whole text.")
        let docRequest = ReportRequest(notebookID: "p", options: ReportOptions(format: .documentFeedback, subject: ReportSubject(kind: .doc, id: "d", title: "Draft")))
        let docPlan = try ReportGeneratorService.plan(
            notebook([context], documents: [.init(id: "d", title: "Draft")]),
            request: docRequest,
            subjectDocument: draft,
            route: testRoute(),
            system: "S"
        )
        #expect(docPlan.subjectDocument == draft)
        #expect(docPlan.sources.map(\.isSubject) == [false])
        #expect(docPlan.recipe.line == "Made from the document and 1 source · Feedback on \u{201C}Draft\u{201D}")
        // The Doc's text must be in hand to plan it.
        #expect(throws: ReportGenerationError.subjectRequired) {
            _ = try ReportGeneratorService.plan(notebook([context]), request: docRequest, route: testRoute(), system: "S")
        }
    }

    @Test("The writer's title is kept, a heading that repeats it is dropped, and a missing one is made from the format")
    func titleAndBody() throws {
        let plan = try ReportGeneratorService.plan(
            notebook([candidate(id: "a", title: "A", text: "Text.")]),
            request: ReportRequest(notebookID: "p", options: ReportOptions(format: .studyGuide)),
            route: testRoute(),
            system: "S"
        )
        #expect(ReportGeneratorService.title(of: ReportDraft(title: " # Study guide: energy ", markdown: "x"), plan: plan) == "Study guide: energy")
        #expect(ReportGeneratorService.title(of: ReportDraft(title: " ", markdown: "x"), plan: plan) == "Study guide: Mitochondria")
        let draft = ReportDraft(title: "Study guide: energy", markdown: "# Study Guide:  Energy\n\n## Overview\n\nText.")
        #expect(ReportGeneratorService.body(of: draft, title: "Study guide: energy") == "## Overview\n\nText.")
        let kept = ReportDraft(title: "T", markdown: "# Something else\n\nText.")
        #expect(ReportGeneratorService.body(of: kept, title: "T") == "# Something else\n\nText.")
    }

    // MARK: - The pipeline

    @Test("A report is saved as a Doc homed in its notebook, grounded on its sources, closing with its Sources and recipe")
    func writesAndSaves() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: "The whole text of A.")
        let b = try await seedSource(storage, url: "https://journal.example/b", title: "Article B", content: "The whole text of B.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id, b.id])

        let recorder = ReportCallRecorder()
        let service = ReportGeneratorService(storage: storage, backend: CannedReportBackend(recorder: recorder))
        let book = try await service.load(notebookID: notebook.id)
        #expect(Set(book.sources.candidates.map(\.source.id)) == [a.id, b.id])
        let plan = try ReportGeneratorService.plan(
            book,
            request: ReportRequest(notebookID: notebook.id, options: ReportOptions(format: .briefing, focus: "energy")),
            route: testRoute()
        )
        let result = try await service.run(plan, artifactID: "report-1")

        #expect(result.artifact.id == "report-1")
        #expect(result.artifact.kind == nil)
        #expect(result.artifact.section == .docs)
        #expect(result.artifact.homeNotebookID == notebook.id)
        #expect(result.artifact.linkedNotebookIDs == [notebook.id])
        #expect(result.artifact.sourceIDs == plan.sources.map(\.candidate.source.id))
        #expect(result.artifact.title == "Briefing: complex I")
        #expect(result.recipe.line == "Made from 2 sources · Briefing · energy")
        #expect(Set(result.citedSourceIDs) == Set([a.id, b.id]))
        #expect(result.unresolvedMarkers.isEmpty)

        // The writer was handed every source whole and the focus first.
        #expect(recorder.parts.isEmpty)
        let user = try #require(recorder.writes.first?.user)
        #expect(user.hasPrefix("Focus: energy"))
        #expect(user.contains("The whole text of A."))
        #expect(user.contains("The whole text of B."))
        #expect(recorder.writes.first?.system == Prompts.reportWriter)

        // The body carries footnotes, never a marker, and no Sources list.
        let body = try await storage.artifactMarkdown("report-1").markdown
        let first = try #require(plan.sources.first?.candidate.source.id)
        #expect(body.contains("[Complex I pumps protons.](foreverlm://grounding/\(first))[^1]"))
        #expect(!body.contains("[S1]"))
        #expect(!body.contains("## Sources"))
        #expect(body.contains("---\n\nMade from 2 sources · Briefing · energy"))
        #expect(body.contains("[Paper A](foreverlm://source/\(a.id))"))
        #expect(body.contains("[Article B](foreverlm://source/\(b.id))"))
        #expect(ReportRecipe.parse(fromMarkdown: body) == result.recipe)
        // The notebook lists it among its Docs, and its sources stay its own.
        let filed = try await storage.loadArtifacts(notebookID: notebook.id)
        #expect(filed.map(\.id).contains("report-1"))
        let sources = try await storage.loadLearningGoal(notebook.id)?.approvedSourceIDs ?? []
        #expect(Set(sources) == Set([a.id, b.id]))
    }

    @Test("A source too long for the window is read from a condensed account of its whole text, and the turn and the Doc say so")
    func condensesWhatDoesNotFit() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let longText = (1...400).map { "Paragraph \($0) of the long chapter about the respiratory chain." }.joined(separator: "\n\n")
        let long = try await seedSource(storage, url: "https://books.example/long", title: "Long Chapter", content: longText)
        let short = try await seedSource(storage, url: "https://journal.example/short", title: "Short", content: "A short text.")
        let notebook = try await makeNotebook(storage, title: "Respiration", sourceIDs: [long.id, short.id])

        let recorder = ReportCallRecorder()
        let service = ReportGeneratorService(storage: storage, backend: CannedReportBackend(recorder: recorder))
        let plan = try ReportGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: ReportRequest(notebookID: notebook.id, options: ReportOptions()),
            route: testRoute(writerBudget: 20_000),
            system: "System."
        )
        #expect(plan.sources.map(\.readAs) == [.condensed, .whole])
        let result = try await service.run(plan, artifactID: "report-2")

        // The parts, in their own order, are the whole text, nothing left out.
        #expect(recorder.parts.sorted { $0.index < $1.index }.map(\.text).joined() == longText)
        let user = try #require(recorder.writes.first?.user)
        #expect(user.contains("Read: condensed"))
        #expect(user.contains("Condensed account of Long Chapter, part 1."))
        #expect(!user.contains("Paragraph 400 of the long chapter"))
        #expect(user.contains("A short text."))
        let body = try await storage.artifactMarkdown(result.artifact.id).markdown
        #expect(body.contains("[Long Chapter](foreverlm://source/\(long.id)) \u{2014} condensed"))
    }

    @Test("Stored ideas stand in only for the whole text they were taken from")
    func ideasThroughLoad() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let shortText = "The whole text of A, about complex I.\n"
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: shortText)
        let line = "A sentence about the respiratory chain.\n"
        let longText = String(repeating: line, count: SourceIdeaDrafting.singleReadCharacterLimit / line.count + 100)
        let b = try await seedSource(storage, url: "https://books.example/b", title: "Book B", content: longText)
        for (source, text) in [(a, shortText), (b, longText)] {
            let hash = SourceIdeaDrafting.contentHash(text)
            try await storage.replaceSourceIdeas(sourceID: source.id, contentHash: hash, ideas: [
                SourceIdea(
                    id: SourceIdea.id(sourceID: source.id, contentHash: hash, index: 0),
                    sourceID: source.id,
                    statement: "Complex I pumps protons.",
                    recallNote: "Four per NADH.",
                    contentHash: hash,
                    sortIndex: 0
                ),
            ])
        }
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id, b.id])
        let book = try await ReportGeneratorService(storage: storage, backend: CannedReportBackend()).load(notebookID: notebook.id)
        let byID = Dictionary(uniqueKeysWithValues: book.sources.candidates.map { ($0.source.id, $0) })
        #expect(byID[a.id]?.ideas?.contains("A good recall holds: Four per NADH.") == true)
        #expect(byID[b.id]?.ideas == nil)
    }

    @Test("A cancelled run saves nothing, even when the writer answers after the cancel")
    func cancelledRunSavesNothing() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id])
        let service = ReportGeneratorService(storage: storage, backend: LateReportBackend())
        let plan = try ReportGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: ReportRequest(notebookID: notebook.id, options: ReportOptions()),
            route: testRoute()
        )
        let run = Task { try await service.run(plan, artifactID: "report-late") }
        await Task.yield()
        run.cancel()
        let outcome = await run.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(try await storage.loadArtifacts().isEmpty)
    }

    @Test("Options still missing their instruction or document are priced but never written")
    func runRefusesAGap() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id])
        let recorder = ReportCallRecorder()
        let service = ReportGeneratorService(storage: storage, backend: CannedReportBackend(recorder: recorder))
        let book = try await service.load(notebookID: notebook.id)
        let custom = try ReportGeneratorService.plan(
            book,
            request: ReportRequest(notebookID: notebook.id, options: ReportOptions(format: .custom)),
            route: testRoute()
        )
        #expect(custom.writingCost.expectedUSD != nil)
        await #expect(throws: ReportGenerationError.instructionRequired) {
            _ = try await service.run(custom, artifactID: "report-gap")
        }
        #expect(recorder.writes.isEmpty)
        #expect(try await storage.loadArtifacts().isEmpty)
    }

    @Test("Spoken scripts and textless sources are set aside; sources outside the notebook and a missing notebook are refused")
    func loadSetsAsideAndRefuses() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let textless = try await seedSource(storage, url: "https://journal.example/none", title: "None", content: nil)
        var explainer = StudioArticle(url: ExplainerScript.url(explaining: a.id), title: "Explainer: A", sourceType: .article, discoveryOrigin: .manual)
        explainer.content = "A spoken script."
        explainer.state = .ready
        try await storage.saveSource(explainer)
        let outside = try await seedSource(storage, url: "https://journal.example/out", title: "Out", content: "Elsewhere.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id, textless.id, explainer.id])

        let service = ReportGeneratorService(storage: storage, backend: CannedReportBackend())
        let book = try await service.load(notebookID: notebook.id)
        #expect(book.sources.candidates.map(\.source.id) == [a.id])
        #expect(Set(book.sources.skipped.map(\.sourceID)) == Set([textless.id, explainer.id]))
        await #expect(throws: ReportGenerationError.sourceNotInNotebook([outside.id])) {
            _ = try await service.load(notebookID: notebook.id, sourceIDs: [a.id, outside.id])
        }
        await #expect(throws: ReportGenerationError.notebookNotFound("missing")) {
            _ = try await service.load(notebookID: "missing")
        }
    }

    @Test("Feedback on one of the notebook's Docs reads it whole; an audio overview is never a document to give feedback on")
    func feedbackOnADoc() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: "The whole text of A.")
        let notebook = try await makeNotebook(storage, title: "Whitepapers", sourceIDs: [a.id])
        let draft = try await storage.createArtifact(
            title: "Draft",
            homeNotebookID: notebook.id,
            linkedNotebookIDs: [],
            markdown: "# Draft\n\nOur claim is bold."
        )
        let overviewSettings = AudioOverviewSettings(
            format: .brief,
            length: nil,
            focus: nil,
            audioSourceID: GeneratedAudioOverview.carrierSourceID(artifactID: "overview-1"),
            sources: [],
            model: nil,
            madeAt: Date()
        )
        _ = try await storage.saveAudioOverview(
            artifactID: "overview-1",
            title: "Overview",
            notebookID: notebook.id,
            sourceIDs: [a.id],
            markdown: try AudioOverviewScript.markdown(settings: overviewSettings),
            carrier: GeneratedAudioOverview.carrierSource(artifactID: "overview-1", title: "Overview", script: "Spoken.")
        )

        let recorder = ReportCallRecorder()
        let service = ReportGeneratorService(storage: storage, backend: CannedReportBackend(recorder: recorder))
        let book = try await service.load(notebookID: notebook.id)
        #expect(book.documents.map(\.id) == [draft.artifact.id])
        let subject = try #require(book.subject(id: draft.artifact.id))
        #expect(subject.kind == .doc)
        let document = try await service.loadSubjectDocument(draft.artifact.id, in: book)
        #expect(document.text == "# Draft\n\nOur claim is bold.")
        await #expect(throws: ReportGenerationError.subjectNotInNotebook("overview-1")) {
            _ = try await service.loadSubjectDocument("overview-1", in: book)
        }

        let plan = try ReportGeneratorService.plan(
            book,
            request: ReportRequest(notebookID: notebook.id, options: ReportOptions(format: .documentFeedback, subject: subject)),
            subjectDocument: document,
            route: testRoute()
        )
        let result = try await service.run(plan, artifactID: "report-feedback")
        let user = try #require(recorder.writes.first?.user)
        #expect(user.contains("=== The document ===\n# Draft\n\nOur claim is bold."))
        #expect(user.contains("=== [S1] Source 1 of 1 ===\nTitle: Paper A"))
        #expect(result.recipe.line == "Made from the document and 1 source · Feedback on \u{201C}Draft\u{201D}")
        #expect(result.artifact.sourceIDs == [a.id])
    }

    @Test("A Doc can be made under a reserved id, grounded on its sources; a taken id is refused")
    func createArtifactTakesAReservedID() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text.")
        let snapshot = try await storage.createArtifact(
            title: "Grounded",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "Body.",
            artifactID: "doc-reserved",
            sourceIDs: [a.id, a.id, ""]
        )
        #expect(snapshot.artifact.id == "doc-reserved")
        #expect(snapshot.artifact.sourceIDs == [a.id])
        let loaded = try #require(try await storage.loadArtifacts().first { $0.id == "doc-reserved" })
        #expect(loaded.sourceIDs == [a.id])
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.createArtifact(title: "Again", homeNotebookID: nil, linkedNotebookIDs: [], artifactID: "doc-reserved")
        }
    }

    // MARK: - The task

    @Test("Report Writing is a learner-started Settings task with the writer's prompt, in the catalog since 29")
    func task() {
        let task = AITask.reportWriting
        #expect(task.rawValue == "report_writing")
        #expect(task.defaultPrompt == Prompts.reportWriter)
        #expect(task.sourceType == nil)
        #expect(!task.isBackgroundWork)
        #expect(!AITask.backgroundWorkTaskIDs.contains(task.rawValue))
        #expect(!task.followsChatRoute)
        #expect(AITaskSettingsCatalog.version >= 29)
        let descriptor = AITaskSettingsCatalog.descriptor(forRawID: "report_writing")
        #expect(descriptor?.displayName == "Report Writing")
        #expect(descriptor?.showInAdvancedSettings == true)
        #expect(descriptor?.modelDefault == .backgroundText)
        #expect(AIUsageTaskLabel.text(for: "report_writing") == "Write Report")
        #expect(Prompts.reportWriter.contains(Prompts.textbookExplanation))
        #expect(Prompts.reportWriter.contains("[S1]"))
        #expect(!Prompts.reportCondenser.isEmpty)
    }

    // MARK: - The Studio column's seam

    @MainActor
    @Test("The Report tile opens the options sheet in the window it was asked from, and a notebook that takes nothing says why")
    func presentReportOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReportTests_vm_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ReportGenerationCoordinator.shared

        // Deaf to other suites' change notices, which would reload the
        // notebooks laid out below from the empty store.
        let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
        let windowID = vm.activeWindowState.id
        defer { coordinator.dismissOptions(in: windowID) }
        let now = Date()
        func record(_ id: String, title: String, status: LearningGoalStatus) -> LearningGoalRecord {
            LearningGoalRecord(
                id: id,
                title: title,
                startAt: now,
                endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: now,
                updatedAt: now,
                status: status.rawValue,
                items: [],
                kind: LearningGoalRecord.companionKind
            )
        }
        vm.learningGoals = [
            record("nb-live", title: "Mitochondria", status: .active),
            record("nb-archived", title: "Old", status: .archived),
        ]

        #expect(ReportEntry.isAvailable)
        #expect(vm.canMakeReport(in: "nb-live"))
        vm.presentReportOptions(notebookID: "nb-live", format: .studyGuide)
        let target = try #require(coordinator.optionsTarget(in: windowID))
        #expect(target.notebookID == "nb-live")
        #expect(target.format == .studyGuide)
        #expect(target.sourceIDs == nil)
        #expect(target.windowID == windowID)

        // Another window's sheet is its own: asking there leaves this
        // window's sheet open, and closing it there leaves this one too.
        let other = StudioWindowState()
        defer { coordinator.dismissOptions(in: other.id) }
        vm.inWindow(other) { vm.presentReportOptions(notebookID: "nb-live", format: .briefing) }
        #expect(coordinator.optionsTarget(in: other.id)?.format == .briefing)
        #expect(coordinator.optionsTarget(in: windowID) == target)
        coordinator.dismissOptions(in: other.id)
        #expect(coordinator.optionsTarget(in: other.id) == nil)
        #expect(coordinator.optionsTarget(in: windowID) == target)

        coordinator.dismissOptions(in: windowID)
        #expect(!vm.canMakeReport(in: "nb-archived"))
        vm.presentReportOptions(notebookID: "nb-archived", format: nil)
        #expect(coordinator.optionsTarget(in: windowID) == nil)
        #expect(vm.toastMessage == "A report can\u{2019}t be made in \u{2018}Old\u{2019}: it is archived.")
        #expect(vm.reportRefusal(notebookID: "missing") == NotebookImportRefusal.missing.reason)
    }

    @MainActor
    @Test("A saved report's row reads its recipe from its body; a Doc that is not a report has none")
    func reportRecipeForTheOutputsRow() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: "The whole text of A.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let service = ReportGeneratorService(storage: storage, backend: CannedReportBackend())
        let plan = try ReportGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: ReportRequest(notebookID: notebook.id, options: ReportOptions(format: .studyGuide, focus: "energy")),
            route: testRoute()
        )
        let report = try await service.run(plan, artifactID: "report-row-\(UUID().uuidString)")
        let note = try await storage.createArtifact(
            title: "Notes",
            homeNotebookID: notebook.id,
            linkedNotebookIDs: [notebook.id],
            markdown: "Plain notes."
        )

        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)
        vm.artifacts = try await storage.loadArtifacts()
        #expect(await vm.reportRecipe(report.artifact.id) == report.recipe)
        #expect(report.recipe.line == "Made from 1 source · Study guide · energy")
        #expect(await vm.reportRecipe(note.artifact.id) == nil)
        #expect(await vm.reportRecipe("not-a-record") == nil)
        // The report is filed in its notebook, so the Studio lists it.
        #expect(vm.linkedArtifacts(notebookID: notebook.id).map(\.id).contains(report.artifact.id))
    }
}

// MARK: - generate_report

private func makeMCPStore() -> (MCPDataStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReportMCPTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path), root)
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// Waits for an MCP call's background work to end.
private func waitForWork(_ workID: String) async throws {
    for _ in 0..<400 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == workID }) {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Suite("Report over MCP")
struct ReportMCPTests {
    @Test("generate_report is registered as paid, self-gated, Notebook-scoped work with a popup")
    func registration() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "generate_report" })
        let required = try #require(tool.inputSchema["required"] as? [String])
        #expect(required == ["notebook_id"])
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect((properties["format"] as? [String: Any])?["enum"] as? [String] == ReportFormat.allCases.map(\.rawValue))
        for name in ["focus", "instruction", "subject_id", "source_ids", "confirm_cost", "approved_spend_usd"] {
            #expect(properties[name] != nil, "\(name)")
        }
        #expect(tool.inputSchema["anyOf"] == nil)
        #expect(tool.description.contains("cancel_ai_work"))
        #expect(tool.description.contains("confirm_cost"))
        #expect(MCPToolRegistry.paidWorkToolNames.contains("generate_report"))
        #expect(MCPToolRegistry.selfGatedToolNames.contains("generate_report"))
        #expect(MCPToolActivityTitle.shownToolNames.contains("generate_report"))
        let title = try #require(MCPToolActivityTitle.forTool("generate_report", arguments: [:]))
        #expect(title.subject == .notebook)
        #expect(title.text(subjectName: "Mitochondria") == "Writing a report for Mitochondria")
    }

    @Test("generate_report refuses what it cannot make, and prices the writing before spending anything")
    func refusals() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to write about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let route = testRoute()
        let backend = CannedReportBackend()

        for arguments: [String: Any] in [
            [:],
            ["notebook_id": notebook.id, "format": "essay"],
            ["notebook_id": "missing"],
            ["notebook_id": notebook.id, "format": "custom"],
            ["notebook_id": notebook.id, "format": "document_feedback"],
            ["notebook_id": notebook.id, "format": "document_feedback", "subject_id": "not-here"],
        ] {
            await #expect(throws: MCPError.self) {
                _ = try await store.generateReport(arguments: arguments, backend: backend, route: route)
            }
        }

        // A priced writing and no confirm_cost: the estimate, and nothing written.
        let quoted = try object(try await store.generateReport(
            arguments: ["notebook_id": notebook.id, "format": "study_guide", "focus": "energy"],
            backend: backend,
            route: route
        ))
        #expect(quoted["status"] as? String == "awaiting_confirmation")
        #expect(quoted["work_id"] == nil)
        #expect(quoted["doc_id"] == nil)
        #expect(quoted["format"] as? String == "study_guide")
        #expect(quoted["recipe"] as? String == "Made from 1 source · Study guide · energy")
        let estimate = try #require((quoted["estimate"] as? [String: Any])?["writing"] as? [String: Any])
        #expect(estimate["estimated_cost_usd"] is Double)
        #expect((quoted["sources"] as? [[String: Any]])?.first?["marker"] as? String == "S1")
        #expect(try await storage.loadArtifacts().isEmpty)

        // Agreed, but above the approved ceiling: still nothing started.
        let tooLow = try object(try await store.generateReport(
            arguments: ["notebook_id": notebook.id, "confirm_cost": true, "approved_spend_usd": 0.000001],
            backend: backend,
            route: route
        ))
        #expect(tooLow["status"] as? String == "approval_too_low")
        #expect(try await storage.loadArtifacts().isEmpty)

        // An archived Notebook takes nothing.
        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil,
            status: LearningGoalStatus.archived.rawValue
        )
        await #expect(throws: MCPError.self) {
            _ = try await store.generateReport(arguments: ["notebook_id": notebook.id, "confirm_cost": true], backend: backend, route: route)
        }
    }

    @Test("Once agreed, generate_report writes in the background and saves the report as a Doc in the Notebook, which read_doc reads with its recipe")
    func startsInTheBackground() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to write about.")
        let b = try await seedSource(storage, url: "https://journal.example/b", title: "B", content: "Text of B, enough to write about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id, b.id])

        let started = try object(try await store.generateReport(
            arguments: ["notebook_id": notebook.id, "format": "meeting_questions", "confirm_cost": true],
            backend: CannedReportBackend(),
            route: testRoute()
        ))
        #expect(started["status"] as? String == "started")
        let workID = try #require(started["work_id"] as? String)
        let docID = try #require(started["doc_id"] as? String)
        #expect(started["cost_confirmed_by"] == nil)

        try await waitForWork(workID)
        #expect(!MCPRunningWork.shared.snapshot.contains { $0.id == workID })
        let saved = try #require(try await storage.loadArtifacts().first { $0.id == docID })
        #expect(saved.homeNotebookID == notebook.id)
        #expect(saved.kind == nil)
        #expect(Set(saved.sourceIDs) == Set([a.id, b.id]))

        let read = try object(try await store.readArtifact(artifactID: docID))
        let report = try #require(read["report"] as? [String: Any])
        #expect(report["format"] as? String == "meeting_questions")
        #expect(report["source_count"] as? Int == 2)
        #expect(report["summary"] as? String == "Made from 2 sources · Questions for a meeting")
        #expect((read["markdown"] as? String)?.contains("foreverlm://grounding/") == true)
    }

    @Test("A free model starts at once, and a source named only as feedback's document is read as well")
    func freeModelAndUntickedSubject() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Context", content: "Text of the context.")
        let w = try await seedSource(storage, url: "https://journal.example/w", title: "Whitepaper", content: "Text of the whitepaper.")
        let notebook = try await makeNotebook(storage, title: "Reviews", sourceIDs: [a.id, w.id])

        let started = try object(try await store.generateReport(
            arguments: [
                "notebook_id": notebook.id,
                "format": "document_feedback",
                "subject_id": w.id,
                "source_ids": [a.id],
            ],
            backend: CannedReportBackend(),
            route: testRoute(input: 0, output: 0)
        ))
        #expect(started["status"] as? String == "started")
        #expect(started["cost_confirmed_by"] as? String == "free_model")
        let subject = try #require(started["subject"] as? [String: Any])
        #expect(subject["kind"] as? String == "source")
        #expect(subject["title"] as? String == "Whitepaper")
        let sources = try #require(started["sources"] as? [[String: Any]])
        #expect(sources.map { $0["source_id"] as? String } == [w.id, a.id])
        #expect(sources.first?["is_subject"] as? Bool == true)
        try await waitForWork(try #require(started["work_id"] as? String))
    }

    @Test("A run that ends without a report tells read_doc why")
    func failedRunIsReported() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to write about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])

        let started = try object(try await store.generateReport(
            arguments: ["notebook_id": notebook.id, "confirm_cost": true],
            backend: FailingReportBackend(),
            route: testRoute()
        ))
        let docID = try #require(started["doc_id"] as? String)
        try await waitForWork(try #require(started["work_id"] as? String))
        do {
            _ = try await store.readArtifact(artifactID: docID)
            Issue.record("read_doc answered for a report that was never saved")
        } catch let MCPError.notFound(message) {
            #expect(message.contains("was not saved"))
            #expect(message.contains(ReportGenerationError.emptyReport.localizedDescription))
        }
        #expect(try await storage.loadArtifacts().isEmpty)
    }
}
