import CryptoKit
import Foundation

// Answers the user's questions ABOUT a source (the inverse of the review quiz
// in MobileReviewBrain, where the app quizzes the user). Compiled into
// the iOS target, which does not build the shared macOS AI stack — so
// MobileOpenRouterChat builds the same cached OpenRouter request locally and
// sends it through the authenticated managed proxy. No provider key is stored.
actor MobileSourceChatService {
    private var sourceTitle: String?
    private var sourceText: String?
    private var usageSource: AIUsageSource?
    private var messages: [MobileSourceChatMessage] = []
    private let session: URLSession
    private var lastBenchmarkValue: MobileSourceChatBenchmark?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        session = URLSession(configuration: config)
    }

    func start(sourceID: String, sourceType: String, sourceTitle: String, sourceText: String) {
        self.sourceTitle = sourceTitle
        self.sourceText = String(sourceText.prefix(DrivingSourceAnswerPlanner.maxSourceCharacters))
        self.usageSource = AIUsageSource(id: sourceID, type: sourceType, title: sourceTitle)
        self.messages = []
    }

    func reset() {
        sourceTitle = nil
        sourceText = nil
        usageSource = nil
        messages = []
        lastBenchmarkValue = nil
    }

    func lastBenchmark() -> MobileSourceChatBenchmark? {
        lastBenchmarkValue
    }

    func send(_ userMessage: String) async throws -> String {
        let totalStart = Date()
        guard let sourceTitle, let sourceText, !sourceText.isEmpty else {
            throw MobileSourceChatError.missingSourceContext
        }
        guard ManagedAI.isSignedIn else {
            throw MobileSourceChatError.missingAIProvider
        }

        let planningStart = Date()
        let prompt = DrivingSourceAnswerPlanner.makePrompt(
            DrivingSourceAnswerRequest(
                sourceTitle: sourceTitle,
                sourceText: sourceText,
                question: userMessage,
                recentMessages: messages
            )
        )
        let planningMilliseconds = MobileBenchmarkClock.milliseconds(since: planningStart)

        messages.append(MobileSourceChatMessage(role: "user", content: userMessage))

        let llmStart = Date()
        guard let usageSource else { throw MobileSourceChatError.missingSourceContext }
        let raw = try await AIUsageAttribution.withSource(
            usageSource,
            activityID: "mobile-source-chat-\(usageSource.id)"
        ) {
            try await complete(prompt: prompt)
        }
        let llmMilliseconds = MobileBenchmarkClock.milliseconds(since: llmStart)
        let trimmed = DrivingSourceAnswerPlanner.spokenAnswer(from: raw)
        guard !trimmed.isEmpty else {
            throw MobileSourceChatError.badResponse("AI provider returned an empty source-chat response.")
        }

        messages.append(MobileSourceChatMessage(role: "assistant", content: trimmed))
        lastBenchmarkValue = MobileSourceChatBenchmark(
            sourceTitle: sourceTitle,
            question: userMessage,
            planningMilliseconds: planningMilliseconds,
            llmMilliseconds: llmMilliseconds,
            totalMilliseconds: MobileBenchmarkClock.milliseconds(since: totalStart),
            promptContextCharacters: prompt.contextCharacterCount,
            selectedPassageCount: prompt.passages.count,
            responseCharacters: trimmed.count
        )
        return trimmed
    }

    private func complete(prompt: DrivingSourceAnswerPrompt) async throws -> String {
        let route = try await MobileModelPreferenceStore.shared.resolve(.chat)
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: prompt.system,
            messages: prompt.messages.map { (role: $0.role, content: $0.content) },
            maxTokens: DrivingSourceAnswerPlanner.responseTokenBudget
        )
        let data = try await perform(
            request,
            providerName: route.provider,
            deniesDataCollection: route.deniesDataCollection
        )
        let parsed = try MobileOpenRouterChat.text(from: data)
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)
        return parsed.text
    }

    private func perform(
        _ originalRequest: URLRequest,
        providerName: String,
        deniesDataCollection: Bool = false
    ) async throws -> Data {
        let (data, response) = try await session.data(for: originalRequest)
        guard let http = response as? HTTPURLResponse else {
            throw MobileSourceChatError.badResponse("\(providerName) did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body."
            // OpenRouter's data-policy refusal answers a switch the learner set
            // in Settings; say so, as the Mac does. The account-level training
            // refusal is translated whatever the switch says. See `AIDataPolicy`.
            // In Free mode the policy that refused is the learner's own
            // OpenRouter account, which has not allowed free endpoints yet.
            if let explanation = AIFreeMode.refusalExplanation(
                forProviderBody: body,
                providerMessage: AIProviderErrorText.fromResponseBody(data)
            ) {
                throw MobileSourceChatError.badResponse(explanation)
            }
            if AIDataPolicy.isTrainingPolicyRefusal(body) {
                throw MobileSourceChatError.badResponse(
                    AIDataPolicy.trainingRefusalExplanation(providerMessage: AIProviderErrorText.fromResponseBody(data))
                )
            }
            if deniesDataCollection, AIDataPolicy.isDataPolicyRefusal(body) {
                let providerMessage = AIProviderErrorText.fromResponseBody(data)
                throw MobileSourceChatError.badResponse(
                    AIDataPolicy.refusalExplanation(providerMessage: providerMessage)
                )
            }
            throw MobileSourceChatError.badResponse(
                AIFreeMode.annotatingBusy("\(providerName) source chat failed (\(http.statusCode)): \(body)", status: http.statusCode)
            )
        }
        return data
    }
}
