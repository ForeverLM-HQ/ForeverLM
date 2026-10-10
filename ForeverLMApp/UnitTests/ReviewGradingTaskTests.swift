import Testing
@testable import ForeverLM

@Suite("Review grading AI task")
struct ReviewGradingTaskTests {
    @Test("Review grading has an independently configurable background route")
    func gradingTaskContract() {
        #expect(AITask.advancedTasks.contains(.reviewGrading))
        #expect(AITask.reviewGrading.usesBackgroundModelDefault)
        #expect(AITask.reviewGrading.displayName == "Review Grading")
        #expect(AITask.reviewGrading.defaultPrompt == nil)
    }

    @Test("Usage history names review grading consistently")
    func usageLabel() {
        #expect(AIUsageTaskLabel.text(for: AITask.reviewGrading.rawValue) == "Grade Review")
    }

    @Test("Memory reviews vary the cue while keeping grading source grounded")
    func memoryTutorPromptContract() {
        let contract = Prompts.memoryCompanionBehavior
        #expect(contract.contains("Generate a fresh"))
        #expect(contract.contains("Never display or read them aloud"))
        #expect(contract.contains("record_memory_attempt` exactly once"))
        #expect(contract.contains("never replace it with a guessed grade"))
        #expect(contract.contains("Never expose a deck"))
        #expect(Prompts.reviewTutor.contains(contract))
        #expect(Prompts.studyChat.contains(contract))
    }
}
