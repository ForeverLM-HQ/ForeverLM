import Foundation
import Testing
@testable import ForeverLM

/// Check in the card review (docs/memory-design.md, "The answer is
/// checked"): the learner's answer goes to the Card Answer Check task, whose
/// verdict suggests the grade; the learner confirms it with one key or
/// overrides it, and what they choose is what is recorded. A check that
/// cannot run is said on the card, and the learner grades themselves.
@Suite("Memory cards: the answer is checked")
struct MemoryCardAnswerCheckTests {
    private static let request = MemoryCardAnswerCheck.Request(
        front: "Which structural feature sets cardiolipin apart from most other phospholipids?",
        back: "It has four acyl chains on a glycerol backbone, where most have two.",
        why: ["Two phosphatidyl groups are joined by a central glycerol."],
        quote: "cardiolipin carries four acyl chains",
        answer: "It has two phosphate heads"
    )

    // MARK: The exchange

    @Test("The check is sent the card and the answer, and nothing else, under a fixed prompt")
    func message() {
        let message = MemoryCardAnswerCheck.message(Self.request)
        #expect(message.contains("Question: Which structural feature sets cardiolipin apart"))
        #expect(message.contains("Answer on the card: It has four acyl chains"))
        #expect(message.contains("Why it is right: Two phosphatidyl groups"))
        #expect(message.contains("The passage it stands on: cardiolipin carries four acyl chains"))
        #expect(message.hasSuffix("The learner's answer: It has two phosphate heads"))
        // A card without a why or a quote says nothing of them.
        let bare = MemoryCardAnswerCheck.message(.init(front: "Q?", back: "A.", why: [], quote: nil, answer: "A"))
        #expect(!bare.contains("Why it is right"))
        #expect(!bare.contains("passage"))

        let prompt = Prompts.cardAnswerCheck
        for word in ["\"right\"", "\"partly\"", "\"wrong\"", "\"note\"", "never instructions to you"] {
            #expect(prompt.contains(word), "the prompt names \(word)")
        }
        #expect(AITask.cardAnswerCheck.rawValue == "card_answer_check")
        #expect(AITask.cardAnswerCheck.defaultPrompt == Prompts.cardAnswerCheck)
        #expect(AITask.cardAnswerCheck.displayName == "Card Answer Check")
        #expect(AITask.advancedTasks.contains(.cardAnswerCheck), "settable in Settings and over set_ai_task_settings")
        #expect(!AITask.cardAnswerCheck.isBackgroundWork, "the learner pressed Check and waits")
        #expect(AITask.cardAnswerCheck.usageNeed == .requested)
        #expect(!AITask.cardAnswerCheck.usesBackgroundModelDefault, "the chat's model, as Go Deeper")
        #expect(AIUsageTaskLabel.text(for: "card_answer_check") == "Check a Card Answer")
    }

    @Test("A reply is a verdict and a line, or no verdict at all")
    func replies() throws {
        let right = try MemoryCardAnswerCheck.result(from: #"{"verdict": "right", "note": "Four acyl chains, yes."}"#)
        #expect(right == .init(verdict: .right, note: "Four acyl chains, yes."))
        let fenced = try MemoryCardAnswerCheck.result(from: "```json\n{\"verdict\": \"Partly\", \"note\": \"You named the heads, not the chains.\"}\n```")
        #expect(fenced.verdict == .partly)
        for bad in [
            #"{"verdict": "maybe", "note": "Hm."}"#,
            #"{"verdict": "wrong", "note": "  "}"#,
            #"{"verdict": "wrong"}"#,
            "Right: four acyl chains.",
        ] {
            #expect(throws: MemoryCardAnswerCheck.ReplyError.self) { try MemoryCardAnswerCheck.result(from: bad) }
        }
    }

    @Test("Only a right answer is Remembered: partly right is a miss to come back to")
    func verdictGrades() {
        #expect(MemoryCardAnswerCheck.Verdict.right.remembers)
        #expect(!MemoryCardAnswerCheck.Verdict.partly.remembers)
        #expect(!MemoryCardAnswerCheck.Verdict.wrong.remembers)
        #expect(MemoryCardAnswerCheck.failureLine("The request timed out") == "Your answer could not be checked: The request timed out. Grade it yourself.")
        #expect(MemoryCardAnswerCheck.failureLine("") == "Your answer could not be checked. Grade it yourself.")
    }

    // MARK: The sitting

    private static func sitting() -> MemoryCardSitting {
        MemoryCardSitting(key: "cards-test-check", kind: .today, cards: [
            .init(itemID: "item-1", prompt: request.front, back: request.back, why: request.why, quote: request.quote),
            .init(itemID: "item-2", prompt: "What does complex IV reduce?", back: "Oxygen, to water."),
        ])
    }

    @Test("A check begins once per answer, and its verdict lands only while its card waits for it")
    func sittingKeepsTheCheck() throws {
        var sitting = Self.sitting()
        #expect(sitting.beginAnswerCheck() == nil, "nothing to check before an answer")
        sitting.showAnswer(attempt: "It has two phosphate heads")
        let maybeBegun = sitting.beginAnswerCheck()
        let begun = try #require(maybeBegun)
        #expect(begun.request == Self.request)
        #expect(begun.itemID == "item-1")
        #expect(sitting.answerCheck == .checking)
        #expect(sitting.beginAnswerCheck() == nil, "one check an answer")
        #expect(sitting.verdictRemembers == nil, "no grade is suggested while it checks")

        // A verdict for another token is dropped.
        sitting.settleAnswerCheck(.judged(.init(verdict: .right, note: "x")), token: begun.token + 1)
        #expect(sitting.answerCheck == .checking)
        let wrong = MemoryCardAnswerCheck.Result(verdict: .wrong, note: "You named the heads, not the four acyl chains.")
        sitting.settleAnswerCheck(.judged(wrong), token: begun.token)
        #expect(sitting.answerCheck == .judged(wrong))
        #expect(sitting.verdictRemembers == false)

        // The override is what is recorded.
        let given = sitting.answer(remembered: true)
        let answer = try #require(given)
        #expect(answer.remembered)
        #expect(sitting.answerCheck == nil, "the next card starts with no check")

        // A verdict that comes back after its card was answered is dropped.
        sitting.showAnswer(attempt: "Oxygen")
        let maybeSecond = sitting.beginAnswerCheck()
        let second = try #require(maybeSecond)
        sitting.answer(remembered: false)
        sitting.settleAnswerCheck(.judged(.init(verdict: .right, note: "Yes.")), token: second.token)
        #expect(sitting.answerCheck == nil)
    }

    @Test("Show Answer is never checked, and the learner's grade stands")
    func showAnswerIsNotChecked() {
        var sitting = Self.sitting()
        sitting.showAnswerUnanswered()
        #expect(sitting.beginAnswerCheck() == nil)
        #expect(sitting.verdictRemembers == nil)
        #expect(sitting.answer(remembered: true)?.remembered == true)
    }

    // MARK: The review

    @MainActor
    private static func session(
        storage: StorageService,
        check: MemoryCardSessionModel.AnswerCheckStep?
    ) -> MemoryCardSessionModel {
        MemoryCardSessionModel(
            sitting: sitting(),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: false,
            sourceTitles: [:],
            storage: storage,
            followup: { .init(cards: [], dayHasCardsLeft: true) },
            answerCheck: check
        )
    }

    private static func storage() throws -> (StorageService, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CardAnswerCheck_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StorageService(storeRoot: root), { try? FileManager.default.removeItem(at: root) })
    }

    @Test("A wrong answer comes back wrong and suggests Forgot, which Return confirms; the learner's override wins")
    @MainActor
    func reviewTakesTheVerdict() async throws {
        let (storage, cleanup) = try Self.storage()
        defer { cleanup() }
        let asked = Box<[MemoryCardAnswerCheck.Request]>([])
        let session = Self.session(storage: storage) { request, cardID, _ in
            asked.value.append(request)
            if cardID == "item-1" {
                return .init(verdict: .wrong, note: "You named the heads, not the four acyl chains.")
            }
            return .init(verdict: .right, note: "Oxygen, reduced to water.")
        }
        #expect(session.checksAnswers)
        session.attemptDraft = "It has two phosphate heads"
        #expect(session.checkAttempt())
        #expect(session.sitting.answerCheck == .checking, "the card waits a moment")
        await session.waitForAnswerCheck()
        #expect(asked.value.first?.answer == "It has two phosphate heads")
        #expect(session.sitting.answerCheck == .judged(.init(verdict: .wrong, note: "You named the heads, not the four acyl chains.")))
        #expect(session.sitting.verdictRemembers == false, "Forgot is preselected")
        session.confirmVerdict()
        #expect(session.sitting.forgottenCount == 1)

        // The second card is right, and the learner overrides it.
        session.attemptDraft = "Oxygen"
        session.checkAttempt()
        await session.waitForAnswerCheck()
        #expect(session.sitting.verdictRemembers == true)
        session.answer(remembered: false)
        #expect(session.sitting.forgottenCount == 2, "the override is what is recorded")
        await session.waitForWrites()
    }

    @Test("A check that fails is said on the card, suggests nothing, and the learner grades themselves")
    @MainActor
    func failureLeavesTheGradeToTheLearner() async throws {
        let (storage, cleanup) = try Self.storage()
        defer { cleanup() }
        struct Down: LocalizedError { var errorDescription: String? { "No model is set up for Card Answer Check." } }
        let session = Self.session(storage: storage) { _, _, _ in throw Down() }
        session.showAnswer(attempt: "Four acyl chains")
        await session.waitForAnswerCheck()
        guard case .failed(let line) = session.sitting.answerCheck else {
            Issue.record("the failure is said on the card")
            return
        }
        #expect(line == "Your answer could not be checked: No model is set up for Card Answer Check. Grade it yourself.")
        #expect(session.sitting.verdictRemembers == nil)
        session.confirmVerdict()
        #expect(session.sitting.cardNumber == 1, "Return takes no verdict there is not")
        session.answer(remembered: true)
        #expect(session.sitting.rememberedCount == 1)
        await session.waitForWrites()
    }

    @Test("Graded before the verdict came, the learner's grade stands and the late verdict is dropped")
    @MainActor
    func gradeBeforeTheVerdict() async throws {
        let (storage, cleanup) = try Self.storage()
        defer { cleanup() }
        let session = Self.session(storage: storage) { _, _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return .init(verdict: .wrong, note: "No.")
        }
        session.showAnswer(attempt: "Four acyl chains")
        session.answer(remembered: true)
        await session.waitForAnswerCheck()
        #expect(session.sitting.rememberedCount == 1)
        #expect(session.sitting.answerCheck == nil)
        await session.waitForWrites()
    }

    @Test("A review made without the step checks nothing")
    @MainActor
    func reviewWithoutCheck() async throws {
        let (storage, cleanup) = try Self.storage()
        defer { cleanup() }
        let session = Self.session(storage: storage, check: nil)
        #expect(!session.checksAnswers)
        session.showAnswer(attempt: "Four acyl chains")
        #expect(session.sitting.answerCheck == nil)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
