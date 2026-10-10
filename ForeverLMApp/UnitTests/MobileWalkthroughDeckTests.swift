import Foundation
import Testing
@testable import ForeverLM

/// The phone reads the walkthrough the Mac writes into the Source payload.
/// These encode with the Mac's own `PaperWalkthrough` and decode with the
/// phone's `MobileWalkthroughDeck`, so a renamed key on either side fails
/// here rather than as a deck that silently never appears.
@Suite("Walkthrough deck on the phone")
struct MobileWalkthroughDeckTests {
    private struct Payload: Encodable {
        let paperWalkthrough: PaperWalkthrough?
    }

    /// Encoded as `CloudKitSourcePayload` is: a plain `JSONEncoder`, so the
    /// record's date is seconds since 2001, as the phone's own save writes it.
    private func payloadData(_ walkthrough: PaperWalkthrough?) throws -> Data {
        try JSONEncoder().encode(Payload(paperWalkthrough: walkthrough))
    }

    private func walkthrough(steps: [PaperWalkthroughStep], version: Int = PaperWalkthrough.currentVersion) -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: "paper-1",
            sourceSHA256: "sha",
            title: "How ouabain loads the cell with sodium",
            steps: steps,
            author: .app,
            version: version
        )
    }

    @Test("A Mac walkthrough decodes into cards with their figures, quotes, beats and questions")
    func decodesMacRecord() throws {
        let record = walkthrough(steps: [
            PaperWalkthroughStep(
                id: "s1",
                kind: .explain,
                title: "The question",
                body: "Cardiac cells hold sodium low.\n\nNobody knew how fast it rose.",
                anchor: PaperWalkthroughAnchor(passage: "how fast intracellular sodium rises")
            ),
            PaperWalkthroughStep(
                id: "s2",
                kind: .figure,
                title: "Sodium over time",
                body: "Ignored because beats exist.",
                anchor: PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 3),
                animationHTML: "<svg></svg>",
                sourceMention: "Intracellular Na rose within minutes of ouabain (Fig. 1a).",
                beats: [
                    PaperWalkthroughBeat(text: "Look at panel a."),
                    PaperWalkthroughBeat(text: "Time runs along x.", figureLabel: "Figure 1", panelLabel: "a"),
                ]
            ),
            PaperWalkthroughStep(
                id: "s3",
                kind: .quiz,
                title: "Check",
                body: "Before the next figure:",
                quiz: PaperWalkthroughQuiz(question: "Why does sodium rise?", answer: "The pump stops.", keyPoints: ["Na/K pump", "ouabain"])
            ),
        ])

        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))
        #expect(deck.title == "How ouabain loads the cell with sodium")
        #expect(deck.steps.count == 3)
        #expect(deck.steps.map(\.id) == ["s1", "s2", "s3"])
        // The whole record rides along, for the card's chat to compose from,
        // and a deck of a record this phone wrote reads the same.
        #expect(deck.record?.steps.map(\.id) == record.steps.map(\.id))
        #expect(deck.record?.steps[2].quiz == record.steps[2].quiz)
        #expect(MobileWalkthroughPayloadParser.deck(from: record) == deck)

        let setup = deck.steps[0]
        #expect(setup.kind == .explain)
        #expect(setup.points == ["Cardiac cells hold sodium low.", "Nobody knew how fast it rose."])
        #expect(setup.passage == "how fast intracellular sodium rises")
        #expect(setup.figureLabel == nil)

        let figure = deck.steps[1]
        #expect(figure.kind == .figure)
        #expect(figure.points == ["Look at panel a.", "Time runs along x."])
        #expect(figure.beats[1] == MobileWalkthroughDeck.Step.Point(text: "Time runs along x.", figureLabel: "Figure 1", panelLabel: "a"))
        #expect(figure.figureDisplayLabel == "Figure 1a")
        #expect(figure.sourceMention == "Intracellular Na rose within minutes of ouabain (Fig. 1a).")
        #expect(figure.animationHTML == "<svg></svg>")
        #expect(figure.question == nil)

        let quiz = deck.steps[2]
        #expect(quiz.kind == .quiz)
        #expect(quiz.question == "Why does sodium rise?")
        #expect(quiz.answer == "The pump stops.")
        #expect(quiz.keyPoints == ["Na/K pump", "ouabain"])
    }

    @Test("A step's cited works reach the phone's cards; an untitled one and a record without any read as none")
    func decodesCitedWorks() throws {
        var cited = PaperWalkthroughStep(id: "s1", kind: .explain, title: "The mapmaker", body: "Lerchner argues against functionalism.")
        cited.cites = [
            PaperWalkthroughCitation(title: "The Abstraction Fallacy", authors: "Alexander Lerchner", year: "2026", kind: .paper, url: "https://example.org/abstraction-fallacy"),
            PaperWalkthroughCitation(title: "  "),
        ]
        let record = walkthrough(steps: [cited, PaperWalkthroughStep(id: "s2", kind: .explain, title: "Next", body: "More.")])
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))
        #expect(deck.steps[0].cites.map(\.title) == ["The Abstraction Fallacy"])
        #expect(deck.steps[0].cites.first?.address?.absoluteString == "https://example.org/abstraction-fallacy")
        #expect(deck.steps[1].cites.isEmpty)
    }

    @Test("The deck is dealt one point a card, a question a card of its own, as the Mac counts them")
    func cardsOnePointEach() throws {
        let record = walkthrough(steps: [
            PaperWalkthroughStep(id: "s1", kind: .explain, title: "The question", body: "Cardiac cells hold sodium low.\n\nNobody knew how fast it rose."),
            PaperWalkthroughStep(
                id: "s2",
                kind: .figure,
                title: "Sodium over time",
                body: "",
                anchor: PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 3),
                beats: [
                    PaperWalkthroughBeat(text: "Look at panel a."),
                    PaperWalkthroughBeat(text: "Panel b is the control.", panelLabel: "b"),
                    PaperWalkthroughBeat(text: "The schematic is in Figure 2c.", figureLabel: "Figure 2", panelLabel: "c"),
                ]
            ),
            PaperWalkthroughStep(
                id: "s3",
                kind: .quiz,
                title: "Check",
                body: "Before the next figure:",
                quiz: PaperWalkthroughQuiz(question: "Why does sodium rise?", answer: "The pump stops.", keyPoints: ["Na/K pump"])
            ),
            PaperWalkthroughStep(id: "s4", kind: .explain, title: "Silent", body: ""),
        ])
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))
        let cards = deck.cards
        #expect(cards.count == record.cardCount)
        #expect(cards.count == 7)
        #expect(cards.map(\.stepIndex) == [0, 0, 1, 1, 1, 2, 3])
        #expect(cards.map(\.indexInStep) == [0, 1, 0, 1, 2, 0, 0])
        #expect(cards.map(\.countInStep) == [2, 2, 3, 3, 3, 1, 1])
        #expect(cards[1].isLastOfStep && !cards[2].isLastOfStep && cards[4].isLastOfStep)
        #expect(cards[5].face == .question("Why does sodium rise?", context: "Before the next figure:"))
        #expect(cards[5].isQuestion)
        // A wordless step still takes one card, its title.
        #expect(cards[6].face == .point(MobileWalkthroughDeck.Step.Point(text: "Silent")))

        // A card's figure follows its point: the step's panel, the panel the
        // point names, or another figure entirely.
        let figure = deck.steps[1]
        #expect(MobileWalkthroughDeck.figureDisplayLabel(for: cards[2], of: figure) == "Figure 1a")
        #expect(MobileWalkthroughDeck.figureDisplayLabel(for: cards[3], of: figure) == "Figure 1b")
        #expect(MobileWalkthroughDeck.figureDisplayLabel(for: cards[4], of: figure) == "Figure 2c")
        #expect(MobileWalkthroughDeck.figureDisplayLabel(for: cards[0], of: deck.steps[0]) == nil)
        #expect(deck.figureStepCount == 1)
        #expect(deck.questionCount == 1)
    }

    @Test("Chapters deal a recap card after their last step, and a question's kind, target panel and chips reach the phone")
    func chaptersKindsAndChips() throws {
        let record = PaperWalkthrough(
            sourceID: "paper-1",
            sourceSHA256: "sha",
            title: "Sodium and energy",
            steps: [
                PaperWalkthroughStep(
                    id: "s1", kind: .explain, title: "Setup", body: "Cells keep sodium low.",
                    more: [PaperWalkthroughMore(label: "What is NCLX?", text: "The mitochondrial sodium–calcium exchanger.", fromPaper: false)]
                ),
                PaperWalkthroughStep(
                    id: "s2", kind: .quiz, title: "Predict", body: "",
                    anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", pageNumber: 4),
                    quiz: PaperWalkthroughQuiz(question: "Where do the bars land?", answer: "Lower.", keyPoints: [], kind: .predict)
                ),
                PaperWalkthroughStep(
                    id: "s3", kind: .quiz, title: "Find", body: "",
                    anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", pageNumber: 4),
                    quiz: PaperWalkthroughQuiz(question: "Which panel is the control?", answer: "Panel b.", keyPoints: [], kind: .find, targetPanel: "b")
                ),
            ],
            chapters: [
                PaperWalkthroughChapter(id: "ch-1", title: "The energy hit", claim: "Raising sodium lowers ATP.", stepIDs: ["s1", "s2"]),
                PaperWalkthroughChapter(id: "ch-2", title: "The control", claim: "", stepIDs: ["s3"]),
            ],
            author: .app
        )
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))
        #expect(deck.chapters?.map(\.title) == ["The energy hit", "The control"])
        #expect(deck.steps[0].more == [MobileWalkthroughDeck.Step.More(label: "What is NCLX?", text: "The mitochondrial sodium–calcium exchanger.", fromPaper: false)])
        #expect(deck.steps[1].quizKind == .predict)
        #expect(deck.steps[1].targetPanel == nil)
        #expect(deck.steps[2].quizKind == .find)
        #expect(deck.steps[2].targetPanel == "b")
        let cards = deck.cards
        // s1 (1 point), s2 (question) + recap of chapter 1, s3 (question); chapter 2 has no claim.
        #expect(cards.count == record.cardCount)
        #expect(cards.count == 4)
        #expect(cards[2].face == .recap(claim: "Raising sodium lowers ATP.", chapterTitle: "The energy hit"))
        #expect(cards[2].isRecap && cards[2].isLastOfStep && cards[2].stepIndex == 1)
        #expect(cards[1].countInStep == 2 && !cards[1].isLastOfStep)
        #expect(MobileWalkthroughDeck.figure(for: cards[2], of: deck.steps[1], in: []) == nil)
    }

    @Test("No walkthrough, an empty one, or one of an unknown version offers no deck")
    func absentOrUnreadable() throws {
        #expect(MobileWalkthroughPayloadParser.deck(from: try payloadData(nil)) == nil)
        #expect(MobileWalkthroughPayloadParser.deck(from: try payloadData(walkthrough(steps: []))) == nil)
        let future = walkthrough(
            steps: [PaperWalkthroughStep(id: "s", kind: .explain, title: "t", body: "b")],
            version: PaperWalkthrough.currentVersion + 1
        )
        #expect(MobileWalkthroughPayloadParser.deck(from: try payloadData(future)) == nil)
        #expect(MobileWalkthroughPayloadParser.deck(from: Data("not json".utf8)) == nil)
    }

    @Test("A card finds its figure by label, preferring the measured row over a caption continued on the next page, and its measured panel")
    func figureMatching() throws {
        let rect = PaperFigureRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
        let panelRect = PaperFigureRect(x: 0.1, y: 0.1, width: 0.4, height: 0.25)
        let analysis = PaperFigureAnalysis(
            summary: "s",
            visualEvidence: [],
            figureRect: rect,
            panels: [
                PaperFigurePanel(id: "pa", label: "(A)", explanation: "a", rect: panelRect),
                PaperFigurePanel(id: "pb", label: "b", explanation: "b", rect: nil),
            ],
            analysisVersion: PaperFigureAnalysis.currentVersion,
            generatedAt: Date()
        )
        let figures = [
            SyncedPaperFigure(id: "f2-continued", sourceID: "p", figureLabel: "Fig. 2", pageIndex: 5, caption: "Continued.", analysis: nil),
            SyncedPaperFigure(id: "f2", sourceID: "p", figureLabel: "Fig. 2", pageIndex: 4, caption: "See next page for caption", analysis: analysis),
            SyncedPaperFigure(id: "f1", sourceID: "p", figureLabel: "Figure 1", pageIndex: 2, caption: "One.", analysis: nil),
        ]
        let record = walkthrough(steps: [
            PaperWalkthroughStep(id: "a", kind: .figure, title: "a", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a")),
            PaperWalkthroughStep(id: "b", kind: .figure, title: "b", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "b")),
            PaperWalkthroughStep(id: "c", kind: .figure, title: "c", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 1")),
            PaperWalkthroughStep(id: "d", kind: .figure, title: "d", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 9")),
        ])
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))

        let panelA = try #require(MobileWalkthroughDeck.figure(for: deck.steps[0], in: figures))
        #expect(panelA.figure.id == "f2")
        #expect(panelA.panel?.id == "pa")
        #expect(!panelA.sharesPage)

        // A panel the analysis never measured carries no rect; the renderer
        // finds it on the page by the letter the figure prints.
        let panelB = try #require(MobileWalkthroughDeck.figure(for: deck.steps[1], in: figures))
        #expect(panelB.figure.id == "f2")
        #expect(panelB.panel == nil)

        let whole = try #require(MobileWalkthroughDeck.figure(for: deck.steps[2], in: figures))
        #expect(whole.figure.id == "f1")
        #expect(MobileWalkthroughDeck.figure(for: deck.steps[3], in: figures) == nil)
    }

    @Test("Reopening a deck returns to the card left, except from the cover or the end")
    func deckPosition() throws {
        let defaults = try #require(UserDefaults(suiteName: "MobileWalkthroughDeckTests.\(UUID().uuidString)"))
        #expect(MobileWalkthroughDeckPosition.restored(sourceID: "s", cardCount: 6, defaults: defaults) == 0)
        MobileWalkthroughDeckPosition.save(3, sourceID: "s", cardCount: 6, defaults: defaults)
        #expect(MobileWalkthroughDeckPosition.restored(sourceID: "s", cardCount: 6, defaults: defaults) == 3)
        // A shorter walk written since clamps back to the cover.
        #expect(MobileWalkthroughDeckPosition.restored(sourceID: "s", cardCount: 4, defaults: defaults) == 0)
        MobileWalkthroughDeckPosition.save(5, sourceID: "s", cardCount: 6, defaults: defaults)
        #expect(MobileWalkthroughDeckPosition.restored(sourceID: "s", cardCount: 6, defaults: defaults) == 0)
    }

    @Test("A step's saved animation by reference survives the payload, for the card to fetch")
    func animationReferenceRoundTrip() throws {
        let reference = WalkthroughAnimationReference(animationID: "anim-1", step: 3, conditions: ["drug": "ouabain"])
        let record = walkthrough(steps: [
            PaperWalkthroughStep(id: "s", kind: .explain, title: "t", body: "b", animation: reference),
            PaperWalkthroughStep(id: "t", kind: .explain, title: "u", body: "c"),
        ])
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))
        #expect(deck.record?.steps.first?.animation == reference)
        let page = reference.pageURL(animationURL: URL(string: "\(LocalSiteServing.scheme)://anim-1/")!)
        #expect(LocalSiteServing.siteID(from: page) == "anim-1")
        #expect(page.query?.contains("step=3") == true)
    }

    @Test("The phone's writer reads a figure as the Mac's does: one per label, the continued caption's words, analysed panels")
    func writerFigureInputs() {
        let analysis = PaperFigureAnalysis(
            summary: "Sodium over time.",
            visualEvidence: [],
            figureRect: nil,
            panels: [PaperFigurePanel(id: "a", label: "a", explanation: "Na rises.", rect: nil)],
            analysisVersion: PaperFigureAnalysis.currentVersion,
            generatedAt: Date()
        )
        let rows = [
            SyncedPaperFigure(id: "e1", sourceID: "p", figureLabel: "Extended Data Fig. 1", pageIndex: 7, caption: "Extended Data Fig. 1 | See next page for caption.", analysis: analysis),
            SyncedPaperFigure(id: "e1b", sourceID: "p", figureLabel: "Extended Data Fig. 1", pageIndex: 8, caption: "Extended Data Fig. 1 | Controls for the pump.", analysis: nil),
        ]
        let chosen = PaperWalkthroughWriting.firstPerLabel(rows, label: \.figureLabel, pageIndex: \.pageIndex)
        #expect(chosen.map(\.id) == ["e1"])
        let caption = PaperWalkthroughWriting.displayCaption(
            for: chosen[0], in: rows, label: \.figureLabel, pageIndex: \.pageIndex, caption: \.caption
        )
        #expect(caption == "Extended Data Fig. 1 | Controls for the pump.")
        #expect(PaperWalkthroughWriting.figureReading(analysis) == "Sodium over time.\nPanel a: Na rises.")
    }

    @Test("The phone deals a step's animation as a card of its own where the Mac does, and borrows a figure picture as the Mac does")
    func animationCardsAndPictures() throws {
        let quiz = PaperWalkthroughQuiz(question: "Why does sodium rise?", answer: "The pump stops.", keyPoints: ["pump"])
        let record = PaperWalkthrough(
            sourceID: "paper-1",
            sourceSHA256: "sha",
            title: "How ouabain loads the cell with sodium",
            steps: [
                PaperWalkthroughStep(id: "s1", kind: .figure, title: "Sodium", body: "", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 3),
                                     animationHTML: "<svg></svg>", quiz: quiz, beats: [PaperWalkthroughBeat(text: "Look at panel a."), PaperWalkthroughBeat(text: "It rises.")]),
                PaperWalkthroughStep(id: "s2", kind: .explain, title: "Why", body: "The pump stops."),
                PaperWalkthroughStep(id: "s3", kind: .explain, title: "Model", body: "A model.", picture: PaperWalkthroughPicture(figureLabel: "Figure 4", panelLabel: "c")),
                PaperWalkthroughStep(id: "s4", kind: .quiz, title: "Guess", body: "", animation: WalkthroughAnimationReference(animationID: "anim", step: 2), quiz: quiz),
                PaperWalkthroughStep(id: "s5", kind: .explain, title: "Alone", body: "Nothing to show."),
            ],
            chapters: [
                PaperWalkthroughChapter(id: "c1", title: "One", claim: "", stepIDs: ["s1", "s2", "s3", "s4"]),
                PaperWalkthroughChapter(id: "c2", title: "Two", claim: "", stepIDs: ["s5"]),
            ],
            author: .app
        )
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: payloadData(record)))
        let cards = deck.cards
        #expect(cards.count == record.cardCount)
        #expect(cards.filter { $0.stepIndex == 0 }.map(\.isAnimation) == [false, false, true, false])
        #expect(cards.filter { $0.stepIndex == 0 }.last?.isQuestion == true)
        #expect(cards.filter { $0.stepIndex == 3 }.map(\.isAnimation) == [false, true])
        // The steps that outline no figure show one: borrowed, or their own.
        #expect(deck.pictureFigure(ofStepAt: 0) == nil)
        #expect(deck.pictureFigure(ofStepAt: 1).map { [$0.label, $0.panel ?? ""] } == ["Figure 1", "a"])
        #expect(deck.pictureFigure(ofStepAt: 2).map { [$0.label, $0.panel ?? ""] } == ["Figure 4", "c"])
        #expect(deck.pictureFigure(ofStepAt: 4) == nil)
    }

}

@Suite("Walkthrough deck pictures on the phone")
struct MobileWalkthroughDeckPictureTests {
    private struct Payload: Encodable {
        let paperWalkthrough: PaperWalkthrough?
    }

    @Test("The phone's card shows the picture the Mac's does, a drawn one included")
    func drawnPicturesMatchTheMac() throws {
        let drawn = "8EFDE434-BF90-4A63-A7DE-F141156577B5"
        let other = "13b0dfba-3cc2-4d2d-9ca6-6a0822e27293"
        let record = PaperWalkthrough(
            sourceID: "article-1",
            sourceSHA256: "sha",
            title: "Metabolism as inference",
            steps: [
                PaperWalkthroughStep(id: "s1", kind: .explain, title: "Two fields", body: "They meet.", picture: PaperWalkthroughPicture(brief: "Two currents", imageID: drawn)),
                PaperWalkthroughStep(id: "s2", kind: .explain, title: "Borrowed", body: "Still the same point."),
                PaperWalkthroughStep(id: "s3", kind: .explain, title: "A figure", body: "See it.", picture: PaperWalkthroughPicture(figureLabel: "Figure 2", panelLabel: "b")),
                PaperWalkthroughStep(id: "s4", kind: .explain, title: "After it", body: "The figure again."),
                PaperWalkthroughStep(id: "s5", kind: .explain, title: "Opening", body: "A new claim."),
                PaperWalkthroughStep(id: "s6", kind: .explain, title: "Drawn later", body: "Its picture.", picture: PaperWalkthroughPicture(brief: "Regress", imageID: other)),
                PaperWalkthroughStep(id: "s7", kind: .explain, title: "Alone", body: "Nothing to show."),
                PaperWalkthroughStep(id: "s8", kind: .explain, title: "Waiting", body: "Undrawn.", picture: PaperWalkthroughPicture(brief: "Not drawn yet")),
            ],
            chapters: [
                PaperWalkthroughChapter(id: "c1", title: "One", claim: "", stepIDs: ["s1", "s2", "s3", "s4"]),
                PaperWalkthroughChapter(id: "c2", title: "Two", claim: "", stepIDs: ["s5", "s6"]),
                PaperWalkthroughChapter(id: "c3", title: "Three", claim: "", stepIDs: ["s7", "s8"]),
            ],
            author: .assistant
        )
        let deck = try #require(MobileWalkthroughPayloadParser.deck(from: JSONEncoder().encode(Payload(paperWalkthrough: record))))
        func mac(_ index: Int) -> MobileWalkthroughDeck.Picture? {
            switch record.cardPicture(of: record.steps[index]) {
            case .figure(let anchor)?: return anchor.figureLabel.map { .figure(label: $0, panel: anchor.panelLabel) }
            case .drawn(let id, _)?: return .drawn(imageID: id.lowercased())
            case .anchoredFigure?, nil: return nil
            }
        }
        for index in record.steps.indices {
            #expect(deck.picture(ofStepAt: index) == mac(index), "step \(index + 1)")
        }
        #expect(deck.drawnPictureID(ofStepAt: 0) == drawn.lowercased())
        #expect(deck.drawnPictureID(ofStepAt: 1) == drawn.lowercased(), "a card with no picture borrows the drawn one before it")
        #expect(deck.pictureFigure(ofStepAt: 3).map { [$0.label, $0.panel ?? ""] } == ["Figure 2", "b"])
        #expect(deck.drawnPictureID(ofStepAt: 4) == other, "a chapter's opening step borrows the one after it")
        #expect(deck.picture(ofStepAt: 6) == nil && deck.picture(ofStepAt: 7) == nil, "an undrawn brief shows nothing yet")
    }
}
