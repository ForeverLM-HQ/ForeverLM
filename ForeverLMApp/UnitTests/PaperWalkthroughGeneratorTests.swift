// Walkthrough generator tests with their recording backend.

import Foundation
import PDFKit
import SQLite3
import Testing
@testable import ForeverLM

private func makeTemporaryStorage(_ name: String) -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PaperWalkthroughTests_\(name)_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

// MARK: - Generator

private final class WalkthroughCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFigureLabels: [String] = []
    private var storedDrawn: [String] = []
    private var storedArguments: [PaperWalkthroughArgumentMap?] = []
    private var storedMapCalls = 0

    var figureLabels: [String] { lock.lock(); defer { lock.unlock() }; return storedFigureLabels }
    var drawn: [String] { lock.lock(); defer { lock.unlock() }; return storedDrawn }
    /// One entry per writing call: the argument the writer was handed.
    var arguments: [PaperWalkthroughArgumentMap?] { lock.lock(); defer { lock.unlock() }; return storedArguments }
    var mapCalls: Int { lock.lock(); defer { lock.unlock() }; return storedMapCalls }

    func recordMap() {
        lock.lock(); defer { lock.unlock() }
        storedMapCalls += 1
    }

    func recordWrite(figures: [PaperWalkthroughFigureReference], argument: PaperWalkthroughArgumentMap?) {
        lock.lock(); defer { lock.unlock() }
        storedFigureLabels = figures.map(\.label)
        storedArguments.append(argument)
    }

    func recordDraw(_ step: PaperWalkthroughStep) {
        lock.lock(); defer { lock.unlock() }
        storedDrawn.append(step.id)
    }
}

private struct CannedWalkthroughBackend: PaperWalkthroughModelBackend {
    var draft: PaperWalkthroughDraft
    /// What the argument pass returns; nil throws, as a failed pass does, and
    /// the writer is then handed no argument.
    var argument: PaperWalkthroughArgumentMap? = PaperWalkthroughArgumentMap(
        title: "Sleep as an energy problem",
        question: "What builds sleep pressure?",
        claims: [.init(title: "The model", claim: "A mitochondrial electron surplus induces sleep.", evidence: ["Figure 2"])],
        prerequisites: ["UCP4"]
    )
    var animation: String? = "<!DOCTYPE html><html><body><svg></svg></body></html>"
    var recorder: WalkthroughCallRecorder? = nil
    var drawFails = false

    func mapArgument(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference]
    ) async throws -> PaperWalkthroughArgumentMap {
        recorder?.recordMap()
        guard let argument else { throw PaperWalkthroughGenerationError.emptyDraft }
        return argument
    }

    func write(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        argument: PaperWalkthroughArgumentMap?
    ) async throws -> PaperWalkthroughDraft {
        recorder?.recordWrite(figures: figures, argument: argument)
        return draft
    }

    func drawAnimation(source: StudioArticle, step: PaperWalkthroughStep, figure: PaperWalkthroughFigureReference?, excerpt: String?) async throws -> String {
        recorder?.recordDraw(step)
        if drawFails { throw PaperWalkthroughGenerationError.emptyDraft }
        return animation ?? ""
    }
}

@Suite("Walkthrough generator")
struct PaperWalkthroughGeneratorTests {

    @Test("The generator refuses a source that is not a paper, a chapter or an article, before spending")
    func refusesUnsupportedSource() async throws {
        let (storage, root) = makeTemporaryStorage("refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        var podcast = StudioArticle(url: "https://example.com/episode", title: "An episode", sourceType: .podcast, discoveryOrigin: .manual)
        podcast.content = paperText
        podcast.state = .ready
        try await storage.saveSource(podcast)
        let service = PaperWalkthroughGeneratorService(
            storage: storage,
            backend: CannedWalkthroughBackend(draft: PaperWalkthroughDraft(title: "x", steps: [])),
            figureIndexer: PaperFigureIndexer(storage: storage, aiService: AIService())
        )
        await #expect(throws: PaperWalkthroughGenerationError.unsupportedSource(podcast.title)) {
            try await service.run(request: PaperWalkthroughRequest(sourceID: podcast.id))
        }
        await #expect(throws: PaperWalkthroughGenerationError.sourceNotFound("missing")) {
            try await service.run(request: PaperWalkthroughRequest(sourceID: "missing"))
        }
    }

    @Test("An article is walked through with passages alone: no figure index is read, a figure step is refused by name, a passage step is kept")
    func walksAnArticleWithPassagesOnly() async throws {
        let (storage, root) = makeTemporaryStorage("article")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedArticle(storage, content: paperText)
        let recorder = WalkthroughCallRecorder()
        let draft = PaperWalkthroughDraft(title: "Walk", steps: [
            .init(kind: "explain", title: "Start", body: "B", figureLabel: nil, panelLabel: nil, passage: "Sleep pressure rises during waking", pageNumber: nil, animationBrief: nil, quiz: nil),
            .init(kind: "figure", title: "The model", body: "B", figureLabel: "Figure 2", panelLabel: nil, passage: nil, pageNumber: nil, animationBrief: "Show electrons.", quiz: nil),
        ])
        let service = PaperWalkthroughGeneratorService(
            storage: storage,
            backend: CannedWalkthroughBackend(draft: draft, recorder: recorder),
            figureIndexer: PaperFigureIndexer(storage: storage, aiService: AIService())
        )
        let result = try await service.run(request: PaperWalkthroughRequest(sourceID: article.id, drawsAnimations: false))
        #expect(recorder.figureLabels.isEmpty, "the writer is offered no figures for an article")
        #expect(result.walkthrough.steps.count == 2)
        #expect(result.walkthrough.steps[0].anchor?.passage == "Sleep pressure rises during waking")
        #expect(result.walkthrough.steps[1].kind == .explain)
        #expect(result.walkthrough.steps[1].anchor == nil)
        #expect(result.warnings.contains { $0.contains("Figure 2") && $0.contains("shown as text") })
        #expect(!result.warnings.contains { $0.contains("figure index could not be read") }, "an article has no index to fail to read")
        #expect(try await storage.loadPaperWalkthrough(article.id)?.title == "Walk")
    }

    @Test("A chapter split from a PDF goes through the figure index; a missing file leaves a walk without figure anchors and says so")
    func walksAPDFChapter() async throws {
        let (storage, root) = makeTemporaryStorage("chapter")
        defer { try? FileManager.default.removeItem(at: root) }
        let chapter = try await seedChapter(storage, file: "Books/Sleep/Chapters/03.pdf", content: paperText)
        let recorder = WalkthroughCallRecorder()
        let draft = PaperWalkthroughDraft(title: "Chapter walk", steps: [
            .init(kind: "explain", title: "Start", body: "B", figureLabel: nil, panelLabel: nil, passage: "Sleep pressure rises during waking", pageNumber: nil, animationBrief: nil, quiz: nil),
            .init(kind: "figure", title: "The model", body: "B", figureLabel: "Figure 2", panelLabel: nil, passage: nil, pageNumber: nil, animationBrief: nil, quiz: nil),
        ])
        let service = PaperWalkthroughGeneratorService(
            storage: storage,
            backend: CannedWalkthroughBackend(draft: draft, recorder: recorder),
            figureIndexer: PaperFigureIndexer(storage: storage, aiService: AIService())
        )
        let result = try await service.run(request: PaperWalkthroughRequest(sourceID: chapter.id, drawsAnimations: false))
        // The chapter's PDF is not on disk here, so the structural read fails
        // and the run goes on the way a paper's does: the figure step keeps its
        // words, and the warning names the index rather than the source type.
        #expect(result.walkthrough.steps.count == 2)
        #expect(result.walkthrough.steps[1].kind == .explain)
        #expect(result.warnings.contains { $0.contains("figure index could not be read") })
        #expect(!result.warnings.contains { $0.contains("shown as text") })
        #expect(try await storage.loadPaperWalkthrough(chapter.id)?.title == "Chapter walk")
    }

    @Test("Figure references collapse a caption continued onto the next page and carry known panels")
    func figureReferences() {
        let analysis = PaperFigureAnalysis(
            summary: "s", visualEvidence: [], figureRect: nil,
            panels: [PaperFigurePanel(id: "p1", label: "a", explanation: "e", rect: nil)],
            analysisVersion: PaperFigureAnalysis.currentVersion, generatedAt: Date()
        )
        let records = [
            PaperFigureRecord(id: "f2b", sourceID: "s", figureLabel: "Figure 2", pageIndex: 4, caption: "See previous page.", analysis: nil),
            PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 1, caption: "One.", analysis: nil),
            PaperFigureRecord(id: "f2", sourceID: "s", figureLabel: "Figure 2", pageIndex: 3, caption: "Two.", analysis: analysis),
        ]
        let references = PaperWalkthroughGeneratorService.figureReferences(from: records)
        #expect(references.map(\.label) == ["Figure 1", "Figure 2"])
        #expect(references[1].pageNumber == 4)
        #expect(references[1].panelLabels == ["a"])
        #expect(references[0].reading == nil)
        #expect(references[1].reading == "s\nPanel a: e")
    }

    @Test("A figure's reading is its analysis in prose: summary, what is visible, each panel; an empty analysis reads as nothing")
    func figureReading() {
        let analysis = PaperFigureAnalysis(
            summary: "Time courses of sodium and pressure.",
            visualEvidence: ["Red circles rise to 1.3 between 25 and 40 minutes.", " "],
            figureRect: nil,
            panels: [
                PaperFigurePanel(id: "a", label: "a", explanation: "Sodium over time.", rect: nil),
                PaperFigurePanel(id: "b", label: "b", explanation: "", rect: nil),
            ],
            analysisVersion: PaperFigureAnalysis.currentVersion, generatedAt: Date()
        )
        let reading = PaperWalkthroughGeneratorService.figureReading(analysis)
        #expect(reading == """
        Time courses of sodium and pressure.
        Visible: Red circles rise to 1.3 between 25 and 40 minutes.
        Panel a: Sodium over time.
        """)
        let empty = PaperFigureAnalysis(summary: " ", visualEvidence: [], figureRect: nil, panels: [], analysisVersion: 1, generatedAt: Date())
        #expect(PaperWalkthroughGeneratorService.figureReading(empty) == nil)
    }

    @Test("The drawer's excerpt is the source's own paragraphs that cite the step's figure, caption left out, or the paragraph holding its passage")
    func sourceExcerpt() {
        let text = """
        We first established a protocol whereby sodium can be raised (Fig. 1a) and lowered again.

        Fig. 1 | Intracellular Na elevation and contractility. a Time-courses of intracellular Na.

        The increase in pressure was titrated back to baseline with PAB (Fig. 1d), holding ATP demand constant.

        Figure 10 shows something else entirely, and Extended Data Fig. 1 shows the control.

        ATP levels were significantly reduced during the Na elevation period (Fig. 2a).
        """
        let figureStep = step(.figure, title: "Design", figure: "Figure 1")
        let excerpt = PaperWalkthroughGeneratorService.sourceExcerpt(for: figureStep, in: text)
        #expect(excerpt == """
        We first established a protocol whereby sodium can be raised (Fig. 1a) and lowered again.

        The increase in pressure was titrated back to baseline with PAB (Fig. 1d), holding ATP demand constant.
        """)
        let extended = step(.figure, title: "Control", figure: "Extended Data Figure 1")
        #expect(PaperWalkthroughGeneratorService.sourceExcerpt(for: extended, in: text)?.hasPrefix("Figure 10 shows") == true)
        let passageStep = step(.explain, title: "ATP", passage: "ATP levels were significantly reduced")
        #expect(PaperWalkthroughGeneratorService.sourceExcerpt(for: passageStep, in: text)?.hasSuffix("(Fig. 2a).") == true)
        #expect(PaperWalkthroughGeneratorService.sourceExcerpt(for: step(.figure, figure: "Figure 7"), in: text) == nil)
        #expect(PaperWalkthroughGeneratorService.sourceExcerpt(for: step(.explain), in: text) == nil)
        // Over budget: whole paragraphs in order until the budget, never a cut paragraph after a kept one.
        let long = String(repeating: "Fig. 3 is cited here. ", count: 200)
        let budgeted = PaperWalkthroughGeneratorService.sourceExcerpt(for: step(.figure, figure: "Figure 3"), in: long + "\n\n" + long)
        #expect(budgeted?.count ?? 0 <= PaperWalkthroughGeneratorService.excerptCharacterBudget + 1)
    }

    @Test("The drawer's turn carries the figure's reading, the source's own words and the brief as what the learner should understand")
    func animatorTurn() {
        var paper = StudioArticle(url: "https://example.com/p", title: "Sodium paper", sourceType: .paper)
        paper.author = "Chung"
        var figure = PaperWalkthroughFigureReference(label: "Figure 1", pageNumber: 2, caption: "Fig. 1 | Intracellular Na elevation.", panelLabels: ["a", "b"])
        figure.reading = "Panel a: Na rises to 1.3 under ouabain."
        let briefed = PaperWalkthroughStep(
            id: "step-2", kind: .figure, title: "Building a controlled sodium challenge", body: "Start with panel a.",
            anchor: PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: nil, pageNumber: 2),
            animationBrief: "The learner should see that PAB holds the work constant while sodium rises."
        )
        let message = PaperWalkthroughGeneratorService.animatorUserMessage(
            source: paper, step: briefed, figure: figure,
            excerpt: "PAB did not attenuate the rise in [Na]i in response to ouabain."
        )
        #expect(message.hasPrefix("Paper: Sodium paper\nStep: Building a controlled sodium challenge\nFigure: Figure 1 — Fig. 1 | Intracellular Na elevation."))
        #expect(message.contains("What the figure shows (from looking at it):\nPanel a: Na rises to 1.3 under ouabain."))
        #expect(message.contains("The source's own words about this (use its measured values; invent none):\nPAB did not attenuate"))
        #expect(message.hasSuffix("Brief — what the learner should come away understanding:\nThe learner should see that PAB holds the work constant while sodium rises."))
        // No reading, no excerpt, no brief: the turn says so plainly and asks for the step text in motion.
        let bare = PaperWalkthroughGeneratorService.animatorUserMessage(source: paper, step: step(.explain, title: "T", body: "B"), figure: nil)
        #expect(!bare.contains("What the figure shows"))
        #expect(!bare.contains("own words"))
        #expect(bare.hasSuffix("Brief — what the learner should come away understanding:\nDraw what the step text describes, in motion."))
        // The drawer is told to plan before it draws, and what the plan holds.
        for heading in ["Point:", "Why the figure is hard:", "Draw:", "Compare:", "Numbers:", "Last frame:"] {
            #expect(Prompts.walkthroughAnimator.contains(heading))
        }
        #expect(Prompts.walkthroughWriter.contains("A brief is a teaching plan, not a scene."))
    }

    @Test("A figure whose page only says See next page for caption reads its words from the continuation row and keeps its page")
    func continuedCaptionReadsFromNextPage() {
        let records = [
            PaperFigureRecord(id: "e1", sourceID: "s", figureLabel: "Extended Data Figure 1", pageIndex: 18, caption: "Extended Data Fig. 1 | See next page for caption.", analysis: nil),
            PaperFigureRecord(id: "e1c", sourceID: "s", figureLabel: "Extended Data Figure 1", pageIndex: 19, caption: "Extended Data Fig. 1 | Elevated NADH/NAD+ ratio drives 2-HG accumulation. a, Schematic.", analysis: nil),
            PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 2, caption: "Fig. 1 | Main.", analysis: nil),
        ]
        #expect(PaperFigureCaptionTitle.isContinuedCaption("Extended Data Fig. 1 | See next page for caption."))
        #expect(!PaperFigureCaptionTitle.isContinuedCaption("Fig. 1 | Main."))
        #expect(PaperWalkthroughGeneratorService.displayCaption(for: records[0], in: records).hasPrefix("Extended Data Fig. 1 | Elevated"))
        #expect(PaperWalkthroughGeneratorService.displayCaption(for: records[2], in: records) == "Fig. 1 | Main.")
        let shown = PaperWalkthroughGeneratorService.displayRecord(for: records[0], in: records)
        #expect(shown.pageIndex == 18)
        #expect(PaperFigureCaptionTitle.title(from: shown.caption) == "Elevated NADH/NAD+ ratio drives 2-HG accumulation")
        #expect(PaperFigureCaptionTitle.panelCaption(for: "a", in: shown.caption)?.hasPrefix("Schematic") == true)
        let references = PaperWalkthroughGeneratorService.figureReferences(from: records)
        #expect(references.map(\.label) == ["Figure 1", "Extended Data Figure 1"])
        #expect(references[1].pageNumber == 19)
        #expect(references[1].caption.hasPrefix("Extended Data Fig. 1 | Elevated"))
    }

    @Test("The writer's turn names the figures with their pages and says when the text was cut")
    func writerTurn() {
        var article = StudioArticle(url: "https://example.com/p", title: "Sleep paper", sourceType: .paper)
        article.author = "Sarnataro"
        let message = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: true, figures: figures)
        #expect(message.contains("Paper: Sleep paper"))
        #expect(message.contains("Authors: Sarnataro"))
        #expect(message.contains("- Figure 2 · page 4 · Figure 2 | A mitochondrial electron surplus induces sleep. · panels: a, b"))
        #expect(message.contains("the opening only"))
        let whole = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: [])
        #expect(whole.contains("none could be read"))
        #expect(!whole.contains("the opening only"))
    }

    @Test("The writer's turn hands over the words a figure prints, so a step can say what its axes are")
    func writerTurnCarriesPrintedText() {
        // Fig. 1 of the cardiac-sodium paper (2026-09-20): the caption says
        // "time-courses of intracellular Na" and nothing about units or the
        // baseline; the axis titles, the tick units and the treatment bars
        // are printed inside the figure, and only the text layer has them.
        var figure = PaperWalkthroughFigureReference(
            label: "Figure 1", pageNumber: 2,
            caption: "Fig. 1 | Intracellular Na elevation and contractility. a Time-courses of intracellular Na.",
            panelLabels: ["a", "b", "c", "d"]
        )
        figure.printedText = ["23Na TQF (intracellular Na)", "relative to baseline (arb. units)", "LVDP (mmHg)", "ouabain", "washout", "Time (min)", "PAB", "ouab+PAB"]
        figure.reading = "Four time courses; sodium rises under ouabain and returns after washout."
        let article = StudioArticle(url: "https://example.com/p", title: "Sodium paper", sourceType: .paper)
        let message = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: [figure])
        #expect(message.contains("the words printed inside the figure"))
        #expect(message.contains("- Figure 1 · page 2 · Fig. 1 | Intracellular Na elevation and contractility. a Time-courses of intracellular Na. · panels: a, b, c, d · printed in the figure: 23Na TQF (intracellular Na); relative to baseline (arb. units); LVDP (mmHg); ouabain; washout; Time (min); PAB; ouab+PAB · seen: Four time courses;"))
        let bare = PaperWalkthroughFigureReference(label: "Figure 2", pageNumber: 3, caption: "Fig. 2 | Raster.", panelLabels: [])
        let plain = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: [bare])
        #expect(plain.contains("- Figure 2 · page 3 · Fig. 2 | Raster.\n"))
        #expect(!plain.contains("printed in the figure"))
    }

    @Test("The toast summary counts steps, questions and animations and says what failed")
    func summary() {
        let walkthrough = PaperWalkthrough(
            sourceID: "s", sourceSHA256: "h", title: "W",
            steps: [
                PaperWalkthroughStep(id: "1", kind: .quiz, title: "t", body: "b", quiz: PaperWalkthroughQuiz(question: "q", answer: "a")),
                PaperWalkthroughStep(id: "2", kind: .figure, title: "t", body: "b", animationHTML: "<html></html>"),
            ],
            author: .app
        )
        let result = PaperWalkthroughGenerationResult(walkthrough: walkthrough, warnings: [], replacedExisting: true, animationFailures: ["x: failed"])
        #expect(WalkthroughGenerationCoordinator.summary(of: result) == "Walkthrough rewritten: 2 steps, 1 questions, 1 animations. 1 animation could not be drawn")
    }

    @Test("The writer opens in the field and closes there, and holds its own knowledge to a stricter standard than the text")
    func writerSituatesTheText() {
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains("where the text sits in its field"))
        #expect(prompt.contains("The first step situates the text before the walk gets specific"))
        #expect(prompt.contains("This is where your own knowledge of the field's history and debates belongs"))
        #expect(prompt.contains("never a particular finding, number, author, paper or year you cannot vouch for"))
        #expect(prompt.contains("The last step closes the same way: what changes for the field if the authors are right"))
        // The grounding rule names the field context as an exception rather
        // than forbidding it, and since 2026-09-30 the textbook background a
        // newcomer needs as the other, never as the text's finding.
        #expect(prompt.contains("except the field context of the first and last steps"))
        #expect(prompt.contains("and the textbook background a newcomer needs anywhere in the walk"))
        #expect(prompt.contains("told as background and never as the text's finding"))
        #expect(!prompt.contains("This is the one place your own knowledge of the field belongs"))
        #expect(!prompt.contains("and sets up the question;"))
    }

    @Test("The writer explains the way a textbook does, for a newcomer unless the learner has said where they are coming from, and asks about the argument rather than its vocabulary")
    func writerExplainsLikeATextbook() throws {
        // The product owner (2026-09-30), of the assistant-written walk of the SoTA
        // letter "Metabolism as inference": "i don't think this is an
        // example that is really intelligible to a human"; he asked for it
        // "much more like a biology textbook; simply and step by step". Its
        // first six steps named eight scientists and three companies, its
        // terms were defined in Say more chips, and 18 of its 20 questions
        // asked for the letter's labels.
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains(Prompts.textbookExplanation))
        #expect(Prompts.textbookExplanation.contains("Start from something concrete the reader can picture"))
        #expect(Prompts.textbookExplanation.contains("Teach the parts before the process"))
        #expect(Prompts.textbookExplanation.contains("bring in at most one or two new terms at a time"))
        #expect(Prompts.textbookExplanation.contains("Translate the source's language instead of rewording it"))
        #expect(Prompts.textbookExplanation.contains("Say how each point follows from the one before"))
        #expect(prompt.contains("Pitch it to the learner."))
        #expect(prompt.contains("Never leave one to a Say more chip alone."))
        #expect(prompt.contains("A beat carries on from the one before it in words"))
        #expect(prompt.contains("is taught through a concrete case first"))
        #expect(prompt.contains("Nor are they reworded into sentences just as dense"))
        #expect(prompt.contains("in plain words and at most about twenty words"))
        #expect(!prompt.contains("Define the argument's prerequisites this way where they first matter, rather than in a beat every learner must read."))
        // The questions ask about the argument.
        #expect(prompt.contains("Aimed at the argument: a question strengthens what it asks and little else"))
        #expect(prompt.contains("never \"What does the author call X?\""))
        #expect(!prompt.contains("most questions are about facts and vocabulary"))
        #expect(prompt.contains("where the result is not what a newcomer would expect"))
        // The argument pass writes claims a learner can say back.
        let mapper = Prompts.walkthroughArgumentMapper
        #expect(mapper.contains("in plain words and at most about twenty words"))
        #expect(mapper.contains("two points joined by a semicolon are two claims"))
        #expect(mapper.contains("each claim says whose it is"))

        // The writer is told who the learner is when they have said, on one line.
        let article = StudioArticle(url: "https://example.com/p", title: "P", sourceType: .paper, discoveryOrigin: .manual)
        let pitched = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: [], learner: "I run a cell biology lab.\n\nNew to active inference.")
        #expect(pitched.contains("The learner, on where they are coming from, in their own words: I run a cell biology lab. New to active inference."))
        for silent in [nil, "", "  \n "] as [String?] {
            let unpitched = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: [], learner: silent)
            #expect(!unpitched.contains("The learner, on where they are coming from"))
        }

        // Every other prompt that explains a source explains the same way.
        for other in [Prompts.courseLessonWriter, Prompts.explainerWriter, Prompts.studyChat, Prompts.summaryChat, Prompts.reviewTutor, Prompts.appAssistant, Prompts.deepRead] {
            #expect(other.contains(Prompts.textbookExplanation))
        }

        // An assistant's walk is held to the same rules.
        let save = try #require(MCPToolRegistry.shared.tools.first(where: { $0.name == "save_walkthrough" }))
        #expect(save.description.contains("Explain it the way a good textbook does"))
        #expect(save.description.contains("when their About you is set (get_app_settings, account.about_you), pitch it to them instead"))
        #expect(save.description.contains("never \"what does the author call X\""))
        #expect(!save.description.contains("mostly facts and vocabulary"))
        let generate = try #require(MCPToolRegistry.shared.tools.first(where: { $0.name == "generate_walkthrough" }))
        #expect(generate.description.contains("It explains the way a good textbook does"))
    }

    @Test("The writer asks quantum.country's kind of question: one detail, precise, quick to check, right after the point it tests")
    func writerAsksMnemonicMediumQuestions() {
        // The product owner (2026-09-23), pointing at quantum.country/qcvc: "i mostly
        // mean these interspersed questions". The same rules are the plugin's
        // foreverlm-walkthrough skill.
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains("right after the point it tests"))
        #expect(prompt.contains("One detail each: one question, one fact, one short answer."))
        #expect(prompt.contains("Precise: only one answer is right."))
        #expect(prompt.contains("Quick to check:"))
        #expect(prompt.contains("never a card's sentence copied with a word blanked out"))
        #expect(prompt.contains("From more than one side:"))
        #expect(prompt.contains("Standalone:"))
        #expect(prompt.contains("Most questions are \"recall\""))
        #expect(!prompt.contains("each used at least once when the text allows it"))
        #expect(PaperWalkthroughValidation.maximumQuestions >= 20, "the prompt asks for at most twenty")
    }

    @Test("The writer makes one point a step: a figure step is one panel, a setup step goes unanchored, and the retry asks for a step per panel")
    func writerMakesOnePointAStep() {
        // The product owner (2026-09-21): "I want each point of the walkthrough sort of
        // to illustrate one point pretty clearly … look at panel A of this
        // paper and it highlights it. And then it just tries to explain what's
        // going on"; and a step that only summarises the setup "can just do
        // that in the chat" without marking text.
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains("One step, one point."))
        #expect(prompt.contains("A figure step is about one panel."))
        #expect(prompt.contains("Never write one step that tours a whole multi-panel figure."))
        #expect(prompt.contains("A step that sets up or sums up needs no anchor"))
        #expect(prompt.contains("Do not mark a passage merely to have something marked."))
        #expect(prompt.contains("Ten to thirty steps"))
        #expect(!prompt.contains("one step reads the whole figure"))
        #expect(!prompt.contains("two to five short paragraphs"))
        #expect(PaperWalkthroughValidation.maximumSteps >= 30, "a paper with five four-panel figures needs the room")
        // Since 2026-09-23 the walk teaches claims (the merged lesson): one
        // chapter a claim, the four question kinds and Say more chips, and a
        // step of its own only for a panel that carries a claim. Since
        // 2026-09-29 the other panels of a figure it shows are named in a
        // beat (writerWalksFiguresInPrintedOrder).
        #expect(prompt.contains("Teach the argument's claims, not a tour of the figures."))
        #expect(prompt.contains("One chapter per claim"))
        #expect(prompt.contains("A panel that carries no claim gets no step of its own"))
        #expect(!prompt.contains("Teach the argument, not the figures in printed order."))
        #expect(prompt.contains("\"think_first\""))
        #expect(prompt.contains("\"predict\""))
        #expect(prompt.contains("\"find\""))
        #expect(prompt.contains("\"more\" chips"))
        #expect(prompt.contains("\"chapters\""))
        // The argument pass is its own prompt, handed to the writer as lines.
        let mapper = Prompts.walkthroughArgumentMapper
        #expect(mapper.contains("three to seven claims, in teaching order"))
        let argument = PaperWalkthroughArgumentMap(title: "T", question: "Q?", claims: [.init(title: "A", claim: "B.", evidence: ["Figure 1a"])], prerequisites: ["NMR"])
        let withArgument = PaperWalkthroughGeneratorService.writerUserMessage(
            source: StudioArticle(url: "https://example.com/p", title: "P", sourceType: .paper, discoveryOrigin: .manual),
            text: "TEXT", truncated: false, figures: [], argument: argument
        )
        #expect(withArgument.contains("The argument to teach, one chapter per claim:"))
        #expect(withArgument.contains("1. A — B. [evidence: Figure 1a]"))
        #expect(withArgument.contains("Terms a newcomer needs: NMR"))
        // A text source is told the same: a passage where the point is in the words, none otherwise.
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, discoveryOrigin: .manual)
        article.domain = "example.com"
        let turn = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: [])
        #expect(turn.contains("a step that sets up or sums up stays unanchored"))
        #expect(!turn.contains("anchor each step"))
    }

    @Test("The writer meets the figures in printed order and says why when it jumps; a figure is one run with every panel addressed, each read by its own axes")
    func writerWalksFiguresInPrintedOrder() throws {
        // 2026-09-29, the app's walk of "Engineered human resilience and
        // durability": its first claim was the Summary's headline, whose only
        // figure is Figure 3, so Figure 3 came at step 3, before Figures 1
        // and 2; Figure 2B and Figure 3 were each outlined three times,
        // Figure 2A never, and the 2B step read panel A's axes.
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains("Walk the figures in the order the text prints them."))
        #expect(prompt.contains("Figure 1 before Figure 2 before Figure 3, and within a figure panel a, then b, then c"))
        #expect(prompt.contains("set that headline up in words, and show its figure where the order reaches it"))
        #expect(prompt.contains("its first beat says why the walk jumps ahead and when the earlier figures come"))
        #expect(prompt.contains("A figure is walked in one run of consecutive steps"))
        #expect(prompt.contains("At most one of its panels is outlined again later"))
        #expect(prompt.contains("give that step a \"picture\" of it rather than another step outlining it"))
        #expect(prompt.contains("Every panel of a figure you show is addressed before the walk leaves it."))
        #expect(prompt.contains("a beat that points at it and says in a few words what it shows ({\"text\": \"Panel c repeats this in liver.\", \"panel_label\": \"c\"})"))
        #expect(prompt.contains("Each panel has its own axes"))
        #expect(prompt.contains("never describe a neighbouring panel's"))
        #expect(!prompt.contains("in the order the claim needs them"))
        #expect(!prompt.contains("Leave a panel out when it carries no claim."))

        // The first pass orders the claims the same way, so a headline no
        // longer opens the walk on a late figure.
        let mapper = Prompts.walkthroughArgumentMapper
        #expect(mapper.contains("meeting the figures in the order the text prints them unless the argument cannot be taught that way"))
        #expect(mapper.contains("The claims follow the figures' printed order"))
        #expect(mapper.contains("A headline the text states first, in its abstract or summary, is taught where its figure falls in that order, not first"))
        #expect(!mapper.contains("not in the order the text prints it"))

        // An assistant's save_walkthrough is held to the same rules.
        let tool = try #require(MCPToolRegistry.shared.tools.first(where: { $0.name == "save_walkthrough" }))
        #expect(tool.description.contains("meet the figures in the order the source prints them"))
        #expect(tool.description.contains("says why, and when the earlier figures come, in its first beat"))
        #expect(tool.description.contains("Walk each figure in one run of steps"))
        #expect(tool.description.contains("has every panel inspect_paper_figure lists addressed before the walk leaves it"))
        #expect(tool.description.contains("what that panel's own x and y axes plot (never a neighbouring panel's)"))
        #expect(!tool.description.contains("not the figures in printed order"))
    }

}
