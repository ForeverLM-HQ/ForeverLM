import Foundation

// MARK: - Go Deeper in the card review
//
// docs/memory-design.md, "Go Deeper on a card". Two calls on the Go Deeper
// task's route (`AITask.cardGoDeeper`, the chat's model: the learner pressed
// it and waits): the question, and the reply to the learner's answer. Neither
// is answered from the response cache — a card met again deserves a question
// in fresh words, and an answer is never the same twice — and a failure is
// thrown for the review to say, never replaced by a question or a reply of
// the app's own (AGENTS.md, "AI tutor failures"). Each call's usage lands in
// the ledger against the card it was about.

extension AIService {
    static let goDeeperQuestionMaxTokens = 600
    static let goDeeperReplyMaxTokens = 500

    /// The probe for one remembered card: the first kind of
    /// `request.kinds` that fits it, or nil when none does (a bare fact).
    /// A response that names a kind not offered, or no question, is no
    /// answer, and the next backup model is asked.
    func goDeeperQuestion(
        _ request: MemoryUnderstandingProbe.CardQuestionRequest,
        cardID: String,
        config: AITaskConfig
    ) async throws -> MemoryUnderstandingProbe.CardQuestion? {
        let kinds = request.kinds
        let response = try await call(
            config: config,
            system: AITask.cardGoDeeper.effectivePrompt ?? Prompts.goDeeperQuestion,
            user: MemoryUnderstandingProbe.cardQuestionMessage(request),
            maxTokens: Self.goDeeperQuestionMaxTokens,
            temperature: 0.7,
            allowsResponseCache: false,
            jsonMode: true,
            validateResponse: { _ = try MemoryUnderstandingProbe.cardQuestion(from: $0, offered: kinds) },
            sourceTitle: request.sourceTitle,
            subjectID: cardID,
            subjectType: "memory_card"
        )
        do {
            return try MemoryUnderstandingProbe.cardQuestion(from: response, offered: kinds)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// The reply to the learner's answer to the probe: two or three plain
    /// sentences on what it got and what it missed (`Prompts.goDeeperReply`).
    func goDeeperReply(
        _ request: MemoryUnderstandingProbe.CardReplyRequest,
        cardID: String,
        config: AITaskConfig
    ) async throws -> String {
        let response = try await call(
            config: config,
            system: Prompts.goDeeperReply,
            user: MemoryUnderstandingProbe.cardReplyMessage(request),
            maxTokens: Self.goDeeperReplyMaxTokens,
            temperature: 0.3,
            allowsResponseCache: false,
            validateResponse: { _ = try MemoryUnderstandingProbe.cardReply(from: $0) },
            sourceTitle: request.sourceTitle,
            subjectID: cardID,
            subjectType: "memory_card"
        )
        do {
            return try MemoryUnderstandingProbe.cardReply(from: response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
