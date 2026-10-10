import Foundation

// MARK: - Memory cards: the model calls
//
// docs/memory-design.md, "Drafting" and "Variations". Two tasks, each on the
// learner's own route (Settings › AI Models › Background, Text): Card
// Drafting writes a source's cards from the turn `CardDraftingPlanner` built;
// Card Variation rewords cards that have earned it and, in a call of its own,
// judges every rewording. Every request is sent exactly as built: the
// planner sized it against the route's window, and one the central one-shot
// trim would cut is refused here rather than sent cut.

enum CardDraftingError: LocalizedError, Equatable {
    /// Signed out, no key or plan, or a broken route for the task.
    case noModelConfigured(String)
    /// None of the sources asked for has text to draft from.
    case noSources
    /// The request would not fit the window as sent, so the central trim
    /// would cut the source; refused instead.
    case wouldBeCut(model: String, title: String)

    var errorDescription: String? {
        switch self {
        case .noModelConfigured(let message):
            return message
        case .noSources:
            return "None of these sources has text to draft cards from yet."
        case .wouldBeCut(let model, let title):
            return "\u{201C}\(title)\u{201D} does not fit \(model)'s context window, and nothing is cut. Choose a model with a larger window for Card Drafting."
        }
    }

    /// Why no Card Drafting model is configured, in the words that lead to
    /// the fix.
    static var noModel: CardDraftingError {
        .noModelConfigured(
            KeychainService.backgroundAIUnavailableMessage(for: .cardDrafting)
                ?? "No model is configured for Card Drafting. Sign in and check Settings › AI Models."
        )
    }
}

/// The drafting model, behind a protocol so the service is pinned in tests
/// with canned cards.
protocol CardDraftingBackend: Sendable {
    /// One source's cards, from the turn `plan` built, on the plan's route.
    func draftCards(
        system: String,
        user: String,
        maxTokens: Int,
        source: AIUsageSource,
        route: CardDraftingRoute
    ) async throws -> [CardDraftingModelCard]
}

/// Drafts on the learner's Card Drafting route, as the plan resolved it.
struct LiveCardDraftingBackend: CardDraftingBackend {
    let aiService: AIService

    func draftCards(
        system: String,
        user: String,
        maxTokens: Int,
        source: AIUsageSource,
        route: CardDraftingRoute
    ) async throws -> [CardDraftingModelCard] {
        guard let config = route.writing.config else { throw CardDraftingError.noModel }
        return try await aiService.draftCards(system: system, user: user, maxTokens: maxTokens, source: source, config: config)
    }
}

/// One card's rewordings as the variation model wrote them.
struct CardVariationModelCard: Decodable, Equatable, Sendable {
    let card: Int
    let variants: [String]
}

/// The judge's word on one rewording.
struct CardVariationVerdict: Decodable, Equatable, Sendable {
    let card: Int
    let variant: Int
    /// The card's back answers it completely and correctly, and no more.
    let answersIt: Bool
    /// It states or strongly hints at the answer.
    let leaksAnswer: Bool

    private enum CodingKeys: String, CodingKey {
        case card
        case variant
        case answersIt = "answers_it"
        case leaksAnswer = "leaks_answer"
    }

    init(card: Int, variant: Int, answersIt: Bool, leaksAnswer: Bool) {
        self.card = card
        self.variant = variant
        self.answersIt = answersIt
        self.leaksAnswer = leaksAnswer
    }
}

/// The variation model, behind a protocol so the day close's pass is pinned
/// in tests.
protocol CardVariationBackend: Sendable {
    /// The route both calls run on; nil when no model is configured.
    var route: NotebookWritingRoute? { get }
    func reword(user: String, source: AIUsageSource) async throws -> [CardVariationModelCard]
    func judge(user: String, source: AIUsageSource) async throws -> [CardVariationVerdict]
}

/// Rewords and judges on the learner's Card Variation route.
struct LiveCardVariationBackend: CardVariationBackend {
    let aiService: AIService
    let route: NotebookWritingRoute?

    init(aiService: AIService) {
        self.aiService = aiService
        self.route = KeychainService.resolveConfig(for: .cardVariation).map {
            NotebookWritingRoute.live(
                $0,
                writerMaxTokens: AIService.cardVariationMaxTokens,
                condenserMaxTokens: AIService.cardVariationMaxTokens
            )
        }
    }

    func reword(user: String, source: AIUsageSource) async throws -> [CardVariationModelCard] {
        guard let config = route?.config else { throw CardVariationError.noModel }
        return try await aiService.rewordCards(user: user, source: source, config: config)
    }

    func judge(user: String, source: AIUsageSource) async throws -> [CardVariationVerdict] {
        guard let config = route?.config else { throw CardVariationError.noModel }
        return try await aiService.judgeCardVariants(user: user, source: source, config: config)
    }
}

enum CardVariationError: LocalizedError, Equatable {
    case noModelConfigured(String)
    case wouldBeCut(model: String)

    var errorDescription: String? {
        switch self {
        case .noModelConfigured(let message):
            return message
        case .wouldBeCut(let model):
            return "These cards do not fit \(model)'s context window together, and nothing is cut."
        }
    }

    static var noModel: CardVariationError {
        .noModelConfigured(
            KeychainService.backgroundAIUnavailableMessage(for: .cardVariation)
                ?? "No model is configured for Card Variation. Sign in and check Settings › AI Models."
        )
    }
}

extension AIService {
    /// The response budget of one rewording or judging call: a source's
    /// batch of cards (`CardVariationPass.batchSize`), three rewordings or
    /// verdicts each.
    static let cardVariationMaxTokens = 6_000

    /// One source's drafted cards. Never answered from the response cache:
    /// Make Cards again asks for new cards, not the ones already drafted.
    func draftCards(
        system: String,
        user: String,
        maxTokens: Int,
        source: AIUsageSource,
        config: AITaskConfig
    ) async throws -> [CardDraftingModelCard] {
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = Self.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: system,
            user: user,
            requestedMaxTokens: maxTokens
        )
        guard budgeted.system == system, budgeted.user == user else {
            throw CardDraftingError.wouldBeCut(model: routed.model, title: source.title)
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
            let answer: CardDraftingModelAnswer = try MemoryReviewPlanning.decodeJSON(response)
            return answer.cards
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// Three rewordings of each of a source's cards (`Prompts.cardVariation`).
    func rewordCards(user: String, source: AIUsageSource, config: AITaskConfig) async throws -> [CardVariationModelCard] {
        struct Answer: Decodable { let cards: [CardVariationModelCard] }
        let system = AITask.cardVariation.effectivePrompt ?? Prompts.cardVariation
        let answer: Answer = try await cardVariationCall(system: system, user: user, source: source, config: config, temperature: 0.7)
        return answer.cards
    }

    /// The judge's verdict on every rewording (`Prompts.cardVariationJudge`):
    /// a call of its own, since a model is a poor judge of what it has just
    /// written.
    func judgeCardVariants(user: String, source: AIUsageSource, config: AITaskConfig) async throws -> [CardVariationVerdict] {
        struct Answer: Decodable { let verdicts: [CardVariationVerdict] }
        let answer: Answer = try await cardVariationCall(
            system: Prompts.cardVariationJudge,
            user: user,
            source: source,
            config: config,
            temperature: 0
        )
        return answer.verdicts
    }

    private func cardVariationCall<Answer: Decodable>(
        system: String,
        user: String,
        source: AIUsageSource,
        config: AITaskConfig,
        temperature: Double
    ) async throws -> Answer {
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = Self.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: system,
            user: user,
            requestedMaxTokens: Self.cardVariationMaxTokens
        )
        guard budgeted.system == system, budgeted.user == user else {
            throw CardVariationError.wouldBeCut(model: routed.model)
        }
        let response = try await AIUsageAttribution.withSource(source, activityID: AIUsageAttribution.activityID ?? UUID().uuidString) {
            try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: Self.cardVariationMaxTokens,
                temperature: temperature,
                allowsResponseCache: false,
                jsonMode: true
            )
        }
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
