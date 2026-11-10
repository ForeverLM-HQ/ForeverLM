import Foundation

// Hands-free review brain for iOS.
//
// Unlike MobileSourceChatService (which answers the user's questions ABOUT a
// source), this drives the inverse loop: it quizzes the learner and grades how
// well they explain the source back. Grading uses the configured task model through
// OpenRouter — the product rule forbids masking AI grading with weak heuristics,
// so this fails loudly if managed sign-in is missing rather than falling back
// to a weaker grader.

struct MobileReviewGap: Equatable {
    let summary: String
    let severity: Double
}

struct MobileReviewTurn: Equatable {
    let spoken: String          // exact words to say to the learner now
    let isComplete: Bool
    let lastEvaluation: String? // short grade of the answer just given (nil on first turn)
    let lastScore: Double?
    let overallScore: Double?   // populated on the final turn
    let summary: String?        // populated on the final turn
    let gaps: [MobileReviewGap]
}

// Identifies the model that actually produced a grade, so the recorded session
// carries true provenance. Provider and model id travel together because they
// are only meaningful as a pair — the Mac reads the provider to interpret the
// model id.
struct MobileReviewModelProvenance: Sendable, Equatable {
    let provider: String
    let modelID: String
}

// Both the cloud brain and the Apple on-device brain drive the same quiz loop:
// begin a review, grade each spoken answer, complete with an honest score. The
// view model holds one engine for the duration of a session so conversation
// state stays intact across turns.
protocol MobileReviewEngine: Sendable {
    /// Read off the engine that ran rather than off the user's grader
    /// preference: makeEngine(for:) can hand back a different engine than the
    /// one selected, and a preference-derived value would then record an
    /// Apple on-device review as the cloud grader.
    func provenance() async throws -> MobileReviewModelProvenance

    func begin(sourceTitle: String, sourceText: String, topic: String) async throws -> MobileReviewTurn
    func answer(_ text: String) async throws -> MobileReviewTurn
    /// Regenerate a normal question if a model violates the no-autonomous-end
    /// contract. The premature closing turn is never spoken to the learner.
    func continueAfterPrematureCompletion() async throws -> MobileReviewTurn
    /// Finalize only after the app has independently recognized an explicit
    /// learner request to stop. Ordinary answer turns never authorize closure.
    func finish() async throws -> MobileReviewTurn
    func reset() async
}

// Which grader runs the hands-free review. This is a deliberate user
// choice, never an automatic fallback: the cloud model (needs managed sign-in)
// or Apple's on-device Foundation Models (private, free, requires iOS 26 +
// Apple Intelligence). The product rule forbids silently downgrading the grader,
// so if the chosen engine cannot run we surface its error rather than swap.
enum MobileReviewGrader: String, CaseIterable, Identifiable, Sendable {
    case claude
    case appleOnDevice

    static let defaultsKey = "foreverlm.grader.v1"
    static let `default`: MobileReviewGrader = .claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Cloud (Settings model)"
        case .appleOnDevice: return "Apple on-device"
        }
    }

    /// Cloud grading requires the managed Apple session; the on-device grader
    /// needs none.
    var requiresManagedSession: Bool { self == .claude }
}

// Availability of Apple's on-device language model, expressed without exposing
// FoundationModels types to callers (the framework is only imported on SDKs that
// ship it, behind canImport in MobileReviewFoundationBrain).
enum MobileAppleGraderAvailability: Sendable, Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    // A short caption explaining the current state, suitable for settings UI.
    var detail: String {
        switch self {
        case .available:
            return "On-device · private · works offline · no API key."
        case .unavailable(let reason):
            return reason
        }
    }
}

// Resolves the concrete engine and reports Apple model availability. Centralizing
// the canImport / #available gating here keeps the view model free of framework
// conditionals.
enum MobileReviewGraderFactory {
    static func makeEngine(for grader: MobileReviewGrader) -> any MobileReviewEngine {
        #if canImport(FoundationModels)
        if grader == .appleOnDevice, #available(iOS 26.0, *) {
            return MobileReviewFoundationBrain()
        }
        #endif
        if grader == .appleOnDevice {
            return UnavailableMobileReviewBrain(
                reason: appleAvailability().detail
            )
        }
        return MobileReviewBrain()
    }

    static func appleAvailability() -> MobileAppleGraderAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return MobileReviewFoundationBrain.availability()
        }
        return .unavailable("On-device grading requires iOS 26 or later.")
        #else
        return .unavailable("This build was compiled without Apple's Foundation Models framework.")
        #endif
    }
}

actor MobileReviewBrain: MobileReviewEngine {
    func provenance() async throws -> MobileReviewModelProvenance {
        guard let route else { throw MobileReviewError.missingResolvedModel }
        return MobileReviewModelProvenance(provider: route.provider, modelID: route.model)
    }

    private let session: URLSession
    private var sourceTitle = ""
    private var sourceText = ""
    private var topic = ""
    private var messages: [(role: String, content: String)] = []
    private var route: ResolvedAITextRoute?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        session = URLSession(configuration: config)
    }

    func begin(sourceTitle: String, sourceText: String, topic: String) async throws -> MobileReviewTurn {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw MobileReviewError.missingSourceText
        }
        self.sourceTitle = sourceTitle
        self.sourceText = String(trimmedText.prefix(60_000))
        self.topic = topic.isEmpty ? sourceTitle : topic
        route = try await MobileModelPreferenceStore.shared.resolve(.mobileReview)
        messages = [(role: "user", content: "Begin the review now. Ask your first question.")]
        return try await runTurn()
    }

    func answer(_ text: String) async throws -> MobileReviewTurn {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append((role: "user", content: trimmed.isEmpty ? "(no answer given)" : trimmed))
        return try await runTurn()
    }

    func finish() async throws -> MobileReviewTurn {
        messages.append((
            role: "user",
            content: "The learner explicitly asked to stop the review. Finish it now with the honest final verdict."
        ))
        return try await runTurn()
    }

    func continueAfterPrematureCompletion() async throws -> MobileReviewTurn {
        messages.append((
            role: "user",
            content: "The learner did not ask to stop. Do not end or say goodbye. Continue the open review with one useful next question and set complete to false."
        ))
        return try await runTurn()
    }

    func reset() {
        sourceTitle = ""
        sourceText = ""
        topic = ""
        messages = []
        route = nil
    }

    private func runTurn() async throws -> MobileReviewTurn {
        guard ManagedAI.isSignedIn else {
            throw MobileReviewError.missingAnthropicKey
        }
        let raw = try await callCloudGrader()
        messages.append((role: "assistant", content: raw))
        return try parseTurn(raw)
    }

    private var systemPrompt: String {
        MobileVoiceReviewPromptContract.instructions(
            sourceTitle: sourceTitle,
            topic: topic,
            sourceText: sourceText
        )
    }

    private func callCloudGrader() async throws -> String {
        guard let route else { throw MobileReviewError.missingResolvedModel }
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: systemPrompt,
            messages: messages,
            maxTokens: 1024,
            jsonMode: true
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileReviewError.badResponse("OpenRouter did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body."
            throw MobileReviewError.badResponse("OpenRouter review request failed (\(http.statusCode)): \(body)")
        }
        let parsed = try MobileOpenRouterChat.text(from: data)
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)

        let trimmed = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MobileReviewError.badResponse("The grader returned an empty response.")
        }
        return trimmed
    }

    private func parseTurn(_ raw: String) throws -> MobileReviewTurn {
        let jsonString = Self.extractJSONObject(from: raw)
        guard let data = jsonString.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MobileReviewError.badResponse("The grader did not return valid review JSON: \(raw)")
        }

        let spoken = (obj["spoken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !spoken.isEmpty else {
            throw MobileReviewError.badResponse("The grader's review JSON had no spoken text.")
        }

        let gaps = (obj["gaps"] as? [[String: Any]])?.compactMap { gap -> MobileReviewGap? in
            guard let summary = (gap["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else { return nil }
            return MobileReviewGap(summary: summary, severity: (gap["severity"] as? Double) ?? 0.5)
        } ?? []

        return MobileReviewTurn(
            spoken: spoken,
            isComplete: (obj["complete"] as? Bool) ?? false,
            lastEvaluation: (obj["lastEvaluation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            lastScore: obj["lastScore"] as? Double,
            overallScore: obj["overallScore"] as? Double,
            summary: (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            gaps: gaps
        )
    }

    // Claude is asked for raw JSON, but strip code fences and isolate the object
    // defensively so a stray ```json wrapper does not break a review mid-drive.
    private static func extractJSONObject(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
            }
        }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor UnavailableMobileReviewBrain: MobileReviewEngine {
    let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func provenance() async throws -> MobileReviewModelProvenance {
        throw MobileReviewError.unavailableSelectedGrader(reason)
    }

    func begin(sourceTitle: String, sourceText: String, topic: String) async throws -> MobileReviewTurn {
        throw MobileReviewError.unavailableSelectedGrader(reason)
    }

    func answer(_ text: String) async throws -> MobileReviewTurn {
        throw MobileReviewError.unavailableSelectedGrader(reason)
    }

    func continueAfterPrematureCompletion() async throws -> MobileReviewTurn {
        throw MobileReviewError.unavailableSelectedGrader(reason)
    }

    func finish() async throws -> MobileReviewTurn {
        throw MobileReviewError.unavailableSelectedGrader(reason)
    }

    func reset() {}
}

enum MobileReviewError: LocalizedError {
    case missingAnthropicKey
    case missingResolvedModel
    case missingSourceText
    case appleModelUnavailable(String)
    case unavailableSelectedGrader(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAnthropicKey:
            return "Sign in with Apple to grade a review."
        case .missingResolvedModel:
            return "The selected review model could not be resolved. No grading request was sent."
        case .missingSourceText:
            return "This source does not have synced text yet. Open it on your Mac so its text syncs to iCloud."
        case .appleModelUnavailable(let reason):
            return "Apple's on-device model can't grade this review right now. \(reason)"
        case .unavailableSelectedGrader(let reason):
            return "The selected on-device grader is unavailable. \(reason)"
        case .badResponse(let message):
            return message
        }
    }
}
