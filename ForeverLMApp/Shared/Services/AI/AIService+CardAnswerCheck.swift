import Foundation

// MARK: - Check in the card review
//
// docs/memory-design.md, "The answer is checked". One call on the Card Answer
// Check task's route (`AITask.cardAnswerCheck`, a model of its own, set in
// Settings › Background › Tasks: the learner pressed Check and waits), sent the card's
// front, back, why and quote and the learner's answer, and nothing else.
// Never answered from the response cache: an answer is never the same twice,
// and a cached verdict for a different answer would be wrong. A reply with no
// readable verdict asks the next backup model; a failure is thrown for the
// card to say, never replaced by a grade of the app's own (AGENTS.md, "AI
// failures surface"). The call's usage lands in the ledger against the card.
//
// The verdict is a word and a line, so the call asks for no thinking
// (`disablesReasoning`, as the card wording check does, 8507888). With thinking
// on, a card about a toxic-sounding subject (CCCP, a mitochondrial uncoupler,
// 2026-11-01) was stopped by the provider with `content_filter` ("Your answer
// could not be checked"), as the wording check's cards were on 2026-10-30.

extension AIService {
    func checkCardAnswer(
        _ request: MemoryCardAnswerCheck.Request,
        cardID: String,
        sourceTitle: String?,
        config: AITaskConfig
    ) async throws -> MemoryCardAnswerCheck.Result {
        let response = try await call(
            config: config,
            system: AITask.cardAnswerCheck.effectivePrompt ?? Prompts.cardAnswerCheck,
            user: MemoryCardAnswerCheck.message(request),
            maxTokens: MemoryCardAnswerCheck.maxTokens,
            temperature: 0,
            disablesReasoning: true,
            allowsResponseCache: false,
            jsonMode: true,
            validateResponse: { _ = try MemoryCardAnswerCheck.result(from: $0) },
            sourceTitle: sourceTitle,
            subjectID: cardID,
            subjectType: "memory_card"
        )
        do {
            return try MemoryCardAnswerCheck.result(from: response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
