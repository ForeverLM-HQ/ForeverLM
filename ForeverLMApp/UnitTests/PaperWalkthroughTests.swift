import Foundation
import PDFKit
import SQLite3
import Testing
@testable import ForeverLM

// MARK: - Fixtures

private func makeTemporaryStorage(_ name: String) -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PaperWalkthroughTests_\(name)_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

private func seedArticle(
    _ storage: StorageService,
    url: String = "https://example.com/paper",
    title: String = "A paper",
    content: String
) async throws -> StudioArticle {
    var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual)
    article.author = "A. Author"
    article.content = content
    article.wordCount = content.split(separator: " ").count
    article.state = .ready
    try await storage.saveSource(article)
    return article
}

/// A book chapter as the importer saves one: a `.book` row under its book's
/// group, its file (a PDF split from the book, or an EPUB's text) and its
/// text, ready. The file itself is not written.
private func seedChapter(
    _ storage: StorageService,
    file: String,
    book: String = "Sleep",
    title: String = "Chapter 3",
    content: String
) async throws -> StudioArticle {
    var chapter = StudioArticle(url: file, title: title, sourceType: .book, discoveryOrigin: .manual, parentGroup: book, localFilePath: file)
    chapter.normalizedURL = URLNormalizer.normalize(file)
    chapter.content = content
    chapter.wordCount = content.split(separator: " ").count
    chapter.state = .ready
    try await storage.saveSource(chapter)
    return chapter
}

private let paperText = """
Sleep pressure rises during waking. We measured ATP in dorsal fan-shaped body neurons and found that \
ATP concentrations were about 1.2 times higher after sleep deprivation than at rest. \
Expressing UCP4 reduced sleep, whereas light-driven proton pumping increased it. \
Figure 2 shows the mitochondrial electron surplus model.
"""

private let figures = [
    PaperWalkthroughFigureReference(label: "Figure 1", pageNumber: 2, caption: "Figure 1 | Sleep in flies.", panelLabels: []),
    PaperWalkthroughFigureReference(label: "Figure 2", pageNumber: 4, caption: "Figure 2 | A mitochondrial electron surplus induces sleep.", panelLabels: ["a", "b"]),
]

private func step(
    _ kind: PaperWalkthroughStep.Kind,
    title: String = "A step",
    body: String = "Some words.",
    figure: String? = nil,
    panel: String? = nil,
    passage: String? = nil,
    page: Int? = nil,
    animation: String? = nil,
    quiz: PaperWalkthroughQuiz? = nil
) -> PaperWalkthroughStep {
    let anchor = PaperWalkthroughAnchor(figureLabel: figure, panelLabel: panel, passage: passage, pageNumber: page)
    return PaperWalkthroughStep(
        id: "",
        kind: kind,
        title: title,
        body: body,
        anchor: anchor.isEmpty ? nil : anchor,
        animationHTML: animation,
        quiz: quiz
    )
}

// MARK: - Validation

@Suite("Walkthrough validation")
struct PaperWalkthroughValidationTests {

    @Test("A draft whose animation brief comes back as an object or a list still decodes, the brief read as its text")
    func structuredBriefDecodes() throws {
        let json = """
        {"title": "W", "steps": [
          {"kind": "figure", "title": "A", "beats": ["Look."], "animation_brief": {"": "Show the measured changes."}},
          {"kind": "explain", "title": "B", "beats": ["Then."], "animation_brief": ["One sentence.", "What moves."]},
          {"kind": "explain", "title": "C", "beats": ["End."], "animation_brief": 3}
        ]}
        """
        let draft = try JSONDecoder().decode(PaperWalkthroughDraft.self, from: Data(json.utf8))
        #expect(draft.steps.map(\.animationBrief) == ["Show the measured changes.", "One sentence. What moves.", nil])
    }

    @Test("Figure and passage anchors that the paper carries are kept, and steps are numbered")
    func keepsRealAnchors() throws {
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "The cost of being awake",
            steps: [
                // Figure 2 has panels a and b; a step about a that also names b leaves none unaddressed.
                step(.figure, title: "The model", body: "Panel a draws the model; panel b measures it.", figure: "Figure 2", panel: "a"),
                step(.explain, title: "The measurement", passage: "ATP concentrations were about 1.2 times higher after sleep deprivation than at rest"),
            ],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: figures,
            text: paperText,
            author: .app
        )
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.walkthrough.steps.map(\.id) == ["step-1", "step-2"])
        #expect(outcome.walkthrough.steps[0].anchor?.figureLabel == "Figure 2")
        #expect(outcome.walkthrough.steps[0].anchor?.panelLabel == "a")
        #expect(outcome.walkthrough.steps[0].anchor?.pageNumber == 4)
        #expect(outcome.walkthrough.steps[1].anchor?.passage?.hasPrefix("ATP concentrations") == true)
        #expect(outcome.walkthrough.author == .app)
    }

    @Test("A figure step carries the sentence of the text that cites its panel, the caption left out; a panel never cited falls back to the figure's own citation; a figure never cited carries none")
    func figureStepsCarryTheAuthorsSentence() throws {
        let text = """
        Sleep pressure rises during waking. Fig. 2 | A mitochondrial electron surplus induces sleep. a, ATP over time. b, Sleep after UCP4.
        We measured ATP in dorsal fan-shaped body neurons (Fig. 2a) and found that ATP concentrations were about 1.2 times higher after sleep depri-
        vation than at rest (Extended Data Fig. 2a), as reported by Smith et al. (2021).
        Expressing UCP4 reduced sleep, whereas light-driven proton pumping increased it (Fig. 2b, c).
        Figure 20 shows something else. The model as a whole is drawn in Fig. 2.
        """
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: [
                step(.figure, title: "ATP", figure: "Figure 2", panel: "a"),
                step(.figure, title: "Sleep", figure: "Figure 2", panel: "C"),
                step(.figure, title: "Nothing cites d", figure: "Fig. 2", panel: "d"),
                step(.figure, title: "Never cited", figure: "Figure 1"),
                step(.explain, title: "No anchor"),
            ],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: figures,
            text: text,
            author: .app
        )
        let mentions = outcome.walkthrough.steps.map(\.sourceMention)
        #expect(mentions[0] == "We measured ATP in dorsal fan-shaped body neurons (Fig. 2a) and found that ATP concentrations were about 1.2 times higher after sleep deprivation than at rest (Extended Data Fig. 2a), as reported by Smith et al. (2021).")
        #expect(mentions[1] == "Expressing UCP4 reduced sleep, whereas light-driven proton pumping increased it (Fig. 2b, c).")
        #expect(mentions[2] == "The model as a whole is drawn in Fig. 2.")
        #expect(mentions[3] == nil)
        #expect(mentions[4] == nil)
        // The mention rides the record's JSON, and a record without it is given it from the text.
        let json = try PaperWalkthroughCoding.json(outcome.walkthrough)
        #expect(json.contains("\"source_mention\""))
        #expect(try PaperWalkthroughCoding.walkthrough(fromJSON: json).steps.map(\.sourceMention) == mentions)
        var bare = outcome.walkthrough
        for index in bare.steps.indices { bare.steps[index].sourceMention = nil }
        #expect(bare.needsSourceMentions)
        #expect(bare.fillingSourceMentions(from: text).steps.map(\.sourceMention) == mentions)
        // A record whose figure the text never cites still says it needs a look, and the look changes nothing.
        #expect(outcome.walkthrough.needsSourceMentions)
        #expect(outcome.walkthrough.fillingSourceMentions(from: text) == outcome.walkthrough)
    }

    @Test("An invented figure loses its anchor and becomes an explanation; an invented quote loses the passage")
    func dropsInventedAnchors() throws {
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: [
                step(.figure, title: "Nothing here", figure: "Figure 7"),
                step(.explain, title: "Misquoted", passage: "the authors conclude that sleep is optional"),
            ],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: figures,
            text: paperText,
            author: .assistant
        )
        #expect(outcome.warnings.count == 2)
        #expect(outcome.walkthrough.steps[0].kind == .explain)
        #expect(outcome.walkthrough.steps[0].anchor == nil)
        #expect(outcome.walkthrough.steps[1].anchor == nil)
    }

    @Test("A quote is matched through line-break hyphens, ligatures and case")
    func matchesThroughTypography() throws {
        let text = "The dorsal fan-shaped body neu-\nrons ﬁre during sleep."
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: [step(.explain, passage: "fan-shaped body neurons fire during sleep")],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: [],
            text: text,
            author: .app
        )
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.walkthrough.steps[0].anchor?.passage == "fan-shaped body neurons fire during sleep")
    }

    @Test("A question needs a reference answer; one without is dropped and the step explains instead")
    func validatesQuizzes() throws {
        let good = PaperWalkthroughQuiz(question: "Which rose after deprivation?", answer: "ATP, about 1.2 times.", keyPoints: ["ATP", "1.2 times"])
        let bad = PaperWalkthroughQuiz(question: "?", answer: "   ")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: [step(.quiz, quiz: good), step(.quiz, quiz: bad), step(.explain, quiz: good)],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: figures,
            text: paperText,
            author: .app
        )
        #expect(outcome.walkthrough.steps[0].kind == .quiz)
        #expect(outcome.walkthrough.steps[0].quiz == good)
        #expect(outcome.walkthrough.steps[1].kind == .explain)
        #expect(outcome.walkthrough.steps[1].quiz == nil)
        // A quiz on a step that called itself an explanation is still a quiz.
        #expect(outcome.walkthrough.steps[2].kind == .quiz)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.walkthrough.quizCount == 2)
    }

    @Test("An animation over the size limit is dropped, and no more than six are kept")
    func boundsAnimations() throws {
        let huge = String(repeating: "x", count: PaperWalkthroughValidation.maximumAnimationCharacters + 1)
        var steps = [step(.explain, animation: huge)]
        for _ in 0..<8 { steps.append(step(.explain, animation: "<!DOCTYPE html><html><body>ok</body></html>")) }
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: steps,
            sourceID: "src",
            sourceSHA256: "sha",
            figures: [],
            text: paperText,
            author: .assistant
        )
        #expect(outcome.walkthrough.steps[0].animationHTML == nil)
        #expect(outcome.walkthrough.animationCount == PaperWalkthroughValidation.maximumAnimationsPerWalkthrough)
        #expect(outcome.warnings.count == 3)
    }

    @Test("No usable steps, too many steps and an empty title are refused")
    func refusesEmpty() {
        #expect(throws: PaperWalkthroughValidation.Failure.self) {
            try PaperWalkthroughValidation.walkthrough(
                title: "Walk", steps: [step(.explain, title: "", body: "")],
                sourceID: "src", sourceSHA256: "sha", figures: [], text: paperText, author: .app
            )
        }
        #expect(throws: PaperWalkthroughValidation.Failure.self) {
            try PaperWalkthroughValidation.walkthrough(
                title: "  ", steps: [step(.explain)],
                sourceID: "src", sourceSHA256: "sha", figures: [], text: paperText, author: .app
            )
        }
        #expect(throws: PaperWalkthroughValidation.Failure.self) {
            try PaperWalkthroughValidation.walkthrough(
                title: "Walk", steps: Array(repeating: step(.explain), count: PaperWalkthroughValidation.maximumSteps + 1),
                sourceID: "src", sourceSHA256: "sha", figures: [], text: paperText, author: .app
            )
        }
    }

    @Test("Questions are counted apart from the step limit, as the writer is asked for them")
    func questionsSitOnTopOfTheStepLimit() throws {
        // The MitoSpace walk (2026-09-23): thirty-odd steps and their
        // questions came to 44, and the whole draft was refused.
        let quiz = PaperWalkthroughQuiz(question: "What does the control show?", answer: "No change without the drug.")
        let points = Array(repeating: step(.explain), count: PaperWalkthroughValidation.maximumSteps)
        let questions = Array(repeating: step(.quiz, body: "", quiz: quiz), count: 12)
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: points + questions,
            sourceID: "src", sourceSHA256: "sha", figures: [], text: paperText, author: .app
        )
        #expect(outcome.walkthrough.steps.count == PaperWalkthroughValidation.maximumSteps + 12)
        #expect(throws: PaperWalkthroughValidation.Failure.tooManyQuestions(PaperWalkthroughValidation.maximumQuestions + 1)) {
            try PaperWalkthroughValidation.walkthrough(
                title: "Walk",
                steps: [step(.explain)] + Array(repeating: step(.quiz, body: "", quiz: quiz), count: PaperWalkthroughValidation.maximumQuestions + 1),
                sourceID: "src", sourceSHA256: "sha", figures: [], text: paperText, author: .app
            )
        }
    }

    @Test("Figure labels match through Fig. and a glued panel letter")
    func matchesLabels() {
        #expect(PaperWalkthroughValidation.figure(labelled: "Fig. 2", in: figures)?.label == "Figure 2")
        #expect(PaperWalkthroughValidation.figure(labelled: "figure 2a", in: figures)?.label == "Figure 2")
        #expect(PaperWalkthroughValidation.figure(labelled: "Figure 3", in: figures) == nil)
    }

    @Test("An Extended Data figure is its own label: it matches the writer's Fig. form and never the main figure of the same number")
    func matchesExtendedDataLabels() {
        let indexed = [
            PaperWalkthroughFigureReference(label: "Figure 2", pageNumber: 4, caption: "Figure 2 | Main.", panelLabels: ["A", "B"]),
            PaperWalkthroughFigureReference(label: "Extended Data Figure 2", pageNumber: 19, caption: "Extended Data Fig. 2 | Control.", panelLabels: ["A"]),
        ]
        #expect(PaperWalkthroughValidation.figure(labelled: "Extended Data Fig. 2", in: indexed)?.pageNumber == 19)
        #expect(PaperWalkthroughValidation.figure(labelled: "extended data figure 2a", in: indexed)?.pageNumber == 19)
        #expect(PaperWalkthroughValidation.figure(labelled: "Figure 2", in: indexed)?.pageNumber == 4)
        #expect(PaperWalkthroughValidation.figure(labelled: "Supplementary Figure 2", in: indexed) == nil)
    }

    @Test("The writer's draft becomes steps with kinds, anchors and briefs")
    func draftToSteps() {
        let draft = PaperWalkthroughDraft(title: "Walk", steps: [
            .init(kind: "Figure", title: "T", body: "B", figureLabel: "Figure 2", panelLabel: "b", passage: nil, pageNumber: 4, animationBrief: "Show electrons.", quiz: nil),
            .init(kind: "nonsense", title: "T2", body: "B2", figureLabel: nil, panelLabel: nil, passage: nil, pageNumber: nil, animationBrief: nil, quiz: nil),
        ])
        let steps = PaperWalkthroughValidation.steps(from: draft)
        #expect(steps.count == 2)
        #expect(steps[0].kind == .figure)
        #expect(steps[0].anchor?.panelLabel == "b")
        #expect(steps[0].animationBrief == "Show electrons.")
        #expect(steps[1].kind == .explain)
        #expect(steps[1].anchor == nil)
    }

    @Test("A walkthrough round-trips through its JSON with snake_case keys")
    func jsonRoundTrip() throws {
        let quiz = PaperWalkthroughQuiz(question: "Q", answer: "A", keyPoints: ["k1", "k2"])
        let walkthrough = PaperWalkthrough(
            sourceID: "src",
            sourceSHA256: "sha",
            title: "Walk",
            steps: [PaperWalkthroughStep(id: "step-1", kind: .quiz, title: "T", body: "B", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", pageNumber: 4), animationHTML: "<html></html>", animationBrief: "brief", quiz: quiz)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            author: .assistant
        )
        let json = try PaperWalkthroughCoding.json(walkthrough)
        #expect(json.contains("\"figure_label\""))
        #expect(json.contains("\"key_points\""))
        #expect(!json.contains("\"correct_index\""))
        #expect(json.contains("\"animation_html\""))
        let decoded = try PaperWalkthroughCoding.walkthrough(fromJSON: json)
        #expect(decoded == walkthrough)
        // A source walk names no subject, so a record saved before the key
        // encodes as it did; one read back without the key is a source walk.
        #expect(!json.contains("\"subject\""))
        #expect(decoded.subject == .source)
    }

    @Test("An animation walk and a step's animation reference round-trip; the reference's page address carries the walk parameters")
    func animationReferenceRoundTrip() throws {
        let reference = WalkthroughAnimationReference(animationID: "anim-1", step: 5, conditions: ["iono": "nig", "resp": "1"])
        let walkthrough = PaperWalkthrough(
            sourceID: "anim-1",
            sourceSHA256: PaperWalkthrough.animationFingerprint(linkedURL: "https://sites.foreverlm.com/pmf/", artifactID: "anim-1"),
            subject: .animation,
            title: "Two forces",
            steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "T", body: "B", animation: reference)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            author: .assistant
        )
        let json = try PaperWalkthroughCoding.json(walkthrough)
        #expect(json.contains("\"subject\":\"animation\""))
        #expect(json.contains("\"animation_ref\""))
        #expect(json.contains("\"animation_id\":\"anim-1\""))
        let decoded = try PaperWalkthroughCoding.walkthrough(fromJSON: json)
        #expect(decoded == walkthrough)
        #expect(decoded.steps[0].hasAnimation)
        #expect(decoded.animationCount == 1)
        #expect(decoded.referencedAnimationIDs == ["anim-1"])
        // A reference with no step and no conditions reads as step 1 of the default conditions.
        let bare = try JSONDecoder().decode(WalkthroughAnimationReference.self, from: Data("{\"animation_id\":\"x\"}".utf8))
        #expect(bare == WalkthroughAnimationReference(animationID: "x"))

        let url = reference.pageURL(animationURL: URL(string: "https://sites.foreverlm.com/pmf/?step=1&other=k")!)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "embed" }?.value == "1")
        #expect(items.first { $0.name == "step" }?.value == "5")
        #expect(items.first { $0.name == "c" }?.value == "iono:nig;resp:1")
        #expect(items.first { $0.name == "other" }?.value == "k")
        #expect(items.filter { $0.name == "step" }.count == 1)
        #expect(reference.summary == "step 5 · iono: nig, resp: 1")
    }

    @Test("A step shows a saved animation by reference; an animation walk drops anchors and keeps the words; a reference outranks an inline document")
    func animationReferences() throws {
        let steps = [
            PaperWalkthroughStep(id: "step-1", kind: .explain, title: "A", body: "B", anchor: PaperWalkthroughAnchor(passage: "some words"),
                                 animation: WalkthroughAnimationReference(animationID: " anim-1 ", step: 5, conditions: ["iono": " nig ", " ": "x", "resp": ""])),
            PaperWalkthroughStep(id: "step-2", kind: .figure, title: "C", body: "D", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2"),
                                 animationHTML: "<html></html>", animation: WalkthroughAnimationReference(animationID: "anim-1", step: 0)),
            PaperWalkthroughStep(id: "step-3", kind: .explain, title: "E", body: "F",
                                 animationHTML: "<html></html>", animation: WalkthroughAnimationReference(animationID: "anim-2", step: 2)),
        ]
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: steps, sourceID: "anim-1", sourceSHA256: "fp", subject: .animation,
            figures: [], allowsFigureAnchors: false, text: "", author: .assistant
        )
        #expect(outcome.walkthrough.subject == .animation)
        #expect(outcome.walkthrough.steps[0].animation == WalkthroughAnimationReference(animationID: "anim-1", step: 5, conditions: ["iono": "nig"]))
        #expect(outcome.walkthrough.steps[0].anchor == nil)
        // Step 0 is not a step: the reference goes, the inline document stays; the figure anchor goes too.
        #expect(outcome.walkthrough.steps[1].animation == nil)
        #expect(outcome.walkthrough.steps[1].animationHTML == "<html></html>")
        #expect(outcome.walkthrough.steps[1].anchor == nil)
        #expect(outcome.walkthrough.steps[1].kind == .explain)
        // Both given: the reference is kept.
        #expect(outcome.walkthrough.steps[2].animation?.animationID == "anim-2")
        #expect(outcome.walkthrough.steps[2].animationHTML == nil)
        #expect(outcome.warnings.contains { $0.contains("steps count from 1") })
        #expect(outcome.warnings.contains { $0.contains("no page to point at") && $0.contains("some words") })
        #expect(outcome.warnings.contains { $0.contains("no page to point at") && $0.contains("Figure 2") })
        #expect(outcome.warnings.contains { $0.contains("inline document was dropped") })
        #expect(outcome.walkthrough.referencedAnimationIDs == ["anim-1", "anim-2"])
        #expect(outcome.walkthrough.animationCount == 3)
    }

    @Test("A walkthrough saved with multiple-choice questions reads back as open questions, graded against the option marked correct")
    func legacyQuizDecodes() throws {
        let json = """
        {"version": 1, "source_id": "src", "source_sha256": "sha", "title": "Walk", "author": "app",
         "generated_at": "2026-09-18T10:00:00Z",
         "steps": [{"id": "step-3", "kind": "quiz", "title": "Why isolate?", "body": "",
                    "quiz": {"question": "Why could the signature only be found by isolating lysosomes?",
                             "options": ["Dilution in whole tissue", "The tag", "Mice"], "correct_index": 0,
                             "explanation": "Whole-tissue measurements average over every organelle."}}]}
        """
        let decoded = try PaperWalkthroughCoding.walkthrough(fromJSON: json)
        let quiz = try #require(decoded.steps[0].quiz)
        #expect(decoded.isUsable)
        #expect(quiz.question.hasPrefix("Why could"))
        #expect(quiz.answer == "Dilution in whole tissue Whole-tissue measurements average over every organelle.")
        #expect(quiz.keyPoints.isEmpty)
        #expect(quiz.isValid)
        // Re-encoding writes the open shape; the options are gone for good.
        let reencoded = try PaperWalkthroughCoding.json(decoded)
        #expect(reencoded.contains("\"answer\""))
        #expect(!reencoded.contains("\"options\""))
        // A legacy quiz whose correct index points nowhere still yields its explanation.
        #expect(PaperWalkthroughQuiz.legacyReferenceAnswer(options: ["a"], correctIndex: 7, explanation: "Because.") == "Because.")
        #expect(PaperWalkthroughQuiz.legacyReferenceAnswer(options: [], correctIndex: nil, explanation: "") == "")
    }

    @Test("A figure the walk visits must have every known panel addressed, in order")
    func panelCoverage() throws {
        let figures = [
            PaperWalkthroughFigureReference(label: "Figure 3", pageNumber: 24, caption: "Fig. 3. Lysosomes.", panelLabels: ["A", "B", "C", "D", "E"]),
            PaperWalkthroughFigureReference(label: "Figure 4", pageNumber: 25, caption: "Fig. 4. Microglia.", panelLabels: ["A", "B", "C"]),
            PaperWalkthroughFigureReference(label: "Figure 5", pageNumber: 26, caption: "Fig. 5. Levels.", panelLabels: ["A", "B"]),
        ]
        // Figure 3: one step anchored to A whose body names B and C, then a step for panels D–E.
        // Figure 4: a step anchored to c alone — A and B are never addressed.
        // Figure 5: no step at all — not this rule's business.
        let steps = [
            step(.figure, title: "Bubbles", body: "Start with panel A. Panel B repeats it in liver; panels B and C agree.", figure: "Figure 3", panel: "a"),
            step(.figure, title: "The rest", body: "Panels D–E show the volcano plots (Fig. 3E in old mice).", figure: "Figure 3", panel: "d"),
            step(.figure, title: "Microglia", body: "Only the heatmap.", figure: "Figure 4", panel: "c"),
        ]
        let gaps = PaperWalkthroughValidation.panelCoverageGaps(steps: steps, figures: figures)
        #expect(gaps == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 4", missingPanels: ["A", "B"])])

        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: steps, sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .assistant
        )
        // From 2026-09-23 a panel left out went unwarned; since 2026-09-29 a
        // figure the walk shows is addressed whole again, and the gap is named.
        #expect(outcome.warnings == ["The steps about Figure 4 leave panels A, B unaddressed; a walk addresses every panel of a figure it shows before it leaves it."])

        // A beat addresses a panel by pointing at it, with or without naming
        // it, and a beat of another step pointing at the figure counts too.
        var microglia = step(.figure, title: "Microglia", body: "", figure: "Figure 4", panel: "c")
        microglia.beats = [
            PaperWalkthroughBeat(text: "Look at the heatmap."),
            PaperWalkthroughBeat(text: "The same cells, sorted.", panelLabel: "a"),
        ]
        var recap = step(.explain, title: "Back to the start", body: "")
        recap.beats = [PaperWalkthroughBeat(text: "The counts began here.", figureLabel: "Figure 4", panelLabel: "b")]
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: [microglia], figures: figures)
                == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 4", missingPanels: ["B"])])
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: [microglia, recap], figures: figures).isEmpty)
        // A beat pointing at another figure addresses that figure's panel, not this one's.
        var elsewhere = step(.figure, title: "Only c", body: "", figure: "Figure 4", panel: "c")
        elsewhere.beats = [PaperWalkthroughBeat(text: "Panel a of Figure 3 showed the bubbles.", figureLabel: "Figure 3", panelLabel: "a")]
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: [elsewhere], figures: figures)
                == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 4", missingPanels: ["A", "B"])])

        // Mentions: "panel A", "panels B and C", "Panels D–E", "Fig. 3E", "(B)"; a bare letter is not one.
        let mentioned = PaperWalkthroughValidation.mentionedPanels(
            in: step(.figure, body: "See (B). Panels D–E and Fig. 3a; a lysosome is an organelle.", figure: "Figure 3"),
            of: figures[0]
        )
        #expect(mentioned == ["B", "D", "E", "A"])

        // Panels of one figure out of order are named.
        let disordered = [
            step(.figure, title: "c first", figure: "Figure 3", panel: "c"),
            step(.figure, title: "then a", figure: "Figure 3", panel: "a"),
        ]
        let orderWarnings = PaperWalkthroughValidation.panelOrderWarnings(steps: disordered)
        #expect(orderWarnings.count == 1)
        #expect(orderWarnings[0].contains("Step 2 (Figure 3 A) comes after step 1 (Figure 3 C)"))
        #expect(PaperWalkthroughValidation.panelLetter("(c)") == "C")
        #expect(PaperWalkthroughValidation.panelLetter("Figure 2B") == "B")
        #expect(PaperWalkthroughValidation.figureNumber(of: "Fig. S2") == "S2")
        #expect(PaperWalkthroughValidation.figureNumber(of: "Figure 3") == "3")
    }

    @Test("A walk that outlines a figure before a lower-numbered one it shows later is named, once, at the step that jumps")
    func figureOrder() throws {
        // The app's walk of "Engineered human resilience and durability"
        // (2026-09-29): explain, explain, then Figure 3 at step 3, before
        // Figure 1 (step 6) and Figure 2 (step 11), then back to 2B and 3.
        let figures = [
            PaperWalkthroughFigureReference(label: "Figure 1", pageNumber: 1, caption: "Figure 1 | Four properties.", panelLabels: []),
            PaperWalkthroughFigureReference(label: "Figure 2", pageNumber: 4, caption: "Figure 2 | Provocation endpoints.", panelLabels: []),
            PaperWalkthroughFigureReference(label: "Figure 3", pageNumber: 6, caption: "Figure 3 | The search funnel.", panelLabels: []),
        ]
        let question = PaperWalkthroughQuiz(question: "How large is the space?", answer: "About 250 million proteins.")
        let walk = [
            step(.explain, title: "Suppression"),
            step(.explain, title: "The question"),
            step(.figure, title: "Every protein", figure: "Figure 3"),
            step(.quiz, quiz: question),
            step(.explain, title: "Why mitochondria"),
            step(.figure, title: "Four properties", figure: "Figure 1"),
            step(.explain, title: "Why it matters"),
            step(.quiz, quiz: question),
            step(.explain, title: "Two states"),
            step(.quiz, quiz: question),
            step(.figure, title: "One scale", figure: "Figure 2", panel: "b"),
            step(.figure, title: "Two arrows", figure: "Figure 2", panel: "b"),
            step(.figure, title: "The funnel", figure: "Figure 3"),
        ]
        let warnings = PaperWalkthroughValidation.figureOrderWarnings(steps: walk)
        #expect(warnings == ["Step 3 outlines Figure 3 before Figure 1 (first at step 6) and Figure 2 (first at step 11); a walk meets the figures in printed order unless the argument needs otherwise, and a step that jumps ahead says why in its first beat."])
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: walk, sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .app
        )
        #expect(outcome.warnings == warnings)

        // Printed order, a revisit, a figure never shown, a picture of a
        // later figure, and an extended-data figure beside the main figure
        // it supports: no warning.
        var reminder = step(.explain, title: "Remember the funnel")
        reminder.picture = PaperWalkthroughPicture(figureLabel: "Figure 3")
        let inOrder = [
            reminder,
            step(.figure, figure: "Figure 1"),
            step(.figure, figure: "Figure 3", panel: "a"),
            step(.figure, figure: "Extended Data Fig. 2"),
            step(.figure, figure: "Figure 1"),
            step(.figure, figure: "Figure 4"),
        ]
        #expect(PaperWalkthroughValidation.figureOrderWarnings(steps: inOrder).isEmpty)
        // A question that points at a figure outlines it; so does a jump within a series of its own.
        let jumps = [
            step(.quiz, figure: "Figure 2", panel: "a", quiz: question),
            step(.figure, figure: "Figure 1"),
            step(.figure, figure: "Figure S3"),
            step(.figure, figure: "Fig. S1"),
            step(.figure, figure: "Extended Data Figure 1"),
        ]
        let jumpWarnings = PaperWalkthroughValidation.figureOrderWarnings(steps: jumps)
        #expect(jumpWarnings.count == 2)
        #expect(jumpWarnings[0].hasPrefix("Step 1 outlines Figure 2 before Figure 1 (first at step 2);"))
        #expect(jumpWarnings[1].hasPrefix("Step 3 outlines Figure S3 before Fig. S1 (first at step 4);"))

        typealias Ordinal = PaperWalkthroughValidation.FigureOrdinal
        #expect(PaperWalkthroughValidation.figureOrdinal(of: "Fig. 3") == Ordinal(series: "figure", numbers: [3]))
        #expect(PaperWalkthroughValidation.figureOrdinal(of: "Figure S2") == Ordinal(series: "figure s", numbers: [2]))
        #expect(PaperWalkthroughValidation.figureOrdinal(of: "Extended Data Fig. 4") == Ordinal(series: "extended data figure", numbers: [4]))
        #expect(PaperWalkthroughValidation.figureOrdinal(of: "FIGURE 3–5") == Ordinal(series: "figure", numbers: [3, 5]))
        let ten = try #require(PaperWalkthroughValidation.figureOrdinal(of: "Figure 10"))
        #expect([9].lexicographicallyPrecedes(ten.numbers), "Figure 10 comes after Figure 9, not between 1 and 2")
        #expect(PaperWalkthroughValidation.figureOrdinal(of: "Scheme") == nil)
    }

    @Test("A figure's printed title is the caption's first sentence after its label, and a panel's caption follows its marker")
    func figureTitles() {
        #expect(PaperFigureCaptionTitle.title(from: "Fig. 1. Atlas of lysosomal changes during aging reveals accumulation of cystine and GPDs. (A) Schematic of the LysoTag mice. (B) Immunoblots.")
                == "Atlas of lysosomal changes during aging reveals accumulation of cystine and GPDs")
        #expect(PaperFigureCaptionTitle.title(from: "Figure 2 | A mitochondrial electron surplus induces sleep. a, Schematic of the model. b, ATP levels in dFBNs.")
                == "A mitochondrial electron surplus induces sleep")
        #expect(PaperFigureCaptionTitle.title(from: "FIGURE 3–5 Fermentation in E. coli under anaerobic conditions. Cells were grown overnight.")
                == "Fermentation in E. coli under anaerobic conditions")
        #expect(PaperFigureCaptionTitle.title(from: "Extended Data Fig. 4: Controls et al. did not differ. Bars show means.")
                == "Controls et al. did not differ")
        #expect(PaperFigureCaptionTitle.title(from: "Figure 7") == nil)
        #expect(PaperFigureCaptionTitle.title(from: "Fig. 3. No period at all") == "No period at all")

        let caption = "Fig. 1. Atlas of lysosomal changes. (A) Schematic of the LysoTag mice, young and old. (B) Immunoblots of tissue and LysoIP fractions. (C) UMAP of lysosomal metabolomes by tissue and by age."
        #expect(PaperFigureCaptionTitle.panelCaption(for: "c", in: caption) == "UMAP of lysosomal metabolomes by tissue and by age.")
        #expect(PaperFigureCaptionTitle.panelCaption(for: "A", in: caption) == "Schematic of the LysoTag mice, young and old.")
        let nature = "Figure 2 | Surplus. a, Schematic of the model. b, ATP levels in dFBNs after sleep deprivation. c, Sleep after UCP4 expression."
        #expect(PaperFigureCaptionTitle.panelCaption(for: "b", in: nature) == "ATP levels in dFBNs after sleep deprivation.")
        #expect(PaperFigureCaptionTitle.panelCaption(for: "z", in: nature) == nil)
    }

    @Test("A panel's own words come out of a step that tours several panels, and stop where the next panel begins")
    func panelNotesFromTheStepBody() {
        // Step 3 of the cardiac-sodium walk as it was written before 2026-09-21:
        // four panels under one outline (the product owner: "when I click A, it just
        // shows the highlight over A, but it should really show this short
        // explanation of what it shows").
        let body = """
        In panel a, the plot follows intracellular sodium, labelled "23Na TQF (intracellular Na)," over "Time (min)." The traces compare the printed conditions. Sodium rises during ouabain exposure and falls after washout.

        Panel b plots left-ventricular developed pressure, labelled "LVDP (mmHg)," against time. The ouabain condition shows the contractile response to sodium loading.

        Panel c again plots intracellular sodium against time, now comparing ouabain plus PAB. Sodium rises with ouabain whether or not PAB is present. Panel d plots LVDP in the same treatment framework. PAB brings pressure back toward baseline.

        Together, the panels validate the central intervention.
        """
        #expect(WalkthroughStepPanelNote.toursSeveralPanels(body))
        #expect(WalkthroughStepPanelNote.note(for: "a", inBody: body)
                == "In panel a, the plot follows intracellular sodium, labelled \"23Na TQF (intracellular Na),\" over \"Time (min).\" The traces compare the printed conditions. Sodium rises during ouabain exposure and falls after washout.")
        #expect(WalkthroughStepPanelNote.note(for: "B", inBody: body)
                == "Panel b plots left-ventricular developed pressure, labelled \"LVDP (mmHg),\" against time. The ouabain condition shows the contractile response to sodium loading.")
        // Two panels in one paragraph: c's note ends where d is named.
        #expect(WalkthroughStepPanelNote.note(for: "c", inBody: body)
                == "Panel c again plots intracellular sodium against time, now comparing ouabain plus PAB. Sodium rises with ouabain whether or not PAB is present.")
        #expect(WalkthroughStepPanelNote.note(for: "d", inBody: body)
                == "Panel d plots LVDP in the same treatment framework. PAB brings pressure back toward baseline.")
        #expect(WalkthroughStepPanelNote.note(for: "e", inBody: body) == nil)

        // The letters a sentence names: lists and spans open out, and a word
        // that merely follows "panel" is not a panel.
        #expect(WalkthroughStepPanelNote.panels(in: "In panel a, the plot follows sodium.") == ["A"])
        #expect(WalkthroughStepPanelNote.panels(in: "Panels b and c share an axis.") == ["B", "C"])
        #expect(WalkthroughStepPanelNote.panels(in: "Panels a–c are time courses; (d) is the control.") == ["A", "B", "C", "D"])
        #expect(WalkthroughStepPanelNote.panels(in: "Together, the panels validate the intervention.").isEmpty)
        #expect(WalkthroughStepPanelNote.panels(in: "Compare Fig. 1d with Figure 2B.") == ["D", "B"])
        #expect(WalkthroughStepPanelNote.panels(in: "A larger sample would help.").isEmpty)

        // Markdown comes off, and a full stop inside quotes or after an
        // abbreviation does not end a sentence.
        let marked = "**Panel b** plots pressure vs. time, per Smith et al. 2020. The bars are means.\n\nPanel c plots sodium."
        #expect(WalkthroughStepPanelNote.sentences(of: WalkthroughStepPanelNote.paragraphs(of: marked)[0])
                == ["Panel b plots pressure vs. time, per Smith et al. 2020.", "The bars are means."])
        #expect(WalkthroughStepPanelNote.note(for: "b", inBody: marked) == "Panel b plots pressure vs. time, per Smith et al. 2020. The bars are means.")

        // A step about one panel has no separate words for it: the bubble is the note.
        #expect(!WalkthroughStepPanelNote.toursSeveralPanels("Panel a follows sodium over time. It rises with ouabain."))
    }

    @Test("The animation document carries the sandbox policy whatever shape the HTML came in")
    func animationDocumentPolicy() {
        let full = PaperWalkthroughAnimationDocument.document(for: "<!DOCTYPE html><html><head><title>x</title></head><body></body></html>")
        #expect(full.contains("Content-Security-Policy"))
        #expect(full.range(of: "<head><meta http-equiv") != nil)
        let headless = PaperWalkthroughAnimationDocument.document(for: "<html lang=\"en\"><body></body></html>")
        #expect(headless.contains("<html lang=\"en\"><head><meta http-equiv"))
        let fragment = PaperWalkthroughAnimationDocument.document(for: "<svg></svg>")
        #expect(fragment.hasPrefix("<!DOCTYPE html>"))
        #expect(fragment.contains("<svg></svg>"))
    }

    @Test("The HTML document is lifted out of a fenced or chatty answer")
    func htmlDocumentExtraction() {
        let answer = "Here you go:\n```html\n<!DOCTYPE html><html><body>hi</body></html>\n```\nEnjoy."
        #expect(AIService.htmlDocument(in: answer) == "<!DOCTYPE html><html><body>hi</body></html>")
        #expect(AIService.htmlDocument(in: "no document here") == nil)
    }
}

// MARK: - Figure geometry

@Suite("Walkthrough spotlight geometry")
struct ReaderWalkthroughSpotlightTests {

    @Test("A normalized top-left rectangle lands in page coordinates with y flipped")
    @MainActor
    func pageRectFlipsY() throws {
        let page = PDFPage()
        let box = page.bounds(for: .mediaBox)
        let rect = try #require(ReaderWalkthroughSpotlight.pageRect(
            for: PaperFigureRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25),
            on: page
        ))
        #expect(abs(rect.minX - (box.minX + 0.1 * box.width)) < 0.001)
        #expect(abs(rect.width - 0.5 * box.width) < 0.001)
        #expect(abs(rect.height - 0.25 * box.height) < 0.001)
        // Top-left y of 0.2 with height 0.25 leaves 0.55 of the page below.
        #expect(abs(rect.minY - (box.minY + 0.55 * box.height)) < 0.001)
    }

    @Test("A rotated page gets no rectangle, so the step scrolls to the page instead")
    @MainActor
    func rotatedPageHasNoRect() {
        let page = PDFPage()
        page.rotation = 90
        #expect(ReaderWalkthroughSpotlight.pageRect(for: PaperFigureRect(x: 0, y: 0, width: 1, height: 1), on: page) == nil)
    }

    // MARK: The outline as a control

    private static let caption = "Fig. 1. Atlas of lysosomal changes during aging. (A) Schematic of the setup."
    private static let panelRect = PaperFigureRect(x: 0.1, y: 0.1, width: 0.5, height: 0.25)

    private static func focus(revision: UInt = 1) -> ReaderWalkthroughFocus {
        ReaderWalkthroughFocus(
            sourceID: "s",
            stepID: "step-1",
            target: .figure(pageIndex: 0, rect: panelRect, caption: caption, sharesPageWithOtherFigures: false),
            revision: revision
        )
    }

    /// The Reader's PDF view showing `document`, in a window and laid out,
    /// so PDFKit can place a page and hit-test a point on it.
    @MainActor
    private static func hostedView(_ document: PDFDocument) -> (FindablePDFView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // A window made in code releases itself on close; ARC releases it too.
        window.isReleasedWhenClosed = false
        let pdfView = FindablePDFView(frame: frame)
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        window.contentView = pdfView
        pdfView.layoutSubtreeIfNeeded()
        return (pdfView, window)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test("The outline remembers its figure, answers for its own annotation only, and forgets it when cleared")
    @MainActor
    func outlineRemembersItsFigure() throws {
        let (page, document, url) = try SyntheticPanelPage.page()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (pdfView, window) = Self.hostedView(document)
        defer { window.close() }
        let spotlight = ReaderWalkthroughSpotlight()

        spotlight.apply(Self.focus(), in: pdfView, pageRange: 0..<1)
        let outline = try #require(page.annotations.first(where: ReaderWalkthroughSpotlight.isOutline))
        #expect(spotlight.figure(outlinedBy: outline) == .init(pageIndex: 0, rect: Self.panelRect, caption: Self.caption))
        let stranger = PDFAnnotation(bounds: outline.bounds, forType: .square, withProperties: nil)
        #expect(spotlight.figure(outlinedBy: stranger) == nil)
        #expect(!ReaderWalkthroughSpotlight.isOutline(stranger))

        spotlight.clear()
        #expect(spotlight.figure(outlinedBy: outline) == nil)
        #expect(!page.annotations.contains(where: ReaderWalkthroughSpotlight.isOutline))
    }

    @Test("A click inside the outline lands on it, so the Reader can open the figure enlarged")
    @MainActor
    func clickOnTheOutlineIsAHit() throws {
        let (page, document, url) = try SyntheticPanelPage.page()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (pdfView, window) = Self.hostedView(document)
        defer { window.close() }
        let spotlight = ReaderWalkthroughSpotlight()
        spotlight.apply(Self.focus(), in: pdfView, pageRange: 0..<1)
        let outline = try #require(page.annotations.first(where: ReaderWalkthroughSpotlight.isOutline))

        // PDFKit resolves a click to the annotation under it with the page's
        // own hit test, the one behind PDFViewAnnotationHit; a synthetic
        // mouseDown is not sent, since PDFView tracks the mouse until a real
        // mouseUp arrives. Inside the outline the hit is the outline and the
        // view reports an annotation area; beside it, neither.
        let onPage = CGPoint(x: outline.bounds.midX, y: outline.bounds.midY)
        let inWindow = pdfView.convert(pdfView.convert(onPage, from: page), to: nil)
        #expect(page.annotation(at: onPage) === outline)
        #expect(pdfView.areaOfInterest(forMouse: Self.mouseEvent(.leftMouseDown, at: inWindow, in: window)).contains(.annotationArea))
        #expect(spotlight.figure(outlinedBy: outline) != nil)

        // The pointer over the outline says a click enlarges; over the page
        // beside it, nothing of the kind.
        pdfView.cursorForAnnotation = PDFKitInlineView.Coordinator.cursorForAnnotation
        #expect(pdfView.annotationCursor(under: Self.mouseEvent(.mouseMoved, at: inWindow, in: window)) === ReaderWalkthroughSpotlight.outlineCursor)
        let outsideOnPage = CGPoint(x: outline.bounds.maxX + 20, y: outline.bounds.midY)
        let outsideInWindow = pdfView.convert(pdfView.convert(outsideOnPage, from: page), to: nil)
        #expect(page.annotation(at: outsideOnPage) == nil)
        #expect(pdfView.annotationCursor(under: Self.mouseEvent(.mouseMoved, at: outsideInWindow, in: window)) == nil)
    }

    @Test("The outlined region renders alone as a lens from the document's file, and the next ask is the cache")
    @MainActor
    func lensRendersTheOutlinedRegion() async throws {
        let (_, document, url) = try SyntheticPanelPage.page()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spotlight = ReaderWalkthroughSpotlight()
        let figure = ReaderWalkthroughSpotlight.PaintedFigure(pageIndex: 0, rect: Self.panelRect, caption: Self.caption)

        let lens = try #require(await spotlight.lens(for: figure, in: document))
        let rep = try #require(NSBitmapImageRep(data: lens))
        // 1,400 px on the longer side, in the rectangle's own proportions.
        #expect(rep.pixelsWide == Int(WalkthroughAnchorResolver.lensPixelSize))
        let expectedRatio = (Self.panelRect.width * SyntheticPanelPage.mediaBox.width) / (Self.panelRect.height * SyntheticPanelPage.mediaBox.height)
        #expect(abs(Double(rep.pixelsWide) / Double(rep.pixelsHigh) - expectedRatio) < 0.02)
        #expect(await spotlight.lens(for: figure, in: document) == lens)
        #expect(PaperFigureCaptionTitle.title(from: figure.caption) == "Atlas of lysosomal changes during aging")

        // The lightbox asks for the screen's size and gets a lossless picture
        // at it, cached apart from the row's size; the size itself follows the
        // screen's pixels, doubled, within its floor and ceiling.
        let large = try #require(await spotlight.lens(for: figure, in: document, pixelSize: 2_800))
        let largeRep = try #require(NSBitmapImageRep(data: large))
        #expect(largeRep.pixelsWide == 2_800)
        #expect(large.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(await spotlight.lens(for: figure, in: document, pixelSize: 2_800) == large)
        #expect(await spotlight.lens(for: figure, in: document) == lens)
        let screenSize = ReaderWalkthroughSpotlight.lightboxLensPixelSize(for: nil)
        #expect(screenSize >= WalkthroughAnchorResolver.lensPixelSize && screenSize <= 6_000)
    }
}

// MARK: - Storage

@Suite("Walkthrough storage")
struct PaperWalkthroughStorageTests {

    private func walkthrough(for article: StudioArticle, text: String, title: String = "Walk") -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: article.id,
            sourceSHA256: PaperContentPreparationService.sha256(text),
            title: title,
            steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "T", body: "B", anchor: PaperWalkthroughAnchor(passage: "Sleep pressure rises"))],
            author: .app
        )
    }

    @Test("A saved walkthrough reads back, replaces itself, queues the source for sync and deletes")
    func saveLoadDelete() async throws {
        let (storage, root) = makeTemporaryStorage("save")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedArticle(storage, content: paperText)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.clearAllPendingSyncChanges()

        #expect(try await storage.loadPaperWalkthrough(article.id) == nil)
        #expect(try await storage.hasPaperWalkthrough(article.id) == false)

        let first = walkthrough(for: article, text: paperText)
        try await storage.savePaperWalkthrough(first)
        let loaded = try #require(try await storage.loadPaperWalkthrough(article.id))
        #expect(loaded.title == "Walk")
        #expect(loaded.steps.count == 1)
        #expect(try await storage.hasPaperWalkthrough(article.id))
        #expect(try store.hasPendingSyncChange(entity: .source, logicalKey: article.id))

        try await storage.savePaperWalkthrough(walkthrough(for: article, text: paperText, title: "Walk again"))
        #expect(try await storage.loadPaperWalkthrough(article.id)?.title == "Walk again")

        #expect(try await storage.deletePaperWalkthrough(article.id))
        #expect(try await storage.loadPaperWalkthrough(article.id) == nil)
        #expect(try await storage.deletePaperWalkthrough(article.id) == false)
    }

    @Test("Each question kind is asked only with what it is checked against, chips are capped, and chapters keep the steps that survive")
    func kindsAndChapters() throws {
        var find = step(.quiz, title: "Find", quiz: PaperWalkthroughQuiz(question: "Which panel?", answer: "Panel b.", kind: .find, targetPanel: "B"))
        find.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a")
        find.id = "find"
        var findNoFigure = step(.quiz, title: "Find nowhere", quiz: PaperWalkthroughQuiz(question: "Which panel?", answer: "Panel b.", kind: .find, targetPanel: "b"))
        findNoFigure.id = "find-nowhere"
        var findWrongPanel = step(.quiz, title: "Find z", figure: "Figure 2", quiz: PaperWalkthroughQuiz(question: "Which panel?", answer: "Panel z.", kind: .find, targetPanel: "z"))
        findWrongPanel.id = "find-z"
        var predict = step(.quiz, title: "Predict", figure: "Figure 2", panel: "a", quiz: PaperWalkthroughQuiz(question: "Where?", answer: "Down.", kind: .predict))
        predict.id = "predict"
        var predictNoFigure = step(.quiz, title: "Predict nowhere", quiz: PaperWalkthroughQuiz(question: "Where?", answer: "Down.", kind: .predict))
        predictNoFigure.id = "predict-nowhere"
        var chips = step(.explain, title: "Chips", body: "Some words.")
        chips.id = "chips"
        chips.more = (1...5).map { PaperWalkthroughMore(label: "Chip \($0)", text: "Text \($0)", fromPaper: $0 == 1) } + [PaperWalkthroughMore(label: "", text: "dropped", fromPaper: false)]
        var dropped = step(.explain, title: "", body: "")
        dropped.id = "dropped"

        let plans = [
            PaperWalkthroughValidation.ChapterPlan(title: "Finding", claim: "Controls matter.", stepIDs: ["find", "find-nowhere", "find-z"]),
            PaperWalkthroughValidation.ChapterPlan(title: "Guessing", claim: "", stepIDs: ["predict", "predict-nowhere"]),
            PaperWalkthroughValidation.ChapterPlan(title: "Gone", claim: "Nothing.", stepIDs: ["dropped"]),
        ]
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Kinds", steps: [find, findNoFigure, findWrongPanel, predict, predictNoFigure, chips, dropped], chapters: plans,
            sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .assistant
        )
        let byID = Dictionary(uniqueKeysWithValues: outcome.walkthrough.steps.map { ($0.id, $0) })
        // A Find it keeps its target, lower-cased, and shows the whole figure.
        #expect(byID["find"]?.quiz?.kind == .find)
        #expect(byID["find"]?.quiz?.targetPanel == "b")
        #expect(byID["find"]?.anchor?.panelLabel == nil)
        // Without a figure, or naming a panel the figure does not print, it is a plain question.
        #expect(byID["find-nowhere"]?.quiz?.kind == .recall)
        #expect(byID["find-z"]?.quiz?.kind == .recall)
        #expect(byID["find-z"]?.quiz?.targetPanel == nil)
        // A prediction needs a figure to hide; without one it is Think first.
        #expect(byID["predict"]?.quiz?.kind == .predict)
        #expect(byID["predict-nowhere"]?.quiz?.kind == .thinkFirst)
        // Chips: the empty one dropped, the first three kept.
        #expect(byID["chips"]?.more.map(\.label) == ["Chip 1", "Chip 2", "Chip 3"])
        #expect(byID["chips"]?.more.first?.fromPaper == true)
        #expect(outcome.warnings.contains { $0.contains("Say more chips") })
        // Chapters: the dropped step's chapter is gone; the unclaimed one is kept and said so; the chip step, unnamed, joins the chapter before it.
        let chapters = try #require(outcome.walkthrough.chapters)
        #expect(chapters.map(\.title) == ["Finding", "Guessing"])
        #expect(chapters.map(\.id) == ["ch-1", "ch-2"])
        #expect(chapters[0].stepIDs == ["find", "find-nowhere", "find-z"])
        #expect(chapters[1].stepIDs == ["predict", "predict-nowhere", "chips"])
        #expect(chapters[1].claim == "")
        #expect(outcome.warnings.contains { $0.contains("Chapter 2 states no claim") })
        #expect(outcome.warnings.contains { $0.contains("Chapter 3 had no usable steps") })
        // The recap card comes after chapter 1's last step and not after the unclaimed chapter's.
        #expect(outcome.walkthrough.playableBeats(of: byID["find-z"]!).last?.kind == .recap)
        #expect(outcome.walkthrough.playableBeats(of: byID["chips"]!).last?.kind == .point)
        // A draft in chapters flattens to the same ids the plans name.
        let draft = PaperWalkthroughDraft(title: "T", chapters: [
            PaperWalkthroughDraft.Chapter(title: "A", claim: "a.", steps: [
                PaperWalkthroughDraft.Step(kind: "explain", title: "One", body: "x", figureLabel: nil, panelLabel: nil, passage: nil, pageNumber: nil, animationBrief: nil, quiz: nil),
            ]),
            PaperWalkthroughDraft.Chapter(title: "B", claim: "b.", steps: [
                PaperWalkthroughDraft.Step(kind: "explain", title: "Two", body: "y", figureLabel: nil, panelLabel: nil, passage: nil, pageNumber: nil, animationBrief: nil, quiz: nil),
                PaperWalkthroughDraft.Step(kind: "explain", title: "Three", body: "z", figureLabel: nil, panelLabel: nil, passage: nil, pageNumber: nil, animationBrief: nil, quiz: nil),
            ]),
        ])
        #expect(draft.steps.map(\.title) == ["One", "Two", "Three"])
        #expect(PaperWalkthroughValidation.chapterPlans(from: draft)?.map(\.stepIDs) == [["step-1"], ["step-2", "step-3"]])
        let json = #"{"title": "T", "chapters": [{"title": "A", "claim": "a.", "steps": [{"kind": "quiz", "title": "Q", "beats": [], "quiz": {"kind": "think_first", "question": "Why?", "answer": "Because.", "key_points": ["b"]}, "more": [{"label": "L", "text": "T", "from_paper": true}]}]}]}"#
        let decoded = try JSONDecoder().decode(PaperWalkthroughDraft.self, from: Data(json.utf8))
        #expect(decoded.chapters?.count == 1)
        #expect(decoded.steps.first?.quiz?.kind == .thinkFirst)
        #expect(decoded.steps.first?.more.first?.fromPaper == true)
    }

    @Test("The Artifacts home's list: every source's walkthrough with its counts, newest first, stale once the text moved")
    func summaries() async throws {
        let (storage, root) = makeTemporaryStorage("summaries")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await storage.paperWalkthroughSummaries().isEmpty)

        let first = try await seedArticle(storage, url: "https://example.com/one", title: "One", content: paperText)
        let second = try await seedArticle(storage, url: "https://example.com/two", title: "Two", content: paperText)
        var early = walkthrough(for: first, text: paperText, title: "First walk")
        early.generatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        early.steps = [
            PaperWalkthroughStep(id: "a", kind: .explain, title: "Setup", body: "One point.\n\nAnother point.", anchor: PaperWalkthroughAnchor(passage: "Sleep pressure rises")),
            PaperWalkthroughStep(id: "b", kind: .figure, title: "Look", body: "Panel a.", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", pageNumber: 4)),
            PaperWalkthroughStep(id: "c", kind: .quiz, title: "Check", body: "", quiz: PaperWalkthroughQuiz(question: "Q?", answer: "A.", keyPoints: [])),
        ]
        try await storage.savePaperWalkthrough(early)
        var late = walkthrough(for: second, text: paperText, title: "Second walk")
        late.generatedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        try await storage.savePaperWalkthrough(late)

        var summaries = try await storage.paperWalkthroughSummaries()
        #expect(summaries.map(\.title) == ["Second walk", "First walk"])
        let firstSummary = try #require(summaries.last)
        #expect(firstSummary.sourceID == first.id)
        #expect(firstSummary.stepCount == 3)
        #expect(firstSummary.cardCount == 4)
        #expect(firstSummary.questionCount == 1)
        #expect(firstSummary.figureStepCount == 1)
        #expect(firstSummary.animationCount == 0)
        #expect(firstSummary.author == .app)
        #expect(firstSummary.status == .ok)
        #expect(summaries.first?.cardCount == 1)

        // The text moves under the first walk: it is still listed, as stale.
        var moved = first
        moved.content = paperText + " A new paragraph."
        try await storage.saveSource(moved)
        summaries = try await storage.paperWalkthroughSummaries()
        #expect(summaries.first { $0.sourceID == first.id }?.status == .stale)
        #expect(summaries.first { $0.sourceID == second.id }?.status == .ok)

        // Removing a walk removes its card.
        #expect(try await storage.deletePaperWalkthrough(second.id))
        #expect(try await storage.paperWalkthroughSummaries().map(\.sourceID) == [first.id])
    }

    @Test("A notebook's Studio reads the walkthroughs of its own sources alone, newest first")
    func summariesForSources() async throws {
        let (storage, root) = makeTemporaryStorage("summaries-for-sources")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await seedArticle(storage, url: "https://example.com/one", title: "One", content: paperText)
        let second = try await seedArticle(storage, url: "https://example.com/two", title: "Two", content: paperText)
        let third = try await seedArticle(storage, url: "https://example.com/three", title: "Three", content: paperText)
        for (index, article) in [first, second, third].enumerated() {
            var walk = walkthrough(for: article, text: paperText, title: "Walk \(index + 1)")
            walk.generatedAt = Date(timeIntervalSinceReferenceDate: Double(1_000 * (index + 1)))
            try await storage.savePaperWalkthrough(walk)
        }

        let mine = try await storage.paperWalkthroughSummaries(forSources: [first.id, third.id, "no-walk"])
        #expect(mine.map(\.sourceID) == [third.id, first.id])
        #expect(mine.map(\.title) == ["Walk 3", "Walk 1"])
        // The same rows the library-wide read gives, narrowed.
        let all = try await storage.paperWalkthroughSummaries()
        #expect(all.filter { [first.id, third.id].contains($0.sourceID) } == mine)
        #expect(try await storage.paperWalkthroughSummaries(forSources: []).isEmpty)
    }

    @Test("A walkthrough written against text the paper no longer carries is refused, and a stale row is not shown")
    func textFingerprint() async throws {
        let (storage, root) = makeTemporaryStorage("sha")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedArticle(storage, content: paperText)

        await #expect(throws: (any Error).self) {
            try await storage.savePaperWalkthrough(walkthrough(for: article, text: "some other text"))
        }

        try await storage.savePaperWalkthrough(walkthrough(for: article, text: paperText))
        var changed = article
        changed.content = paperText + " And a new sentence."
        try await storage.saveSource(changed)
        #expect(try await storage.loadPaperWalkthrough(article.id) == nil)
        // The row is still there, so the Reader offers "Write Walkthrough Again".
        #expect(try await storage.hasPaperWalkthrough(article.id))
    }

    @Test("A day's readings answer ok, stale or nothing in one query")
    func statuses() async throws {
        let (storage, root) = makeTemporaryStorage("statuses")
        defer { try? FileManager.default.removeItem(at: root) }
        let walked = try await seedArticle(storage, url: "https://example.com/walked", content: paperText)
        let moved = try await seedArticle(storage, url: "https://example.com/moved", content: paperText)
        let bare = try await seedArticle(storage, url: "https://example.com/bare", content: paperText)
        try await storage.savePaperWalkthrough(walkthrough(for: walked, text: paperText))
        try await storage.savePaperWalkthrough(walkthrough(for: moved, text: paperText))
        // The text moves under the second one.
        var changed = moved
        changed.content = paperText + " And then a new paragraph the walkthrough never saw."
        try await storage.saveSource(changed)

        let statuses = try await storage.paperWalkthroughStatuses(for: [walked.id, moved.id, bare.id, "missing"])
        #expect(statuses[walked.id] == .ok)
        #expect(statuses[moved.id] == .stale)
        #expect(statuses[bare.id] == nil)
        #expect(statuses["missing"] == nil)
        #expect(try await storage.paperWalkthroughStatuses(for: [String]()).isEmpty)
    }

    @Test("Deleting the source deletes its walkthrough")
    func deleteCascade() async throws {
        let (storage, root) = makeTemporaryStorage("cascade")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedArticle(storage, content: paperText)
        try await storage.savePaperWalkthrough(walkthrough(for: article, text: paperText))
        try await storage.deleteSource(article.id)
        #expect(try await storage.hasPaperWalkthrough(article.id) == false)
    }

    @Test("The walkthrough rides the Source sync payload and lands on the other Mac only for the same text")
    func syncPayload() async throws {
        let (storage, root) = makeTemporaryStorage("payload")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedArticle(storage, content: paperText)
        let record = walkthrough(for: article, text: paperText)

        let payload = CloudKitSourcePayload(article: article, paperWalkthrough: record)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CloudKitSourcePayload.self, from: data)
        #expect(decoded.paperWalkthrough == record)

        // An older client's payload has no key: the local row is left alone.
        let older = try JSONDecoder().decode(CloudKitSourcePayload.self, from: JSONEncoder().encode(CloudKitSourcePayload(article: article)))
        #expect(older.paperWalkthrough == nil)

        let store = try KnowledgeStore(storeDirectory: root)
        try store.savePaperWalkthroughFromSync(sourceID: article.id, walkthrough: record)
        #expect(try store.loadPaperWalkthrough(article.id)?.title == "Walk")

        var other = record
        other.sourceSHA256 = "not-this-text"
        other.title = "Wrong text"
        try store.savePaperWalkthroughFromSync(sourceID: article.id, walkthrough: other)
        #expect(try store.loadPaperWalkthrough(article.id)?.title == "Walk")
        // A payload with no walkthrough leaves the row alone.
        try store.savePaperWalkthroughFromSync(sourceID: article.id, walkthrough: nil)
        #expect(try store.loadPaperWalkthrough(article.id)?.title == "Walk")
    }
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

// MARK: - Schema

/// The forward migration from the last released shape and its rollback.
@Suite("Walkthrough schema migration")
struct PaperWalkthroughSchemaMigrationTests {

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalarInt(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    private static func userVersion(at root: URL) -> Int32 { Int32(scalarInt(at: root, "PRAGMA user_version")) }

    private static func tableExists(at root: URL, _ table: String) -> Bool {
        scalarInt(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") == 1
    }

    /// Every released build up to v121 wrote a store with no walkthrough table
    /// and, from schema 123 on, no word for what kind of hour a block is.
    private static func reshapeToVersion121(_ store: KnowledgeStore) throws {
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try store.execForTesting("DROP TABLE IF EXISTS source_walkthroughs")
        try store.execForTesting("ALTER TABLE time_blocks DROP COLUMN purpose")
        try store.execForTesting("PRAGMA user_version = 121")
    }

    @Test("A same-named table of another shape rolls the migration back and leaves the store at 121")
    func rollback() throws {
        let root = try Self.temporaryRoot("schema-v122-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try Self.reshapeToVersion121(store)
            try store.execForTesting("CREATE TABLE source_walkthroughs (id INTEGER PRIMARY KEY, blob TEXT)")
        }
        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }
        #expect(Self.userVersion(at: root) == 121)
        #expect(Self.scalarInt(at: root, "SELECT COUNT(*) FROM pragma_table_info('source_walkthroughs') WHERE name = 'blob'") == 1)
    }
}

// MARK: - Panel locator

/// A synthetic two-panel figure page whose panels print the words a plot
/// prints: an axis title with its unit under each, tick numbers along the
/// bottom, and a caption beneath. What `PaperFigurePanelLocator.printedText`
/// is meant to read.
private enum SyntheticAxisPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let panelA = CGRect(x: 80, y: 520, width: 200, height: 150)
    static let panelB = CGRect(x: 330, y: 520, width: 200, height: 150)
    static let captionLine = "Figure 1 | Two synthetic panels with axis titles, drawn for the printed-text tests."

    static func page() throws -> (PDFPage, PDFDocument, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntheticAxisPage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("paper.pdf")
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.15, alpha: 1)
        context.fill(panelA)
        context.fill(panelB)
        draw("A", at: CGPoint(x: panelA.minX, y: 690), font: "Helvetica-Bold", size: 10, in: context)
        draw("B", at: CGPoint(x: panelB.minX, y: 690), font: "Helvetica-Bold", size: 10, in: context)
        draw("0 10 20", at: CGPoint(x: panelA.minX + 20, y: panelA.minY - 8), font: "Helvetica", size: 5, in: context)
        draw("Time (min)", at: CGPoint(x: panelA.minX + 60, y: panelA.minY - 18), font: "Helvetica", size: 6, in: context)
        draw("Pressure (mmHg)", at: CGPoint(x: panelB.minX + 40, y: panelB.minY - 18), font: "Helvetica", size: 6, in: context)
        draw(captionLine, at: CGPoint(x: 80, y: 480), font: "Helvetica", size: 9, in: context)
        for index in 0..<3 {
            draw("Legend prose describing the panels at length, line \(index + 1), so the legend holds ink.",
                 at: CGPoint(x: 80, y: 480 - 16 - CGFloat(index) * 16), font: "Times-Roman", size: 9, in: context)
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(url: url))
        return (try #require(document.page(at: 0)), document, url)
    }

    private static func draw(_ text: String, at point: CGPoint, font: String, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName(font as CFString, size, nil)]
            )),
            context
        )
    }
}

/// A synthetic two-panel figure page: a page-wide banner line across the top
/// (a preprint server's running head), two panel blocks side by side headed
/// by bold letters "A" and "B" with small axis labels under them, the caption
/// beneath, and prose under that. Geometry in PDF points from the bottom-left.
private enum SyntheticPanelPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let bannerBaseline: CGFloat = 770
    static let panelA = CGRect(x: 80, y: 520, width: 200, height: 150)
    static let panelB = CGRect(x: 330, y: 520, width: 200, height: 150)
    static let letterBaseline: CGFloat = 690
    static let captionBaseline: CGFloat = 480
    static let captionLine = "Figure 1 | Two synthetic panels, drawn for the panel locator tests."
    /// How many lines of legend prose sit under the caption. With `denseLegend`
    /// the legend fills the page below the caption and carries more ink than
    /// the figure, which is the Fig. 3 case. `proseSize` is the point size the
    /// legend is set at, its lines pitched as a journal pitches them: 11 like
    /// a preprint, or 8 like a Nature journal's columns.
    static func write(to url: URL, denseLegend: Bool, proseSize: CGFloat = 11) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)

        draw("bioRxiv preprint doi: https://doi.org/10.1101/2025.09.25.678303; this version posted September 26, 2025.",
             at: CGPoint(x: 40, y: bannerBaseline), font: "Helvetica", size: 8, in: context)

        context.setFillColor(gray: 0.15, alpha: 1)
        context.fill(panelA)
        context.fill(panelB)
        draw("A", at: CGPoint(x: panelA.minX, y: letterBaseline), font: "Helvetica-Bold", size: 10, in: context)
        draw("B", at: CGPoint(x: panelB.minX, y: letterBaseline), font: "Helvetica-Bold", size: 10, in: context)
        // Axis labels: bold, but far smaller than the panel letters.
        draw("Y", at: CGPoint(x: panelA.minX + 4, y: panelA.minY - 8), font: "Helvetica-Bold", size: 4, in: context)
        draw("X", at: CGPoint(x: panelB.minX + 4, y: panelB.minY - 8), font: "Helvetica-Bold", size: 4, in: context)

        draw(captionLine, at: CGPoint(x: 80, y: captionBaseline), font: "Helvetica", size: 11, in: context)
        let pitch = (proseSize * 1.45).rounded()
        let legendLines = denseLegend ? Int((captionBaseline - 40) / pitch) : 3
        for index in 0..<legendLines {
            draw("(A) Legend prose describing the first panel at length, line \(index + 1), so the legend holds ink.",
                 at: CGPoint(x: 80, y: captionBaseline - 16 - CGFloat(index) * pitch), font: "Times-Roman", size: proseSize, in: context)
        }

        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ text: String, at point: CGPoint, font: String, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName(font as CFString, size, nil)]
            )),
            context
        )
    }

    /// The page, the document that owns it, and the file. A `PDFPage` only
    /// weakly references its `PDFDocument`; a caller that kept the page alone
    /// let the document go, and PDFKit's text scanner then crashed the test
    /// host inside `selectionForWord(at:)` ("Drawing a PDFPage when its
    /// PDFDocument is nil is unsupported"). Hold the document for as long as
    /// the page is used — `withExtendedLifetime(document)` at the end of the
    /// test is enough.
    static func page(denseLegend: Bool = false, proseSize: CGFloat = 11) throws -> (PDFPage, PDFDocument, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntheticPanelPage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("paper.pdf")
        try write(to: url, denseLegend: denseLegend, proseSize: proseSize)
        let document = try #require(PDFDocument(url: url))
        return (try #require(document.page(at: 0)), document, url)
    }

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static func normalizedTop(_ y: CGFloat) -> Double { (mediaBox.maxY - y) / mediaBox.height }
    static func normalizedX(_ x: CGFloat) -> Double { x / mediaBox.width }
}

@Suite("Walkthrough panel locator")
struct PaperFigurePanelLocatorTests {

    private func line(_ text: String, size: Double, bold: Bool, x: Double, y: Double, width: Double = 0.01) -> PaperFigurePanelLocator.TextLine {
        PaperFigurePanelLocator.TextLine(
            text: text,
            fontName: bold ? "Arial-BoldMT" : "ArialMT",
            pointSize: size,
            isBold: bold,
            rect: PaperFigureRect(x: x, y: y, width: width, height: 0.0125)
        )
    }

    @Test("A line opens with a panel letter when its first token is one letter, however it is dressed")
    func leadingLetters() {
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "A") == "A")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "a") == "A")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "(b)") == "B")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "C.") == "C")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "E Lysosomes") == "E")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "-") == nil)
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "5") == nil)
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "Brain") == nil)
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "") == nil)
    }

    @Test("Panel letters are the bold single letters near the largest such size, once each, in a run")
    func anchors() {
        let lines = [
            line("A", size: 8.8, bold: true, x: 0.12, y: 0.10),
            line("Tmem192 LCMS analysis", size: 6.2, bold: true, x: 0.5, y: 0.11),
            line("B", size: 8.8, bold: true, x: 0.12, y: 0.21),
            line("D", size: 8.8, bold: true, x: 0.33, y: 0.21),
            line("-", size: 7.0, bold: true, x: 0.2, y: 0.25),
            line("Y", size: 4.2, bold: true, x: 0.14, y: 0.26),       // an axis label
            line("C", size: 8.8, bold: true, x: 0.12, y: 0.32),
            line("C", size: 8.8, bold: true, x: 0.6, y: 0.40),        // a second C: the first wins
            line("E Lysosomes", size: 8.8, bold: true, x: 0.33, y: 0.48),
            line("F", size: 8.8, bold: false, x: 0.7, y: 0.48),       // not bold
            line("X", size: 8.8, bold: true, x: 0.8, y: 0.05),        // out of the run
        ]
        let anchors = PaperFigurePanelLocator.panelAnchors(from: lines)
        #expect(anchors.map(\.label) == ["A", "B", "D", "C", "E"])
        #expect(anchors.first { $0.label == "C" }?.rect.x == 0.12)
        #expect(PaperFigurePanelLocator.panelAnchors(from: [line("Q", size: 8, bold: true, x: 0.1, y: 0.1)]).map(\.label) == ["Q"])
        #expect(PaperFigurePanelLocator.panelAnchors(from: []).isEmpty)
    }

    @Test("Letters partition the figure: right to the next letter overlapping the row, down to the first letter below, out to the edge otherwise")
    func partition() throws {
        // Figure 1 of the lysosome-aging preprint: A across the top; B and D on
        // the second row, D tall; C under B, reaching the bottom; E under D.
        let figure = PaperFigureRect(x: 0.11, y: 0.08, width: 0.78, height: 0.51)
        func anchor(_ label: String, _ x: Double, _ y: Double) -> PaperFigurePanelLocator.PanelAnchor {
            .init(label: label, rect: PaperFigureRect(x: x, y: y, width: 0.0104, height: 0.0125), pointSize: 8.8)
        }
        let anchors = [anchor("A", 0.119, 0.098), anchor("B", 0.118, 0.208), anchor("D", 0.328, 0.208), anchor("C", 0.118, 0.324), anchor("E", 0.327, 0.476)]
        let panels = PaperFigurePanelLocator.partition(anchors, within: figure)
        let gutter = PaperFigurePanelLocator.gutter
        let a = try #require(panels["A"]); let b = try #require(panels["B"]); let c = try #require(panels["C"])
        let d = try #require(panels["D"]); let e = try #require(panels["E"])
        let right = figure.x + figure.width
        let bottom = figure.y + figure.height
        func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-6 }

        // A: the whole first row, from the figure's top to just above B and D.
        #expect(close(a.x, figure.x) && close(a.y, figure.y) && close(a.x + a.width, right))
        #expect(close(a.y + a.height, 0.208 - gutter))
        // B: from the figure's left to just before D; down to C.
        #expect(close(b.x, figure.x) && close(b.y, 0.208 - gutter))
        #expect(close(b.x + b.width, 0.328 - gutter) && close(b.y + b.height, 0.324 - gutter))
        // C: under B, to the figure's bottom, stopping where D's column and E begin — E is beside it, not below it.
        #expect(close(c.x, figure.x) && close(c.x + c.width, min(0.328, 0.327) - gutter) && close(c.y + c.height, bottom))
        // D: tall — from its letter to the right edge, down to E.
        #expect(close(d.x, 0.328 - gutter) && close(d.y, 0.208 - gutter) && close(d.x + d.width, right))
        #expect(close(d.y + d.height, 0.476 - gutter))
        // E: beside C's lower half, so from its own letter, to the corner.
        #expect(close(e.x, 0.327 - gutter) && close(e.y, 0.476 - gutter) && close(e.x + e.width, right) && close(e.y + e.height, bottom))
        let allValid = panels.values.allSatisfy { $0.isValid }
        #expect(allValid)

        // A tall left panel keeps its height beside a column of two.
        let tall = PaperFigurePanelLocator.partition(
            [anchor("A", 0.12, 0.10), anchor("B", 0.5, 0.10), anchor("C", 0.5, 0.35)],
            within: figure
        )
        #expect(close(try #require(tall["A"]).y + tall["A"]!.height, bottom))
        #expect(close(try #require(tall["A"]).x + tall["A"]!.width, 0.5 - gutter))
        #expect(close(try #require(tall["B"]).y + tall["B"]!.height, 0.35 - gutter))
        #expect(close(try #require(tall["C"]).x, 0.5 - gutter))
        #expect(PaperFigurePanelLocator.partition([], within: figure).isEmpty)
    }

    @Test("On a page, the bold letters place the panels, the crop starts under the banner, and the axis labels are ignored")
    func panelsOnAPage() throws {
        let (page, document, _) = try SyntheticPanelPage.page()
        defer { withExtendedLifetime(document) {} }
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticPanelPage.captionLine, on: page))
        // The banner across the top is not part of the figure.
        #expect(crop.y > SyntheticPanelPage.normalizedTop(SyntheticPanelPage.bannerBaseline) + 0.005)
        #expect(crop.y < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.letterBaseline + 10))
        #expect(crop.y + crop.height < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.captionBaseline))

        let lines = PaperFigurePanelLocator.textLines(in: crop, on: page)
        #expect(lines.contains { $0.text == "A" && $0.isBold && $0.pointSize > 9 })
        #expect(lines.contains { $0.text == "Y" && $0.isBold && $0.pointSize < 5 })

        let panels = PaperFigurePanelLocator.panelRects(in: crop, on: page, mask: mask)
        #expect(panels.keys.sorted() == ["A", "B"])
        let a = try #require(panels["A"]); let b = try #require(panels["B"])
        // A ends before B begins, and each holds its own block.
        #expect(a.x + a.width <= b.x + 0.001)
        #expect(a.x <= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelA.minX) + 0.01)
        #expect(a.x + a.width >= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelA.maxX) - 0.01)
        #expect(b.x <= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelB.minX) + 0.01)
        #expect(b.x + b.width >= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelB.maxX) - 0.01)
        #expect(a.y + a.height >= SyntheticPanelPage.normalizedTop(SyntheticPanelPage.panelA.minY) - 0.01)
        #expect(PaperFigurePanelLocator.panelRect(labelled: "b", in: crop, on: page, mask: mask) == b)
        #expect(PaperFigurePanelLocator.panelRect(labelled: "c", in: crop, on: page, mask: mask) == nil)
    }

    @Test("A long legend under the caption is prose, so the figure is the sparse side above it")
    func figureSideReadsProse() throws {
        let (page, document, _) = try SyntheticPanelPage.page(denseLegend: true)
        defer { withExtendedLifetime(document) {} }
        let caption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticPanelPage.captionLine, on: page))
        #expect(PaperFigureRectRefiner.figureSide(captionBounds: caption, on: page) == .above)
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticPanelPage.captionLine, on: page))
        // Above the caption, not the legend below it.
        #expect(crop.y + crop.height < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.captionBaseline))
        // The sparse variant has too little prose either side to say; the ink decides.
        let (sparse, sparseDocument, _) = try SyntheticPanelPage.page(denseLegend: false)
        defer { withExtendedLifetime(sparseDocument) {} }
        let sparseCaption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticPanelPage.captionLine, on: sparse))
        #expect(PaperFigureRectRefiner.figureSide(captionBounds: sparseCaption, on: sparse) == nil)
        let head = try #require(PaperFigureRectRefiner.runningHeadBounds(on: page))
        #expect(head.minY > SyntheticPanelPage.mediaBox.height * (1 - PaperFigureRectRefiner.runningHeadDepth))
        #expect(head.width >= SyntheticPanelPage.mediaBox.width * PaperFigureRectRefiner.runningHeadMinimumWidthShare)
    }

    @Test("A figure's printed words are its axis titles, legend keys and condition labels — not its panel letters or tick numbers")
    func printedTextReadsLabelsNotTicks() {
        // The lines PDFKit hands back for Fig. 1 of the cardiac-sodium paper
        // (2026-09-20), in reading order, with two panels sharing an x axis.
        let lines = [
            line("a b", size: 11.3, bold: false, x: 0.2, y: 0.05),
            line("23Na TQF (intracellular Na)", size: 4.5, bold: false, x: 0.2, y: 0.1),
            line("relative to baseline (arb. units)", size: 7.7, bold: false, x: 0.21, y: 0.1),
            line("1.4", size: 7, bold: false, x: 0.23, y: 0.06),
            line("1.0", size: 7, bold: false, x: 0.23, y: 0.12),
            line("LVDP (mmHg)", size: 7.7, bold: false, x: 0.5, y: 0.1),
            line("**", size: 8.4, bold: false, x: 0.77, y: 0.1),
            line("ouabain", size: 4.9, bold: false, x: 0.36, y: 0.18),
            line("washout", size: 4.9, bold: false, x: 0.42, y: 0.18),
            line("ouabain", size: 4.9, bold: false, x: 0.65, y: 0.18),
            line("0 10 20 30 40 50 60", size: 7, bold: false, x: 0.27, y: 0.2),
            line("Time (min) Time (min)", size: 7.7, bold: false, x: 0.34, y: 0.21),
            line("c d", size: 11.3, bold: false, x: 0.2, y: 0.23),
            line("PAB PAB", size: 7, bold: false, x: 0.34, y: 0.24),
            line("n = 6", size: 7, bold: false, x: 0.34, y: 0.3),
            line("−5%", size: 7, bold: false, x: 0.34, y: 0.31),
        ]
        #expect(PaperFigurePanelLocator.printedText(from: lines) == [
            "23Na TQF (intracellular Na)", "relative to baseline (arb. units)", "LVDP (mmHg)", "**",
            "ouabain", "washout", "Time (min)", "PAB", "n = 6",
        ])
        #expect(PaperFigurePanelLocator.printedLine("  (C)  ") == nil)
        #expect(PaperFigurePanelLocator.printedLine("0.8") == nil)
        #expect(PaperFigurePanelLocator.printedLine("E Lysosomes") == "E Lysosomes")
        let many = (0..<60).map { line("label \($0)", size: 7, bold: false, x: 0.2, y: 0.1 + Double($0) * 0.01) }
        #expect(PaperFigurePanelLocator.printedText(from: many).count == PaperFigurePanelLocator.printedTextLineLimit)
    }

    @Test("The text-layer reading of a drawn figure has its panel letters and the words under them, and the writer's reference carries both")
    func textLayerReadingFromPage() throws {
        let (page, document, url) = try SyntheticAxisPage.page()
        defer { withExtendedLifetime(document) {} }
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticAxisPage.captionLine, on: page))
        let printed = PaperFigurePanelLocator.printedText(in: crop, on: page)
        // Two titles set on one baseline come back from PDFKit as one line,
        // "Time (min) Pressure (mmHg)"; the writer reads them either way.
        #expect(printed.contains { $0.contains("Time (min)") })
        #expect(printed.contains { $0.contains("Pressure (mmHg)") })
        #expect(!printed.contains("A"))
        #expect(!printed.contains { $0.hasPrefix("Figure 1 |") })
        #expect(!printed.contains("0 10 20"))

        let record = PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 0, caption: SyntheticAxisPage.captionLine, analysis: nil)
        let readings = PaperFigurePanelLocator.textLayer(for: [record], pdfPath: url.path)
        #expect(readings["f1"]?.panelLabels == ["A", "B"])
        #expect(readings["f1"]?.printedText == printed)
        #expect(PaperFigurePanelLocator.panelLabels(for: [record], pdfPath: url.path) == ["f1": ["A", "B"]])
        let references = PaperWalkthroughGeneratorService.figureReferences(from: [record], pdfPath: url.path)
        #expect(references.first?.panelLabels == ["A", "B"])
        #expect(references.first?.printedText == printed)
    }

    @Test("Prose set at 8 pt, as Nature journals set their columns, is still prose")
    func figureSideReadsSmallProse() throws {
        // Fig. 1 of the cardiac-sodium paper (Nature Communications, 2026-09-20):
        // columns at 8.2 pt sat under a fixed 9 pt floor, no line counted as
        // body text, and the ink vote cropped the figure to the prose below
        // its caption. Prose is read by line width now, whatever its size.
        let (page, document, _) = try SyntheticPanelPage.page(denseLegend: true, proseSize: 8)
        defer { withExtendedLifetime(document) {} }
        let caption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticPanelPage.captionLine, on: page))
        #expect(PaperFigureRectRefiner.figureSide(captionBounds: caption, on: page) == .above)
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticPanelPage.captionLine, on: page))
        #expect(crop.y + crop.height < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.captionBaseline))
        #expect(crop.y > SyntheticPanelPage.normalizedTop(SyntheticPanelPage.bannerBaseline) + 0.005)
    }
}

// MARK: - Analysed panel rectangles

@Suite("Analysed panel rectangles grow onto the ink they cut")
struct PaperFigureExtendedPanelTests {

    @Test("A panel cut short inside its own ink grows to its edge, and never into the next panel")
    func cutPanelGrowsToItsInkNotItsNeighbour() throws {
        // Figure 2h of the cardiac-sodium paper (2026-09-22): the vision
        // rectangle stopped a group of bars short of the panel's right edge,
        // and the figure's own rectangle short of the same labels.
        let (page, document, url) = try SyntheticPanelPage.page()
        defer {
            withExtendedLifetime(document) {}
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let a = SyntheticPanelPage.panelA, b = SyntheticPanelPage.panelB
        func normalized(_ rect: CGRect) -> PaperFigureRect {
            PaperFigureRect(
                x: SyntheticPanelPage.normalizedX(rect.minX),
                y: SyntheticPanelPage.normalizedTop(rect.maxY),
                width: rect.width / SyntheticPanelPage.mediaBox.width,
                height: rect.height / SyntheticPanelPage.mediaBox.height
            )
        }
        // A's rectangle stops 60 pt inside A; B's rectangle reaches 10 pt
        // into the gutter towards A, which is white, so it stays.
        let cutA = normalized(CGRect(x: a.minX, y: a.minY, width: a.width - 60, height: a.height))
        let looseB = normalized(CGRect(x: b.minX - 10, y: b.minY, width: b.width, height: b.height))
        // The figure's rectangle stops 40 pt inside B.
        let cutFigure = normalized(CGRect(x: a.minX, y: a.minY, width: b.maxX - a.minX - 40, height: a.height))

        let extended = PaperFigureRectRefiner.extendedPanelRects(["a": cutA, "b": looseB], within: cutFigure, with: mask)

        let tolerance = 0.01
        let figureRight = extended.figure.x + extended.figure.width
        #expect(abs(figureRight - SyntheticPanelPage.normalizedX(b.maxX)) < tolerance)
        let grownA = try #require(extended.panels["a"])
        let aRight = grownA.x + grownA.width
        #expect(abs(aRight - SyntheticPanelPage.normalizedX(a.maxX)) < tolerance)
        #expect(aRight < SyntheticPanelPage.normalizedX(b.minX))
        let grownB = try #require(extended.panels["b"])
        #expect(abs(grownB.x - looseB.x) < 0.001)
        #expect(abs(grownB.x + grownB.width - SyntheticPanelPage.normalizedX(b.maxX)) < tolerance)
    }

    @Test("Two panels whose rectangles overlap are split at the white gutter between them")
    func overlappingPanelsSplitAtTheirGutter() throws {
        // Figure 1 of the MitoSpace paper (2026-09-23): panel A's rectangle
        // ran into panel B's, and A's card showed B's heading cut in half.
        let (page, document, url) = try SyntheticPanelPage.page()
        defer {
            withExtendedLifetime(document) {}
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let a = SyntheticPanelPage.panelA, b = SyntheticPanelPage.panelB
        let box = SyntheticPanelPage.mediaBox
        func normalized(_ rect: CGRect) -> PaperFigureRect {
            PaperFigureRect(
                x: SyntheticPanelPage.normalizedX(rect.minX),
                y: SyntheticPanelPage.normalizedTop(rect.maxY),
                width: rect.width / box.width,
                height: rect.height / box.height
            )
        }
        // Both reach up to the letters; A runs 20 pt into B, B starts 20 pt
        // into the 50 pt gutter towards A.
        let top = SyntheticPanelPage.letterBaseline + 14
        let wideA = normalized(CGRect(x: a.minX, y: a.minY, width: b.minX + 20 - a.minX, height: top - a.minY))
        let wideB = normalized(CGRect(x: a.maxX + 20, y: b.minY, width: b.maxX - a.maxX - 20, height: top - b.minY))

        let split = PaperFigureRectRefiner.separatedPanelRects(["a": wideA, "b": wideB], with: mask)
        let splitA = try #require(split["a"]), splitB = try #require(split["b"])
        let aRight = splitA.x + splitA.width
        #expect(aRight >= SyntheticPanelPage.normalizedX(a.maxX))
        #expect(aRight < SyntheticPanelPage.normalizedX(b.minX))
        #expect(splitB.x > SyntheticPanelPage.normalizedX(a.maxX))
        #expect(splitB.x < SyntheticPanelPage.normalizedX(b.minX))
        #expect(aRight <= splitB.x)
        // Only the overlapping edges moved.
        #expect(abs(splitA.x - wideA.x) < 0.002 && abs(splitA.y - wideA.y) < 0.002)
        #expect(abs(splitA.height - wideA.height) < 0.002)
        #expect(abs(splitB.x + splitB.width - (wideB.x + wideB.width)) < 0.002)

        // The Reader's route, through the growth pass, keeps the split.
        let figure = normalized(CGRect(x: a.minX, y: a.minY, width: b.maxX - a.minX, height: top - a.minY))
        let extended = PaperFigureRectRefiner.extendedPanelRects(["a": wideA, "b": wideB], within: figure, with: mask)
        let extendedA = try #require(extended.panels["a"])
        #expect(extendedA.x + extendedA.width < SyntheticPanelPage.normalizedX(b.minX))

        // Two rectangles overlapping inside one block of ink have no gutter
        // between them, and are left as they were.
        let left = normalized(CGRect(x: a.minX, y: a.minY, width: 120, height: a.height))
        let right = normalized(CGRect(x: a.minX + 80, y: a.minY, width: 120, height: a.height))
        let unsplit = PaperFigureRectRefiner.separatedPanelRects(["x": left, "y": right], with: mask)
        #expect(unsplit["x"] == left && unsplit["y"] == right)
    }
}

// MARK: - Anchor resolver

@Suite("Walkthrough anchor resolver")
struct WalkthroughAnchorResolverTests {

    @Test("A panel step resolves to that panel with a lens; the whole figure without; the document opens and the page is read once")
    func resolvesAndCaches() async throws {
        let (_, _, url) = try SyntheticPanelPage.page()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 0, caption: SyntheticPanelPage.captionLine, analysis: nil)
        let resolver = WalkthroughAnchorResolver(figures: [record], pdfPath: url.path)

        let panelA = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 1)))
        #expect(panelA.panelLabels == ["A", "B"])
        #expect(panelA.panel == "A")
        let lens = try #require(panelA.lensImage)
        #expect(!lens.isEmpty)
        #expect(NSImage(data: lens) != nil)
        guard case .figure(let pageIndex, let rect, let caption, let shares) = panelA.target else {
            Issue.record("expected a figure target"); return
        }
        #expect(pageIndex == 0 && caption == SyntheticPanelPage.captionLine && !shares)
        let a = try #require(rect)
        #expect(a.x + a.width < SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelB.minX))

        let whole = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1")))
        #expect(whole.panel == nil && whole.lensImage == nil && whole.panelLabels == ["A", "B"])
        guard case .figure(_, let wholeRect, _, _) = whole.target else { Issue.record("expected a figure target"); return }
        #expect(try #require(wholeRect).width > a.width)

        // The learner's own pick within the step, and "the whole figure" again.
        let picked = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a"), panel: "B"))
        #expect(picked.panel == "B")
        let cleared = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a"), panel: ""))
        #expect(cleared.panel == nil)

        // Every answer came from one open document and one read of the page's ink.
        let again = await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 1))
        #expect(again == panelA)
        await resolver.prefetch([PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "b"), nil])
        #expect(await resolver.documentOpens == 1)
        #expect(await resolver.maskRenders == 1)

        // Other anchors, and nothing.
        let passage = try #require(await resolver.resolve(PaperWalkthroughAnchor(passage: "Two synthetic panels", pageNumber: 1)))
        #expect(passage.target == .passage("Two synthetic panels", pageHint: 0) && passage.panelLabels.isEmpty)
        #expect(try #require(await resolver.resolve(PaperWalkthroughAnchor(pageNumber: 3))).target == .page(pageIndex: 2))
        #expect(await resolver.resolve(nil) == nil)
        #expect(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 9")) == nil)
        #expect(resolver.matches(figures: [record], pdfPath: url.path))
        #expect(!resolver.matches(figures: [], pdfPath: url.path))
    }

    @Test("A figure the page cannot place still scrolls to its page, and a panel of it has no lens")
    func figureWithoutGeometry() async throws {
        let record = PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 0, caption: "Figure 1 | Missing.", analysis: nil)
        let resolver = WalkthroughAnchorResolver(figures: [record], pdfPath: "/nonexistent/paper.pdf")
        let resolved = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "c")))
        #expect(resolved.target == .figure(pageIndex: 0, rect: nil, caption: "Figure 1 | Missing.", sharesPageWithOtherFigures: false))
        #expect(resolved.panel == nil && resolved.lensImage == nil && resolved.panelLabels.isEmpty)
    }
}

// MARK: - Panel identity

/// A panel is its label, not the label's last letter (2026-09-29). Figure 3
/// of "Engineered human resilience and durability" is a four-column funnel
/// whose vision analysis names its panels ALL OF BIOLOGY, FUNCTION
/// RETRIEVAL, DESIGN and VALIDATION; read as letters they were Y, L, N and
/// N, so DESIGN's rectangle was overwritten by VALIDATION's, and a walk
/// taking the columns left to right was warned it had them out of order.
@Suite("Walkthrough panel identity")
struct PaperWalkthroughPanelIdentityTests {

    /// The rectangles the vision pass stored for that figure.
    static let funnelPanels = [
        PaperFigurePanel(id: "fig-3-panel-1", label: "ALL OF BIOLOGY", explanation: "Every protein.",
                         rect: PaperFigureRect(x: 0.10671, y: 0.12364, width: 0.20242, height: 0.18040)),
        PaperFigurePanel(id: "fig-3-panel-2", label: "FUNCTION RETRIEVAL", explanation: "Proteins with the function.",
                         rect: PaperFigureRect(x: 0.30033, y: 0.12364, width: 0.19912, height: 0.17107)),
        PaperFigurePanel(id: "fig-3-panel-3", label: "DESIGN", explanation: "Designed variants.",
                         rect: PaperFigureRect(x: 0.49175, y: 0.12364, width: 0.19802, height: 0.18974)),
        PaperFigurePanel(id: "fig-3-panel-4", label: "VALIDATION", explanation: "What survives the assay.",
                         rect: PaperFigureRect(x: 0.69307, y: 0.15086, width: 0.19142, height: 0.17263)),
    ]
    static let funnelAnalysis = PaperFigureAnalysis(
        summary: "The search space and funnel.",
        visualEvidence: [],
        figureRect: PaperFigureRect(x: 0.10671, y: 0.12364, width: 0.77778, height: 0.22473),
        panels: funnelPanels,
        analysisVersion: PaperFigureAnalysis.currentVersion,
        generatedAt: Date(timeIntervalSince1970: 0)
    )
    static let funnelNames = ["ALL OF BIOLOGY", "FUNCTION RETRIEVAL", "DESIGN", "VALIDATION"]
    static let funnel = PaperWalkthroughFigureReference(
        label: "Figure 3", pageNumber: 6, caption: "Figure 3: The search space and funnel.", panelLabels: funnelNames
    )
    static let funnelText = """
    Every protein biology has produced is a candidate mechanism. Each stage of the funnel narrows the candidates \
    before any is tested. Figure 3 lays out the search space and the funnel from all of biology to validation.
    """

    /// `panelLetter` as it stood before named panels had an identity: the
    /// last character of the label, upper-cased.
    static func legacyPanelLetter(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]."))
        guard let last = trimmed.last, last.isLetter else { return nil }
        return String(last).uppercased()
    }

    @Test("A lettered panel is its letter, exactly as before; a named panel is its whole name")
    func identity() {
        // Every spelling of a lettered panel the model and the vision pass
        // write: the letter is what it always was, and the letter is the key.
        let lettered = ["a", "A", "(a)", "(B)", "b.", "[c]", "  d  ", "1a", "1A", "Figure 2B", "Fig. 3e", "Fig. S2b",
                        "Extended Data Fig. 3a", "panel b", "Panel B", "panels c and d", "b–d", "a, b", "(a) and (b)", "i", "v"]
        for label in lettered {
            #expect(PaperWalkthroughValidation.panelLetter(label) == Self.legacyPanelLetter(label), "\(label)")
            #expect(PaperWalkthroughValidation.panelKey(label) == Self.legacyPanelLetter(label), "\(label)")
            #expect(PaperWalkthroughValidation.panelDisplayName(label) == Self.legacyPanelLetter(label), "\(label)")
        }
        #expect(PaperWalkthroughValidation.panelLetter("(c)") == "C")
        #expect(PaperWalkthroughValidation.panelLetter("Figure 2B") == "B")
        #expect(PaperWalkthroughValidation.samePanel("(a)", "Figure 1A"))
        #expect(!PaperWalkthroughValidation.samePanel("a", "b"))

        // A named panel is never one letter of its name.
        for name in Self.funnelNames {
            #expect(PaperWalkthroughValidation.panelLetter(name) == nil, "\(name)")
        }
        #expect(Self.funnelNames.compactMap(PaperWalkthroughValidation.panelKey)
                == ["all of biology", "function retrieval", "design", "validation"])
        #expect(Set(PaperWalkthroughValidation.panelKeys(Self.funnelNames)).count == 4)
        #expect(PaperWalkthroughValidation.panelKey("ALL OF  BIOLOGY") == "all of biology")
        #expect(PaperWalkthroughValidation.panelKey(" Design ") == "design")
        #expect(PaperWalkthroughValidation.panelKey("Figure 3 DESIGN") == "design")
        #expect(PaperWalkthroughValidation.samePanel("DESIGN", "design"))
        #expect(!PaperWalkthroughValidation.samePanel("DESIGN", "VALIDATION"))
        #expect(!PaperWalkthroughValidation.samePanel("DESIGN", "n"))
        // Roman-numeral panels stop colliding too: "ii" was "I".
        #expect(PaperWalkthroughValidation.panelKey("ii") == "ii")
        #expect(PaperWalkthroughValidation.panelKey("i") == "I")
        // A figure's label alone names no panel.
        #expect(PaperWalkthroughValidation.panelKey("Figure 2") == nil)
        #expect(PaperWalkthroughValidation.panelKey("") == nil)

        #expect(PaperWalkthroughValidation.panelDisplayName("Design") == "Design")
        #expect(PaperWalkthroughValidation.figurePanelLabel("Figure 2", panel: "b") == "Figure 2b")
        #expect(PaperWalkthroughValidation.figurePanelLabel("Figure 3", panel: "DESIGN") == "Figure 3 DESIGN")
        #expect(PaperWalkthroughValidation.figurePanelLabel("Figure 3", panel: nil) == "Figure 3")
        #expect(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: "DESIGN").figureDisplayLabel == "Figure 3 DESIGN")
        #expect(PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a").figureDisplayLabel == "Figure 2a")
    }

    @Test("Lettered panels are ordered, covered and found exactly as before, with or without the figure list")
    func letteredUnchanged() throws {
        let figure = PaperWalkthroughFigureReference(label: "Figure 3", pageNumber: 24, caption: "Fig. 3.", panelLabels: ["A", "B", "C"])
        let disordered = [
            step(.figure, title: "c first", figure: "Figure 3", panel: "c"),
            step(.figure, title: "then a", figure: "Figure 3", panel: "a"),
            step(.figure, title: "then b", figure: "Figure 3", panel: "Figure 3B"),
        ]
        let expected = ["Step 2 (Figure 3 A) comes after step 1 (Figure 3 C); a figure's panels are walked in order."]
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: disordered) == expected)
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: disordered, figures: [figure]) == expected)

        let gaps = PaperWalkthroughValidation.panelCoverageGaps(
            steps: [step(.figure, body: "Panel B repeats it.", figure: "Figure 3", panel: "a")],
            figures: [figure]
        )
        #expect(gaps == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 3", missingPanels: ["C"])])

        // A lettered Find it keeps the lower-cased letter the record always kept.
        var find = step(.quiz, title: "Find", quiz: PaperWalkthroughQuiz(question: "Which panel?", answer: "Panel b.", kind: .find, targetPanel: "(B)"))
        find.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 3")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [find, step(.explain, body: "More.")], sourceID: "src", sourceSHA256: "sha",
            figures: [figure], text: paperText, author: .assistant
        )
        #expect(outcome.walkthrough.steps[0].quiz?.kind == .find)
        #expect(outcome.walkthrough.steps[0].quiz?.targetPanel == "b")

        // The resolver's letters stay alphabetical and upper case.
        let panels = WalkthroughAnchorResolver.analysedPanels([
            PaperFigurePanel(id: "c", label: "c", explanation: "", rect: PaperFigureRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2)),
            PaperFigurePanel(id: "a", label: "(a)", explanation: "", rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            PaperFigurePanel(id: "b", label: "B", explanation: "", rect: nil),
        ])
        #expect(panels.labels == ["A", "C"])
        #expect(panels.rects["A"]?.x == 0.1)
    }

    @Test("Figure 3's four named columns are four panels: walked left to right, covered, and found by name")
    func namedPanelsInTheValidator() throws {
        let leftToRight = zip(Self.funnelNames, ["Everything", "Retrieval", "Design", "Validation"]).map { name, title in
            step(.figure, title: title, body: "This column narrows the candidates.", figure: "Figure 3", panel: name)
        }
        // Alphabetically DESIGN comes before FUNCTION RETRIEVAL; the figure
        // prints it after, and the figure's order is the one walked.
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: leftToRight, figures: [Self.funnel]).isEmpty)
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: leftToRight, figures: [Self.funnel]).isEmpty)

        let backwards = [leftToRight[2], leftToRight[1]]
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: backwards, figures: [Self.funnel])
                == ["Step 2 (Figure 3 FUNCTION RETRIEVAL) comes after step 1 (Figure 3 DESIGN); a figure's panels are walked in order."])
        // DESIGN and VALIDATION were both "N", so a step on each read as one panel twice.
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: [leftToRight[3], leftToRight[2]], figures: [Self.funnel]).count == 1)

        // Coverage: a column is addressed by anchoring to it or naming it.
        let threeColumns = Array(leftToRight.prefix(3))
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: threeColumns, figures: [Self.funnel])
                == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 3", missingPanels: ["VALIDATION"])])
        let named = step(.figure, body: "The Validation column is what survives the assay.", figure: "Figure 3", panel: "DESIGN")
        #expect(PaperWalkthroughValidation.mentionedPanels(in: named, of: Self.funnel) == ["design", "validation"])

        // The whole walk validates without a false order warning, and a
        // Find it names its column by name.
        var find = step(.quiz, title: "Find", quiz: PaperWalkthroughQuiz(question: "Which column is tested in cells?", answer: "Validation.", kind: .find, targetPanel: "validation"))
        find.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 3")
        var byLetter = step(.quiz, title: "Find by letter", quiz: PaperWalkthroughQuiz(question: "Which column?", answer: "Design.", kind: .find, targetPanel: "N"))
        byLetter.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 3")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Funnel", steps: leftToRight + [find, byLetter], sourceID: "src", sourceSHA256: "sha",
            figures: [Self.funnel], text: Self.funnelText, author: .assistant
        )
        #expect(!outcome.warnings.contains { $0.contains("walked in order") })
        #expect(!outcome.warnings.contains { $0.contains("unaddressed") })
        #expect(outcome.walkthrough.steps.map(\.anchor?.panelLabel).prefix(4).map { $0 ?? "" } == Self.funnelNames)
        #expect(outcome.walkthrough.steps[4].quiz?.kind == .find)
        #expect(outcome.walkthrough.steps[4].quiz?.targetPanel == "VALIDATION")
        // "N" is not a panel of this figure, however DESIGN used to be read.
        #expect(outcome.walkthrough.steps[5].quiz?.kind == .recall)

        // No letter-shaped caption, note or citation is made up for a name.
        #expect(PaperFigureCaptionTitle.panelCaption(for: "DESIGN", in: "Figure 3: The funnel. (N) Not a panel.") == nil)
        #expect(WalkthroughStepPanelNote.note(for: "DESIGN", inBody: "Look at panel n. It is not this one.") == nil)
        let text = "Unrelated counts are shown in Fig. 3n of the supplement here. The funnel in Figure 3 narrows all of biology down to validation."
        #expect(PaperFigureMention.sentence(citing: "Figure 3", panel: "DESIGN", in: text)?.hasPrefix("The funnel in Figure 3") == true)
        #expect(PaperFigureMention.sentence(citing: "Figure 3", panel: "n", in: text)?.hasPrefix("Unrelated counts") == true)

        // The grade names the column as printed.
        let quiz = try #require(outcome.walkthrough.steps[4].quiz)
        #expect(WalkthroughStepComposer.findRecord(quiz: quiz, picked: "DESIGN", correct: false)
                .hasPrefix("**Not panel DESIGN — it's panel VALIDATION.**"))
    }

    @Test("The resolver keeps each named column's own rectangle, in the figure's order, and a pick by name finds it")
    func namedPanelsInTheResolver() async throws {
        let record = PaperFigureRecord(id: "fig-3", sourceID: "s", figureLabel: "Figure 3", pageIndex: 5,
                                       caption: "Figure 3: The search space and funnel.", analysis: Self.funnelAnalysis)
        let resolver = WalkthroughAnchorResolver(figures: [record], pdfPath: nil)
        for panel in Self.funnelPanels {
            let resolved = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: panel.label)))
            #expect(resolved.panel == panel.label)
            #expect(resolved.panelLabels == Self.funnelNames)
            guard case .figure(let pageIndex, let rect, _, _) = resolved.target else {
                Issue.record("expected a figure target"); return
            }
            #expect(pageIndex == 5)
            #expect(rect == panel.rect, "\(panel.label)")
        }
        // A pick by name in any case, over a step anchored to another column.
        let picked = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: "DESIGN"), panel: "validation"))
        #expect(picked.panel == "VALIDATION")
        // A letter that used to stand for DESIGN is not a panel.
        let byLetter = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: "N")))
        #expect(byLetter.panel == nil)
        guard case .figure(_, let whole, _, _) = byLetter.target else { Issue.record("expected a figure target"); return }
        #expect(whole == Self.funnelAnalysis.figureRect)
    }

    @Test("inspect_paper_figure and the phone deck find a named column by name, not by its last letter")
    func namedPanelsInTheToolsAndThePhone() throws {
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "DESIGN", in: Self.funnelAnalysis)?.id == "fig-3-panel-3")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "design", in: Self.funnelAnalysis)?.id == "fig-3-panel-3")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "Figure 3 VALIDATION", in: Self.funnelAnalysis)?.id == "fig-3-panel-4")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "all of  biology", in: Self.funnelAnalysis)?.id == "fig-3-panel-1")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "N", in: Self.funnelAnalysis) == nil)

        let figure = SyncedPaperFigure(id: "fig-3", sourceID: "s", figureLabel: "Figure 3", pageIndex: 5,
                                       caption: "Figure 3: The search space and funnel.", analysis: Self.funnelAnalysis)
        let design = try #require(MobileWalkthroughDeck.figure(labelled: "Figure 3", panel: "Design", in: [figure]))
        #expect(design.panel?.id == "fig-3-panel-3")
        let validation = try #require(MobileWalkthroughDeck.figure(labelled: "Figure 3", panel: "VALIDATION", in: [figure]))
        #expect(validation.panel?.id == "fig-3-panel-4")
        #expect(MobileWalkthroughDeck.panelLetters(of: design) == Self.funnelNames)

        // A lettered figure's chips are the lower-case letters they always were.
        let lettered = PaperFigureAnalysis(
            summary: "s", visualEvidence: [], figureRect: nil,
            panels: [
                PaperFigurePanel(id: "pa", label: "(A)", explanation: "", rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
                PaperFigurePanel(id: "pb", label: "b", explanation: "", rect: nil),
                PaperFigurePanel(id: "pa2", label: "a", explanation: "", rect: nil),
            ],
            analysisVersion: PaperFigureAnalysis.currentVersion, generatedAt: Date(timeIntervalSince1970: 0)
        )
        let letteredFigure = SyncedPaperFigure(id: "f2", sourceID: "s", figureLabel: "Figure 2", pageIndex: 1, caption: "Figure 2.", analysis: lettered)
        let panelA = try #require(MobileWalkthroughDeck.figure(labelled: "Figure 2", panel: "Figure 2a", in: [letteredFigure]))
        #expect(panelA.panel?.id == "pa")
        #expect(MobileWalkthroughDeck.panelLetters(of: panelA) == ["a", "b"])
    }
}

// MARK: - Subject

/// What a walkthrough may be written about, and with which anchors (product owner,
/// 2026-09-19: "books (or chapters thereof) and articles").
@Suite("Walkthrough subject")
struct PaperWalkthroughSubjectTests {

    private func source(_ type: StudioSourceType, url: String = "https://example.com/s", file: String? = nil, state: StudioArticleState = .ready) -> StudioArticle {
        var article = StudioArticle(url: url, title: "S", sourceType: type, discoveryOrigin: .manual, localFilePath: file)
        article.state = state
        return article
    }

    @Test("A paper, a book chapter and an article are subjects; a podcast, a video and an explainer's page are not")
    func subjects() {
        #expect(PaperWalkthroughSubject.of(source(.paper)) == .paper)
        #expect(PaperWalkthroughSubject.of(source(.book, file: "Books/B/Chapters/01.pdf")) == .chapter)
        #expect(PaperWalkthroughSubject.of(source(.article)) == .article)
        #expect(PaperWalkthroughSubject.of(source(.podcast)) == nil)
        #expect(PaperWalkthroughSubject.of(source(.video)) == nil)
        #expect(PaperWalkthroughSubject.of(source(.meeting)) == nil)
        #expect(PaperWalkthroughSubject.of(source(.article, url: GeneratedExplainer.url(explaining: "abc"))) == nil)
        #expect(PaperWalkthroughSubject.paper.noun == "paper")
        #expect(PaperWalkthroughSubject.chapter.noun == "chapter")
        #expect(PaperWalkthroughSubject.article.noun == "article")
    }

    @Test("Figures may be anchored on a paper and a PDF chapter; never on an article or an EPUB chapter")
    func figureAnchors() {
        #expect(PaperWalkthroughSubject.allowsFigureAnchors(source(.paper)))
        #expect(PaperWalkthroughSubject.allowsFigureAnchors(source(.book, file: "Books/B/Chapters/01.pdf")))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(source(.book, file: "Books/B/Chapters/01.xhtml")))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(source(.article)))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(source(.podcast)))
    }

    @Test("The readiness gate is the paper's ingestion gate, and a chapter's or an article's ready state")
    func readiness() {
        // A paper is ready only after its metadata and cleanup stages; a bare
        // ready paper has neither.
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.paper)))
        #expect(PaperWalkthroughGeneratorService.canWalkThrough(source(.article)))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.article, state: .queued)))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.article, state: .error)))
        #expect(PaperWalkthroughGeneratorService.canWalkThrough(source(.book, file: "Books/B/Chapters/01.pdf")))
        #expect(PaperWalkthroughGeneratorService.canWalkThrough(source(.book, file: "Books/B/Chapters/01.xhtml")))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.book, file: "Books/B/Chapters/01.pdf", state: .fetching)))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.podcast)))
    }

    @Test("The writer's turn names the subject and, for a text source, says there is nothing to outline")
    func writerTurnPerSubject() {
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, discoveryOrigin: .manual)
        article.domain = "example.com"
        let articleTurn = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: figures)
        #expect(articleTurn.hasPrefix("Article: A post\nSite: example.com"))
        #expect(articleTurn.contains("shown as text, not as a PDF"))
        #expect(articleTurn.contains("Write no step of kind \"figure\""))
        #expect(!articleTurn.contains("Figures printed"), "an article is offered no figure list even when one is passed")

        let chapter = StudioArticle(url: "Books/Sleep/Chapters/03.pdf", title: "Chapter 3", sourceType: .book, discoveryOrigin: .manual, parentGroup: "Sleep", localFilePath: "Books/Sleep/Chapters/03.pdf")
        let chapterTurn = PaperWalkthroughGeneratorService.writerUserMessage(source: chapter, text: "TEXT", truncated: false, figures: figures)
        #expect(chapterTurn.hasPrefix("Chapter: Chapter 3\nBook: Sleep"))
        #expect(chapterTurn.contains("Figures printed in the paper"))
        #expect(chapterTurn.contains("- Figure 2 · page 4"))

        let epub = StudioArticle(url: "Books/Sleep/Chapters/03.xhtml", title: "Chapter 3", sourceType: .book, discoveryOrigin: .manual, parentGroup: "Sleep", localFilePath: "Books/Sleep/Chapters/03.xhtml")
        let epubTurn = PaperWalkthroughGeneratorService.writerUserMessage(source: epub, text: "TEXT", truncated: false, figures: [])
        #expect(epubTurn.contains("this chapter is shown as text"))

        let paper = StudioArticle(url: "https://example.com/p", title: "Sleep paper", sourceType: .paper)
        #expect(PaperWalkthroughGeneratorService.writerUserMessage(source: paper, text: "TEXT", truncated: false, figures: figures).hasPrefix("Paper: Sleep paper"))
    }

    @Test("A figure anchor on a text source is refused by name and the step explains instead; its passage is kept")
    func validatorRefusesFiguresOnTextSource() throws {
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: [
                step(.figure, title: "The model", figure: "Figure 2", passage: "Figure 2 shows the mitochondrial electron surplus model"),
                step(.explain, title: "Plain", passage: "Sleep pressure rises during waking"),
            ],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: figures,
            allowsFigureAnchors: false,
            text: paperText,
            author: .assistant
        )
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].contains("Figure 2"))
        #expect(outcome.warnings[0].contains("shown as text and has no figures to outline"))
        #expect(outcome.walkthrough.steps[0].kind == .explain)
        #expect(outcome.walkthrough.steps[0].anchor?.figureLabel == nil)
        #expect(outcome.walkthrough.steps[0].anchor?.passage?.hasPrefix("Figure 2 shows") == true)
        #expect(outcome.walkthrough.steps[1].anchor?.passage == "Sleep pressure rises during waking")
    }
}

// MARK: - Figure index for chapters

/// A chapter split from a PDF enters the figure index the way a paper does;
/// an EPUB chapter's text file does not.
@Suite("Walkthrough figure index for chapters")
struct PaperWalkthroughFigureIndexTests {

    @Test("A PDF chapter is queued and found as an index candidate and target; an EPUB chapter is not")
    func chapterEntersFigureIndex() async throws {
        let (storage, root) = makeTemporaryStorage("figure-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfChapter = try await seedChapter(storage, file: "Books/Sleep/Chapters/03.pdf", content: paperText)
        let epubChapter = try await seedChapter(storage, file: "Books/Sleep/Chapters/04.xhtml", title: "Chapter 4", content: paperText)
        let store = try KnowledgeStore(storeDirectory: root)

        try store.ensurePaperFigureIndexQueuedForReview(sourceID: pdfChapter.id, force: false)
        let candidate = try #require(try store.paperFigureIndexCandidate(sourceID: pdfChapter.id))
        #expect(candidate.title == "Chapter 3")
        #expect(candidate.pdfPath.hasSuffix("Books/Sleep/Chapters/03.pdf"))
        #expect(try store.nextPaperFigureIndexCandidate()?.sourceID == pdfChapter.id)
        let target = try #require(try store.paperFigureIndexTarget(sourceID: pdfChapter.id))
        #expect(target.pdfPath.hasSuffix("Books/Sleep/Chapters/03.pdf"))

        try store.ensurePaperFigureIndexQueuedForReview(sourceID: epubChapter.id, force: false)
        #expect(try store.paperFigureIndexCandidate(sourceID: epubChapter.id) == nil)
    }
}

// MARK: - MCP

/// The four tools on a source that is not a paper (walkthrough-design.md,
/// "Books (or chapters thereof) and articles").
@Suite("MCP walkthrough tools")
struct MCPWalkthroughToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_walkthrough_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func seed(_ store: MCPDataStore, type: StudioSourceType, url: String, title: String, file: String? = nil, group: String? = nil) throws -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual, parentGroup: group, localFilePath: file)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.domain = "example.com"
        article.author = "A. Author"
        article.content = paperText
        article.state = .ready
        try store.knowledgeStore().saveSource(article)
        return article
    }

    private let steps: [[String: Any]] = [
        ["kind": "explain", "title": "Start", "body": "Read this first.", "passage": "Sleep pressure rises during waking"],
        ["kind": "figure", "title": "The model", "body": "Look here.", "figure_label": "Figure 2"],
        ["kind": "quiz", "title": "Check", "body": "One question.", "quiz": ["question": "What rose?", "answer": "ATP rose about 1.2 times after sleep deprivation.", "key_points": ["ATP", "higher after deprivation"]]],
    ]

    @Test("save_walkthrough on an article refuses the figure anchor by name, keeps the passage, and get, then delete, read it back")
    func articleRoundTrip() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let article = try seed(store, type: .article, url: "https://example.com/post", title: "A post")

        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "article")
        #expect(saved["figure_anchors"] as? Bool == false)
        #expect((saved["figures_available"] as? [[String: Any]])?.isEmpty == true)
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Figure 2") && warnings[0].contains("shown as text"))
        #expect((saved["message"] as? String)?.contains("beside the article") == true)

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        #expect(got["status"] as? String == "ok")
        #expect(got["subject"] as? String == "article")
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        #expect(gotSteps.map { $0["kind"] as? String } == ["explain", "explain", "quiz"])
        #expect((gotSteps[0]["anchor"] as? [String: Any])?["passage"] as? String == "Sleep pressure rises during waking")
        #expect(gotSteps[1]["anchor"] == nil)

        let deleted = try parseJSON(try await store.deleteWalkthrough(arguments: ["source_id": article.id]))
        #expect(deleted["status"] as? String == "deleted")
        #expect((deleted["message"] as? String)?.contains("article's walkthrough") == true)
        let none = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        #expect(none["status"] as? String == "none")
        #expect(none["figure_anchors"] as? Bool == false)
    }

    @Test("list_walkthroughs names every walk with its source, counts and status, and is empty until one is saved")
    func listTool() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let empty = try parseJSON(try await store.listWalkthroughs())
        #expect(empty["count"] as? Int == 0)
        #expect((empty["walkthroughs"] as? [[String: Any]])?.isEmpty == true)

        let article = try seed(store, type: .article, url: "https://example.com/post", title: "A post")
        _ = try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": steps])
        let listed = try parseJSON(try await store.listWalkthroughs())
        #expect(listed["count"] as? Int == 1)
        let entry = try #require((listed["walkthroughs"] as? [[String: Any]])?.first)
        #expect(entry["source_id"] as? String == article.id)
        #expect(entry["source_title"] as? String == "A post")
        #expect(entry["subject"] as? String == "article")
        #expect(entry["title"] as? String == "Walk")
        #expect(entry["status"] as? String == "ok")
        #expect(entry["author"] as? String == "assistant")
        #expect(entry["step_count"] as? Int == 3)
        // "Read this first." and "Look here." are a card each; the quiz is one.
        #expect(entry["card_count"] as? Int == 3)
        #expect(entry["quiz_count"] as? Int == 1)
        #expect(entry["figure_step_count"] as? Int == 0)
    }

    @Test("save_walkthrough on a PDF chapter takes figure anchors; a chapter whose PDF is unread keeps the words and names the index")
    func chapterSave() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let chapter = try seed(store, type: .book, url: "Books/Sleep/Chapters/03.pdf", title: "Chapter 3", file: "Books/Sleep/Chapters/03.pdf", group: "Sleep")

        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": chapter.id, "title": "Chapter walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "chapter")
        #expect(saved["figure_anchors"] as? Bool == true)
        let warnings = try #require(saved["warnings"] as? [String])
        // No PDF on disk, so the index is empty: the figure is "not in the
        // index", never "this source has no figures".
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("figure index does not have"))
        #expect((saved["message"] as? String)?.contains("beside the chapter") == true)
    }

    @Test("A podcast is refused with the qualifying kinds named, and generate_walkthrough refuses a source that is not ready")
    func refusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let podcast = try seed(store, type: .podcast, url: "https://example.com/episode", title: "An episode")
        await #expect(throws: MCPError.self) {
            try await store.saveWalkthrough(arguments: ["source_id": podcast.id, "title": "Walk", "steps": steps])
        }
        await #expect(throws: MCPError.self) {
            try await store.generateWalkthrough(arguments: ["source_id": podcast.id])
        }
        do {
            _ = try await store.saveWalkthrough(arguments: ["source_id": podcast.id, "title": "Walk", "steps": steps])
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains(PaperWalkthroughSubject.savableQualifyingPhrase))
        }
    }

    @Test("save_walkthrough keeps a step's cited works, checks a library id, and get_walkthrough says which the library holds")
    func citedWorksRoundTrip() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let article = try seed(store, type: .article, url: "https://example.com/letter", title: "A letter")
        let held = try seed(store, type: .article, url: "https://example.com/held-essay", title: "The held essay")
        var cited = steps
        cited[0]["cites"] = [
            ["title": "The Abstraction Fallacy", "authors": ["Alexander Lerchner"], "year": 2026, "kind": "paper", "url": "https://example.org/abstraction-fallacy"],
            ["title": "The held essay", "url": "foreverlm://source/\(held.id)"],
            ["title": "An essay the library lost", "source_id": "src_not_in_this_library", "kind": "treatise"],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": cited]))
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("src_not_in_this_library") && $0.contains("does not hold") })
        #expect(warnings.contains { $0.contains("kind treatise") })

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        let cites = try #require(gotSteps[0]["cites"] as? [[String: Any]])
        #expect(cites.map { $0["title"] as? String } == ["The Abstraction Fallacy", "The held essay", "An essay the library lost"])
        #expect(cites[0]["authors"] as? String == "Alexander Lerchner")
        #expect(cites[0]["year"] as? String == "2026")
        #expect(cites[0]["kind"] as? String == "paper")
        #expect(cites[0]["in_library"] as? Bool == false)
        #expect(cites[1]["in_library"] as? Bool == true)
        #expect(cites[1]["source_id"] as? String == held.id)
        #expect(cites[2]["source_id"] == nil)
        #expect(cites[2]["kind"] == nil)
        #expect(gotSteps[1]["cites"] == nil)
    }
}

// MARK: - Video walkthroughs

/// A talk as the importer stores one: timed transcript blocks, then the block
/// its captured slides add.
private let talkTranscript = """
[0:00] Welcome to Agential Topics. Today we look at the cristae of the inner mitochondrial membrane.

[0:42] The folds are not random. Their curvature concentrates the proton motive force along the ridge.

[1:30] So the geometry itself does electrical work, which is the claim of this talk.
"""

private let talkSlides = """
\(SlideFrameExtraction.slideSectionHeader)

Representative slide screenshots extracted from this video's frames.

### Slide frame 1 [0:40–1:25]
Image: Videos/59GAgPbcQVg/slide_001.jpg
"""

/// A YouTube video's walk (walkthrough-design.md, "2026-09-29: a video is
/// walked through at its moments"): its steps point at moments of the talk,
/// the Reader holds the player there, and only an assistant writes one.
@Suite("Video walkthroughs")
struct VideoWalkthroughTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_video_walkthrough_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: tmpDir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func video(url: String = "https://www.youtube.com/watch?v=59GAgPbcQVg", content: String = talkTranscript + "\n\n" + talkSlides) -> StudioArticle {
        var video = StudioArticle(url: url, title: "Finbow's cristae", sourceType: .video, discoveryOrigin: .manual)
        video.normalizedURL = URLNormalizer.normalize(url)
        video.content = content
        video.state = .ready
        return video
    }

    @Test("A YouTube video is a subject the Reader plays and the writer leaves to an assistant; another site's video is none")
    func subject() {
        let youTube = video()
        #expect(PaperWalkthroughSubject.of(youTube) == .video)
        #expect(PaperWalkthroughGeneratorService.canPlayWalkthrough(youTube))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(youTube))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(youTube))
        #expect(PaperWalkthroughSubject.video.allowsMomentAnchors)
        #expect(!PaperWalkthroughSubject.video.writerWrites)
        #expect(PaperWalkthroughSubject.of(video(url: "https://vimeo.com/123456")) == nil)
    }

    @Test("A video's walk is of its talk: the slide block is left out of the text it is held to, and capturing slides leaves it current")
    func walkedText() {
        let captured = talkTranscript + "\n\n" + talkSlides
        #expect(PaperWalkthroughSubject.walkedText(of: captured) == talkTranscript)
        #expect(PaperWalkthroughSubject.walkedText(of: talkTranscript) == talkTranscript)
        #expect(PaperWalkthroughSubject.walkedText(of: paperText) == paperText)
        #expect(PaperWalkthroughSubject.momentLimit(ofTranscript: talkTranscript) == 90 + 120)
        #expect(PaperWalkthroughSubject.momentLimit(ofTranscript: paperText) == nil)

        let sha = PaperContentPreparationService.sha256(talkTranscript)
        #expect(KnowledgeStore.walkthroughText(talkTranscript, matches: sha))
        #expect(KnowledgeStore.walkthroughText(captured, matches: sha), "capturing slides does not make the walk stale")
        #expect(!KnowledgeStore.walkthroughText(talkTranscript + " One more sentence.", matches: sha), "a changed transcript does")
        #expect(!KnowledgeStore.walkthroughText(talkTranscript, matches: nil))
        // A paper's walk is held to its whole text, as before.
        #expect(KnowledgeStore.walkthroughText(paperText, matches: PaperContentPreparationService.sha256(paperText)))
    }

    @Test("A video's step keeps its moment inside the talk; past the end, or on a source with no timeline, the moment is dropped and named")
    func momentValidation() throws {
        let steps = [
            PaperWalkthroughStep(id: "", kind: .explain, title: "Cristae", body: "Some words.", anchor: PaperWalkthroughAnchor(seconds: 50)),
            PaperWalkthroughStep(id: "", kind: .explain, title: "Later", body: "Some words.", anchor: PaperWalkthroughAnchor(seconds: 9000)),
        ]
        let onVideo = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: steps, sourceID: "v", sourceSHA256: "sha", figures: [],
            allowsFigureAnchors: false, allowsMomentAnchors: true, momentLimit: 210,
            text: talkTranscript, author: .assistant
        )
        #expect(onVideo.walkthrough.steps[0].anchor?.seconds == 50)
        #expect(onVideo.walkthrough.steps[0].anchor?.momentClock == "0:50")
        #expect(onVideo.walkthrough.steps[1].anchor == nil)
        #expect(onVideo.warnings.contains { $0.contains("2:30:00") && $0.contains("past the end") })

        let onPaper = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: steps, sourceID: "p", sourceSHA256: "sha", figures: figures,
            text: paperText, author: .assistant
        )
        #expect(onPaper.walkthrough.steps.allSatisfy { $0.anchor == nil })
        #expect(onPaper.warnings.contains { $0.contains("0:50") && $0.contains("no timeline") })
    }

    @Test("A moment is stored as at and read back; an anchor written before moments reads with none")
    func momentCoding() throws {
        let anchor = PaperWalkthroughAnchor(passage: "Their curvature", seconds: 754)
        let data = try JSONEncoder().encode(anchor)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["at"] as? Int == 754)
        #expect(try JSONDecoder().decode(PaperWalkthroughAnchor.self, from: data) == anchor)
        let older = try JSONDecoder().decode(PaperWalkthroughAnchor.self, from: Data(#"{"passage":"x","page_number":3}"#.utf8))
        #expect(older.seconds == nil)
        #expect(!PaperWalkthroughAnchor(seconds: 0).isEmpty)
        #expect(PaperWalkthroughAnchor(seconds: 3723).momentClock == "1:02:03")
    }

    @Test("save_walkthrough on a video keeps each step's moment, places a quote where the talk says it, names a moment past the talk or unreadable, and get reads at back")
    func saveAndGet() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let talk = video()
        try store.knowledgeStore().saveSource(talk)

        let steps: [[String: Any]] = [
            ["kind": "explain", "title": "The question", "body": "What cristae are.", "at": "0:05"],
            ["kind": "explain", "title": "Curvature", "body": "Why the folds matter.", "passage": "Their curvature concentrates the proton motive force along the ridge"],
            ["kind": "explain", "title": "Too late", "body": "Past the end.", "at": 5000],
            ["kind": "explain", "title": "Unreadable", "body": "A bad moment.", "at": "soon"],
            ["kind": "figure", "title": "A figure", "body": "No figures here.", "figure_label": "Figure 1", "at": 90],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": talk.id, "title": "Cristae walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "video")
        #expect(saved["moment_anchors"] as? Bool == true)
        #expect(saved["figure_anchors"] as? Bool == false)
        #expect((saved["message"] as? String)?.contains("holds the video at its moment") == true)
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("1:23:20") && $0.contains("past the end") })
        #expect(warnings.contains { $0.contains("soon") && $0.contains("no moment") })
        #expect(warnings.contains { $0.contains("Figure 1") && $0.contains("shown as text") })

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": talk.id]))
        #expect(got["status"] as? String == "ok", "a walk of the talk is current while the stored content carries its slides")
        #expect(got["moment_anchors"] as? Bool == true)
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        func at(_ index: Int) -> String? { (gotSteps[index]["anchor"] as? [String: Any])?["at"] as? String }
        #expect(at(0) == "0:05")
        // Quoted from the block under [0:42], a quarter of the way in: placed
        // inside that block, before the next one's [1:30].
        let placed = try #require(SourceImageReference.timestampSeconds(at(1)))
        #expect((42..<90).contains(placed))
        #expect(gotSteps[2]["anchor"] == nil)
        #expect(gotSteps[3]["anchor"] == nil)
        #expect(at(4) == "1:30")

        let stored = try #require(try await store.knowledgeStore().loadPaperWalkthrough(talk.id))
        #expect(stored.sourceSHA256 == PaperContentPreparationService.sha256(talkTranscript))
    }

    @Test("generate_walkthrough leaves a video to save_walkthrough, and get_walkthrough on a video with none says so")
    func writerRefusesVideos() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let talk = video()
        try store.knowledgeStore().saveSource(talk)
        do {
            _ = try await store.generateWalkthrough(arguments: ["source_id": talk.id])
            Issue.record("generate_walkthrough wrote a video's walk")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("save_walkthrough"))
        }
        let none = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": talk.id]))
        #expect(none["status"] as? String == "none")
        #expect(none["subject"] as? String == "video")
        #expect((none["message"] as? String)?.contains("generate_walkthrough") == false)
    }
}

// MARK: - Animation walkthroughs

@Suite("Animation walkthrough storage")
struct AnimationWalkthroughStorageTests {

    private func animationWalk(for artifact: ArtifactRecord, title: String = "Two forces", subject: PaperWalkthrough.Subject = .animation, fingerprint: String? = nil) -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: artifact.id,
            sourceSHA256: fingerprint ?? PaperWalkthrough.animationFingerprint(linkedURL: artifact.linkedURL, artifactID: artifact.id),
            subject: subject,
            title: title,
            steps: [
                PaperWalkthroughStep(id: "step-1", kind: .explain, title: "One pump", body: "Two consequences.", animation: WalkthroughAnimationReference(animationID: artifact.id, step: 1)),
                PaperWalkthroughStep(id: "step-2", kind: .explain, title: "Nigericin", body: "Trades the pH term.", animation: WalkthroughAnimationReference(animationID: artifact.id, step: 5, conditions: ["iono": "nig"])),
            ],
            author: .assistant
        )
    }

    @Test("An animation's walkthrough saves on the artifact, reads back, queues the artifact for sync, replaces itself and deletes")
    func saveLoadDelete() async throws {
        let (storage, root) = makeTemporaryStorage("anim")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try await storage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/pmf-two-components/")!, title: "One force, two components",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let store = try KnowledgeStore(storeDirectory: root)
        try store.clearAllPendingSyncChanges()

        #expect(try await storage.loadArtifactWalkthrough(artifact.id) == nil)
        #expect(try await storage.hasArtifactWalkthrough(artifact.id) == false)
        #expect(try await storage.artifactIDsWithWalkthroughs().isEmpty)

        try await storage.saveArtifactWalkthrough(animationWalk(for: artifact))
        let loaded = try #require(try await storage.loadArtifactWalkthrough(artifact.id))
        #expect(loaded.title == "Two forces")
        #expect(loaded.subject == .animation)
        #expect(loaded.steps.count == 2)
        #expect(loaded.steps[1].animation?.conditions == ["iono": "nig"])
        #expect(try await storage.hasArtifactWalkthrough(artifact.id))
        #expect(try await storage.artifactIDsWithWalkthroughs() == [artifact.id])
        #expect(try store.hasPendingSyncChange(entity: .artifact, logicalKey: artifact.id))
        // The source table knows nothing of it.
        #expect(try await storage.loadPaperWalkthrough(artifact.id) == nil)

        try await storage.saveArtifactWalkthrough(animationWalk(for: artifact, title: "Again"))
        #expect(try await storage.loadArtifactWalkthrough(artifact.id)?.title == "Again")

        #expect(try await storage.deleteArtifactWalkthrough(artifact.id))
        #expect(try await storage.loadArtifactWalkthrough(artifact.id) == nil)
        #expect(try await storage.deleteArtifactWalkthrough(artifact.id) == false)
    }

    @Test("A source walk, a wrong fingerprint and a Site are refused; a re-addressed animation reads stale; deleting the animation takes the walk")
    func refusalsAndStaleness() async throws {
        let (storage, root) = makeTemporaryStorage("anim-stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try await storage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/pmf-two-components/")!, title: "One force",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let site = try await storage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/a-site/")!, title: "A site",
            homeNotebookID: nil, linkedNotebookIDs: []
        )
        await #expect(throws: (any Error).self) {
            try await storage.saveArtifactWalkthrough(animationWalk(for: artifact, subject: .source))
        }
        await #expect(throws: (any Error).self) {
            try await storage.saveArtifactWalkthrough(animationWalk(for: artifact, fingerprint: "stale"))
        }
        await #expect(throws: (any Error).self) {
            try await storage.saveArtifactWalkthrough(animationWalk(for: site))
        }

        try await storage.saveArtifactWalkthrough(animationWalk(for: artifact))
        _ = try await storage.relinkArtifact(artifactID: artifact.id, url: URL(string: "https://sites.foreverlm.com/pmf-renamed/")!)
        #expect(try await storage.loadArtifactWalkthrough(artifact.id) == nil)
        #expect(try await storage.hasArtifactWalkthrough(artifact.id))

        try await storage.deleteArtifact(artifact.id)
        #expect(try await storage.hasArtifactWalkthrough(artifact.id) == false)
    }

    @Test("The walk rides the Artifact sync payload and comes back; a payload without the key reads as none")
    func syncPayload() async throws {
        let (storage, root) = makeTemporaryStorage("anim-sync")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try await storage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/pmf-two-components/")!, title: "One force",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let walk = animationWalk(for: artifact)
        let payload = CloudKitArtifactPayload(artifact: artifact, bodyRevision: "r1", bodyByteCount: 3, bodyFormatVersion: 1, walkthrough: walk)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CloudKitArtifactPayload.self, from: data)
        #expect(decoded.walkthrough == walk)
        #expect(decoded.bodyRevision == "r1")
        let older = try JSONDecoder().decode(CloudKitArtifactPayload.self, from: try JSONEncoder().encode(CloudKitArtifactPayload(artifact: artifact)))
        #expect(older.walkthrough == nil)

        // Applied from sync: stored without a sync change of its own.
        let store = try KnowledgeStore(storeDirectory: root)
        try store.clearAllPendingSyncChanges()
        try store.saveArtifactWalkthroughFromSync(artifactID: artifact.id, walkthrough: walk)
        #expect(try store.loadArtifactWalkthrough(artifact.id)?.title == "Two forces")
        #expect(try store.hasPendingSyncChange(entity: .artifact, logicalKey: artifact.id) == false)
        // A payload with none leaves the row alone.
        try store.saveArtifactWalkthroughFromSync(artifactID: artifact.id, walkthrough: nil)
        #expect(try store.loadArtifactWalkthrough(artifact.id)?.title == "Two forces")
    }
}

@Suite("MCP walkthrough tools: animations")
struct MCPAnimationWalkthroughToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_animation_walkthrough_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func seedArticle(_ store: MCPDataStore) throws -> StudioArticle {
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, discoveryOrigin: .manual)
        article.normalizedURL = URLNormalizer.normalize("https://example.com/post")
        article.domain = "example.com"
        article.content = paperText
        article.state = .ready
        try store.knowledgeStore().saveSource(article)
        return article
    }

    @Test("save_walkthrough with animation saves an animation walk keyed to the artifact, whose steps pin the page; get and delete read it back")
    func animationWalk() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let animation = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/pmf-two-components/")!, title: "One force, two components",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let steps: [[String: Any]] = [
            ["kind": "explain", "title": "One pump", "body": "Two consequences.", "animation_step": 1, "passage": "Sleep pressure rises"],
            ["kind": "explain", "title": "Nigericin", "body": "Trades the pH term.", "animation_step": 5, "animation_conditions": ["iono": "nig", "resp": true]],
            ["kind": "quiz", "title": "Check", "body": "", "quiz": ["question": "Where did the force go?", "answer": "Into ΔpH.", "key_points": ["ΔpH"]]],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["animation": "pmf-two-components", "title": "Two forces", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "animation")
        #expect(saved["animation_id"] as? String == animation.id)
        #expect(saved["figure_anchors"] as? Bool == false)
        #expect(saved["animation_count"] as? Int == 2)
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.count == 1 && warnings[0].contains("no page to point at"))
        #expect((saved["message"] as? String)?.contains("beside the animation") == true)

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["animation": animation.id]))
        #expect(got["status"] as? String == "ok")
        #expect(got["subject"] as? String == "animation")
        #expect(got["animation_url"] as? String == "https://sites.foreverlm.com/pmf-two-components/")
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        #expect(gotSteps.count == 3)
        #expect(gotSteps[0]["has_animation"] as? Bool == true)
        #expect(gotSteps[0]["anchor"] == nil)
        let second = try #require(gotSteps[1]["animation"] as? [String: Any])
        #expect(second["animation_id"] as? String == animation.id)
        #expect(second["step"] as? Int == 5)
        #expect(second["conditions"] as? [String: String] == ["iono": "nig", "resp": "1"])
        #expect(second["title"] as? String == "One force, two components")
        let url = try #require(second["url"] as? String)
        #expect(url.hasPrefix("https://sites.foreverlm.com/pmf-two-components/?"))
        #expect(url.contains("embed=1") && url.contains("step=5") && url.contains("iono:nig"))
        #expect(gotSteps[2]["has_animation"] as? Bool == false)

        // list_animations says the animation is walked.
        let listed = try parseJSON(try await store.listAnimations(sourceID: nil))
        let entry = try #require((listed["animations"] as? [[String: Any]])?.first)
        #expect(entry["has_walkthrough"] as? Bool == true)

        let deleted = try parseJSON(try await store.deleteWalkthrough(arguments: ["animation": "https://sites.foreverlm.com/pmf-two-components/"]))
        #expect(deleted["status"] as? String == "deleted")
        #expect((deleted["message"] as? String)?.contains("animation's walkthrough") == true)
        let none = try parseJSON(try await store.getWalkthrough(arguments: ["animation": animation.id]))
        #expect(none["status"] as? String == "none")
        #expect(none["subject"] as? String == "animation")
    }

    @Test("A source's step shows a saved animation by slug; a Site, an unknown handle, both subjects at once and a stepless reference are refused")
    func referencesAndRefusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let article = try seedArticle(store)
        let animation = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/pmf-two-components/")!, title: "One force",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        _ = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/a-site/")!, title: "A site",
            homeNotebookID: nil, linkedNotebookIDs: []
        )
        let steps: [[String: Any]] = [
            ["kind": "explain", "title": "Start", "body": "Read this first.", "passage": "Sleep pressure rises during waking"],
            ["kind": "explain", "title": "See it move", "body": "The force has two parts.", "animation": "pmf-two-components", "animation_step": 4],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "article")
        #expect(saved["animation_count"] as? Int == 1)
        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        let ref = try #require(gotSteps[1]["animation"] as? [String: Any])
        #expect(ref["animation_id"] as? String == animation.id)
        #expect((ref["url"] as? String)?.contains("step=4") == true)
        #expect((gotSteps[0]["anchor"] as? [String: Any])?["passage"] as? String == "Sleep pressure rises during waking")

        for bad: [String: Any] in [
            ["source_id": article.id, "title": "W", "steps": [["kind": "explain", "title": "S", "body": "B", "animation": "a-site", "animation_step": 1]]],
            ["source_id": article.id, "title": "W", "steps": [["kind": "explain", "title": "S", "body": "B", "animation": "nothing-here", "animation_step": 1]]],
            ["source_id": article.id, "title": "W", "steps": [["kind": "explain", "title": "S", "body": "B", "animation_step": 2]]],
            ["source_id": article.id, "animation": "pmf-two-components", "title": "W", "steps": steps],
            ["animation": "a-site", "title": "W", "steps": steps],
        ] {
            await #expect(throws: MCPError.self) { try await store.saveWalkthrough(arguments: bad) }
        }
        await #expect(throws: MCPError.self) { try await store.generateWalkthrough(arguments: ["animation": "pmf-two-components"]) }
    }
}

// MARK: - Figure mentions

@Suite("Walkthrough figure mention")
struct PaperFigureMentionTests {

    @Test("A citation's panels are read as papers print them: glued, bracketed, listed, ranged, in one case; an article 'a' is not a panel")
    func panelsCited() {
        let text = """
        Sodium rose within minutes (Fig. 1a–c). Pressure fell with PAB (Fig. 1(d)). Both were repeated in Figs. 1E and F. \
        In Fig. 1G, a decrease followed. Figure 12 is not this figure. See Fig. 1 for the design.
        """
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "b", in: text) == "Sodium rose within minutes (Fig. 1a–c).")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "D", in: text) == "Pressure fell with PAB (Fig. 1(d)).")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "f", in: text) == "Both were repeated in Figs. 1E and F.")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "g", in: text) == "In Fig. 1G, a decrease followed.")
        // No sentence cites h: the figure's own citation stands in.
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "h", in: text) == "See Fig. 1 for the design.")
        // The figure itself: the first citation.
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: nil, in: text) == "Sodium rose within minutes (Fig. 1a–c).")
        #expect(PaperFigureMention.sentence(citing: "Figure 12", panel: nil, in: text) == "Figure 12 is not this figure.")
        #expect(PaperFigureMention.sentence(citing: "Extended Data Figure 1", panel: nil, in: text) == nil)
        // "a" after a comma is the article, not panel a, unless the list closes on it.
        let article = "In Fig. 1G, a decrease followed. Panel a is in Fig. 1a. Then Fig. 1B, A and C together."
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "a", in: article) == "Panel a is in Fig. 1a.")
        // A list keeps one case: "1B, A" is B and A; "1G, a" is G alone.
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "c", in: article) == "Then Fig. 1B, A and C together.")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "a", in: "See Fig. 1B, A and C.") == "See Fig. 1B, A and C.")
    }

    @Test("Sentences end at a stop before a capital, and not at an abbreviation, an initial, a decimal or a citation")
    func sentences() {
        let text = """
        Cells were treated as in ref. 12 and Smith et al. (2019). ATP fell by 40% (p < 0.05). J. Doe measured it. \
        The U.S. data agree. Fig. 3 shows it; see e.g. Figure 4. Is that all? Yes.
        """
        #expect(PaperFigureMention.sentences(in: text) == [
            "Cells were treated as in ref. 12 and Smith et al. (2019).",
            "ATP fell by 40% (p < 0.05).",
            "J. Doe measured it.",
            "The U.S. data agree.",
            "Fig. 3 shows it; see e.g. Figure 4.",
            "Is that all?",
            "Yes.",
        ])
        // A word the column broke closes up; a hyphen before a capital stays; a sentence over the length is passed over.
        let broken = "Sleep depri-\nvation raised Na+-\nATPase activity (Fig. 2a).\nThe rest follows."
        #expect(PaperFigureMention.sentence(citing: "Figure 2", panel: "a", in: broken) == "Sleep deprivation raised Na+-ATPase activity (Fig. 2a).")
        let long = (0..<130).map { _ in "word" }.joined(separator: " ") + " (Fig. 2a). Short one (Fig. 2a)."
        #expect(PaperFigureMention.sentence(citing: "Figure 2", panel: "a", in: long) == "Short one (Fig. 2a).")
        #expect(PaperFigureMention.sentence(citing: "Figure 2", panel: "a", in: "") == nil)
        #expect(PaperFigureMention.sentence(citing: "Figure", panel: "a", in: "Fig. 2a") == nil)
    }
}

// MARK: - Schema 131: lessons become walkthroughs

/// The one-day Lessons feature (schema 130) folded into walkthroughs
/// (2026-09-23): a store that reached 130 converts its lesson rows into
/// walkthroughs, archives the lesson artifacts and drops the table.
@Suite("Walkthrough schema 131: lesson adoption")
struct WalkthroughLessonAdoptionMigrationTests {

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalarInt(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    /// The lesson as schema 130's `PaperLesson` encoded it.
    private static let lessonJSON = """
    {"version":1,"source_id":"%SOURCE%","source_sha256":"%SHA%","title":"Sodium as an energy problem","generated_at":"2026-09-22T20:00:00Z","author":"app","chapters":[{"id":"ch-1","title":"The energy hit","claim":"Raising sodium lowers ATP.","moments":[{"id":"ch-1-m1","kind":"context","text":"Cells keep sodium low.","more":[{"label":"What is NCLX?","text":"The exchanger.","from_paper":false}]},{"id":"ch-1-m2","kind":"look","text":"Look at panel a.","anchor":{"figure_label":"Figure 2","panel_label":"a","page_number":4},"source_mention":"ATP fell (Fig. 2a)."},{"id":"ch-1-m3","kind":"predict","text":"Where do the bars land?","anchor":{"figure_label":"Figure 2","panel_label":"b","page_number":4},"question":{"answer":"Lower.","key_points":["lower"]}},{"id":"ch-1-m4","kind":"find","text":"Which panel is the control?","anchor":{"figure_label":"Figure 2","page_number":4},"question":{"answer":"Panel b.","key_points":[],"target_panel":"b"}},{"id":"ch-1-m5","kind":"explain","text":"Why does ATP fall?","question":{"answer":"The pump spends it.","key_points":["pump"]}}]}]}
    """

    @Test("A store that never had the lesson table migrates past 131 untouched")
    func noTableNoWork() async throws {
        let root = try Self.temporaryRoot("schema-131-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let article = try await seedArticle(storage, content: paperText)
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try store.clearAllPendingSyncChanges()
            try store.execForTesting("PRAGMA user_version = 129")
        }
        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalarInt(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(try migrated.loadPaperWalkthrough(article.id) == nil)
        #expect(Self.scalarInt(at: root, "SELECT COUNT(*) FROM sync_changes") == 0)
    }
}

// MARK: - Card pictures and animation cards

@Suite("Walkthrough card pictures")
struct PaperWalkthroughCardPictureTests {
    private func walk(_ steps: [PaperWalkthroughStep], chapters: [PaperWalkthroughChapter]? = nil, subject: PaperWalkthrough.Subject = .source) -> PaperWalkthrough {
        PaperWalkthrough(sourceID: "s", sourceSHA256: "sha", subject: subject, title: "W", steps: steps, chapters: chapters, author: .app)
    }

    @Test("A step's animation is dealt as a card of its own: after the points and before the question, after a question step's question, never on an animation walk")
    func animationHasItsOwnCard() {
        let quiz = PaperWalkthroughQuiz(question: "Where does the charge go?", answer: "Into ΔpH.", keyPoints: ["ΔpH"])
        let explained = PaperWalkthroughStep(
            id: "a", kind: .explain, title: "The pump", body: "",
            animationHTML: "<html></html>", quiz: quiz,
            beats: [PaperWalkthroughBeat(text: "One."), PaperWalkthroughBeat(text: "Two.")]
        )
        let asked = PaperWalkthroughStep(id: "b", kind: .quiz, title: "Guess", body: "", animationHTML: "<html></html>", quiz: quiz)
        let plain = PaperWalkthroughStep(id: "c", kind: .explain, title: "Plain", body: "Words.")
        let source = walk([explained, asked, plain])
        #expect(source.playableBeats(of: explained).map(\.kind) == [.point, .point, .animation, .question])
        #expect(source.playableBeats(of: asked).map(\.kind) == [.question, .animation])
        #expect(source.playableBeats(of: plain).map(\.kind) == [.point])
        #expect(source.cardCount == 4 + 2 + 1)
        let animationWalk = walk([explained], subject: .animation)
        #expect(animationWalk.playableBeats(of: explained).map(\.kind) == [.point, .point, .question])
    }

    @Test("A card shows the figure its step outlines, else its own picture, else the one before it in its chapter — and borrowing stops at the chapter")
    func picturesAreSharedWithinAChapter() {
        let figure = PaperWalkthroughStep(id: "1", kind: .figure, title: "F", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", passage: nil, pageNumber: 4))
        let after = PaperWalkthroughStep(id: "2", kind: .explain, title: "E", body: "b", anchor: PaperWalkthroughAnchor(passage: "some words"))
        let named = PaperWalkthroughStep(id: "3", kind: .explain, title: "N", body: "b", picture: PaperWalkthroughPicture(figureLabel: "Figure 1"))
        let drawn = PaperWalkthroughStep(id: "4", kind: .explain, title: "D", body: "b", picture: PaperWalkthroughPicture(brief: "A pump.", imageID: "0123abcd-0000"))
        let waiting = PaperWalkthroughStep(id: "5", kind: .explain, title: "W", body: "b", picture: PaperWalkthroughPicture(brief: "Not drawn yet."))
        let opening = PaperWalkthroughStep(id: "6", kind: .explain, title: "O", body: "b")
        let lonely = PaperWalkthroughStep(id: "7", kind: .explain, title: "L", body: "b")
        let later = PaperWalkthroughStep(id: "8", kind: .figure, title: "G", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 3"))
        let chapters = [
            PaperWalkthroughChapter(id: "c1", title: "One", claim: "x", stepIDs: ["1", "2", "3", "4", "5"]),
            PaperWalkthroughChapter(id: "c2", title: "Two", claim: "y", stepIDs: ["6", "8"]),
            PaperWalkthroughChapter(id: "c3", title: "Three", claim: "z", stepIDs: ["7"]),
        ]
        let w = walk([figure, after, named, drawn, waiting, opening, lonely, later], chapters: chapters)
        #expect(w.cardPicture(of: figure) == .anchoredFigure)
        // The passage step borrows the figure step's panel, without its page anchor's passage.
        #expect(w.cardPicture(of: after) == .figure(PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", pageNumber: 4)))
        #expect(w.cardPicture(of: named) == .figure(PaperWalkthroughAnchor(figureLabel: "Figure 1")))
        #expect(w.cardPicture(of: drawn) == .drawn(imageID: "0123abcd-0000", brief: "A pump."))
        // An undrawn brief borrows meanwhile.
        #expect(w.cardPicture(of: waiting) == .drawn(imageID: "0123abcd-0000", brief: "A pump."))
        #expect(w.stepsAwaitingPicture.map(\.id) == ["5"])
        // A chapter's opening step borrows forward within its chapter.
        #expect(w.cardPicture(of: opening) == .figure(PaperWalkthroughAnchor(figureLabel: "Figure 3")))
        // A chapter with no picture lends none and borrows none.
        #expect(w.cardPicture(of: lonely) == nil)
        #expect(walk([after], subject: .animation).cardPicture(of: after) == nil)
    }

    @Test("A picture is checked as an anchor is: its figure against the index, dropped on a figure step, refused on a text source, and its image id by shape")
    func picturesAreValidated() throws {
        var own = step(.figure, title: "Own", figure: "Figure 2", panel: "a")
        own.picture = PaperWalkthroughPicture(figureLabel: "Figure 1")
        var shown = step(.explain, title: "Shown")
        shown.picture = PaperWalkthroughPicture(figureLabel: "Fig. 1", panelLabel: "b", brief: "ignored beside a figure")
        var invented = step(.explain, title: "Invented")
        invented.picture = PaperWalkthroughPicture(figureLabel: "Figure 9")
        var briefed = step(.explain, title: "Briefed")
        briefed.picture = PaperWalkthroughPicture(brief: "Electrons pile up.", imageID: "NOT AN ID")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [own, shown, invented, briefed],
            sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .assistant
        )
        let steps = outcome.walkthrough.steps
        #expect(steps[0].picture == nil)
        #expect(steps[1].picture == PaperWalkthroughPicture(figureLabel: "Figure 1", panelLabel: "b"))
        #expect(steps[2].picture == nil)
        #expect(steps[3].picture == PaperWalkthroughPicture(brief: "Electrons pile up."))
        #expect(outcome.warnings.contains { $0.contains("Figure 9") })
        #expect(outcome.warnings.contains { $0.contains("not an image id") })

        let text = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [shown, briefed],
            sourceID: "src", sourceSHA256: "sha", figures: [], allowsFigureAnchors: false, text: paperText, author: .assistant
        )
        #expect(text.walkthrough.steps[0].picture == PaperWalkthroughPicture(brief: "ignored beside a figure"))
        #expect(text.warnings.contains { $0.contains("has no figures") })
    }

    @Test("A draft's picture decodes leniently, round-trips on the record, and a record without one encodes as before")
    func pictureCoding() throws {
        let json = """
        {"title": "T", "steps": [
          {"kind": "explain", "title": "A", "beats": ["x"], "picture": {"brief": ["What it shows.", "Labels."]}},
          {"kind": "explain", "title": "B", "beats": ["y"], "picture": {"figure_label": "Figure 1", "panel_label": "a"}},
          {"kind": "explain", "title": "C", "beats": ["z"], "picture": 3}
        ]}
        """
        let draft = try JSONDecoder().decode(PaperWalkthroughDraft.self, from: Data(json.utf8))
        #expect(draft.steps.map(\.picture) == [
            PaperWalkthroughPicture(brief: "What it shows. Labels."),
            PaperWalkthroughPicture(figureLabel: "Figure 1", panelLabel: "a"),
            nil,
        ])
        let pictured = PaperWalkthroughStep(id: "1", kind: .explain, title: "T", body: "b", picture: PaperWalkthroughPicture(brief: "B", imageID: "0123abcd-0000"))
        let record = walk([pictured, PaperWalkthroughStep(id: "2", kind: .explain, title: "U", body: "c")])
        let encoded = try PaperWalkthroughCoding.json(record)
        #expect(encoded.contains("\"image_id\":\"0123abcd-0000\""))
        #expect(try PaperWalkthroughCoding.walkthrough(fromJSON: encoded).steps == record.steps)
        #expect(!(try PaperWalkthroughCoding.json(walk([PaperWalkthroughStep(id: "2", kind: .explain, title: "U", body: "c")]))).contains("picture"))
    }

    @Test("The run draws each waiting brief once, shares a drawing between steps whose briefs read the same, and saves after each")
    func runDrawsPictures() async throws {
        let one = PaperWalkthroughStep(id: "1", kind: .explain, title: "One", body: "b", picture: PaperWalkthroughPicture(brief: "A pump."))
        let same = PaperWalkthroughStep(id: "2", kind: .explain, title: "Same", body: "b", picture: PaperWalkthroughPicture(brief: "a  PUMP."))
        let other = PaperWalkthroughStep(id: "3", kind: .explain, title: "Other", body: "b", picture: PaperWalkthroughPicture(brief: "A gradient."))
        var walkthrough = walk([one, same, other])
        let drawn = Counter()
        let saves = Counter()
        let failures = try await PaperWalkthroughWriting.drawPictures(
            in: &walkthrough,
            illustrate: { _ in
                let n = await drawn.increment()
                return "0000000\(n)-aaaa"
            },
            save: { _ in _ = await saves.increment() },
            onStage: nil,
            onStepsSaved: nil
        )
        #expect(failures.isEmpty)
        #expect(await drawn.value == 2)
        #expect(await saves.value == 3)
        #expect(walkthrough.steps.map(\.picture?.imageID) == ["00000001-aaaa", "00000001-aaaa", "00000002-aaaa"])
        #expect(walkthrough.stepsAwaitingPicture.isEmpty)
    }

    @Test("The writer is asked for a picture on every card that outlines no figure, and never on a question")
    func writerAsksForPictures() {
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains("Every card shows a picture above its point"))
        #expect(prompt.contains("give a quiz step no \"picture\""))
        #expect(prompt.contains("\"picture\": {\"brief\": \"...\"}"))
        let text = PaperWalkthroughWriting.picturePrompt(
            summary: PaperWalkthroughSourceSummary(id: "s", subject: .paper, allowsFigureAnchors: true, title: "MitoSpace", sourceType: "paper"),
            step: PaperWalkthroughStep(id: "1", kind: .explain, title: "Movies", body: "", beats: [PaperWalkthroughBeat(text: "40,000 movies.")], picture: PaperWalkthroughPicture(brief: "A grid of cells."))
        )
        #expect(text.contains("A grid of cells."))
        #expect(text.contains("40,000 movies."))
        #expect(text.contains("Invent no data"))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

// MARK: - Cited works

/// A step's cited works (walkthrough-design.md, "2026-09-30: a card shows
/// the work it cites"): what the record keeps, what the validator lets
/// through, what the tutor reads, and how a card finds the work.
@Suite("Walkthrough cited works")
struct PaperWalkthroughCitationTests {

    @Test("A step's cited works round-trip through the record's JSON, and a step without them encodes as it did")
    func roundTrip() throws {
        var cited = step(.explain, title: "The mapmaker", body: "Lerchner argues.")
        cited.id = "s1"
        cited.cites = [
            PaperWalkthroughCitation(title: "The Abstraction Fallacy", authors: "Alexander Lerchner", year: "2026", venue: "PhilArchive", kind: .paper, url: "https://example.org/abstraction-fallacy"),
            PaperWalkthroughCitation(title: "Life Itself", authors: "Robert Rosen", kind: .book, sourceID: "src_rosen"),
        ]
        let data = try JSONEncoder().encode(cited)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"cites\""))
        #expect(json.contains("\"source_id\""))
        let back = try JSONDecoder().decode(PaperWalkthroughStep.self, from: data)
        #expect(back.cites == cited.cites)

        var plain = step(.explain)
        plain.id = "s2"
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("cites"))
    }

    @Test("A numeric year reads as its digits, an unknown kind as none, and a malformed list loses only the citations")
    func tolerantDecoding() throws {
        let json = #"{"kind": "explain", "title": "T", "beats": ["x"], "cites": [{"title": "What Is Life?", "authors": "Erwin Schrödinger", "year": 1944, "kind": "monograph"}]}"#
        let draft = try JSONDecoder().decode(PaperWalkthroughDraft.Step.self, from: Data(json.utf8))
        #expect(draft.cites.first?.title == "What Is Life?")
        #expect(draft.cites.first?.year == "1944")
        #expect(draft.cites.first?.kind == nil)
        #expect(PaperWalkthroughValidation.steps(from: PaperWalkthroughDraft(title: "T", steps: [draft])).first?.cites == draft.cites)

        let broken = #"{"kind": "explain", "title": "T", "beats": ["x"], "cites": "Lerchner 2026"}"#
        let kept = try JSONDecoder().decode(PaperWalkthroughDraft.Step.self, from: Data(broken.utf8))
        #expect(kept.title == "T")
        #expect(kept.cites.isEmpty)

        let stored = #"{"id": "s", "kind": "explain", "title": "T", "body": "b", "cites": 3}"#
        #expect(try JSONDecoder().decode(PaperWalkthroughStep.self, from: Data(stored.utf8)).cites.isEmpty)
    }

    @Test("Validation keeps titled works, reads a DOI in its spellings and a library link, drops the walked source and a repeat, and keeps three")
    func validation() throws {
        var cited = step(.explain, title: "Cited", body: "Some words.")
        cited.id = "cited"
        cited.cites = [
            PaperWalkthroughCitation(title: "  The   Abstraction Fallacy ", authors: " Alexander Lerchner ", doi: "https://doi.org/10.5555/ABC.123"),
            PaperWalkthroughCitation(title: "The Abstraction Fallacy, again", doi: "doi:10.5555/abc.123"),
            PaperWalkthroughCitation(title: "", url: "https://example.com/untitled"),
            PaperWalkthroughCitation(title: "Life Itself", url: "https://doi.org/10.7312/rose07564"),
            PaperWalkthroughCitation(title: "The walk's own source", sourceID: "src"),
            PaperWalkthroughCitation(title: "In the library", url: "foreverlm://source/src_held"),
            PaperWalkthroughCitation(title: "Bad address", doi: "not a doi", url: "ftp://example.com/x"),
            PaperWalkthroughCitation(title: "A fifth work", url: "https://example.com/fifth"),
        ]
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [cited, step(.explain, title: "Two")],
            sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .assistant
        )
        let cites = try #require(outcome.walkthrough.steps.first?.cites)
        #expect(cites.map(\.title) == ["The Abstraction Fallacy", "Life Itself", "In the library"])
        #expect(cites[0].doi == "10.5555/abc.123")
        #expect(cites[0].authors == "Alexander Lerchner")
        #expect(cites[1].doi == "10.7312/rose07564")
        #expect(cites[1].url == nil)
        #expect(cites[2].sourceID == "src_held")
        #expect(cites[2].url == nil)
        #expect(outcome.walkthrough.steps[1].cites.isEmpty)
        #expect(outcome.warnings.contains { $0.contains("no title") })
        #expect(outcome.warnings.contains { $0.contains("walks through") })
        #expect(outcome.warnings.contains { $0.contains("not a DOI") })
        #expect(outcome.warnings.contains { $0.contains("not a web address") })
        #expect(outcome.warnings.contains { $0.contains("cites 5 works") })
    }

    @Test("A cited work's address, byline, identity, reference line and Scholar search")
    func presentation() throws {
        let paper = PaperWalkthroughCitation(
            title: "Metabolism–Repair systems",
            authors: "Hofmeyr J-HS; Cornish-Bowden A; Rohwer J",
            year: "2021",
            venue: "Interface Focus",
            doi: "10.1098/rsfs.2020.0077"
        )
        #expect(paper.address?.absoluteString == "https://doi.org/10.1098/rsfs.2020.0077")
        #expect(paper.byline == "Hofmeyr J-HS et al. · Interface Focus · 2021")
        #expect(paper.identityKey == "doi:10.1098/rsfs.2020.0077")
        #expect(paper.referenceLine == "Hofmeyr J-HS, Cornish-Bowden A, Rohwer J. Metabolism–Repair systems. Interface Focus. 2021. doi:10.1098/rsfs.2020.0077")
        #expect(PaperWalkthroughCitation(title: "X", authors: "A; B").byline == "A & B")
        #expect(PaperWalkthroughCitation(title: "X").byline == nil)

        let named = PaperWalkthroughCitation(title: "What Is Life?", authors: "Erwin Schrödinger", year: "1944", kind: .book)
        #expect(named.address == nil)
        #expect(named.identityKey == "title:what is life")
        #expect(named.referenceLine == "Erwin Schrödinger. What Is Life? 1944")
        let search = try #require(named.scholarSearchURL)
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "\"What Is Life?\" Erwin Schrödinger")
        #expect(PaperWalkthroughCitation.eyebrow(kind: .book) == "Cited book")
        #expect(PaperWalkthroughCitation.eyebrow(kind: nil) == "Cited work")

        let page = PaperWalkthroughCitation(title: "A post", url: "https://example.com/post")
        #expect(page.identityKey == "url:https://example.com/post")
        #expect(PaperWalkthroughCitation(title: "A post", url: "javascript:alert(1)").address == nil)
    }

    @Test("A step's turn tells the tutor what its card cites")
    func tutorReadsTheCitation() {
        var cited = step(.explain, title: "The mapmaker", body: "Lerchner argues.")
        cited.cites = [PaperWalkthroughCitation(title: "The Abstraction Fallacy", authors: "Alexander Lerchner", year: "2026")]
        let text = WalkthroughStepComposer.markdown(
            step: cited,
            marker: WalkthroughStepTurn.Marker(sourceID: "src", stepID: "s1", index: 0, count: 3),
            lens: nil
        )
        #expect(text.contains("*Cites:* Alexander Lerchner. The Abstraction Fallacy. 2026"))
        #expect(!WalkthroughStepComposer.markdown(
            step: step(.explain),
            marker: WalkthroughStepTurn.Marker(sourceID: "src", stepID: "s2", index: 1, count: 3),
            lens: nil
        ).contains("Cites:"))
    }

    @Test("A card finds the work among the walked source's recorded cited papers by DOI, address, or an exact distinctive title")
    func recordedCitedPaperMatch() {
        let rows = [
            VideoCitedPaper(sourceID: "src", title: "Metabolism-Repair Systems Revisited", doi: "10.1/abc", url: "https://doi.org/10.1/abc", status: .pending),
            VideoCitedPaper(
                sourceID: "src",
                title: "Anticipatory Systems: Philosophical, Mathematical and Methodological Foundations",
                url: "https://link.springer.com/book/10.1007/978-1-4614-1269-4",
                status: .imported,
                importedSourceID: "src_rosen"
            ),
            VideoCitedPaper(sourceID: "src", title: "Introduction", status: .unresolved),
        ]
        #expect(StudioViewModel.recordedCitedPaper(matching: PaperWalkthroughCitation(title: "anything", doi: "10.1/ABC"), in: rows)?.id == rows[0].id)
        #expect(StudioViewModel.recordedCitedPaper(
            matching: PaperWalkthroughCitation(title: "x", url: "https://link.springer.com/book/10.1007/978-1-4614-1269-4"),
            in: rows
        )?.id == rows[1].id)
        #expect(StudioViewModel.recordedCitedPaper(
            matching: PaperWalkthroughCitation(title: "Anticipatory systems — philosophical, mathematical and methodological foundations"),
            in: rows
        )?.id == rows[1].id)
        // Too short a title names nothing.
        #expect(StudioViewModel.recordedCitedPaper(matching: PaperWalkthroughCitation(title: "Introduction"), in: rows) == nil)
        // A citation with an address of its own is never matched by its title.
        #expect(StudioViewModel.recordedCitedPaper(
            matching: PaperWalkthroughCitation(title: "Metabolism-Repair Systems Revisited", url: "https://example.com/other"),
            in: rows
        ) == nil)

        #expect(StudioViewModel.isDistinctiveCitedTitle("the abstraction fallacy"))
        #expect(!StudioViewModel.isDistinctiveCitedTitle("life itself"))
        #expect(StudioViewModel.soleSource(titled: "the abstraction fallacy why ai", among: [(id: "a", title: "The Abstraction Fallacy: why AI"), (id: "b", title: "Other")]) == "a")
        #expect(StudioViewModel.soleSource(titled: "same title said here", among: [(id: "a", title: "Same title said here"), (id: "b", title: "Same Title, Said Here")]) == nil)
    }
}

/// The drawn pictures a walk shows ride its Source record
/// (`walkthroughPicturesAsset`): out of the store of the Mac that holds them,
/// into every other Mac's, showing there what they show here.
@Suite("Walkthrough Picture Package")
struct WalkthroughPicturePackageTests {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    // Three images: `v` revised once, `x` revised and then its revision
    // redrawn, and `solo`, which nothing names.
    private static let v1 = "a0000000-0000-4000-8000-000000000001"
    private static let v2 = "a0000000-0000-4000-8000-000000000002"
    private static let x1 = "b0000000-0000-4000-8000-000000000001"
    private static let x2 = "b0000000-0000-4000-8000-000000000002"
    private static let x3 = "b0000000-0000-4000-8000-000000000003"
    private static let solo = "c0000000-0000-4000-8000-000000000001"
    private static let missing = "d0000000-0000-4000-8000-000000000001"

    private func root(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("walk_picture_package_\(name)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(GeneratedImageStore.directory), withIntermediateDirectories: true)
        return url
    }

    private func store(_ id: String, _ details: GeneratedImageStore.Details, in root: URL) throws {
        let stored = try GeneratedImageStore.withDetails(GeneratedImage(data: Self.png, mediaType: "image/png"), details)
        try stored.data.write(to: root.appendingPathComponent(GeneratedImageStore.directory).appendingPathComponent("\(id).png"))
    }

    private func seed(_ root: URL) throws {
        try store(Self.v1, .init(origin: .saved, text: "A cell.", title: "Cell", imageID: Self.v1, version: 1), in: root)
        try store(Self.v2, .init(origin: .saved, text: "A cell, labelled.", title: "Cell", imageID: Self.v1, version: 2), in: root)
        try store(Self.x1, .init(origin: .drawn, text: "A blanket.", title: "Blanket", imageID: Self.x1, version: 1), in: root)
        try store(Self.x2, .init(origin: .drawn, text: "A blanket, nested.", title: "Blanket", imageID: Self.x1, version: 2, replacedBy: Self.x3), in: root)
        try store(Self.x3, .init(origin: .drawn, text: "A blanket, nested.", title: "Blanket", imageID: Self.x1, version: 3, replaces: Self.x2), in: root)
        try store(Self.solo, .init(origin: .saved, text: "Alone.", title: "Alone", imageID: Self.solo, version: 1), in: root)
    }

    private func walk(naming ids: [String?]) -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: "article-1",
            sourceSHA256: "sha",
            title: "Metabolism as inference",
            steps: ids.enumerated().map { offset, id in
                PaperWalkthroughStep(
                    id: "s\(offset)", kind: .explain, title: "Step \(offset)", body: "Point \(offset).",
                    picture: id.map { PaperWalkthroughPicture(brief: "Picture \(offset)", imageID: $0) }
                )
            },
            author: .assistant
        )
    }

    @Test("A walk names each drawn picture once, in step order, lower-cased")
    func namesPictures() {
        let record = walk(naming: [Self.v1.uppercased(), nil, Self.x2, Self.v1])
        #expect(record.drawnPictureIDs == [Self.v1, Self.x2])
        #expect(walk(naming: [nil, nil]).drawnPictureIDs.isEmpty)
    }

    @Test("Each named image travels whole, the version a step shows first; what this Mac lacks is left out")
    func packsWhatStepsShow() throws {
        let sender = try root("sender")
        defer { try? FileManager.default.removeItem(at: sender) }
        try seed(sender)

        let contents = WalkthroughPicturePackage.contents(for: [Self.v1, Self.x2, Self.missing], root: sender)
        // Named as the image, `v` shows its latest; named as a version, `x2`
        // shows its redraw.
        #expect(contents.shown == [Self.v1: "\(Self.v2).png", Self.x2: "\(Self.x3).png"])
        #expect(contents.files.map(\.id) == [Self.v2, Self.x3, Self.v1, Self.x2, Self.x1])
        #expect(!contents.files.contains { $0.id == Self.solo }, "an image no step names stays home")
        #expect(contents.digest.hasPrefix("w:"))
        #expect(WalkthroughPicturePackage.contents(for: [Self.v1, Self.x2], root: sender).digest == contents.digest)
        #expect(WalkthroughPicturePackage.contents(for: [Self.v1, Self.x1], root: sender).digest != contents.digest,
                "what a step shows is part of the signature")
        #expect(WalkthroughPicturePackage.contents(for: [Self.missing], root: sender).isEmpty)
        #expect(WalkthroughPicturePackage.contents(for: [], root: sender).isEmpty)
    }

    @Test("The receiving store shows what the sender's does, and the manifest never lands in it")
    func roundTrip() throws {
        let sender = try root("sender")
        let receiver = try root("receiver")
        defer {
            try? FileManager.default.removeItem(at: sender)
            try? FileManager.default.removeItem(at: receiver)
        }
        try seed(sender)
        let named = [Self.v1, Self.x2]
        let contents = WalkthroughPicturePackage.contents(for: named, root: sender)
        let package = try #require(contents.encoded())
        let entries = try #require(try PropertyListSerialization.propertyList(from: package, options: [], format: nil) as? [String: Data])
        let manifest = try #require(entries[WalkthroughPicturePackageFormat.manifestName])
        #expect(try PropertyListSerialization.propertyList(from: manifest, options: [], format: nil) as? [String: String] == contents.shown)

        let packageURL = receiver.appendingPathComponent("package.plist")
        try package.write(to: packageURL)
        let written = WalkthroughPicturePackage.materialize(packageAt: packageURL, root: receiver)
        #expect(Set(written) == [Self.v1, Self.v2, Self.x1, Self.x2, Self.x3])
        let folder = receiver.appendingPathComponent(GeneratedImageStore.directory)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(WalkthroughPicturePackageFormat.manifestName).path))
        #expect(try Data(contentsOf: folder.appendingPathComponent("\(Self.x3).png")) == Data(contentsOf: sender.appendingPathComponent(GeneratedImageStore.directory).appendingPathComponent("\(Self.x3).png")))
        // The receiver would send the same pictures showing the same way.
        #expect(WalkthroughPicturePackage.contents(for: named, root: receiver).shown == contents.shown)
        #expect(WalkthroughPicturePackage.materialize(packageAt: packageURL, root: receiver).isEmpty, "a second arrival adds nothing")
    }
}
