import Foundation
import Testing
@testable import ForeverLM

/// A card stands on its own (docs/memory-design.md, "A card stands on its
/// own"): the gate every model- or assistant-written card face passes before
/// it is saved. The gate's model is canned (`CannedCardWording`).
@Suite("Memory cards: a card stands on its own")
struct CardWordingGateTests {
    private static let lectureTitle = "Mitochondrial Cell Biology 2"
    private static let pointing = "In this lecture, what structural feature of cardiolipin distinguishes it from most other phospholipids?"
    private static let named = "Which structural feature of cardiolipin distinguishes it from most other phospholipids?"
    private static let back = "Four acyl chains on a glycerol backbone, where most phospholipids have two."

    // MARK: The turns

    @Test("The check reads every card with its source's title, and its reply must answer every card")
    func turns() throws {
        let faces = [
            CardWordingCheck.Face(front: Self.pointing, back: Self.back, sourceTitle: Self.lectureTitle),
            CardWordingCheck.Face(front: "What does complex IV reduce?", back: "Oxygen, to water.", sourceTitle: "Mitochondria"),
        ]
        let message = CardWordingCheck.checkMessage(faces)
        #expect(message.contains("Card 1, from \u{201C}Mitochondrial Cell Biology 2\u{201D}\nQuestion: \(Self.pointing)\nAnswer: \(Self.back)"))
        #expect(message.contains("Card 2, from \u{201C}Mitochondria\u{201D}"))

        let verdicts = try CardWordingCheck.verdicts(
            from: #"{"cards": [{"card": 1, "stands_alone": false, "problem": "asks about this lecture"}, {"card": 2, "stands_alone": true, "problem": null}]}"#,
            count: 2
        )
        #expect(verdicts[1] == .init(standsAlone: false, problem: "asks about this lecture"))
        #expect(verdicts[2] == .init(standsAlone: true, problem: nil))
        // A reply that leaves a card out is no verdict: nothing is taken on a guess.
        #expect(throws: CardWordingCheck.ReplyError.self) {
            try CardWordingCheck.verdicts(from: #"{"cards": [{"card": 1, "stands_alone": true}]}"#, count: 2)
        }

        let kept = CardWordingCheck.rewordMessage([(faces[0], "asks about this lecture")], answersMayChange: false)
        #expect(kept.contains("The answers may not change"))
        #expect(kept.contains("What is wrong: asks about this lecture"))
        let rewordings = try CardWordingCheck.rewordings(
            from: #"{"cards": [{"card": 1, "front": "Which structural feature of cardiolipin distinguishes it?", "back": "Changed."}]}"#,
            count: 1,
            answersMayChange: false
        )
        #expect(rewordings[1] == .init(front: "Which structural feature of cardiolipin distinguishes it?", back: nil), "a kept card's answer never changes")

        for rule in ["\"this lecture\"", "\"the speaker\"", "\"stands_alone\""] {
            #expect(Prompts.cardWordingCheck.contains(rule))
        }
        // A question with several correct answers, whose card holds the source's one, is held back too.
        #expect(Prompts.cardStandsAloneRule.contains("the question has one answer"))
        #expect(Prompts.cardWordingCheck.contains("more than one correct answer"))
        #expect(Prompts.cardWordingRewrite.contains("attribute it"))
        #expect(Prompts.cardDrafter.contains(Prompts.cardStandsAloneRule))
        #expect(Prompts.situatedCards.contains(Prompts.cardStandsAloneRule))
        #expect(Prompts.mnemonicReadingWriter.contains("\"this lecture\" without naming it"))
        #expect(AITask.cardWordingCheck.rawValue == "card_wording_check")
        #expect(AITask.cardWordingCheck.isBackgroundWork)
        #expect(AITask.cardWordingCheck.usesBackgroundModelDefault)
        #expect(AITask.advancedTasks.contains(.cardWordingCheck))
    }

    @Test("No prompt that writes or judges a question models a question that opens by pointing at its source")
    func noPromptTeachesPointingOpeners() {
        let questionPrompts: [(name: String, text: String)] = [
            ("cardDrafter", Prompts.cardDrafter), ("situatedCards", Prompts.situatedCards),
            ("cardStandsAloneRule", Prompts.cardStandsAloneRule), ("cardWordingCheck", Prompts.cardWordingCheck),
            ("cardWordingRewrite", Prompts.cardWordingRewrite), ("mnemonicReadingWriter", Prompts.mnemonicReadingWriter),
            ("walkthroughWriter", Prompts.walkthroughWriter), ("lectureQuizWriter", Prompts.lectureQuizWriter),
            ("courseQuizWriter", Prompts.courseQuizWriter),
        ]
        let openers = ["paper", "lecture", "course", "video", "episode", "chapter", "talk", "article", "book", "reading"]
            .flatMap { ["In this \($0),", "In this \($0) \u{2026}"] }
        for prompt in questionPrompts {
            for opener in openers {
                #expect(!prompt.text.contains(opener), "\(prompt.name) still models a question that opens \"\(opener)\"")
            }
        }
        // The walkthrough, lecture-quiz and course-quiz writers once did; now they name the subject, or whose claim it is.
        #expect(Prompts.walkthroughWriter.contains("never \"this paper\""))
        #expect(Prompts.lectureQuizWriter.contains("never \"this lecture\""))
        #expect(Prompts.courseQuizWriter.contains("never \"this course\""))
        #expect(Prompts.walkthroughWriter.contains("say whose claim it is"))
        #expect(Prompts.lectureQuizWriter.contains("name the lecture or speaker"))
        #expect(Prompts.courseQuizWriter.contains("name the lecture or speaker"))
    }

    // MARK: The gate

    @Test("A face that stands alone passes in one call; one that points is reworded once with its title and checked again, or fails")
    func screens() async throws {
        let wording = CannedCardWording(pointing: ["this lecture", "the speaker"]) { question in
            question == Self.pointing ? Self.named : nil
        }
        let usage = AIUsageSource(id: "src-lecture", type: "video", title: Self.lectureTitle)
        let fine = try await CardWordingGate.screen(
            [.init(front: Self.named, back: Self.back, sourceTitle: Self.lectureTitle)],
            answersMayChange: true, usage: usage, backend: wording
        )
        #expect(fine == [.passed])
        #expect(wording.checks.count == 1)
        #expect(wording.rewordings.isEmpty)

        let outcomes = try await CardWordingGate.screen([
            .init(front: Self.pointing, back: Self.back, sourceTitle: Self.lectureTitle),
            .init(front: "What does the speaker say cardiolipin binds?", back: "Cytochrome c.", sourceTitle: Self.lectureTitle),
            .init(front: Self.named, back: Self.back, sourceTitle: Self.lectureTitle),
        ], answersMayChange: true, usage: usage, backend: wording)
        #expect(outcomes[0] == .reworded(front: Self.named, back: Self.back))
        guard case .failed(let reason) = outcomes[1] else {
            Issue.record("a rewording that still points is not saved")
            return
        }
        #expect(reason.contains("points at its source"))
        #expect(outcomes[2] == .passed)
        #expect(wording.checks.count == 3, "one check, then one check of the rewordings")
        #expect(wording.rewordings.count == 1)
        #expect(wording.rewordings.last?.contains("from \u{201C}\(Self.lectureTitle)\u{201D}") == true, "the rewording may name the source")

        let down = CannedCardWording(failure: CardWordingGate.Unavailable(message: "No model is set up for Card Wording Check."))
        await #expect(throws: CardWordingGate.Unavailable.self) {
            _ = try await CardWordingGate.screen(
                [.init(front: Self.named, back: Self.back, sourceTitle: Self.lectureTitle)],
                answersMayChange: true, usage: usage, backend: down
            )
        }
    }
}
