import Foundation
import Observation
import SQLite3
import Testing
@testable import ForeverLM

// MARK: - Fixtures

private func makeTemporaryStorage(_ name: String) -> StorageService {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WalkthroughChatTests_\(name)_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return StorageService(storeRoot: root)
}

private let marker = WalkthroughStepTurn.Marker(
    sourceID: "030EFA00-1058-42B1-81D4-20EEA62CCD9A",
    stepID: "step-3",
    index: 2,
    count: 11
)

private let figureStep = PaperWalkthroughStep(
    id: "step-3",
    kind: .figure,
    title: "ATP rises with sleep pressure",
    body: "Look at panel b first.\n\nThe bars are ATP after rest and after deprivation.",
    anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "b", pageNumber: 4),
    quiz: PaperWalkthroughQuiz(
        question: "Why does ATP rise?",
        answer: "Because fewer electrons are spent while awake.",
        keyPoints: ["electron surplus", "less consumption"]
    ),
    sourceMention: "ATP was about 1.2 times higher after deprivation than at rest (Fig. 2b)."
)

private func exchange(_ sequence: Int, question: String, answer: String? = nil, evaluation: String? = nil) -> ReviewExchangeRecord {
    ReviewExchangeRecord(
        id: "exchange-\(sequence)",
        sessionID: "session-1",
        sequenceNumber: sequence,
        question: question,
        userAnswer: answer,
        evaluation: evaluation,
        score: nil,
        sourceRefs: [marker.sourceID],
        knowledgeNote: nil,
        answeredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(sequence)),
        contextContent: nil
    )
}

/// Set from `withObservationTracking`'s Sendable onChange.
private final class WalkthroughReloadProbe: @unchecked Sendable {
    var named = false
    var written = false
}

// MARK: - The step line

@Suite("Walkthrough step line")
struct WalkthroughStepTurnTests {

    @Test("The line names the record, the step and its place, and reads back as written")
    func lineRoundTrips() {
        let line = WalkthroughStepTurn.line(marker)
        #expect(line == "<flm_walk_step source=\"030EFA00-1058-42B1-81D4-20EEA62CCD9A\" step=\"step-3\" index=\"2\" count=\"11\"/>")
        #expect(WalkthroughStepTurn.marker(in: line) == marker)
        #expect(WalkthroughStepTurn.split("\(line)\n\n### Title\n\nBody.") == [
            .step(marker),
            .text("### Title\n\nBody."),
        ])
        #expect(WalkthroughStepTurn.stripped("\(line)\n\n### Title\n\nBody.") == "### Title\n\nBody.")
    }

    @Test("A tag missing an attribute, out of range, or closed the long way is debris or tolerated; plain prose is untouched")
    func variants() {
        #expect(WalkthroughStepTurn.split("<flm_walk_step source=\"a\" step=\"s\"/>Q") == [.text("Q")])
        #expect(WalkthroughStepTurn.split("<flm_walk_step source=\"a\" step=\"s\" index=\"4\" count=\"4\"/>Q") == [.text("Q")])
        #expect(WalkthroughStepTurn.split("<flm_walk_step source='a' step='s' index='0' count='1'></flm_walk_step>Q") == [
            .step(WalkthroughStepTurn.Marker(sourceID: "a", stepID: "s", index: 0, count: 1)), .text("Q"),
        ])
        #expect(WalkthroughStepTurn.split("Plain reply.") == [.text("Plain reply.")])
        #expect(WalkthroughStepTurn.stripped("Plain reply.") == "Plain reply.")
        #expect(WalkthroughStepTurn.marker(in: "Plain reply.") == nil)
        #expect(WalkthroughStepTurn.split("   ").isEmpty)
    }

    @Test("A source turn line and a step line in one text are both understood")
    func coexistsWithSourceTurn() {
        let text = "\(WalkthroughStepTurn.line(marker))\n\(MemoryReviewSourceTurn.line(sourceID: "x"))\nProse."
        #expect(WalkthroughStepTurn.marker(in: text) == marker)
        #expect(MemoryReviewSourceTurn.stripped(WalkthroughStepTurn.stripped(text)) == "Prose.")
    }
}

// MARK: - Composing a step

@Suite("Walkthrough step turn")
@MainActor
struct WalkthroughStepComposerTests {

    @Test("A played step is its marker, its title as a heading, its paragraphs, the authors' sentence, the panel enlarged and the question last")
    func composedMarkdown() {
        let rect = PaperFigureRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
        let resolved = WalkthroughResolvedAnchor(
            target: .figure(pageIndex: 3, rect: rect, caption: "Figure 2 | ATP.", sharesPageWithOtherFigures: false),
            panelLabels: ["A", "B"],
            panel: "B"
        )
        let lens = WalkthroughStepComposer.lensReference(sourceID: marker.sourceID, resolved: resolved)
        #expect(lens?.location == .page(4))
        #expect(lens?.crop == rect)
        let markdown = WalkthroughStepComposer.markdown(step: figureStep, marker: marker, lens: lens)
        let blocks = markdown.components(separatedBy: "\n\n")
        #expect(blocks.first == WalkthroughStepTurn.line(marker))
        #expect(blocks[1] == "### ATP rises with sleep pressure")
        #expect(blocks[2] == "Look at panel b first.")
        #expect(blocks[3] == "The bars are ATP after rest and after deprivation.")
        #expect(blocks[4] == "> In the authors’ words: “ATP was about 1.2 times higher after deprivation than at rest (Fig. 2b).”")
        #expect(blocks[5].hasPrefix("![Figure 2B](foreverlm://image/030EFA00-1058-42B1-81D4-20EEA62CCD9A/page/4?crop="))
        // A step the text never cites repeats nothing.
        var uncited = figureStep
        uncited.sourceMention = nil
        #expect(WalkthroughStepComposer.markdown(step: uncited, marker: marker, lens: nil).contains("authors’ words") == false)
        #expect(blocks.last == "**Question:** Why does ATP rise?")
        // What the model and a client without the row read.
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: markdown)?.hasPrefix("### ATP rises") == true)
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: markdown)?.contains("flm_walk_step") == false)
    }

    @Test("A panel step shows no lens while a Reader beside the chat has the source on screen; it keeps the lens when none does")
    func lensSkippedWhileReaderShowsSource() {
        let rect = PaperFigureRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
        let resolved = WalkthroughResolvedAnchor(
            target: .figure(pageIndex: 3, rect: rect, caption: "Figure 2 | ATP.", sharesPageWithOtherFigures: false),
            panelLabels: ["A", "B"],
            panel: "B"
        )
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: resolved, readerBesideChatShowsSource: true) == nil)
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: resolved, readerBesideChatShowsSource: false)?.crop == rect)
        let markdown = WalkthroughStepComposer.markdown(
            step: figureStep,
            marker: marker,
            lens: WalkthroughStepComposer.lensReference(sourceID: marker.sourceID, resolved: resolved, readerBesideChatShowsSource: true)
        )
        #expect(markdown.contains("foreverlm://image/") == false)
        #expect(markdown.components(separatedBy: "\n\n").last == "**Question:** Why does ATP rise?")
    }

    @Test("A whole-figure, passage or page step shows no lens; a panel without a rectangle shows none either")
    func lensOnlyForPlacedPanels() {
        let whole = WalkthroughResolvedAnchor(
            target: .figure(pageIndex: 3, rect: PaperFigureRect(x: 0, y: 0, width: 1, height: 0.5), caption: "", sharesPageWithOtherFigures: false),
            panelLabels: ["A", "B"]
        )
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: whole) == nil)
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: WalkthroughResolvedAnchor(target: .passage("words", pageHint: nil))) == nil)
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: WalkthroughResolvedAnchor(target: .page(pageIndex: 1))) == nil)
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: nil) == nil)
        let unplaced = WalkthroughResolvedAnchor(
            target: .figure(pageIndex: 3, rect: nil, caption: "", sharesPageWithOtherFigures: false),
            panelLabels: [],
            panel: "B"
        )
        #expect(WalkthroughStepComposer.lensReference(sourceID: "s", resolved: unplaced) == nil)
    }

    @Test("The grading brief carries the question, the reference answer, the key points and how to grade")
    func gradingContext() {
        let context = WalkthroughStepComposer.gradingContext(step: figureStep, quiz: figureStep.quiz!, marker: marker)
        #expect(context.hasPrefix("[ForeverLM] The learner is answering the question of walkthrough step 3 of 11 (ATP rises with sleep pressure)."))
        #expect(context.contains("Question: Why does ATP rise?"))
        #expect(context.contains("Reference answer: Because fewer electrons are spent while awake."))
        #expect(context.contains("- electron surplus"))
        #expect(context.contains("- less consumption"))
        #expect(context.contains("meaning, not its wording"))
        // Since 2026-09-30 the grade teaches: why the answer is right, tied
        // back to what showed it, after one follow-up for an answer on the
        // right track; a prediction is answered at once.
        #expect(context.contains("why it is right, pointing back to the card or the panel that showed it"))
        #expect(context.contains(WalkthroughStepComposer.followUpRule))
        let predict = PaperWalkthroughQuiz(question: "Where do the bars land?", answer: "Higher after deprivation.", kind: .predict)
        let guessed = WalkthroughStepComposer.gradingContext(step: figureStep, quiz: predict, marker: marker)
        #expect(!guessed.contains("ask one short follow-up"))
        #expect(guessed.contains("A wrong guess is not a failure"))
    }
}

// MARK: - The transcript, live and resumed

@Suite("Walkthrough chat transcript")
@MainActor
struct WalkthroughChatTranscriptTests {

    @Test("A played step is one assistant row carrying its marker, live and again on resume")
    func liveAndResumedRowsAgree() {
        let markdown = WalkthroughStepComposer.markdown(step: figureStep, marker: marker, lens: nil)
        let live = ReviewSessionManager.playedWalkthroughRowsForTesting(markdown: markdown)
        #expect(live.count == 1)
        #expect(live.first?.step == marker)
        #expect(live.first?.content.hasPrefix("### ATP rises with sleep pressure") == true)
        #expect(live.first?.content.contains("flm_walk_step") == false)

        let resumed = ReviewSessionManager.reconstructedWalkthroughRowsForTesting(from: [
            exchange(1, question: markdown),
            exchange(2, question: WalkthroughStepComposer.markdown(
                step: PaperWalkthroughStep(id: "step-4", kind: .explain, title: "What it means", body: "The surplus is the signal."),
                marker: WalkthroughStepTurn.Marker(sourceID: marker.sourceID, stepID: "step-4", index: 3, count: 11),
                lens: nil
            ), answer: "Because electrons pile up", evaluation: "Right: the surplus is the point."),
        ])
        #expect(resumed.map(\.role) == ["assistant", "assistant", "user", "assistant"])
        #expect(resumed[0].step == marker)
        #expect(resumed[0].content == live[0].content)
        #expect(resumed[1].step?.stepID == "step-4")
        #expect(resumed[1].step?.index == 3)
        #expect(resumed[1].content == "### What it means\n\nThe surplus is the signal.")
        #expect(resumed[2].step == nil)
        #expect(resumed[3].step == nil)
        #expect(resumed[3].content == "Right: the surplus is the point.")
    }

    @Test("An ordinary reply carries no marker")
    func plainReplyHasNoMarker() {
        let rows = ReviewSessionManager.playedWalkthroughRowsForTesting(markdown: "Just a reply.")
        #expect(rows.count == 1)
        #expect(rows.first?.step == nil)
        #expect(rows.first?.content == "Just a reply.")
    }
}

// MARK: - Storage

@Suite("Walkthrough beats")
struct WalkthroughBeatTests {

    @Test("A step with no beats is its body a sentence a card, the question last, and never the authors' sentence")
    func beatsCutFromTheBody() {
        let beats = figureStep.playableBeats
        #expect(beats.map(\.kind) == [.point, .point, .question])
        #expect(beats.first?.text == "Look at panel b first.")
        #expect(beats[1].text == "The bars are ATP after rest and after deprivation.")
        #expect(beats.last?.text == "Why does ATP rise?")
        // The sentence of the paper stays in the record and the step's turn,
        // not on a card (product owner, 2026-09-23).
        #expect(!beats.contains { $0.text == figureStep.sourceMention })
        #expect(figureStep.takeaway == "The bars are ATP after rest and after deprivation.")
        #expect(figureStep.cardCount == 3)
    }

    @Test("A question step is one card: its question, with the writer's reminder as context; the deck counts cards across steps")
    func questionStepIsOneCard() {
        let quiz = PaperWalkthroughStep(
            id: "step-5",
            kind: .quiz,
            title: "Check",
            body: "Before the next figure, one question about the pump.",
            quiz: PaperWalkthroughQuiz(question: "What stops the pump?", answer: "Ouabain.", keyPoints: ["ouabain"])
        )
        let cards = quiz.playableBeats
        #expect(cards.count == 1)
        #expect(cards[0].kind == .question)
        #expect(cards[0].text == "What stops the pump?")
        #expect(cards[0].context == "Before the next figure, one question about the pump.")
        #expect(quiz.takeaway == "What stops the pump?")
        let wordless = PaperWalkthroughStep(id: "step-6", kind: .explain, title: "Silent", body: "")
        #expect(wordless.playableBeats.isEmpty)
        #expect(wordless.cardCount == 1)

        let walk = PaperWalkthrough(sourceID: "s", sourceSHA256: "sha", title: "W", steps: [figureStep, quiz, wordless], author: .app)
        #expect(walk.cardCount == 5)
        #expect(walk.cardOrdinal(stepIndex: 0, card: 1) == 1)
        #expect(walk.cardOrdinal(stepIndex: 0, card: 3) == 3)
        #expect(walk.cardOrdinal(stepIndex: 1, card: 1) == 4)
        #expect(walk.cardOrdinal(stepIndex: 2, card: 1) == 5)
        #expect(walk.figureStepCount == 1)
        #expect(walk.chapterCount == 1)
    }

    @Test("A chapter with a claim deals a recap card after its last step; the walk counts it, the step does not")
    func chapterRecapCard() throws {
        let quiz = PaperWalkthroughStep(
            id: "step-5", kind: .quiz, title: "Check", body: "",
            quiz: PaperWalkthroughQuiz(question: "What stops the pump?", answer: "Ouabain.", keyPoints: ["ouabain"], kind: .thinkFirst)
        )
        let chapters = [
            PaperWalkthroughChapter(id: "ch-1", title: "The energy hit", claim: "Raising sodium lowers ATP.", stepIDs: ["step-3", "step-5"]),
            PaperWalkthroughChapter(id: "ch-2", title: "Unclaimed", claim: "", stepIDs: ["step-6"]),
        ]
        let wordless = PaperWalkthroughStep(id: "step-6", kind: .explain, title: "Silent", body: "")
        let walk = PaperWalkthrough(sourceID: "s", sourceSHA256: "sha", title: "W", steps: [figureStep, quiz, wordless], chapters: chapters, author: .app)
        #expect(walk.chapterCount == 2)
        #expect(walk.chapterIndex(ofStep: "step-5") == 0)
        #expect(walk.closesChapter(figureStep) == nil)
        #expect(walk.closesChapter(quiz)?.id == "ch-1")
        // A chapter with no claim has nothing to say back.
        #expect(walk.closesChapter(wordless) == nil)
        let cards = walk.playableBeats(of: quiz)
        #expect(cards.map(\.kind) == [.question, .recap])
        #expect(cards[1].text == "Raising sodium lowers ATP.")
        #expect(cards[1].context == "The energy hit")
        #expect(quiz.cardCount == 1)
        #expect(walk.cardCount(of: quiz) == 2)
        #expect(walk.cardCount == 3 + 2 + 1)
        #expect(walk.cardOrdinal(stepIndex: 2, card: 1) == 6)
        // Chapters round-trip, and a chapter naming a step the record lacks loses it.
        var stray = walk
        stray.chapters?[1].stepIDs.append("step-99")
        let json = try PaperWalkthroughCoding.json(stray)
        let decoded = try PaperWalkthroughCoding.walkthrough(fromJSON: json)
        #expect(decoded.chapters?.map(\.stepIDs) == [["step-3", "step-5"], ["step-6"]])
        #expect(json.contains("\"chapters\""))
        // A record with no chapters encodes without the key, as before.
        let flat = PaperWalkthrough(sourceID: "s", sourceSHA256: "sha", title: "W", steps: [figureStep], author: .app)
        #expect(!(try PaperWalkthroughCoding.json(flat)).contains("chapters"))
    }

    @Test("A question's kind and a step's Say more chips ride the record; an older record reads as plain questions with no chips")
    func kindsAndChipsRoundTrip() throws {
        var step = PaperWalkthroughStep(
            id: "step-7", kind: .quiz, title: "Which panel", body: "",
            anchor: PaperWalkthroughAnchor(figureLabel: "Figure 4", pageNumber: 7),
            quiz: PaperWalkthroughQuiz(question: "Which panel shows the control?", answer: "Panel b.", keyPoints: ["b"], kind: .find, targetPanel: "b"),
            more: [PaperWalkthroughMore(label: "What is a control?", text: "A comparison that holds everything else fixed.", fromPaper: false)]
        )
        let data = try PaperWalkthroughCoding.encoder().encode(step)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"kind\":\"find\""))
        #expect(text.contains("\"target_panel\":\"b\""))
        #expect(text.contains("\"from_paper\":false"))
        let decoded = try PaperWalkthroughCoding.decoder().decode(PaperWalkthroughStep.self, from: data)
        #expect(decoded == step)
        #expect(decoded.quiz?.kind.label == "Find it")
        // The plain question encodes no kind, so an older record is byte for byte as it was.
        step.quiz = PaperWalkthroughQuiz(question: "Q?", answer: "A.")
        step.more = []
        let plain = try #require(String(data: try PaperWalkthroughCoding.encoder().encode(step), encoding: .utf8))
        #expect(!plain.contains("\"kind\":\"recall\""))
        #expect(!plain.contains("\"more\""))
        // A kind this build does not know reads as the plain question.
        let future = #"{"question": "Q?", "answer": "A.", "key_points": [], "kind": "juggle", "target_panel": "c"}"#
        let quiz = try PaperWalkthroughCoding.decoder().decode(PaperWalkthroughQuiz.self, from: Data(future.utf8))
        #expect(quiz.kind == .recall)
        #expect(quiz.targetPanel == nil)
    }

    @Test("A sentence naming one panel of the step's figure points the outline there; one naming another figure, or two panels, points nowhere of its own")
    func derivedBeatsFollowThePanels() {
        let tour = PaperWalkthroughStep(
            id: "step-4",
            kind: .figure,
            title: "Figure 1 in turn",
            body: "Panel a plots sodium over time. Panel b shows the pump current. Compare this with Figure 3c. Panels c and d repeat it in rat cells.",
            anchor: PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 3)
        )
        let anchors = tour.playableBeats.map(\.anchor)
        #expect(anchors[0] == PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 3))
        #expect(anchors[1] == PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "b", pageNumber: 3))
        #expect(anchors[2] == nil)
        #expect(anchors[3] == nil)
        // A step with no figure has no panels to follow.
        let setup = PaperWalkthroughStep(id: "s", kind: .explain, title: "Setup", body: "Panel a comes later.")
        #expect(setup.playableBeats.map(\.anchor) == [nil])
    }

    @Test("Written beats are strings or objects naming a panel; they round-trip, and fill an empty body")
    func writtenBeatsRoundTrip() throws {
        let json = #"{"kind": "figure", "title": "T", "figure_label": "Figure 2", "panel_label": "c", "beats": ["Look at panel c.", {"text": "Panel d is the control.", "panel_label": "d"}, {"text": "The schematic is Figure 1a.", "figure_label": "Figure 1", "panel_label": "a"}]}"#
        let draft = try JSONDecoder().decode(PaperWalkthroughDraft.Step.self, from: Data(json.utf8))
        #expect(draft.body.isEmpty)
        #expect(draft.beats == [
            PaperWalkthroughBeat(text: "Look at panel c."),
            PaperWalkthroughBeat(text: "Panel d is the control.", panelLabel: "d"),
            PaperWalkthroughBeat(text: "The schematic is Figure 1a.", figureLabel: "Figure 1", panelLabel: "a"),
        ])
        var step = PaperWalkthroughStep(
            id: "step-1", kind: .figure, title: "T", body: "",
            anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "c", pageNumber: 5),
            beats: draft.beats
        )
        let encoded = try PaperWalkthroughCoding.encoder().encode(step)
        let text = try #require(String(data: encoded, encoding: .utf8))
        // A beat that points nowhere of its own is written as a bare string.
        #expect(text.contains(#""Look at panel c.""#))
        #expect(!text.contains(#"{"text":"Look at panel c."#))
        #expect(try PaperWalkthroughCoding.decoder().decode(PaperWalkthroughStep.self, from: encoded) == step)
        let anchors = step.playableBeats.map(\.anchor)
        #expect(anchors[0] == nil)
        #expect(anchors[1] == PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "d", pageNumber: 5))
        #expect(anchors[2] == PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a"))
        #expect(step.takeaway == "The schematic is Figure 1a.")
        // A record written before beats has none, and decodes as it did.
        step.beats = nil
        let old = try PaperWalkthroughCoding.encoder().encode(step)
        #expect(!(String(data: old, encoding: .utf8) ?? "").contains("beats"))
    }

    @Test("save_walkthrough's beats: strings and objects both taken, nothing sent is nil")
    func toolBeats() {
        #expect(MCPDataStore.walkthroughBeats(nil) == nil)
        #expect(MCPDataStore.walkthroughBeats([] as [Any]) == nil)
        #expect(MCPDataStore.walkthroughBeats(["One.", ["text": "Two.", "panel_label": "b"], ["panel_label": "c"]] as [Any]) == [
            PaperWalkthroughBeat(text: "One."),
            PaperWalkthroughBeat(text: "Two.", panelLabel: "b"),
        ])
    }
}

@Suite("Walkthrough card thread")
@MainActor
struct WalkthroughTranscriptFoldTests {

    private let article = StudioArticle(url: "https://example.com/p", title: "P", sourceType: .article, discoveryOrigin: .manual)

    private func turn(_ stepID: String, _ index: Int) -> ReviewSessionManager.Message {
        ReviewSessionManager.Message(
            role: .assistant,
            content: "### \(stepID)",
            walkthroughStep: WalkthroughStepTurn.Marker(sourceID: article.id, stepID: stepID, index: index, count: 3)
        )
    }

    private func playback(current: Int) -> ReviewSessionManager.WalkthroughPlayback {
        ReviewSessionManager.WalkthroughPlayback(
            subject: .source(article),
            walkthrough: PaperWalkthrough(
                sourceID: article.id,
                sourceSHA256: "x",
                title: "W",
                steps: (1...3).map { PaperWalkthroughStep(id: "step-\($0)", kind: .explain, title: "S\($0)", body: "B.") },
                author: .app
            ),
            currentIndex: current,
            playedStepIDs: ["step-1", "step-2", "step-3"]
        )
    }

    @Test("Under the card, the chat holds that card's own conversation and nothing else; step turns are the card and never drawn")
    func showsTheCardsThread() {
        let before = ReviewSessionManager.Message(role: .user, content: "Before the walk")
        let q1 = ReviewSessionManager.Message(role: .user, content: "About step 1?")
        let a1 = ReviewSessionManager.Message(role: .assistant, content: "Answer 1")
        let q3 = ReviewSessionManager.Message(role: .user, content: "About step 3?")
        let q1Again = ReviewSessionManager.Message(role: .user, content: "Back on step 1")
        // A question asked after going back re-adds the card's turn first
        // (`bringWalkthroughCardIntoChat`), so it belongs to that card.
        let messages = [before, turn("step-1", 0), q1, a1, turn("step-2", 1), turn("step-3", 2), q3, turn("step-1", 0), q1Again]

        let onThree = WalkthroughTranscriptFold.cardThread(messages, playback: playback(current: 2))
        #expect(onThree.map(\.content) == ["About step 3?"])

        let onOne = WalkthroughTranscriptFold.cardThread(messages, playback: playback(current: 0))
        #expect(onOne.map(\.content) == ["About step 1?", "Answer 1", "Back on step 1"])

        let onTwo = WalkthroughTranscriptFold.cardThread(messages, playback: playback(current: 1))
        #expect(onTwo.isEmpty)

        // No walk playing: the conversation shows, and the step turns fold to
        // the one played last — the row that resumes the walk.
        let resting = WalkthroughTranscriptFold.cardThread(messages, playback: nil)
        #expect(resting.map(\.content) == ["Before the walk", "About step 1?", "Answer 1", "About step 3?", "### step-1", "Back on step 1"])
        #expect(resting.compactMap(\.walkthroughStep).map(\.stepID) == ["step-1"])

        // A chat with no walk in it is untouched.
        let plain = [before, q1, a1]
        #expect(WalkthroughTranscriptFold.cardThread(plain, playback: nil).map(\.id) == plain.map(\.id))
    }

    @Test("A self-graded question card's record carries its grade, question and answer")
    func recallRecordCarriesTheQuestion() {
        let quiz = PaperWalkthroughQuiz(question: "Why hold contraction constant?", answer: "So sodium, not work, explains the metabolic change.")
        let kept = WalkthroughStepComposer.recallRecord(quiz: quiz, remembered: true)
        #expect(kept.hasPrefix("**Remembered.**"))
        #expect(kept.contains("Question: Why hold contraction constant?"))
        #expect(kept.contains("Answer: So sodium, not work, explains the metabolic change."))
        #expect(WalkthroughStepComposer.recallRecord(quiz: quiz, remembered: false).hasPrefix("**Missed"))
    }
}

@Suite("Walkthrough chat storage")
struct WalkthroughChatStorageTests {

    @Test("A chat that has played a step is kept when the learner has typed nothing; an empty prompt-only chat is still dropped")
    func stepsKeepTheSession() async throws {
        let storage = makeTemporaryStorage("keep")
        var paper = StudioArticle(url: "https://example.com/sleep", title: "Sleep pressure", sourceType: .article, discoveryOrigin: .manual)
        paper.author = "A. Author"
        paper.content = "Sleep pressure rises during waking."
        paper.wordCount = 5
        paper.state = .ready
        try await storage.saveSource(paper)
        let played = WalkthroughStepTurn.Marker(sourceID: paper.id, stepID: "step-1", index: 0, count: 11)
        try await storage.createReviewSession(id: "walk", topic: "A walk", sourceIDs: [paper.id])
        try await storage.addReviewPrompt(
            sessionID: "walk",
            question: WalkthroughStepComposer.markdown(step: figureStep, marker: played, lens: nil),
            sourceRefs: [paper.id]
        )
        #expect(try await storage.deleteReviewSessionIfNoRecordedConversation("walk") == false)
        #expect(try await storage.loadReviewSessionExchanges(sessionID: "walk").count == 1)

        try await storage.createReviewSession(id: "blank", topic: "A blank chat", sourceIDs: [paper.id])
        try await storage.addReviewPrompt(sessionID: "blank", question: "What is this paper about?", sourceRefs: [paper.id])
        #expect(try await storage.deleteReviewSessionIfNoRecordedConversation("blank") == true)
    }
}


// MARK: - Playing a walk in a manager

@Suite("Walkthrough chat playback")
@MainActor
struct WalkthroughChatPlaybackTests {

    private let text = "Sleep pressure rises during waking. ATP concentrations were about 1.2 times higher after sleep deprivation than at rest. Expressing UCP4 reduced sleep."

    private func seed(_ storage: StorageService) async throws -> StudioArticle {
        var article = StudioArticle(url: "https://example.com/sleep-article", title: "Sleep pressure", sourceType: .article, discoveryOrigin: .manual)
        article.author = "A. Author"
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        try await storage.saveSource(article)
        try await storage.savePaperWalkthrough(PaperWalkthrough(
            sourceID: article.id,
            sourceSHA256: PaperContentPreparationService.sha256(text),
            title: "How sleep pressure builds",
            steps: [
                PaperWalkthroughStep(id: "step-1", kind: .explain, title: "The question", body: "Why do we sleep?\n\nThe authors ask what builds pressure.", anchor: PaperWalkthroughAnchor(passage: "Sleep pressure rises during waking")),
                PaperWalkthroughStep(id: "step-2", kind: .explain, title: "ATP after deprivation", body: "ATP is higher.", anchor: PaperWalkthroughAnchor(passage: "ATP concentrations were about 1.2 times higher")),
                PaperWalkthroughStep(id: "step-3", kind: .quiz, title: "Check", body: "", anchor: PaperWalkthroughAnchor(passage: "Expressing UCP4 reduced sleep"), quiz: PaperWalkthroughQuiz(question: "What did UCP4 do?", answer: "It reduced sleep.", keyPoints: ["reduced sleep"])),
            ],
            author: .app
        ))
        return article
    }

    @Test("Asking for the same step several times at once deals it once, and makes no chat")
    func concurrentPlaysOfOneStepDealOnce() async throws {
        let storage = makeTemporaryStorage("play-once")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        #expect(await manager.loadWalkthrough(for: article))

        async let a: Void = manager.playWalkthroughStep(at: 0)
        async let b: Void = manager.playWalkthroughStep(at: 0)
        async let c: Void = manager.showWalkthroughStep(at: 0)
        _ = await (a, b, c)

        #expect(manager.walkthroughPlayback?.playedStepIDs == ["step-1"])
        #expect(manager.chatMessages.isEmpty)
        #expect(manager.currentSessionID == nil)
        await manager.flushWalkthroughProgressSaves()
        let progress = try #require(try await storage.loadWalkthroughProgress(article.id))
        #expect(progress.playedStepIDs == ["step-1"])
        #expect(progress.currentStepID == "step-1")
    }

    @Test("Walk Through deals cards with no model call and no chat, keeps the place in the walk's own record, and a question brings the card into the walk's chat")
    func dealsCardsWithoutAChat() async throws {
        let storage = makeTemporaryStorage("play")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        var focuses: [WalkthroughReaderFocus] = []
        manager.walkthroughFocusHandler = { focuses.append($0) }

        #expect(await manager.loadWalkthrough(for: article))
        let playback = try #require(manager.walkthroughPlayback)
        #expect(playback.steps.count == 3)
        #expect(playback.playedStepIDs.isEmpty)

        #expect(manager.walkthroughStepScrollRequest == nil)
        await manager.playWalkthroughStep(at: 0)
        // The card is dealt: no turn, no session, nothing among the chats.
        #expect(manager.chatMessages.isEmpty)
        #expect(manager.currentSessionID == nil)
        #expect(try await storage.loadReviewSessionLinks().isEmpty)
        #expect(manager.walkthroughStepScrollRequest?.stepID == "step-1")
        let firstScroll = manager.walkthroughStepScrollRequest
        // A source shown as text: the passage is scrolled to and flashed.
        #expect(focuses == [.flash(passage: "Sleep pressure rises during waking", sourceID: article.id)])

        // Step one is two sentences, so two cards: it lands on the first, and
        // Next shows the second without a move of the page.
        #expect(manager.walkthroughPlayback?.revealedBeatCount(of: playback.steps[0]) == 1)
        #expect(manager.walkthroughPlayback?.currentStepHasBeatsLeft == true)
        let focusesBeforeBeat = focuses.count
        await manager.walkthroughNext()
        #expect(manager.walkthroughPlayback?.currentIndex == 0)
        #expect(manager.walkthroughPlayback?.revealedBeatCount(of: playback.steps[0]) == 2)
        #expect(focuses.count == focusesBeforeBeat)
        // Back takes the card back; Next shows it again.
        await manager.walkthroughBack()
        #expect(manager.walkthroughPlayback?.revealedBeatCount(of: playback.steps[0]) == 1)
        await manager.walkthroughNext()

        await manager.walkthroughNext()
        #expect(manager.walkthroughPlayback?.currentIndex == 1)
        #expect(focuses.last == .flash(passage: "ATP concentrations were about 1.2 times higher", sourceID: article.id))
        #expect(manager.walkthroughStepScrollRequest?.stepID == "step-2")
        #expect(manager.chatMessages.isEmpty)

        // Back and Next re-focus; each move is a fresh scroll request.
        await manager.walkthroughBack()
        #expect(manager.walkthroughPlayback?.currentIndex == 0)
        #expect(focuses.last == .flash(passage: "Sleep pressure rises during waking", sourceID: article.id))
        #expect(manager.walkthroughStepScrollRequest?.stepID == "step-1")
        #expect(manager.walkthroughStepScrollRequest != firstScroll)
        await manager.walkthroughNext()
        #expect(manager.walkthroughPlayback?.currentIndex == 1)
        // A chip points the page without moving the chat.
        let beforeRefocus = manager.walkthroughStepScrollRequest
        await manager.refocusWalkthroughStep(id: "step-1")
        #expect(manager.walkthroughStepScrollRequest == beforeRefocus)
        #expect(manager.walkthroughPlayback?.currentIndex == 0)
        await manager.walkthroughNext()

        // The walk's record has the place.
        await manager.flushWalkthroughProgressSaves()
        let saved = try #require(try await storage.loadWalkthroughProgress(article.id))
        #expect(saved.currentStepID == "step-2")
        #expect(saved.playedStepIDs == ["step-1", "step-2"])
        #expect(saved.revealedBeats["step-1"] == 2)
        #expect(saved.chatSessionID == nil)

        // The question step, then a message about it: the walk's chat is made
        // and the card goes into it first, and the answer carries the
        // grading brief, once.
        await manager.walkthroughNext()
        #expect(manager.chatMessages.isEmpty)
        await manager.bringWalkthroughCardIntoChat()
        let sessionID = try #require(manager.currentSessionID)
        #expect(manager.chatMessages.count == 1)
        let card = try #require(manager.chatMessages.last)
        #expect(card.walkthroughStep == WalkthroughStepTurn.Marker(sourceID: article.id, stepID: "step-3", index: 2, count: 3))
        #expect(card.content.hasSuffix("**Question:** What did UCP4 do?"))
        #expect(manager.linkedSourceIDs == [article.id])
        let brief = try #require(manager.takeWalkthroughAnswerContext())
        #expect(brief.contains("Reference answer: It reduced sleep."))
        #expect(manager.takeWalkthroughAnswerContext() == nil)
        // The same card asked about again adds nothing.
        await manager.bringWalkthroughCardIntoChat()
        #expect(manager.chatMessages.count == 1)
        #expect(try await storage.loadReviewSessionExchanges(sessionID: sessionID).count == 1)
        let session = try #require(try await storage.loadReviewSessionLinks().first { $0.id == sessionID })
        #expect(session.title == "How sleep pressure builds")

        await manager.flushWalkthroughProgressSaves()
        let asked = try #require(try await storage.loadWalkthroughProgress(article.id))
        #expect(asked.chatSessionID == sessionID)
        #expect(asked.outcomes["step-3"] == .answered)
    }

    @Test("A graded question card is kept in the walk's record and as a Memory attempt, and adds nothing to a chat")
    func gradedQuestionGoesToMemory() async throws {
        let storage = makeTemporaryStorage("grade")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        manager.walkthroughFocusHandler = { _ in }
        #expect(await manager.loadWalkthrough(for: article))
        await manager.playWalkthroughStep(at: 2)
        manager.revealWalkthroughAnswer()
        await manager.gradeWalkthroughRecall(remembered: false)

        #expect(manager.walkthroughPlayback?.recall["step-3"] == .forgot)
        #expect(manager.chatMessages.isEmpty)
        #expect(manager.currentSessionID == nil)
        let items = try await storage.loadMemoryItems()
        let item = try #require(items.first { MemoryCard(storedIn: $0)?.front == "What did UCP4 do?" })
        #expect(item.sources.first?.sourceID == article.id)
        #expect(MemoryCard(storedIn: item)?.origin == .walkthrough, "a Forgot is a kept card at once")
        let attempts = try await storage.loadMemoryAttempts(memoryItemID: item.id)
        #expect(attempts.count == 1)
        #expect(attempts.first?.scheduleRating == .again)
        #expect(attempts.first?.attemptType == .discovery)
        #expect(attempts.first?.sessionID == nil)

        await manager.flushWalkthroughProgressSaves()
        #expect(try await storage.loadWalkthroughProgress(article.id)?.outcomes["step-3"] == .forgot)

        // Graded again on another walk through: the same item, a review.
        let again = ReviewSessionManager(storage: storage)
        again.walkthroughFocusHandler = { _ in }
        #expect(await again.loadWalkthrough(for: article))
        #expect(again.walkthroughPlayback?.recall["step-3"] == .forgot)
    }

    @Test("The strip's × leaves the walk: the record and the outline go, the place is kept")
    func leavingTheWalk() async throws {
        let storage = makeTemporaryStorage("leave")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        var focuses: [WalkthroughReaderFocus] = []
        manager.walkthroughFocusHandler = { focuses.append($0) }

        #expect(await manager.loadWalkthrough(for: article))
        await manager.playWalkthroughStep(at: 0)

        manager.leaveWalkthroughPlayback()
        #expect(manager.walkthroughPlayback == nil)
        // The page stops being pointed at a step it is no longer walking.
        #expect(focuses.last == .clear)
        // Leaving a walk is not undoing it: the place stays in its record.
        await manager.flushWalkthroughProgressSaves()
        #expect(try await storage.loadWalkthroughProgress(article.id)?.currentStepID == "step-1")
        // Nothing to leave twice.
        manager.leaveWalkthroughPlayback()
        #expect(focuses.filter { $0 == .clear }.count == 1)
    }

    @Test("The only pane's × on a walking chat ends the walk on New chat, not on the walked source in the Reader")
    func paneCloseLeavesTheWalkForNewChat() async throws {
        // Setting a window's layout persists it; put the developer's back.
        let layoutKey = "studio.centerTabGroups.v1"
        let priorLayout = UserDefaults.standard.stringArray(forKey: layoutKey)
        defer {
            if let priorLayout {
                UserDefaults.standard.set(priorLayout, forKey: layoutKey)
            } else {
                UserDefaults.standard.removeObject(forKey: layoutKey)
            }
        }
        let storage = makeTemporaryStorage("pane-close")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        var focuses: [WalkthroughReaderFocus] = []
        manager.walkthroughFocusHandler = { focuses.append($0) }
        #expect(await manager.loadWalkthrough(for: article))
        await manager.playWalkthroughStep(at: 0)

        let vm = StudioViewModel(storageService: storage)
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.chat, .reader], activeTab: .chat)])
        window.walkthroughDeckManager = manager
        vm.reviewChatResetRequestID = nil

        vm.dismissCenterSurface(.chat, in: window)

        #expect(window.centerTabGroups.groups.first?.activeTab == .chat)
        #expect(manager.walkthroughPlayback == nil)
        #expect(focuses.last == .clear)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.reviewChatTargetWindowID == window.id)

        // With no walk playing, the × reveals the Space, as a lone pane's ×
        // does since 2026-10-01 (it was the Notebooks home until 2026-10-09).
        vm.dismissCenterSurface(.chat, in: window)
        #expect(window.centerTabGroups.groups.first?.activeTab == .artifacts)
    }

    @Test("The wait for a step is named while it happens and gone after it, so the pane is never silently blank")
    func namesTheWaitForAStep() async throws {
        let storage = makeTemporaryStorage("preparing")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        // The focus handler fires inside the step's own work, so it is the
        // probe for what the transcript's working line says at that moment.
        var detailWhileWorking: [String?] = []
        manager.walkthroughFocusHandler = { _ in detailWhileWorking.append(manager.walkthroughPreparationDetail) }

        #expect(manager.walkthroughPreparationDetail == nil)
        #expect(await manager.loadWalkthrough(for: article))
        #expect(manager.walkthroughPreparationDetail == nil)

        await manager.playWalkthroughStep(at: 0)
        #expect(detailWhileWorking == ["Getting step 1 ready"])
        #expect(manager.walkthroughPreparationDetail == nil)

        // Next goes through `showWalkthroughStep`, so the name is the inner
        // step's and the nesting leaves nothing behind. Step one's second
        // beat comes first, and is no wait at all.
        await manager.walkthroughNext()
        #expect(detailWhileWorking == ["Getting step 1 ready"])
        await manager.walkthroughNext()
        #expect(detailWhileWorking.last == "Getting step 2 ready")
        #expect(manager.walkthroughPreparationDetail == nil)
    }

    @Test("Reading the playing walk again names no wait and, with nothing changed, writes nothing the card draws from")
    func reloadingThePlayingWalkIsQuiet() async throws {
        let storage = makeTemporaryStorage("quiet-reload")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        #expect(await manager.loadWalkthrough(for: article))
        await manager.playWalkthroughStep(at: 0)
        let before = manager.walkthroughPlayback

        // Any synced change to a source reloads the walk. A named wait there
        // took the card off the stage for the compact card and put it back,
        // so the card flickered while the learner read it (2026-09-29).
        let probe = WalkthroughReloadProbe()
        withObservationTracking { _ = manager.walkthroughPreparationDetail } onChange: { probe.named = true }
        withObservationTracking { _ = manager.walkthroughPlayback } onChange: { probe.written = true }
        await manager.reloadWalkthrough()

        #expect(!probe.named)
        #expect(!probe.written)
        #expect(manager.walkthroughPlayback == before)
    }

    @Test("A walk opened again resumes from its own record; its chat, reopened, holds only the cards asked about")
    func resumesTheWalk() async throws {
        let storage = makeTemporaryStorage("resume")
        let article = try await seed(storage)
        let first = ReviewSessionManager(storage: storage)
        first.walkthroughFocusHandler = { _ in }
        #expect(await first.loadWalkthrough(for: article))
        await first.playWalkthroughStep(at: 0)
        await first.walkthroughNext() // step one's second beat
        await first.walkthroughNext()
        await first.bringWalkthroughCardIntoChat()
        let sessionID = try #require(first.currentSessionID)
        await first.flushWalkthroughProgressSaves()

        // No chat needed to pick the walk back up.
        let fresh = ReviewSessionManager(storage: storage)
        #expect(await fresh.loadWalkthrough(for: article))
        let resumed = try #require(fresh.walkthroughPlayback)
        #expect(resumed.currentIndex == 1)
        #expect(resumed.playedStepIDs == ["step-1", "step-2"])
        #expect(resumed.chatSessionID == sessionID)
        #expect(fresh.chatMessages.isEmpty)

        // The walk's chat reopened: one card turn, the one asked about.
        let exchanges = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
        let second = ReviewSessionManager(storage: storage)
        let playback = try #require(await second.restoreWalkthroughForTesting(exchanges: exchanges, article: article))
        #expect(second.chatMessages.compactMap(\.walkthroughStep).map(\.stepID) == ["step-2"])
        #expect(playback.currentIndex == 1)
        #expect(playback.playedStepIDs == ["step-1", "step-2"])
    }

    @Test("A chat that played a walk before the walk had its own record is taken up from its step turns, and the record is written from them")
    func seedsProgressFromAnOlderChat() async throws {
        let storage = makeTemporaryStorage("seed")
        let article = try await seed(storage)
        let walk = try #require(try await storage.loadPaperWalkthrough(article.id))
        try await storage.createReviewSession(id: "old-walk", topic: "How sleep pressure builds", sourceIDs: [article.id])
        for (index, step) in walk.steps.prefix(2).enumerated() {
            let marker = WalkthroughStepTurn.Marker(sourceID: article.id, stepID: step.id, index: index, count: walk.steps.count)
            try await storage.addReviewPrompt(
                sessionID: "old-walk",
                question: WalkthroughStepComposer.markdown(step: step, marker: marker, lens: nil),
                sourceRefs: [article.id]
            )
        }
        #expect(try await storage.loadWalkthroughProgress(article.id) == nil)

        let manager = ReviewSessionManager(storage: storage)
        manager.walkthroughFocusHandler = { _ in }
        let playback = try #require(await manager.restoreWalkthroughForTesting(
            exchanges: try await storage.loadReviewSessionExchanges(sessionID: "old-walk"),
            article: article
        ))
        #expect(playback.currentIndex == 1)
        #expect(playback.playedStepIDs == ["step-1", "step-2"])
        await manager.flushWalkthroughProgressSaves()
        let seeded = try #require(try await storage.loadWalkthroughProgress(article.id))
        #expect(seeded.currentStepID == "step-2")
        #expect(seeded.playedStepIDs == ["step-1", "step-2"])
    }

    @Test("A new chat about another source drops a walk that has no chat of its own; one about the walk's source keeps it")
    func newChatReleasesAWalkAboutAnotherSource() async throws {
        let storage = makeTemporaryStorage("release-on-new-chat")
        let article = try await seed(storage)
        let other = StudioArticle(url: "https://example.com/other", title: "Ten things about mitochondria", sourceType: .article, discoveryOrigin: .manual)
        let manager = ReviewSessionManager(storage: storage)
        var focuses: [WalkthroughReaderFocus] = []
        manager.walkthroughFocusHandler = { focuses.append($0) }

        #expect(await manager.loadWalkthrough(for: article))
        manager.releaseWalkthroughPlaybackForNewChat(about: [article])
        #expect(manager.walkthroughPlayback?.sourceID == article.id)

        manager.releaseWalkthroughPlaybackForNewChat(about: [other])
        #expect(manager.walkthroughPlayback == nil)
        #expect(focuses == [.clear])

        // A walk whose cards were asked about in this chat is the chat's own.
        #expect(await manager.loadWalkthrough(for: article))
        await manager.playWalkthroughStep(at: 0)
        await manager.bringWalkthroughCardIntoChat()
        manager.releaseWalkthroughPlaybackForNewChat(about: [other])
        #expect(manager.walkthroughPlayback?.sourceID == article.id)
    }

    @Test("A walk opens over an empty chat or its own, never over a conversation it is no part of or a chat still reopening")
    func walkOpensOnlyOverItsOwnChat() async throws {
        let storage = makeTemporaryStorage("own-chat")
        let article = try await seed(storage)

        // 2026-09-30: a search typed in an unrelated chat was drawn whole
        // under the walk's card, none of its turns being a card.
        let busy = ReviewSessionManager(storage: storage)
        busy.showUserMessage("Can you search the term Markov blanket across all my sources?")
        #expect(!busy.chatTakesWalkthrough(of: article.id))
        #expect(await busy.loadWalkthrough(for: article) == false)
        #expect(busy.walkthroughPlayback == nil)

        let reopening = ReviewSessionManager(storage: storage)
        reopening.walkthroughFocusHandler = { _ in }
        reopening.isResumingSession = true
        #expect(await reopening.loadWalkthrough(for: article) == false)
        reopening.isResumingSession = false
        #expect(await reopening.loadWalkthrough(for: article))

        // The walk's chat, reopened before its cards are back in the
        // transcript, is still the walk's by the walk's record.
        await reopening.playWalkthroughStep(at: 0)
        await reopening.bringWalkthroughCardIntoChat()
        let walkChatID = try #require(reopening.currentSessionID)
        await reopening.flushWalkthroughProgressSaves()
        let own = ReviewSessionManager(storage: storage)
        own.configureNavigationStateForTesting(sessionID: walkChatID, generationInFlight: false)
        #expect(own.hasConversation)
        #expect(await own.loadWalkthrough(for: article))
        #expect(own.walkthroughPlayback?.chatSessionID == walkChatID)
    }

    @Test("A chat reopened over a walk lets the walk go unless the chat is the walk's own")
    func reopenedChatReleasesAWalkThatIsNotItsOwn() async throws {
        let storage = makeTemporaryStorage("release-on-reopen")
        let article = try await seed(storage)
        let manager = ReviewSessionManager(storage: storage)
        var focuses: [WalkthroughReaderFocus] = []
        manager.walkthroughFocusHandler = { focuses.append($0) }
        #expect(await manager.loadWalkthrough(for: article))
        await manager.playWalkthroughStep(at: 0)

        // An unrelated chat picked from the pane's previous-chats list lands
        // on the manager dealing the walk's cards.
        manager.chatMessages = [
            .init(role: .user, content: "Can you search the term Markov blanket across all my sources?"),
            .init(role: .assistant, content: "Found 13 sources mentioning it."),
        ]
        manager.releaseWalkthroughPlaybackForReopenedChat("chat-markov")
        #expect(manager.walkthroughPlayback == nil)
        #expect(focuses.last == .clear)
        // Its place stays in its record.
        await manager.flushWalkthroughProgressSaves()
        #expect(try await storage.loadWalkthroughProgress(article.id)?.currentStepID == "step-1")

        // A chat holding the walk's cards is the walk's own.
        manager.chatMessages = []
        #expect(await manager.loadWalkthrough(for: article))
        let card = WalkthroughStepTurn.Marker(sourceID: article.id, stepID: "step-1", index: 0, count: 3)
        manager.chatMessages = [.init(role: .assistant, content: "Why do we sleep?", walkthroughStep: card)]
        manager.releaseWalkthroughPlaybackForReopenedChat("old-walk")
        #expect(manager.walkthroughPlayback?.sourceID == article.id)

        // So is the chat its questions go to, before its cards are back.
        manager.walkthroughPlayback?.chatSessionID = "walk-chat"
        manager.chatMessages = []
        manager.releaseWalkthroughPlaybackForReopenedChat("walk-chat")
        #expect(manager.walkthroughPlayback?.sourceID == article.id)
        await manager.flushWalkthroughProgressSaves()
    }
}

@Suite("Animation walkthrough chat playback")
@MainActor
struct AnimationWalkthroughChatPlaybackTests {

    @Test("Walk Through on an animation deals its cards with no model call and no chat, and points the animation's pane at each step")
    func playsAnAnimationWalk() async throws {
        let storage = makeTemporaryStorage("anim-play")
        let animation = try await storage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://pmf-two-components/")!, title: "One force, two components",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        try await storage.saveArtifactWalkthrough(PaperWalkthrough(
            sourceID: animation.id,
            sourceSHA256: PaperWalkthrough.animationFingerprint(linkedURL: animation.linkedURL, artifactID: animation.id),
            subject: .animation,
            title: "Two forces",
            steps: [
                PaperWalkthroughStep(id: "step-1", kind: .explain, title: "One pump", body: "Two consequences.", animation: WalkthroughAnimationReference(animationID: animation.id, step: 1)),
                PaperWalkthroughStep(id: "step-2", kind: .explain, title: "Nigericin", body: "Trades the pH term.", animation: WalkthroughAnimationReference(animationID: animation.id, step: 5, conditions: ["iono": "nig"])),
                PaperWalkthroughStep(id: "step-3", kind: .quiz, title: "Check", body: "", quiz: PaperWalkthroughQuiz(question: "Where did the force go?", answer: "Into ΔpH.", keyPoints: ["ΔpH"])),
            ],
            author: .assistant
        ))
        let manager = ReviewSessionManager(storage: storage)
        var focuses: [WalkthroughReaderFocus] = []
        manager.walkthroughFocusHandler = { focuses.append($0) }

        #expect(await manager.loadWalkthrough(forAnimation: animation))
        let playback = try #require(manager.walkthroughPlayback)
        #expect(playback.isAnimationWalk)
        #expect(playback.article == nil)
        #expect(playback.sourceID == animation.id)
        #expect(playback.animationPageURL(for: playback.steps[1])?.absoluteString.contains("step=5") == true)

        await manager.playWalkthroughStep(at: 0)
        #expect(manager.chatMessages.isEmpty)
        #expect(manager.currentSessionID == nil)
        #expect(focuses == [.animation(artifactID: animation.id, step: 1, conditions: [:])])

        await manager.walkthroughNext()
        #expect(focuses.last == .animation(artifactID: animation.id, step: 5, conditions: ["iono": "nig"]))
        await manager.walkthroughBack()
        #expect(focuses.last == .animation(artifactID: animation.id, step: 1, conditions: [:]))

        // The question step shows no animation and clears the pane's pin.
        await manager.walkthroughNext()
        await manager.walkthroughNext()
        #expect(focuses.last == .clear)

        // A question about it makes the walk's chat, titled by the walk; an
        // animation about no source attaches none.
        await manager.bringWalkthroughCardIntoChat()
        let sessionID = try #require(manager.currentSessionID)
        #expect(manager.chatMessages.count == 1)
        #expect(manager.chatMessages.first?.walkthroughStep == WalkthroughStepTurn.Marker(sourceID: animation.id, stepID: "step-3", index: 2, count: 3))
        #expect(manager.linkedSourceIDs.isEmpty)
        #expect(manager.topic == "Two forces")
        #expect(try await storage.loadReviewSessionExchanges(sessionID: sessionID).count == 1)
        await manager.flushWalkthroughProgressSaves()

        // A reopened chat finds the animation again from its step lines, on
        // the step its record kept.
        let reopened = ReviewSessionManager(storage: storage)
        try await reopened.restoreWalkthroughForTesting(
            exchanges: try await storage.loadReviewSessionExchanges(sessionID: sessionID),
            article: nil
        )
        #expect(reopened.walkthroughPlayback?.isAnimationWalk == true)
        #expect(reopened.walkthroughPlayback?.currentIndex == 2)
    }
}

@Suite("Walkthrough progress storage")
struct WalkthroughProgressStorageTests {

    private func seedWalk(_ store: KnowledgeStore, id: String) throws {
        let text = "Sleep pressure rises during waking. Expressing UCP4 reduced sleep."
        var article = StudioArticle(url: "https://example.com/\(id)", title: "Sleep pressure", sourceType: .article, discoveryOrigin: .manual, id: id)
        article.normalizedURL = URLNormalizer.normalize(article.url)
        article.content = text
        article.wordCount = 10
        article.state = .ready
        try store.saveSource(article)
        try store.savePaperWalkthrough(PaperWalkthrough(
            sourceID: id,
            sourceSHA256: PaperContentPreparationService.sha256(text),
            title: "How sleep pressure builds",
            steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "The question", body: "Why do we sleep?")],
            author: .app
        ))
    }

    private func syncChanges(_ store: KnowledgeStore) throws -> [(entity: String, key: String, operation: String)] {
        var rows: [(String, String, String)] = []
        try store.query("SELECT entity_type, logical_key, operation FROM sync_changes WHERE entity_type = 'walkthroughProgress'") { stmt in
            rows.append((store.string(stmt, 0) ?? "", store.string(stmt, 1) ?? "", store.string(stmt, 2) ?? ""))
        }
        return rows
    }

    @Test("A walk's progress saves, reads back, is queued for sync, and an unknown outcome reads as none")
    func savesAndQueues() throws {
        let store = try KnowledgeStore(inMemory: true)
        try seedWalk(store, id: "walked")
        let progress = WalkthroughProgress(
            subjectID: "walked",
            currentStepID: "step-1",
            revealedBeats: ["step-1": 1],
            playedStepIDs: ["step-1"],
            outcomes: ["step-9": .forgot],
            chatSessionID: "chat-1",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try store.saveWalkthroughProgress(progress)
        #expect(try store.loadWalkthroughProgress("walked") == progress)
        #expect(try syncChanges(store).map(\.key) == ["walked"])

        let json = #"{"subject_id":"w","outcomes":{"step-1":"remembered","step-2":"a-later-kind"}}"#
        let decoded = try JSONDecoder().decode(WalkthroughProgress.self, from: Data(json.utf8))
        #expect(decoded.outcomes == ["step-1": .remembered])
        #expect(decoded.playedStepIDs.isEmpty)
    }

    @Test("An inbound record wins only when newer, and applies without echoing back")
    func inboundNewerWins() throws {
        let store = try KnowledgeStore(inMemory: true)
        try seedWalk(store, id: "walked")
        let local = WalkthroughProgress(subjectID: "walked", currentStepID: "step-1", playedStepIDs: ["step-1"], updatedAt: Date(timeIntervalSinceReferenceDate: 2_000))
        try store.saveWalkthroughProgress(local)
        let payload = try #require(try store.loadWalkthroughProgressForSync("walked"))
        let roundTripped = try JSONDecoder().decode(CloudKitWalkthroughProgressPayload.self, from: JSONEncoder().encode(payload))
        #expect(roundTripped.progress == local)

        let older = WalkthroughProgress(subjectID: "walked", currentStepID: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.withoutSyncTracking { try store.saveWalkthroughProgressRecord(CloudKitWalkthroughProgressPayload(progress: older)) }
        #expect(try store.loadWalkthroughProgress("walked") == local)

        let newer = WalkthroughProgress(subjectID: "walked", currentStepID: "step-1", revealedBeats: ["step-1": 1], playedStepIDs: ["step-1"], updatedAt: Date(timeIntervalSinceReferenceDate: 3_000))
        try store.withoutSyncTracking { try store.saveWalkthroughProgressRecord(CloudKitWalkthroughProgressPayload(progress: newer)) }
        #expect(try store.loadWalkthroughProgress("walked") == newer)
        #expect(try store.hasLocalSyncRecord(entity: .walkthroughProgress, logicalKey: "walked"))

        try store.deleteWalkthroughProgressRecord("walked")
        #expect(try store.loadWalkthroughProgress("walked") == nil)
    }

    @Test("Removing a walk removes its progress, and tells the other Macs")
    func deletedWithTheWalk() throws {
        let store = try KnowledgeStore(inMemory: true)
        try seedWalk(store, id: "walked")
        try store.saveWalkthroughProgress(WalkthroughProgress(subjectID: "walked", currentStepID: "step-1", playedStepIDs: ["step-1"]))
        #expect(try store.deletePaperWalkthrough("walked"))
        #expect(try store.loadWalkthroughProgress("walked") == nil)
        #expect(try syncChanges(store).last?.operation == "delete")
    }

    @Test("A question remembered first time leaves nothing in Memory; one forgotten becomes a target, and a later grade is an attempt on it")
    func questionsBecomeTargetsOnlyWhenMissed() throws {
        let store = try KnowledgeStore(inMemory: true)
        try seedWalk(store, id: "walked")
        let step = PaperWalkthroughStep(id: "step-2", kind: .quiz, title: "Check", body: "", anchor: PaperWalkthroughAnchor(passage: "Expressing UCP4 reduced sleep"))
        let question = SourceMemoryQuestion(
            sourceID: "walked",
            step: step,
            quiz: PaperWalkthroughQuiz(question: "What did UCP4 do?", answer: "It reduced sleep.", keyPoints: ["reduced sleep"])
        )
        try store.recordSourceQuestionAttempt(question, answer: "I had it.", feedback: "Remembered.", score: 1, rating: .good)
        #expect(try store.loadMemoryItems().isEmpty)

        try store.recordSourceQuestionAttempt(question, answer: "I didn't have it.", feedback: "Missed.", score: 0, rating: .again)
        let item = try #require(try store.loadMemoryItems().first)
        #expect(item.sources.first?.excerpt == "Expressing UCP4 reduced sleep")
        #expect(item.rubricJSON.contains("reduced sleep"))
        try store.recordSourceQuestionAttempt(question, answer: "I had it.", feedback: "Remembered.", score: 1, rating: .good)
        #expect(try store.loadMemoryItems().map(\.id) == [item.id])
        let attempts = try store.loadMemoryAttempts(memoryItemID: item.id)
        #expect(attempts.map(\.attemptType).sorted { $0.rawValue < $1.rawValue } == [.discovery, .review])

        // A question whose card quotes nothing the source prints has no anchor.
        let ungrounded = SourceMemoryQuestion(
            sourceID: "walked",
            step: PaperWalkthroughStep(id: "step-3", kind: .quiz, title: "Check", body: "", anchor: PaperWalkthroughAnchor(passage: "Words the paper never printed")),
            quiz: PaperWalkthroughQuiz(question: "Why?", answer: "Because.")
        )
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordSourceQuestionAttempt(ungrounded, answer: "I didn't have it.", feedback: "Missed.", score: 0, rating: .again)
        }
    }

    @Test("A question with no passage of its own is grounded in the step it follows in its chapter, never in another chapter's")
    func unanchoredQuestionGroundsInTheStepItTests() throws {
        // 2026-09-30: none of the 20 questions of the "Metabolism as
        // inference" walk carried a passage, so a Forgot on any of them
        // threw and the miss never reached spaced review.
        let store = try KnowledgeStore(inMemory: true)
        try seedWalk(store, id: "walked")
        let steps = [
            PaperWalkthroughStep(id: "step-1", kind: .explain, title: "Pressure", body: "", anchor: PaperWalkthroughAnchor(passage: "Sleep pressure rises during waking")),
            PaperWalkthroughStep(id: "step-2", kind: .explain, title: "UCP4", body: "", anchor: PaperWalkthroughAnchor(passage: "Expressing UCP4 reduced sleep")),
            PaperWalkthroughStep(id: "step-3", kind: .explain, title: "Setup", body: "No anchor."),
            PaperWalkthroughStep(id: "step-4", kind: .quiz, title: "Check", body: "", quiz: PaperWalkthroughQuiz(question: "What did UCP4 do?", answer: "It reduced sleep.")),
            PaperWalkthroughStep(id: "step-5", kind: .quiz, title: "Check", body: "", quiz: PaperWalkthroughQuiz(question: "What opens chapter two?", answer: "Nothing yet.")),
        ]
        let walk = PaperWalkthrough(
            sourceID: "walked", sourceSHA256: "h", title: "T", steps: steps,
            chapters: [
                PaperWalkthroughChapter(id: "ch-1", title: "Pressure", claim: "Pressure builds.", stepIDs: ["step-1"]),
                PaperWalkthroughChapter(id: "ch-2", title: "UCP4", claim: "UCP4 reduces sleep.", stepIDs: ["step-2", "step-3", "step-4"]),
                PaperWalkthroughChapter(id: "ch-3", title: "More", claim: "More.", stepIDs: ["step-5"]),
            ],
            author: .app
        )
        // Nearest first, and only within the chapter.
        #expect(walk.stepsBefore(question: "step-4").map(\.id) == ["step-3", "step-2"])
        #expect(walk.stepsBefore(question: "step-5").isEmpty)

        let question = SourceMemoryQuestion(sourceID: "walked", step: steps[3], quiz: steps[3].quiz!, testing: walk.stepsBefore(question: "step-4"))
        #expect(question.excerpts == ["Expressing UCP4 reduced sleep"])
        try store.recordSourceQuestionAttempt(question, answer: "I didn't have it.", feedback: "Missed.", score: 0, rating: .again)
        let item = try #require(try store.loadMemoryItems().first)
        #expect(item.sources.first?.excerpt == "Expressing UCP4 reduced sleep")

        // A chapter whose steps before the question quote nothing still has no anchor.
        let alone = SourceMemoryQuestion(sourceID: "walked", step: steps[4], quiz: steps[4].quiz!, testing: walk.stepsBefore(question: "step-5"))
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordSourceQuestionAttempt(alone, answer: "I didn't have it.", feedback: "Missed.", score: 0, rating: .again)
        }
    }

}

// MARK: - A chat pointing the Reader

/// "Explain the key points and walk through the figures" of a paper a search
/// had just found: the chat opens the source beside itself and points at
/// what its reply is about, attached or not.
@Suite("Chat points the Reader")
@MainActor
struct ChatReaderFocusTests {
    private enum Event: Equatable {
        case opened(String)
        case focused(WalkthroughReaderFocus)
    }

    private let text = "Identity is written in development. Development writes deep valleys of cell identity that adult maintenance slowly erodes with age. Ageing flattens the valleys."

    private func seedArticle(_ storage: StorageService) async throws -> StudioArticle {
        var article = StudioArticle(url: "https://example.org/grammar-of-identity", title: "Grammar of identity", sourceType: .article, discoveryOrigin: .manual)
        article.author = "Zara Holt"
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        try await storage.saveSource(article)
        return article
    }

    @Test("focus_source_anchor rides every chat a pane shows, a source attached or not, and no manager without a pane")
    func offeredWhereverAReaderCanBePointed() {
        let detached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false, pointsReader: true
        )
        let focus = detached.first { $0.name == "focus_source_anchor" }
        #expect(focus != nil)
        #expect(focus?.description.contains("need not be attached") == true)
        #expect(focus?.description.contains("one place per reply") == true)
        let sourceProperty = (focus?.inputSchema["properties"] as? [String: Any])?["source_id"] as? [String: Any]
        #expect((sourceProperty?["description"] as? String)?.contains("search result") == true)

        // No pane lent a way to point the Reader: nothing to offer, whatever
        // is attached.
        for attached in [false, true] {
            let paneless = ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: attached, appTools: [], hasSynthesisContext: false
            )
            #expect(!paneless.contains { $0.name == "focus_source_anchor" })
        }
    }

    @Test("A passage of an article no Reader shows opens the article beside the chat first, then flashes there")
    func passageOpensTheSourceFirst() async throws {
        let storage = makeTemporaryStorage("focus-opens")
        let article = try await seedArticle(storage)
        let manager = ReviewSessionManager(storage: storage)
        var events: [Event] = []
        manager.walkthroughFocusHandler = { events.append(.focused($0)) }
        manager.walkthroughReaderShowsSource = { _ in false }
        manager.readerBesideChatOpener = { sourceID in
            events.append(.opened(sourceID))
            return true
        }

        let passage = "Development writes deep valleys of cell identity that adult maintenance slowly erodes"
        let result = await manager.focusSourceAnchorForTesting(arguments: ["source_id": article.id, "passage": passage])

        #expect(!result.isError)
        #expect(result.text.contains("flashed"))
        #expect(events == [.opened(article.id), .focused(.flash(passage: passage, sourceID: article.id))])
    }

    @Test("An article already beside the chat is pointed at in place; a passage it does not print opens nothing")
    func shownSourceIsNotOpenedAgain() async throws {
        let storage = makeTemporaryStorage("focus-shown")
        let article = try await seedArticle(storage)
        #expect(try #require(await storage.loadSourceContent(article.id)).contains("deep valleys"))
        let manager = ReviewSessionManager(storage: storage)
        var events: [Event] = []
        manager.walkthroughFocusHandler = { events.append(.focused($0)) }
        manager.walkthroughReaderShowsSource = { $0 == article.id }
        manager.readerBesideChatOpener = { sourceID in
            events.append(.opened(sourceID))
            return true
        }

        let passage = "Ageing flattens the valleys"
        let shown = await manager.focusSourceAnchorForTesting(arguments: ["source_id": article.id, "passage": passage])
        #expect(!shown.isError)
        #expect(events == [.focused(.flash(passage: passage, sourceID: article.id))])

        events = []
        let invented = await manager.focusSourceAnchorForTesting(arguments: [
            "source_id": article.id,
            "passage": "Ageing is a programme the genome runs on purpose",
        ])
        #expect(invented.isError)
        #expect(events.isEmpty)
    }

    @Test("A video is pointed at by a moment — at, or a passage of its timed transcript — and refuses words it never says or a page")
    func videoIsPointedAtByAMoment() async throws {
        let storage = makeTemporaryStorage("focus-video")
        let transcript = """
        [0:00] Welcome, everyone. Today we follow energy through the cell.

        [16:00] Health is not a point but a continuum, and healing moves you along it toward more energy flow.

        [16:40] So let us look at what that means for the mitochondria.
        """
        var video = StudioArticle(url: "https://www.youtube.com/watch?v=abc123xyz00", title: "A journey through energy", sourceType: .video, discoveryOrigin: .manual)
        video.content = transcript
        video.wordCount = transcript.split(separator: " ").count
        video.state = .ready
        try await storage.saveSource(video)
        let manager = ReviewSessionManager(storage: storage)
        var events: [Event] = []
        manager.walkthroughFocusHandler = { events.append(.focused($0)) }
        manager.walkthroughReaderShowsSource = { _ in false }
        manager.readerBesideChatOpener = { sourceID in
            events.append(.opened(sourceID))
            return true
        }

        let at = await manager.focusSourceAnchorForTesting(arguments: ["source_id": video.id, "at": "16:13"])
        #expect(!at.isError, "\(at.text)")
        #expect(at.text.contains("16:13"))
        #expect(events == [.opened(video.id), .focused(.moment(seconds: 973, sourceID: video.id))])

        events = []
        let said = await manager.focusSourceAnchorForTesting(arguments: [
            "source_id": video.id,
            "passage": "Health is not a point but a continuum",
        ])
        #expect(!said.isError, "\(said.text)")
        #expect(events == [.focused(.moment(seconds: 960, sourceID: video.id))], "the opened Reader is not opened again")

        events = []
        let invented = await manager.focusSourceAnchorForTesting(arguments: [
            "source_id": video.id,
            "passage": "Ageing is a programme the genome runs on purpose",
        ])
        #expect(invented.isError)
        let page = await manager.focusSourceAnchorForTesting(arguments: ["source_id": video.id, "page_number": 2])
        #expect(page.isError)
        let nothing = await manager.focusSourceAnchorForTesting(arguments: ["source_id": video.id])
        #expect(nothing.isError)
        #expect(events.isEmpty)
    }

    @Test("A meeting's notes are pointed at by a passage, and refuse a figure or a page they do not have")
    func meetingNotesTakeAPassageOnly() async throws {
        let storage = makeTemporaryStorage("focus-meeting")
        var meeting = StudioArticle(url: "https://notes.example.org/d/standup", title: "Standup on mitochondria", sourceType: .meeting, discoveryOrigin: .manual)
        meeting.content = text
        meeting.wordCount = text.split(separator: " ").count
        meeting.state = .ready
        try await storage.saveSource(meeting)
        let manager = ReviewSessionManager(storage: storage)
        var events: [Event] = []
        manager.walkthroughFocusHandler = { events.append(.focused($0)) }
        manager.walkthroughReaderShowsSource = { $0 == meeting.id }

        let passage = "Ageing flattens the valleys"
        let shown = await manager.focusSourceAnchorForTesting(arguments: ["source_id": meeting.id, "passage": passage])
        #expect(!shown.isError)
        #expect(events == [.focused(.flash(passage: passage, sourceID: meeting.id))])

        events = []
        let figure = await manager.focusSourceAnchorForTesting(arguments: ["source_id": meeting.id, "figure_label": "Figure 1"])
        #expect(figure.isError)
        let page = await manager.focusSourceAnchorForTesting(arguments: ["source_id": meeting.id, "page_number": 2])
        #expect(page.isError)
        #expect(events.isEmpty)
    }

    @Test("A figure whose reading failed is reported as a failure that says where it is outlined, and never reads the picture")
    func failedFigureReadingSaysWhereTheFigureIs() {
        let outlined = ReviewSessionManager.figureReadingUnavailableMessage(
            figureLabel: "Figure 1",
            pageNumber: 2,
            caption: "Fig. 1 | Three layers of regulation.",
            failure: "The free model is rate-limited upstream (429)",
            outlinedBesideChat: true
        )
        #expect(outlined.hasPrefix("Error: the visual reading of Figure 1 failed: The free model is rate-limited upstream (429)."))
        #expect(outlined.contains("outlined on PDF page 2 in the Reader beside this chat"))
        #expect(outlined.contains("do not describe what the figure shows as if you had seen it"))
        #expect(outlined.contains("Fig. 1 | Three layers of regulation."))
        #expect(!outlined.contains("show_source_image"))

        // No Reader beside the chat, and no model set up to read figures:
        // the picture is still one call away.
        let unopened = ReviewSessionManager.figureReadingUnavailableMessage(
            figureLabel: "Figure 1",
            pageNumber: 2,
            caption: "Fig. 1 | Three layers of regulation.",
            failure: nil,
            outlinedBesideChat: false
        )
        #expect(unopened.hasPrefix("Error: Figure 1 is indexed, but its visual understanding could not be prepared."))
        #expect(unopened.contains("show_source_image for page 2"))
        #expect(!unopened.contains("outlined"))
    }
}
