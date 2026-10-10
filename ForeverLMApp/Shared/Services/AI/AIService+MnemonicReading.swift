import Foundation

// MARK: - A mnemonic reading: the model call
//
// docs/memory-design.md, "Mnemonic reading". One request a source (or a
// consecutive part of a long one), on the learner's Mnemonic Reading Writing
// route (Settings › AI Models › Background, Text), sent exactly as the plan
// built it: the planner sized it against the route's window, and one the
// central one-shot trim would cut is refused here rather than sent cut.

extension AIService {
    /// One request's questions. Never answered from the response cache: a
    /// reading written again asks for its questions again.
    func writeMnemonicReadingQuestions(
        system: String,
        user: String,
        maxTokens: Int,
        source: AIUsageSource,
        config: AITaskConfig
    ) async throws -> [MnemonicReadingModelQuestion] {
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = Self.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: system,
            user: user,
            requestedMaxTokens: maxTokens
        )
        guard budgeted.system == system, budgeted.user == user else {
            throw MnemonicReadingError.wouldBeCut(model: routed.model, title: source.title)
        }
        let response = try await AIUsageAttribution.withSource(source, activityID: AIUsageAttribution.activityID ?? UUID().uuidString) {
            try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: maxTokens,
                temperature: 0.3,
                allowsResponseCache: false,
                jsonMode: true
            )
        }
        do {
            let answer: MnemonicReadingModelAnswer = try MemoryReviewPlanning.decodeJSON(response)
            return answer.questions
        } catch {
            throw AIError.invalidResponse
        }
    }
}
