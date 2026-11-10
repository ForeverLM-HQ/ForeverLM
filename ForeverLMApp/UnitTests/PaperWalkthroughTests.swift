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

func seedArticle(
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
func seedChapter(
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

let paperText = """
Sleep pressure rises during waking. We measured ATP in dorsal fan-shaped body neurons and found that \
ATP concentrations were about 1.2 times higher after sleep deprivation than at rest. \
Expressing UCP4 reduced sleep, whereas light-driven proton pumping increased it. \
Figure 2 shows the mitochondrial electron surplus model.
"""

let figures = [
    PaperWalkthroughFigureReference(label: "Figure 1", pageNumber: 2, caption: "Figure 1 | Sleep in flies.", panelLabels: []),
    PaperWalkthroughFigureReference(label: "Figure 2", pageNumber: 4, caption: "Figure 2 | A mitochondrial electron surplus induces sleep.", panelLabels: ["a", "b"]),
]

func step(
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
            sourceSHA256: PaperWalkthrough.animationFingerprint(linkedURL: "foreverlm-site://anim-1/", artifactID: "anim-1"),
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

        let url = reference.pageURL(animationURL: URL(string: "foreverlm-site://anim-1/?step=1&other=k")!)
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

    @Test("A saved walkthrough reads back, replaces itself and deletes")
    func saveLoadDelete() async throws {
        let (storage, root) = makeTemporaryStorage("save")
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedArticle(storage, content: paperText)

        #expect(try await storage.loadPaperWalkthrough(article.id) == nil)
        #expect(try await storage.hasPaperWalkthrough(article.id) == false)

        let first = walkthrough(for: article, text: paperText)
        try await storage.savePaperWalkthrough(first)
        let loaded = try #require(try await storage.loadPaperWalkthrough(article.id))
        #expect(loaded.title == "Walk")
        #expect(loaded.steps.count == 1)
        #expect(try await storage.hasPaperWalkthrough(article.id))

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
}

