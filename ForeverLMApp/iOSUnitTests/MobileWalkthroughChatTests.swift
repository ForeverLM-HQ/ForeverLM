import Foundation
import XCTest
@testable import ForeverLM

/// A walkthrough's chat on the phone saves the Mac's own shape, so the Mac
/// reopens it as the walk: each card joins the chat as its step turn (the
/// `WalkthroughStepTurn` line first), and a Forgot/Remembered is an exchange
/// with score 1 or 0 and no model call. Under each card the chat shows only
/// that card's conversation.
@MainActor
final class MobileWalkthroughChatTests: XCTestCase {
    private func walkthrough() -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: "paper-1",
            sourceSHA256: "sha",
            title: "Walk",
            steps: [
                PaperWalkthroughStep(id: "s1", kind: .explain, title: "Setup", body: "Cells keep sodium low."),
                PaperWalkthroughStep(
                    id: "s2",
                    kind: .quiz,
                    title: "Check",
                    body: "Before the figure:",
                    quiz: PaperWalkthroughQuiz(question: "Why does sodium rise?", answer: "The pump stops.", keyPoints: ["pump"])
                ),
            ],
            author: .app
        )
    }

    private func chat() -> MobileChatViewModel {
        MobileChatViewModel(
            source: MobileCloudSource(
                id: "paper-1",
                title: "Paper",
                subtitle: nil,
                sourceType: "paper",
                dateAdded: Date(timeIntervalSinceReferenceDate: 0),
                hasAudio: false,
                isArchived: false
            ),
            sourceText: "Cells keep sodium low. The pump stops.",
            selection: nil,
            walkthrough: walkthrough(),
            // A grade queues the session's save, which asks the account for
            // the chat model; the account's store would build a CKContainer
            // and trap this unsigned test host.
            resolveSaveRoute: { throw CancellationError() }
        )
    }

    func testRecallGradeSavesTheCardTurnThenTheGrade() throws {
        let chat = chat()
        chat.currentStepIndex = 1
        chat.gradeRecall(remembered: true)

        let exchanges = chat.recordedExchangesForTesting
        XCTAssertEqual(exchanges.count, 2)

        let marker = try XCTUnwrap(WalkthroughStepTurn.marker(in: exchanges[0].question))
        XCTAssertEqual(marker.stepID, "s2")
        XCTAssertEqual(marker.index, 1)
        XCTAssertEqual(marker.count, 2)
        XCTAssertTrue(exchanges[0].question.contains("**Question:** Why does sodium rise?"))
        XCTAssertEqual(exchanges[0].userAnswer, "")
        XCTAssertNil(exchanges[0].evaluation)

        XCTAssertEqual(exchanges[1].question, "")
        XCTAssertEqual(exchanges[1].userAnswer, "I had it.")
        XCTAssertEqual(exchanges[1].score, 1)
        XCTAssertEqual(
            exchanges[1].evaluation,
            WalkthroughStepComposer.recallRecord(quiz: try XCTUnwrap(walkthrough().steps[1].quiz), remembered: true)
        )
        XCTAssertEqual(chat.recall["s2"], true)

        // A second grade of the same card changes nothing.
        chat.gradeRecall(remembered: false)
        XCTAssertEqual(chat.recordedExchangesForTesting.count, 2)
        XCTAssertEqual(chat.recall["s2"], true)
    }

    func testEachCardShowsOnlyItsOwnConversation() {
        let chat = chat()
        chat.currentStepIndex = 1
        chat.gradeRecall(remembered: false)

        XCTAssertEqual(chat.displayedMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.displayedMessages.first?.content, "I didn't have it.")
        XCTAssertTrue(chat.displayedMessages.allSatisfy { $0.walkStepID == nil })

        chat.currentStepIndex = 0
        XCTAssertTrue(chat.displayedMessages.isEmpty)
    }

    func testAGradeOnAStepWithoutAQuestionIsIgnored() {
        let chat = chat()
        chat.currentStepIndex = 0
        chat.gradeRecall(remembered: true)
        XCTAssertTrue(chat.recordedExchangesForTesting.isEmpty)
    }
}
