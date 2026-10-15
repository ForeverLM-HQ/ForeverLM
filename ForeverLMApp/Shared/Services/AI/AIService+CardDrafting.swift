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

extension AIService {
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

    /// The response budget of one source-linking call: a pick and its quote
    /// for each of `CardSourceLinking.cardsPerCall` cards.
    static let cardSourceLinkingMaxTokens = 3_000

    /// Which candidate passages state each card (`Prompts.cardSourceLinking`),
    /// on the Card Drafting route: a card's other sources are part of drafting
    /// it. Never answered from the response cache, and sent exactly as built.
    func linkCardSources(
        user: String,
        source: AIUsageSource,
        config: AITaskConfig
    ) async throws -> [CardSourceLinkingVerdict] {
        let system = Prompts.cardSourceLinking
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = Self.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: system,
            user: user,
            requestedMaxTokens: Self.cardSourceLinkingMaxTokens
        )
        guard budgeted.system == system, budgeted.user == user else {
            throw CardDraftingError.wouldBeCut(model: routed.model, title: source.title)
        }
        let response = try await AIUsageAttribution.withSource(source, activityID: AIUsageAttribution.activityID ?? UUID().uuidString) {
            try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: Self.cardSourceLinkingMaxTokens,
                temperature: 0,
                allowsResponseCache: false,
                jsonMode: true
            )
        }
        do {
            let answer: CardSourceLinkingAnswer = try MemoryReviewPlanning.decodeJSON(response)
            return answer.cards
        } catch {
            throw AIError.invalidResponse
        }
    }
}
