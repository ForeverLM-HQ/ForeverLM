import Foundation

// MARK: - The gate a card passes before it is saved
//
// docs/memory-design.md, "A card stands on its own". Every card face a model
// or an assistant writes passes here before storage sees it: ForeverLM's
// drafting (Make Cards, background drafting, `draft_cards`), cards drafted
// from what the learner made sense of, an assistant's `save_card_drafts` and
// `update_card`, a mnemonic reading's questions (written here and saved over
// MCP).
//
// One Card Wording Check call reads a whole batch; the cards that point at
// their source unnamed are reworded once, together, with each source's title
// to name, and the rewordings are checked again in a call of their own (a
// model is a poor judge of what it has just written). A card whose rewording
// still fails is not saved. A check that cannot run — no model, a failed
// call — throws: the caller saves nothing and says why, and never saves a
// card unchecked (AGENTS.md, "No fallbacks that mask failure").

/// The model behind the gate, so its users are tested with canned verdicts.
protocol CardWordingBackend: Sendable {
    /// The check's reply to `user` (`Prompts.cardWordingCheck`), for
    /// `cardCount` cards.
    func check(user: String, cardCount: Int, usage: AIUsageSource) async throws -> String
    /// The rewording's reply to `user` (`Prompts.cardWordingRewrite`).
    func reword(user: String, cardCount: Int, answersMayChange: Bool, usage: AIUsageSource) async throws -> String
}

/// The model of the chat that asked for a tool action, for the model calls
/// that action makes on the way. A card the learner has the chat save, or a
/// figure they have it look at, is work they wait on, so it runs on the model
/// they see in the chat, not on the background task's own route (product
/// owner, 2026-10-29: "if i tell the model in the chat to do something, it
/// should use THAT model"). Callers outside the in-app chat bind nothing and
/// keep the task's own route.
enum ChatRequestedModel {
    /// The tools whose inner model calls follow the chat's model: the card
    /// wording check, and the vision reading of one figure.
    static let toolNames: Set<String> = [
        "save_card_drafts", "update_card", "draft_cards",
        "save_mnemonic_reading", "answer_mnemonic_question",
        "inspect_paper_figure",
    ]

    /// What the tool call now running was asked on, set by `MCPToolRegistry`
    /// around a call the in-app chat made.
    @TaskLocal static var current: AITaskConfig?

    private static let lock = NSLock()
    private nonisolated(unsafe) static var configs: [String: AITaskConfig] = [:]

    /// The chat session's model while one of its tool calls runs.
    static func set(_ config: AITaskConfig?, forSession sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        configs[sessionID] = config
    }

    static func config(forSession sessionID: String?) -> AITaskConfig? {
        guard let sessionID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return configs[sessionID]
    }
}

/// The learner's Card Wording Check route (Settings › AI Models ›
/// Background), resolved at each call, or the chat's model when the chat
/// asked for the action (`ChatRequestedModel`).
struct LiveCardWordingBackend: CardWordingBackend {
    let aiService: AIService

    private func config() throws -> AITaskConfig {
        if var chat = ChatRequestedModel.current {
            chat.taskLabel = AITask.cardWordingCheck.rawValue
            return chat
        }
        guard let config = KeychainService.resolveConfig(for: .cardWordingCheck) else {
            throw CardWordingGate.Unavailable(
                message: KeychainService.backgroundAIUnavailableMessage(for: .cardWordingCheck)
                    ?? "No model is set up for Card Wording Check. Sign in and check Settings › AI Models."
            )
        }
        return config
    }

    // Both calls are a verdict or a one-line rewording, so neither asks for
    // thinking. On the chat's model they would otherwise inherit the chat's
    // effort: on Claude Opus 5.5 a one-card check spent 368 of its 400 output
    // tokens on thinking about the card's subject, and a card on a pathogenic
    // mtDNA mutation (3243A>G heteroplasmy) was then stopped by the provider's
    // `content_filter` three times (2026-10-30), though the same model had
    // discussed the paper in the chat. With no thinking the reply is the
    // verdict JSON alone.

    func check(user: String, cardCount: Int, usage: AIUsageSource) async throws -> String {
        let config = try config()
        return try await AIUsageAttribution.withSource(usage, activityID: AIUsageAttribution.activityID ?? UUID().uuidString) {
            try await aiService.call(
                config: config,
                system: AITask.cardWordingCheck.effectivePrompt ?? Prompts.cardWordingCheck,
                user: user,
                maxTokens: CardWordingCheck.maxTokens(cardCount: cardCount),
                temperature: 0,
                disablesReasoning: true,
                jsonMode: true,
                validateResponse: { _ = try CardWordingCheck.verdicts(from: $0, count: cardCount) }
            )
        }
    }

    func reword(user: String, cardCount: Int, answersMayChange: Bool, usage: AIUsageSource) async throws -> String {
        let config = try config()
        return try await AIUsageAttribution.withSource(usage, activityID: AIUsageAttribution.activityID ?? UUID().uuidString) {
            try await aiService.call(
                config: config,
                system: Prompts.cardWordingRewrite,
                user: user,
                maxTokens: CardWordingCheck.maxTokens(cardCount: cardCount) * 2,
                temperature: 0.3,
                disablesReasoning: true,
                allowsResponseCache: false,
                jsonMode: true,
                validateResponse: {
                    _ = try CardWordingCheck.rewordings(from: $0, count: cardCount, answersMayChange: answersMayChange)
                }
            )
        }
    }
}

enum CardWordingGate {
    /// No model to check with, said in the words Settings would use.
    struct Unavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A test's own backend for every gate the task it runs reaches
    /// (`MemoryCardStateStore.bound` is the same shape): a suite that drafts
    /// with canned cards checks them with canned verdicts.
    @TaskLocal static var backendOverride: (any CardWordingBackend)?

    /// The backend a gate uses: a test's, else the learner's route.
    static func backend(aiService: AIService = AIService()) -> any CardWordingBackend {
        backendOverride ?? LiveCardWordingBackend(aiService: aiService)
    }

    /// Every face through the check, a batch a call: those that stand alone
    /// pass, the rest are reworded once and checked again. `answersMayChange`
    /// is false for a kept card, whose answer is its identity. Outcomes come
    /// back in `faces`' order. Throws when the check cannot be made.
    static func screen(
        _ faces: [CardWordingCheck.Face],
        answersMayChange: Bool,
        usage: AIUsageSource,
        backend: any CardWordingBackend
    ) async throws -> [CardWordingCheck.Outcome] {
        var outcomes = [CardWordingCheck.Outcome](repeating: .passed, count: faces.count)
        for start in stride(from: 0, to: faces.count, by: CardWordingCheck.batchSize) {
            try Task.checkCancellation()
            let batch = Array(faces[start..<min(start + CardWordingCheck.batchSize, faces.count)])
            let first = try CardWordingCheck.verdicts(
                from: try await backend.check(user: CardWordingCheck.checkMessage(batch), cardCount: batch.count, usage: usage),
                count: batch.count
            )
            let failing = batch.indices.filter { first[$0 + 1]?.standsAlone == false }
            guard !failing.isEmpty else { continue }
            try Task.checkCancellation()
            let problems = failing.map { first[$0 + 1]?.problem }
            let asked = zip(failing, problems).map { index, problem in
                (face: batch[index], problem: problem ?? "it points at its source without naming it")
            }
            let rewordings = try CardWordingCheck.rewordings(
                from: try await backend.reword(
                    user: CardWordingCheck.rewordMessage(asked, answersMayChange: answersMayChange),
                    cardCount: asked.count,
                    answersMayChange: answersMayChange,
                    usage: usage
                ),
                count: asked.count,
                answersMayChange: answersMayChange
            )
            let reworded: [CardWordingCheck.Face] = failing.enumerated().map { offset, index in
                let rewording = rewordings[offset + 1]
                return CardWordingCheck.Face(
                    front: rewording?.front ?? batch[index].front,
                    back: rewording?.back ?? batch[index].back,
                    sourceTitle: batch[index].sourceTitle
                )
            }
            try Task.checkCancellation()
            let second = try CardWordingCheck.verdicts(
                from: try await backend.check(user: CardWordingCheck.checkMessage(reworded), cardCount: reworded.count, usage: usage),
                count: reworded.count
            )
            for (offset, index) in failing.enumerated() {
                let verdict = second[offset + 1]
                if verdict?.standsAlone == true {
                    outcomes[start + index] = .reworded(front: reworded[offset].front, back: reworded[offset].back)
                } else {
                    outcomes[start + index] = .failed(reason: CardWordingCheck.failureReason(verdict?.problem ?? problems[offset]))
                }
            }
        }
        return outcomes
    }

    /// Drafts through the gate: each kept as written, in its rewording, or
    /// refused with the reason, in the drafts' order. Ids, seeds, quotes and
    /// everything else a draft carries are kept.
    static func screen(
        drafts: [Flashcard],
        sourceTitle: String,
        usage: AIUsageSource,
        backend: any CardWordingBackend
    ) async throws -> (passed: [Flashcard], refused: [CardDraftingAnswer.Refused]) {
        guard !drafts.isEmpty else { return ([], []) }
        let outcomes = try await screen(
            drafts.map { CardWordingCheck.Face(front: $0.front, back: $0.back, sourceTitle: $0.sourceTitle ?? sourceTitle) },
            answersMayChange: true,
            usage: usage,
            backend: backend
        )
        var passed: [Flashcard] = []
        var refused: [CardDraftingAnswer.Refused] = []
        for (draft, outcome) in zip(drafts, outcomes) {
            switch outcome {
            case .passed:
                passed.append(draft)
            case .reworded(let front, let back):
                var card = draft
                card.front = front
                card.back = back
                passed.append(card)
            case .failed(let reason):
                refused.append(CardDraftingAnswer.Refused(front: draft.front, reason: reason))
            }
        }
        return (passed, refused)
    }

    /// A mnemonic reading's questions through the gate: each answered
    /// question becomes a card, so each is held to the same rule. A reworded
    /// question is minted again, since a question's id is its content's.
    static func screen(
        questions: [MnemonicQuestion],
        sourceTitle: String,
        usage: AIUsageSource,
        backend: any CardWordingBackend
    ) async throws -> (passed: [MnemonicQuestion], refused: [MnemonicReadingDrafts.Refused]) {
        guard !questions.isEmpty else { return ([], []) }
        let outcomes = try await screen(
            questions.map { CardWordingCheck.Face(front: $0.question, back: $0.answer, sourceTitle: sourceTitle) },
            answersMayChange: true,
            usage: usage,
            backend: backend
        )
        var passed: [MnemonicQuestion] = []
        var refused: [MnemonicReadingDrafts.Refused] = []
        for (question, outcome) in zip(questions, outcomes) {
            switch outcome {
            case .passed:
                passed.append(question)
            case .reworded(let front, let back):
                passed.append(MnemonicQuestion.mint(
                    sourceID: question.sourceID,
                    quote: question.quote,
                    question: front,
                    answer: back,
                    why: question.why
                ))
            case .failed(let reason):
                refused.append(MnemonicReadingDrafts.Refused(question: question.question, reason: reason))
            }
        }
        return (passed, refused)
    }
}
