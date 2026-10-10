import Foundation

#if DEBUG && os(macOS)
/// A real, billable prompt-cache check for debug builds.
///
/// The diagnostic deliberately uses the same request rewrite as production:
/// OpenRouter-shaped request -> `ManagedAI.rewrite` -> authenticated
/// `ai.foreverlm.com` proxy -> OpenRouter. It cannot accept a provider key or
/// construct a provider-direct fallback, so a pass proves the deployed managed
/// rail observed both the cache write and the subsequent cache read.
actor PromptCacheDiagnostic {
    static let shared = PromptCacheDiagnostic()

    struct Result: Sendable, Equatable {
        let model: String
        let firstPromptTokens: Int
        let cacheWriteTokens: Int
        let cachedReadTokens: Int
        let hitRate: Double
        let totalProviderCostUSD: Double
    }

    enum DiagnosticError: LocalizedError, Equatable {
        case noSession
        case routeInvariant
        case requestFailed(status: Int, message: String)
        case invalidResponse
        case promptTooShort(tokens: Int)
        case cacheWriteMissing(tokens: Int)
        case cacheHitMissing(cached: Int, firstPrompt: Int)

        var errorDescription: String? {
            switch self {
            case .noSession:
                return "Sign in with Apple before verifying prompt caching."
            case .routeInvariant:
                return "The cache diagnostic did not resolve to the managed proxy."
            case .requestFailed(let status, let message):
                return message.isEmpty
                    ? "The managed cache request failed (\(status))."
                    : "The managed cache request failed (\(status)): \(message)"
            case .invalidResponse:
                return "OpenRouter returned no parseable cache-usage details."
            case .promptTooShort(let tokens):
                return "The diagnostic prompt was only \(tokens) tokens; at least 4,096 are required."
            case .cacheWriteMissing(let tokens):
                return "The first request reported only \(tokens) cache-write tokens."
            case .cacheHitMissing(let cached, let firstPrompt):
                return "The second request cached only \(cached) of \(firstPrompt) initial prompt tokens."
            }
        }
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }

        struct Usage: Decodable {
            struct PromptDetails: Decodable {
                let cachedTokens: Int?
                let cacheWriteTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case cachedTokens = "cached_tokens"
                    case cacheWriteTokens = "cache_write_tokens"
                }
            }

            let promptTokens: Int?
            let promptTokensDetails: PromptDetails?
            let cost: Double?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case promptTokensDetails = "prompt_tokens_details"
                case cost
            }
        }

        let choices: [Choice]?
        let usage: Usage?
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: String?
            let message: String?
        }
        let error: Payload?
    }

    func run() async throws -> Result {
        guard ManagedAI.sessionToken != nil else { throw DiagnosticError.noSession }
        guard let config = KeychainService.resolveConfig(for: .chat) else {
            throw DiagnosticError.routeInvariant
        }
        let model = OpenRouterModelID.slug(
            provider: config.provider,
            model: config.model
        )

        let runID = UUID().uuidString
        let firstBody = try Self.requestBody(runID: runID, assistantAnswer: nil, model: model)
        let firstData = try await send(firstBody)
        let first = try Self.decodeCompletion(firstData)
        let firstAnswer = first.choices?.first?.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstAnswer, !firstAnswer.isEmpty else {
            throw DiagnosticError.invalidResponse
        }

        let secondBody = try Self.requestBody(runID: runID, assistantAnswer: firstAnswer, model: model)
        let secondData = try await send(secondBody)
        let second = try Self.decodeCompletion(secondData)
        return try Self.validate(first: first, second: second, model: model)
    }

    /// Exact body shape used by both the live diagnostic and unit tests.
    static func requestBody(
        runID: String,
        assistantAnswer: String?,
        model: String = AIModelDefaults.promptCacheDiagnosticFixture
    ) throws -> Data {
        let paper = extractedPaperFixture(runID: runID)
        let systemContent: [[String: Any]] = [[
            "type": "text",
            "text": "You are discussing the attached paper.\n\n\(paper)",
            "cache_control": ["type": "ephemeral", "ttl": "1h"],
        ]]
        let opening = "Acknowledge the paper in at most five words."
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemContent],
            ["role": "user", "content": opening],
        ]
        if let assistantAnswer {
            messages.append(["role": "assistant", "content": assistantAnswer])
            messages.append([
                "role": "user",
                "content": "Name the study design in at most five words.",
            ])
        }
        let payload: [String: Any] = [
            "model": model,
            "session_id": "cache-diagnostic-\(runID)",
            "messages": messages,
            "max_tokens": 16,
            "temperature": 0,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func validate(
        firstData: Data,
        secondData: Data,
        model: String = AIModelDefaults.promptCacheDiagnosticFixture
    ) throws -> Result {
        try validate(
            first: decodeCompletion(firstData),
            second: decodeCompletion(secondData),
            model: model
        )
    }

    private func send(_ body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ForeverLM Cache Diagnostic", forHTTPHeaderField: "X-Title")
        request.httpBody = body
        try ManagedAI.rewrite(&request)

        guard request.url?.host == ManagedAI.baseURL.host,
              request.url?.path == "/v1/proxy/openrouter/api/v1/chat/completions",
              request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true else {
            throw DiagnosticError.routeInvariant
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiagnosticError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
            if error?.code == "invalid_session" {
                ManagedAI.clearSession()
            }
            let message = error?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DiagnosticError.requestFailed(status: http.statusCode, message: message)
        }
        return data
    }

    private static func decodeCompletion(_ data: Data) throws -> CompletionResponse {
        do {
            return try JSONDecoder().decode(CompletionResponse.self, from: data)
        } catch {
            throw DiagnosticError.invalidResponse
        }
    }

    private static func validate(
        first: CompletionResponse,
        second: CompletionResponse,
        model: String
    ) throws -> Result {
        guard let firstUsage = first.usage, let secondUsage = second.usage else {
            throw DiagnosticError.invalidResponse
        }
        let firstPrompt = firstUsage.promptTokens ?? 0
        let written = firstUsage.promptTokensDetails?.cacheWriteTokens ?? 0
        let cached = secondUsage.promptTokensDetails?.cachedTokens ?? 0
        guard firstPrompt >= 4_096 else {
            throw DiagnosticError.promptTooShort(tokens: firstPrompt)
        }
        guard written >= 4_096 else {
            throw DiagnosticError.cacheWriteMissing(tokens: written)
        }
        guard cached >= 4_096, Double(cached) >= Double(firstPrompt) * 0.8 else {
            throw DiagnosticError.cacheHitMissing(cached: cached, firstPrompt: firstPrompt)
        }
        return Result(
            model: model,
            firstPromptTokens: firstPrompt,
            cacheWriteTokens: written,
            cachedReadTokens: cached,
            hitRate: Double(cached) / Double(firstPrompt),
            totalProviderCostUSD: (firstUsage.cost ?? 0) + (secondUsage.cost ?? 0)
        )
    }

    private static func extractedPaperFixture(runID: String) -> String {
        let paragraph = "The experiment compares retrieval practice with repeated study. "
            + "Methods, observations, confidence intervals, limitations, and replication details remain fixed. "
        let sections = (1...240).map { index in
            "Section \(index). \(String(repeating: paragraph, count: 3))"
        }
        return (["PAPER-TEXT-START", "Diagnostic run \(runID)"] + sections + ["PAPER-TEXT-END"])
            .joined(separator: "\n\n")
    }
}
#endif
