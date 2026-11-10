import Foundation

// Target-agnostic AI usage accounting: the usage report, response parsers,
// list-price table, and the persisted event shape. This file is compiled into
// the macOS and iOS targets (Foundation only — no CloudKit, SQLite,
// or app-model dependencies) so every platform stamps costs with the same
// pricing table and encodes the exact same Codable payload. The ledger writer
// lives in AIUsageTracking.swift, on the Mac alone: the phone writes no usage
// to CloudKit, and the Mac's ledger is its own (docs/cloudkit-schema-design.md
// §14.1).

struct AIUsageReport: Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedInputTokens: Int?
    var cacheCreationInputTokens: Int?
    /// Anthropic `cache_creation.ephemeral_5m_input_tokens` — cache writes with
    /// a 5-minute TTL, billed at 1.25x base input. Cost-computation detail only;
    /// the persisted event keeps the combined `cacheCreationInputTokens` and the
    /// split stays inspectable in `rawUsageJSON`.
    var cacheWrite5mInputTokens: Int?
    /// Anthropic `cache_creation.ephemeral_1h_input_tokens` — cache writes with
    /// a 1-hour TTL, billed at 2x base input (not 1.25x).
    var cacheWrite1hInputTokens: Int?
    var reasoningTokens: Int?
    var audioInputTokens: Int?
    var audioOutputTokens: Int?
    /// Gemini image-generation output tokens (candidatesTokensDetails, IMAGE
    /// modality) — billed at a separate per-1M rate from text output.
    var imageOutputTokens: Int?
    var imageCount: Int?
    var totalTokens: Int?
    var characterCount: Int?
    var durationSeconds: Double?
    /// Wall-clock milliseconds the call took as this client saw it, request
    /// sent to response received. Recorded so slowness is read from the same
    /// ledger as cost; nil on call paths that do not time themselves.
    var latencyMilliseconds: Int?
    /// Server-side web-search tool invocations (Anthropic
    /// `server_tool_use.web_search_requests`, OpenAI Responses
    /// `web_search_call` output items) — billed per call, on top of tokens.
    var webSearchCalls: Int?
    /// True when the call went through a provider Batch API (Anthropic, OpenAI,
    /// and Gemini all bill batch at 50% of list price). Set by the call site —
    /// batch responses don't self-identify.
    var billedAtBatchRates: Bool = false
    var providerReportedCost: Double?
    var currency: String?
    var rawUsageJSON: String?
    /// Model id the provider says actually served the response (Anthropic top-level
    /// `model` / stream `message.model`, OpenAI top-level `model`). Can differ from
    /// the requested id when the API substitutes another model — e.g. a
    /// claude-fable-5 request answered by Opus under load.
    var servedModel: String?

    static let empty = AIUsageReport()

    init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheWrite5mInputTokens: Int? = nil,
        cacheWrite1hInputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        audioInputTokens: Int? = nil,
        audioOutputTokens: Int? = nil,
        imageOutputTokens: Int? = nil,
        imageCount: Int? = nil,
        totalTokens: Int? = nil,
        characterCount: Int? = nil,
        durationSeconds: Double? = nil,
        latencyMilliseconds: Int? = nil,
        webSearchCalls: Int? = nil,
        billedAtBatchRates: Bool = false,
        providerReportedCost: Double? = nil,
        currency: String? = nil,
        rawUsageJSON: String? = nil,
        servedModel: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheWrite5mInputTokens = cacheWrite5mInputTokens
        self.cacheWrite1hInputTokens = cacheWrite1hInputTokens
        self.reasoningTokens = reasoningTokens
        self.audioInputTokens = audioInputTokens
        self.audioOutputTokens = audioOutputTokens
        self.imageOutputTokens = imageOutputTokens
        self.imageCount = imageCount
        self.totalTokens = totalTokens
        self.characterCount = characterCount
        self.durationSeconds = durationSeconds
        self.latencyMilliseconds = latencyMilliseconds
        self.webSearchCalls = webSearchCalls
        self.billedAtBatchRates = billedAtBatchRates
        self.providerReportedCost = providerReportedCost
        self.currency = currency
        self.rawUsageJSON = rawUsageJSON
        self.servedModel = servedModel
    }

    /// True when the provider reported anything the user could have been billed
    /// for. Gates recording on failed/cancelled streams: a request that died
    /// before any usage was observed leaves no evidence of billing and would
    /// only pollute the ledger with empty rows.
    var hasBillableUsage: Bool {
        func positive(_ value: Int?) -> Bool { (value ?? 0) > 0 }
        return positive(inputTokens) || positive(outputTokens)
            || positive(cachedInputTokens) || positive(cacheCreationInputTokens)
            || positive(cacheWrite5mInputTokens) || positive(cacheWrite1hInputTokens)
            || positive(reasoningTokens)
            || positive(audioInputTokens) || positive(audioOutputTokens)
            || positive(imageOutputTokens) || positive(imageCount)
            || positive(totalTokens) || positive(characterCount)
            || positive(webSearchCalls)
            || (durationSeconds ?? 0) > 0
            || (providerReportedCost ?? 0) > 0
    }

    /// Sums another report into this one. Use for combining *independent*
    /// requests (e.g. per-chunk batch results); streaming events for one
    /// request report cumulative totals and must use `merge` instead.
    mutating func accumulate(_ other: AIUsageReport?) {
        guard let other else { return }
        func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            if lhs == nil && rhs == nil { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }
        func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
            if lhs == nil && rhs == nil { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }
        inputTokens = sum(inputTokens, other.inputTokens)
        outputTokens = sum(outputTokens, other.outputTokens)
        cachedInputTokens = sum(cachedInputTokens, other.cachedInputTokens)
        cacheCreationInputTokens = sum(cacheCreationInputTokens, other.cacheCreationInputTokens)
        cacheWrite5mInputTokens = sum(cacheWrite5mInputTokens, other.cacheWrite5mInputTokens)
        cacheWrite1hInputTokens = sum(cacheWrite1hInputTokens, other.cacheWrite1hInputTokens)
        reasoningTokens = sum(reasoningTokens, other.reasoningTokens)
        audioInputTokens = sum(audioInputTokens, other.audioInputTokens)
        audioOutputTokens = sum(audioOutputTokens, other.audioOutputTokens)
        imageOutputTokens = sum(imageOutputTokens, other.imageOutputTokens)
        imageCount = sum(imageCount, other.imageCount)
        totalTokens = sum(totalTokens, other.totalTokens)
        characterCount = sum(characterCount, other.characterCount)
        durationSeconds = sum(durationSeconds, other.durationSeconds)
        // Independent requests ran one after another, so their times add.
        latencyMilliseconds = sum(latencyMilliseconds, other.latencyMilliseconds)
        webSearchCalls = sum(webSearchCalls, other.webSearchCalls)
        billedAtBatchRates = billedAtBatchRates || other.billedAtBatchRates
        providerReportedCost = sum(providerReportedCost, other.providerReportedCost)
        currency = currency ?? other.currency
        servedModel = servedModel ?? other.servedModel
        // Per-chunk raw payloads don't aggregate meaningfully; keep none rather
        // than a misleading single chunk's JSON.
        rawUsageJSON = nil
    }

    mutating func merge(_ other: AIUsageReport?) {
        guard let other else { return }
        inputTokens = max(inputTokens, other.inputTokens)
        outputTokens = max(outputTokens, other.outputTokens)
        cachedInputTokens = max(cachedInputTokens, other.cachedInputTokens)
        cacheCreationInputTokens = max(cacheCreationInputTokens, other.cacheCreationInputTokens)
        cacheWrite5mInputTokens = max(cacheWrite5mInputTokens, other.cacheWrite5mInputTokens)
        cacheWrite1hInputTokens = max(cacheWrite1hInputTokens, other.cacheWrite1hInputTokens)
        reasoningTokens = max(reasoningTokens, other.reasoningTokens)
        audioInputTokens = max(audioInputTokens, other.audioInputTokens)
        audioOutputTokens = max(audioOutputTokens, other.audioOutputTokens)
        imageOutputTokens = max(imageOutputTokens, other.imageOutputTokens)
        imageCount = max(imageCount, other.imageCount)
        totalTokens = max(totalTokens, other.totalTokens)
        characterCount = max(characterCount, other.characterCount)
        durationSeconds = max(durationSeconds, other.durationSeconds)
        latencyMilliseconds = max(latencyMilliseconds, other.latencyMilliseconds)
        webSearchCalls = max(webSearchCalls, other.webSearchCalls)
        billedAtBatchRates = billedAtBatchRates || other.billedAtBatchRates
        providerReportedCost = max(providerReportedCost, other.providerReportedCost)
        currency = currency ?? other.currency
        rawUsageJSON = other.rawUsageJSON ?? rawUsageJSON
        servedModel = servedModel ?? other.servedModel
    }

    /// The served model when it names a genuinely different model than the one
    /// requested — the provider-substitution case. A dated snapshot of the
    /// requested alias (claude-sonnet-5 → claude-sonnet-5-20260203) is the same
    /// model and returns nil, so callers record the requested id for normal calls
    /// and the served id only for real substitutions.
    func servedModelIfDifferent(fromRequested requested: String) -> String? {
        guard let servedModel else { return nil }
        guard Self.canonicalModelID(servedModel) != Self.canonicalModelID(requested) else { return nil }
        return servedModel
    }

    /// The served model when the caller must reject the answer: a substitution
    /// of a model the request named. OpenRouter's routers (`openrouter/free`,
    /// `openrouter/auto`) choose the model per request, so any model they
    /// serve is the one asked for, except that the Free Models Router must
    /// land on a free model: anything else would bill a learner who picked it
    /// to pay nothing. The ledger still records the served model.
    func rejectedSubstitution(fromRequested requested: String) -> String? {
        guard let served = servedModelIfDifferent(fromRequested: requested) else { return nil }
        guard Self.isOpenRouterRouter(requested) else { return served }
        let router = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if router == AIModelDefaults.openRouterFreeRouter {
            return AIFreeModels.isFreeModelID(served) ? nil : served
        }
        return nil
    }

    /// The served model when a router picked a safety classifier for the work.
    /// On 2026-09-27 (a slide) and again on 2026-10-06 (two papers' metadata)
    /// the Free Models Router chose `nvidia/nemotron-3.5-content-safety:free`,
    /// whose whole reply was "User Safety: safe". A model the learner named
    /// is held to their choice; only a router's pick is judged.
    func routedSafetyClassifier(fromRequested requested: String) -> String? {
        guard Self.isOpenRouterRouter(requested),
              let served = servedModelIfDifferent(fromRequested: requested),
              Self.isSafetyClassifier(served) else { return nil }
        return served
    }

    /// OpenRouter's routers (`openrouter/free`, `openrouter/auto`) choose the
    /// model per request rather than naming one.
    static func isOpenRouterRouter(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("openrouter/")
    }

    /// Models built only to rate text as safe or unsafe: NVIDIA's content-safety
    /// Nemotrons and NemoGuard, Meta's Llama Guard, IBM's Granite Guardian,
    /// OpenAI's gpt-oss-safeguard and Google's ShieldGemma. Each family says so
    /// in its slug, which is the only place OpenRouter's directory says it.
    static func isSafetyClassifier(_ model: String) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["content-safety", "guard", "shieldgemma"].contains { id.contains($0) }
    }

    private static func canonicalModelID(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Managed OpenRouter responses may include the maker namespace while a
        // provider-shaped request uses the provider-native id. The final slug
        // is still the same selected model, not a substitution.
        if let finalComponent = id.split(separator: "/").last {
            id = String(finalComponent)
        }
        for pattern in ["-\\d{4}-\\d{2}-\\d{2}$", "-\\d{8}$"] {
            if let range = id.range(of: pattern, options: .regularExpression) {
                id.removeSubrange(range)
            }
        }
        return id
    }

    private func max<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): return Swift.max(lhs, rhs)
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.none, .none): return nil
        }
    }
}

enum AIUsageParser {
    static func report(from json: [String: Any]) -> AIUsageReport? {
        var base: AIUsageReport?
        if let response = json["response"] as? [String: Any] {
            // Responses SSE terminal events wrap the billable response (usage,
            // served model, and web-search output items) under `response`.
            base = report(from: response)
        } else if let usage = json["usage"] as? [String: Any] {
            base = report(fromUsageObject: usage)
        } else if let metadata = json["usageMetadata"] as? [String: Any] {
            base = report(fromGeminiUsageMetadata: metadata)
        } else if let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] {
            base = report(fromUsageObject: usage)
        } else if let groq = json["x_groq"] as? [String: Any],
                  let usage = groq["usage"] as? [String: Any] {
            // Groq streams deliver usage nested under x_groq in the final chunk.
            base = report(fromUsageObject: usage)
        }

        // OpenAI Responses API: web-search tool calls are output items, not a
        // usage field, and each one is billed per call on top of tokens.
        if let output = json["output"] as? [[String: Any]] {
            let searchCalls = output.filter { ($0["type"] as? String) == "web_search_call" }.count
            if searchCalls > 0 {
                var augmented = base ?? .empty
                augmented.webSearchCalls = max(augmented.webSearchCalls ?? 0, searchCalls)
                base = augmented
            }
        }
        if let servedModel = servedModel(from: json) {
            base?.servedModel = servedModel
        }
        return base
    }

    /// Model id the provider reports it actually used: top level on Anthropic and
    /// OpenAI responses, inside `message` on Anthropic stream `message_start` events.
    static func servedModel(from json: [String: Any]) -> String? {
        let raw = (json["model"] as? String)
            ?? ((json["message"] as? [String: Any])?["model"] as? String)
        guard let model = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return nil }
        return model
    }

    static func report(fromUsageObject usage: [String: Any]) -> AIUsageReport {
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        let outputDetails = usage["output_tokens_details"] as? [String: Any]
        // Anthropic itemizes cache writes by TTL: 5-minute writes bill at 1.25x
        // base input, 1-hour writes at 2x.
        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let cacheWrite5m = int(cacheCreation?["ephemeral_5m_input_tokens"])
        let cacheWrite1h = int(cacheCreation?["ephemeral_1h_input_tokens"])
        let serverToolUse = usage["server_tool_use"] as? [String: Any]
        let costDetails = usage["cost_details"] as? [String: Any]

        return AIUsageReport(
            inputTokens: int(usage["input_tokens"]) ?? int(usage["prompt_tokens"]),
            outputTokens: int(usage["output_tokens"]) ?? int(usage["completion_tokens"]),
            cachedInputTokens: int(usage["cache_read_input_tokens"])
                ?? int(inputDetails?["cached_tokens"])
                ?? int(promptDetails?["cached_tokens"]),
            cacheCreationInputTokens: int(usage["cache_creation_input_tokens"])
                ?? sum(cacheWrite5m, cacheWrite1h)
                // OpenRouter reports Anthropic-style cache writes as
                // prompt_tokens_details.cache_write_tokens.
                ?? int(promptDetails?["cache_write_tokens"]),
            cacheWrite5mInputTokens: cacheWrite5m,
            cacheWrite1hInputTokens: cacheWrite1h,
            reasoningTokens: int(completionDetails?["reasoning_tokens"])
                ?? int(outputDetails?["reasoning_tokens"]),
            audioInputTokens: int(inputDetails?["audio_tokens"])
                ?? int(promptDetails?["audio_tokens"]),
            audioOutputTokens: int(completionDetails?["audio_tokens"])
                ?? int(outputDetails?["audio_tokens"]),
            totalTokens: int(usage["total_tokens"]),
            webSearchCalls: int(serverToolUse?["web_search_requests"]),
            // `cost` is what OpenRouter charged us. On a BYOK route
            // (`is_byok: true`) that is a real, final zero — inference was
            // billed straight to the upstream provider key instead — so the
            // amount actually spent is `cost_details.upstream_inference_cost`.
            // Preferring it over the list-price estimate keeps BYOK rows exact
            // rather than approximated.
            providerReportedCost: billedCost(usage["cost"])
                ?? billedCost(costDetails?["upstream_inference_cost"])
                ?? billedCost(usage["total_cost"])
                ?? billedCost(usage["totalCost"]),
            currency: usage["currency"] as? String,
            rawUsageJSON: rawJSONString(usage)
        )
    }

    static func report(fromGeminiUsageMetadata metadata: [String: Any]) -> AIUsageReport {
        AIUsageReport(
            inputTokens: int(metadata["promptTokenCount"]),
            outputTokens: int(metadata["candidatesTokenCount"]),
            cachedInputTokens: int(metadata["cachedContentTokenCount"]),
            reasoningTokens: int(metadata["thoughtsTokenCount"]),
            audioInputTokens: modalityTokens("AUDIO", in: metadata["promptTokensDetails"]),
            audioOutputTokens: modalityTokens("AUDIO", in: metadata["candidatesTokensDetails"]),
            imageOutputTokens: modalityTokens("IMAGE", in: metadata["candidatesTokensDetails"]),
            totalTokens: int(metadata["totalTokenCount"]),
            providerReportedCost: billedCost(metadata["cost"])
                ?? billedCost(metadata["totalCost"]),
            currency: metadata["currency"] as? String,
            rawUsageJSON: rawJSONString(metadata)
        )
    }

    /// Gemini reports per-modality token splits as
    /// `[{"modality": "AUDIO", "tokenCount": 123}, …]`. Audio (TTS) and image
    /// output tokens carry their own per-1M rates, so they must be separable
    /// from text output.
    private static func modalityTokens(_ modality: String, in details: Any?) -> Int? {
        guard let entries = details as? [[String: Any]] else { return nil }
        var total: Int?
        for entry in entries where (entry["modality"] as? String)?.uppercased() == modality {
            total = (total ?? 0) + (int(entry["tokenCount"]) ?? 0)
        }
        return total
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        if lhs == nil && rhs == nil { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    static func report(fromTranscriptionResponse json: [String: Any]) -> AIUsageReport {
        var result = Self.report(from: json) ?? .empty
        // Whisper-style verbose responses carry the billable audio length as a
        // top-level `duration` (seconds); usage objects may nest it instead.
        let usage = json["usage"] as? [String: Any]
        result.durationSeconds = double(json["duration"])
            ?? double(usage?["duration"])
            ?? double(usage?["seconds"])
            ?? result.durationSeconds
        return result
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// A provider-reported cost, or nil when the provider reported nothing
    /// usable. A zero is treated as "not reported" rather than as a real price.
    /// It is not that the number is wrong — on a BYOK route OpenRouter really
    /// did charge us nothing — but that it is the wrong number to show as the
    /// call's cost, since inference was still billed upstream. Dropping it lets
    /// the caller fall through to the upstream amount, then to the estimate.
    private static func billedCost(_ value: Any?) -> Double? {
        guard let cost = double(value), cost > 0 else { return nil }
        return cost
    }

    /// True when a stored OpenRouter usage object says the call cost nothing
    /// anywhere: `cost` is an explicit zero, the route was not BYOK, and no
    /// upstream inference was billed either. That is OpenRouter's own final
    /// word — a free model, or a generation that ended before anything was
    /// charged — so it is a real zero, unlike the BYOK zero `billedCost`
    /// drops. The bare zero alone is not enough; the other two fields are what
    /// rule out spend that was billed somewhere else.
    static func openRouterBilledNothing(rawUsageJSON: String?) -> Bool {
        guard let data = rawUsageJSON?.data(using: .utf8),
              let usage = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cost = double(usage["cost"]), cost == 0,
              usage["is_byok"] as? Bool == false else {
            return false
        }
        let upstream = (usage["cost_details"] as? [String: Any])?["upstream_inference_cost"]
        guard let upstream, !(upstream is NSNull) else { return true }
        return double(upstream) == 0
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func rawJSONString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Ambient attribution for the usage ledger: the chat/review session the
/// current task's AI calls are billed to. The chat harness binds it around a
/// turn's work; `AIUsageTracker.record` reads it at record time. Task-local
/// values flow into child and unstructured `Task {}` closures (not detached
/// tasks), so nested calls — provider streams, history compaction, grading —
/// attribute to the session without threading an ID through every signature.
enum AIUsageAttribution {
    @TaskLocal static var sessionID: String?
    /// What feature the current call serves — an `AITask` rawValue for
    /// configured steps, or a purpose label like "chat" or "read_aloud" for
    /// paths without one. The `AIService` entry points bind it from
    /// `AITaskConfig.taskLabel`, so the transport and stream recorders deep
    /// below pick it up the same way they pick up `sessionID`; call sites
    /// that record directly pass it as an argument instead.
    @TaskLocal static var task: String?
    /// Human-facing title of the source a background request is processing.
    /// This is sent to the managed billing ledger so a charge can identify the
    /// article, paper, or book behind it. It does not participate in source
    /// identity and is intentionally absent for calls that do not serve one
    /// source (for example chat).
    @TaskLocal static var sourceTitle: String?
    /// Stable identity for the item a task is processing. Titles are display
    /// metadata only; usage grouping must prefer this deterministic ID so a
    /// rename cannot split one item or merge two items with the same title.
    @TaskLocal static var subjectID: String?
    /// Names the subject namespace (for example "podcast_episode", "video",
    /// "source", or "review_session") so IDs from different domains never
    /// collide in the usage ledger.
    @TaskLocal static var subjectType: String?
    /// One invocation of a user-visible workflow. A formatting run can make
    /// many chunk calls for one episode; all of those calls share this ID.
    @TaskLocal static var activityID: String?
    /// The learner asked for this work themselves (pressed Listen), so a step
    /// they stopped in the background-work list still runs for it: the stop
    /// was meant for the work running on its own (`AIInFlightCalls.stop`).
    @TaskLocal static var learnerAsked = false

    /// Resolves the ledger's mandatory activity identity without inventing
    /// meaning: explicit workflow identity wins, then chat/review session
    /// identity, and a one-call workflow falls back to its immutable event id.
    static func resolvedActivityID(
        _ explicit: String?,
        sessionID: String?,
        fallback: String
    ) -> String {
        for candidate in [explicit, sessionID] {
            let clean = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !clean.isEmpty { return clean }
        }
        return fallback
    }

    /// Establishes one source-bound workflow context. Every nested managed AI
    /// request and every local usage recorder inherits this through Swift task
    /// locals, including child tasks created for transcript chunks or slides.
    /// Source-specific services accept `AIUsageSource` explicitly so omitting
    /// attribution is a compile-time error at their call sites.
    static func withSource<Result>(
        _ source: AIUsageSource,
        activityID explicitActivityID: String = UUID().uuidString,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $activityID.withValue(explicitActivityID) {
            try await $subjectType.withValue(source.type) {
                try await $subjectID.withValue(source.id) {
                    try await $sourceTitle.withValue(source.title) {
                        try await operation()
                    }
                }
            }
        }
    }
}

/// Deterministic identity and display metadata for one stored source. Identity
/// always comes from the source record's ID; a title is never promoted into an
/// ID, so renames and duplicate titles cannot reshuffle accounting history.
struct AIUsageSource: Sendable, Equatable {
    let id: String
    let type: String
    let title: String

    init(id: String, type: String, title: String) {
        precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        precondition(!type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.id = id
        self.type = type
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Opt-in for exact response replay on deterministic, single-turn AITasks.
/// Interactive chat never binds this value. The managed proxy requires both
/// this policy and a task label before it enables OpenRouter response caching.
enum AIResponseCachePolicy {
    @TaskLocal static var deterministic = false
}

/// One recorded AI API call. Persisted in the Mac's `ai_usage_events` SQLite
/// ledger; mobile targets author the same shape as an `AIUsageEvent` CKRecord
/// that the Mac ingests. Keep the Codable keys stable — they are the CloudKit
/// payload contract between devices.
struct AIUsageEvent: Identifiable, Codable, Sendable {
    let id: String
    let provider: String
    let model: String
    let operation: String
    /// The feature this call served — an `AITask` rawValue
    /// ("slide_citation_extraction") or a purpose label ("chat",
    /// "read_aloud"). Distinct from `operation`, which names the API shape
    /// (text_completion, tool_completion), not why it was made. Nil for rows
    /// recorded before the column existed, which stay untagged rather than
    /// backfilled — the same stance as `sessionID`.
    let task: String?
    /// `review_sessions` row this call was made for, when the call happened
    /// inside a chat/review session (see `AIUsageAttribution`). Nil for
    /// background work — and for every row recorded before the column existed,
    /// which stays unattributed rather than backfilled.
    let sessionID: String?
    /// One user-visible workflow invocation. Nil for historical rows and call
    /// paths that have not yet adopted activity attribution.
    var activityID: String? = nil
    /// Deterministic identity of the item being processed. Never derived from
    /// `subjectTitle`; nil on historical and non-item-bound calls.
    var subjectID: String? = nil
    /// Namespace for `subjectID`, such as "podcast_episode" or "video".
    var subjectType: String? = nil
    /// Human-facing item title for drill-down display. It may change and never
    /// participates in stored source identity.
    var subjectTitle: String? = nil
    let createdAt: Date
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let reasoningTokens: Int?
    let audioInputTokens: Int?
    let audioOutputTokens: Int?
    let imageCount: Int?
    let totalTokens: Int?
    /// Billable input characters for character-priced APIs (TTS).
    let characterCount: Int?
    /// Billable audio duration for time-priced APIs (STT).
    let durationSeconds: Double?
    let providerReportedCost: Double?
    /// USD cost estimated from the pricing table at record time; nil when no
    /// rate is known for the provider/model.
    let estimatedCost: Double?
    let currency: String?
    let rawUsageJSON: String?
    /// Device family that originated the request ("macOS", "iOS", etc.).
    /// Older local rows and proxy rows recorded before platform attribution
    /// remain nil rather than being guessed.
    var clientPlatform: String? = nil
    /// D1's immutable managed_ai_ledger id. Present only on rows reconciled
    /// from the proxy, which are authoritative for managed billing.
    var serverLedgerID: Int64? = nil
    /// Proxy/OpenRouter reconciliation id for operator diagnostics.
    var serverRequestID: String? = nil
    /// How long the call took as the client saw it, in milliseconds. Nil on
    /// rows recorded before the column existed and on call paths that do not
    /// time themselves; a nil is "unmeasured", never "instant".
    var latencyMilliseconds: Int? = nil
    /// True when the learner's own router key paid for this call **and** the
    /// call went straight to that router.
    ///
    /// Both halves matter. The proxy never saw such a call, so no
    /// authoritative server row will ever arrive to stand in for it, which is
    /// why `aiUsageAccountingRowPredicate` keeps these rows even inside a
    /// period the server otherwise covers. A key the proxy spends on the
    /// learner's behalf instead (see `ManagedAI.OwnKeyRouter.sendsDirect`)
    /// does produce a server row, so its client row stays false and keeps
    /// deferring — otherwise the pane would count that call twice.
    ///
    /// Optional rather than a defaulted `Bool` because the synthesized decoder
    /// does not apply property defaults: a payload written by a build from
    /// before the column would fail to decode outright. Nil is a row recorded
    /// before the direct rail existed, which by definition went through the
    /// proxy — `paidByOwnKey` is the question every caller should ask.
    var ownKey: Bool? = nil

    /// `ownKey` with the historical reading applied: a row that predates the
    /// flag went through the proxy.
    var paidByOwnKey: Bool { ownKey == true }

    /// True when the row records at least one quantity a provider could bill
    /// for. A row with none of them describes a call that consumed nothing.
    var hasPositiveBillableQuantity: Bool {
        func positive(_ value: Int?) -> Bool { (value ?? 0) > 0 }
        return positive(inputTokens) || positive(outputTokens)
            || positive(cachedInputTokens) || positive(cacheCreationInputTokens)
            || positive(reasoningTokens)
            || positive(audioInputTokens) || positive(audioOutputTokens)
            || positive(imageCount) || positive(totalTokens)
            || positive(characterCount)
            || (durationSeconds ?? 0) > 0
    }

    /// What this call cost, for both display and totals: the amount the
    /// provider actually billed when it reported a real one, else the
    /// list-price estimate stamped at record time. A reported zero does not
    /// outrank an estimate — see `AIUsageParser.billedCost`, where zero means
    /// "not reported" — but when there is no estimate either and the row
    /// reports no billable quantity at all, zero is the honest answer rather
    /// than a missing one: nothing was consumed, so nothing could be charged.
    /// Nil is then reserved for calls whose cost is genuinely unknown.
    ///
    /// `KnowledgeStore.aiUsageEventCostExpression` is this rule in SQL; the two
    /// must stay in step or a row's own cost and the period total disagree.
    var accountedCostUSD: Double? {
        if let reported = providerReportedCost, reported > 0 { return reported }
        if let estimatedCost { return estimatedCost }
        if providerReportedCost == 0, !hasPositiveBillableQuantity { return 0 }
        return nil
    }

    /// The `estimated_cost` the ledger stores for this row. Every write goes
    /// through `KnowledgeStore.saveAIUsageEventRecord`, which stores this in
    /// place of `estimatedCost`, and the repricing sweep applies it to rows
    /// already on disk, so a call can only stay unpriced when its price is
    /// genuinely unknown — never because the price table had not loaded yet,
    /// or because the row predates a rate the table has since learned.
    ///
    /// In order:
    /// 1. Zero, when OpenRouter reported that it billed nothing at all —
    ///    even over an estimate already stamped. OpenRouter's own zero is the
    ///    bill; a list price in its place is spend that never happened (a
    ///    `:free` call once carried its paid sibling's rate this way).
    /// 2. A row that already has a cost keeps it.
    /// 3. A server row keeps its own answer. D1 is the billing truth, and an
    ///    unmetered server row is a metering failure the pane must go on
    ///    showing, not one to paper over with a list price.
    /// 4. The rate card at the call's own date, applied to the quantities the
    ///    row recorded.
    /// 5. Zero, when an OpenRouter response carried no usage whatsoever (a
    ///    failed attempt; see `isOpenRouterResponseWithoutUsage`). Zero
    ///    quantities alone are not that evidence (see `accountedCostUSD`).
    ///
    /// Repricing from stored columns cannot see what only the full provider
    /// report carried (web-search calls, the Anthropic 5m/1h cache-write
    /// split), which is why it runs only where the live record found no price.
    var ledgerEstimatedCost: Double? {
        if billedNothingPerOpenRouter { return 0 }
        if let estimatedCost { return estimatedCost }
        if accountedCostUSD != nil { return nil }
        if serverLedgerID != nil { return nil }
        if let repriced = AIProviderPricing.estimatedCostUSD(
            provider: provider,
            model: model,
            report: storedQuantities,
            at: createdAt
        ) {
            return repriced
        }
        if isOpenRouterResponseWithoutUsage { return 0 }
        return nil
    }

    /// True when this row stores a positive estimate for a call OpenRouter
    /// says it billed nothing for — invented spend that
    /// `KnowledgeStore.zeroEstimatesOpenRouterDidNotBill` resets to zero.
    var estimatesSpendOpenRouterDidNotBill: Bool {
        (estimatedCost ?? 0) > 0 && billedNothingPerOpenRouter
    }

    /// OpenRouter's usage says the call cost nothing anywhere, and no amount
    /// the provider reported says otherwise. A server row is D1's answer and
    /// is left to it.
    private var billedNothingPerOpenRouter: Bool {
        serverLedgerID == nil
            && (providerReportedCost ?? 0) <= 0
            && AIUsageParser.openRouterBilledNothing(rawUsageJSON: rawUsageJSON)
    }

    /// An OpenRouter row that recorded nothing the response could have said:
    /// no usage object, no quantity, no reported cost. OpenRouter returns
    /// usage with every generation it bills, so such a row is a failed
    /// attempt that billed nothing. `AIService.recordUsage` no longer writes
    /// these; this prices the ones written before it stopped.
    private var isOpenRouterResponseWithoutUsage: Bool {
        provider.caseInsensitiveCompare("OpenRouter") == .orderedSame
            && rawUsageJSON == nil
            && providerReportedCost == nil
            && !hasPositiveBillableQuantity
    }

    /// The billable quantities this row recorded, as a report the rate card
    /// can price.
    private var storedQuantities: AIUsageReport {
        AIUsageReport(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningTokens: reasoningTokens,
            audioInputTokens: audioInputTokens,
            audioOutputTokens: audioOutputTokens,
            imageCount: imageCount,
            totalTokens: totalTokens,
            characterCount: characterCount,
            durationSeconds: durationSeconds
        )
    }
}

/// Whether any rail can pay for an AI call right now.
///
/// The learner's own OpenRouter key pays for AI work on every account (only
/// MCP is paid for); without a key, only an account's leftover balance (or a
/// comp) can.
///
/// This answers from what the app last learned, never from the network, so a
/// caller about to start work can ask cheaply and often. It is a way to *skip*
/// doomed work, not the authority on entitlement — the proxy still refuses the
/// call, and that refusal is what raises the purchase prompt.
enum AICreditEntitlement {
    static var isOutOfCredits: Bool {
        ManagedAI.creditsAreEmpty
    }

    /// What a learner-initiated AI action says when neither rail can pay. Chat
    /// refuses on this before sending, so the answer is immediate and no request
    /// is spent discovering what the app already knew.
    /// Any account needs only the key: the phone adds it under its own
    /// Settings › Key, the Mac in AI Usage.
    #if os(iOS)
    static let purchaseRequiredMessage =
        "Chat runs on your own OpenRouter key. Add your key in Settings → Key "
            + "to pick up exactly where you left off. Everything you've set up stays as it is."
    #else
    static let purchaseRequiredMessage =
        "Chat runs on your own OpenRouter key. Add your key in AI Usage (the sidebar's OpenRouter button) "
            + "to pick up exactly where you left off. Everything you've set up stays as it is."
    #endif

    /// Whether a surfaced error came from a budget rather than from the model or
    /// the network — the case where Retry cannot succeed and a purchase can.
    static func isBlockedByBudget(_ message: String) -> Bool {
        message.contains(purchaseRequiredMessage)
            || planEraPurchaseRequiredMessages.contains { message.contains($0) }
    }

    /// The message's wordings from while the key needed a plan (until the
    /// lock of 2026-10-11), the phone's first and the Mac's second. Nothing
    /// says them now; stored chats still hold them.
    static let planEraPurchaseRequiredMessages = [
        "Chat runs on your own OpenRouter key with a ForeverLM plan. Add your key and choose a plan in Settings → Billing "
            + "to pick up exactly where you left off — everything you've set up stays exactly as it is.",
        "Chat runs on your own OpenRouter key with a ForeverLM plan. Add your key in AI Usage (the sidebar's OpenRouter button) and choose a plan in Settings → Billing "
            + "to pick up exactly where you left off — everything you've set up stays exactly as it is.",
    ]
}

/// Database-aggregated task row for the activity-first usage log. Aggregation
/// happens in SQLite on `StorageService`'s actor, never in a SwiftUI render.
struct AIUsageTaskActivitySummary: Identifiable, Sendable, Equatable {
    let key: String
    let task: String?
    let subjectType: String?
    let subjectCount: Int
    let activityCount: Int
    let callCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double?
    let unpricedCallCount: Int
    let latestAt: Date
    /// The models that served this task in the period, most calls first.
    var models: [AIUsageModelUse] = []

    var id: String { key }
}

/// One model an activity-log row ran on, and how many of its calls it served.
/// A row can span several: Chat runs whichever model each message picked, and
/// a task falls back to its backup when the first choice fails. Grouped by
/// model id alone, because the ledger spells one router two ways
/// ("OpenRouter", "openrouter") depending on the rail that recorded the call.
struct AIUsageModelUse: Sendable, Equatable {
    let provider: String
    let model: String
    let callCount: Int
    /// Calls OpenRouter reported as `is_byok: true`: the learner's own
    /// upstream key paid for them, not OpenRouter credits.
    var byokCallCount: Int = 0
    /// Calls OpenRouter reported as `is_byok: false`: billed to OpenRouter
    /// credits. A call whose usage block carried no flag counts in neither.
    var creditCallCount: Int = 0
}

/// One item beneath a task row, such as a podcast episode beneath Transcript
/// Formatting. Its stable key is produced by SQLite from type + deterministic
/// ID, with title-only attribution kept apart as such.
struct AIUsageSubjectActivitySummary: Identifiable, Sendable, Equatable {
    let key: String
    let subjectID: String?
    let subjectType: String?
    let subjectTitle: String?
    let activityCount: Int
    let callCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double?
    let unpricedCallCount: Int
    let latestAt: Date
    /// The models that served this item in the period, most calls first.
    var models: [AIUsageModelUse] = []

    var id: String { key }
}

/// User-facing action for a stable usage-ledger task identifier. Configurable
/// AI tasks use their action-oriented history name; feature-specific task tags
/// stay centralized here so macOS and iOS describe the same work consistently.
enum AIUsageTaskLabel {
    static func text(for task: String) -> String {
        switch task {
        case "article_metadata": return "Extract Article Metadata"
        case "audio_overview_writing": return "Write Audio Overview"
        case "automatic_audio_filtering": return "Filter Automatic Audio"
        case "author_normalization": return "Normalize Author Names"
        case "book_author": return "Extract Book Metadata"
        case "book_chapter_splitting": return "Split Book Chapters"
        case "scanned_page_proofreading": return "Proofread Scanned Pages"
        case "card_drafting": return "Draft Cards"
        case "card_variation": return "Reword Cards"
        case "chat": return "Answer in Chat"
        case "chat_quiz_grading": return "Grade Quiz Answer in Chat"
        case "chat_title": return "Create Chat Title"
        case "composer_dictation": return "Transcribe Message Dictation"
        case "citation_resolution": return "Look Up Citation"
        case "course_lecture_naming": return "Name Course Lectures"
        case "course_metadata": return "Extract Course Metadata"
        case "course_ordering": return "Order Course"
        case "deep_research": return "Run Deep Research"
        case "source_discovery": return "Discover Sources"
        case "diagram_generation": return "Generate Diagram"
        case "doc_edit": return "Edit Page Passage"
        case "doc_image": return "Draw Page Picture"
        case "duplicate_detection": return "Detect Duplicates"
        case "embedding": return "Embed Text"
        case "chat": return "Run Review Session"
        case "flashcard_generation": return "Generate Flashcards"
        case "lecture_note_matching": return "Match Lecture Notes"
        case "journal_article_matching": return "Match Journal Articles"
        case "lecture_paper_discovery": return "Discover Lecture Papers"
        case "meeting_paper_discovery": return "Discover Meeting Papers"
        case "meeting_session_details": return "Extract Meeting Details"
        case "mnemonic_reading_writing": return "Write Mnemonic Reading"
        case "notebook_naming": return "Name Notebook"
        case "pasted_line_joining": return "Join Pasted Lines"
        case "notebook_cover": return "Notebook Thumbnail"
        case "course_quiz_picture": return "Draw Quiz Picture"
        case "course_quiz_icon": return "Draw Quiz Icon"
        case "card_picture": return "Draw Card Picture"
        case "map_summaries": return "Summarize Canvas"
        case "canvas_ask": return "Ask the Canvas"
        case "canvas_voice": return "Change Canvas by Voice"
        case "canvas_voice_dictation": return "Transcribe Canvas Voice"
        case "card_go_deeper": return "Go Deeper on a Card"
        case "card_answer_check": return "Check a Card Answer"
        case "card_wording_check": return "Check Card Wording"
        case "atlas_writing": return "Write Atlas"
        case "source_levels": return "Write Reading Levels"
        case "mobile_review": return "Grade Hands-Free Review"
        case "mobile_voice_agent": return "Route Hands-Free Command"
        case "paper_attachment_check": return "Check Paper Attachment"
        case "paper_browser_agent": return "Find Paper PDF"
        case "paper_metadata": return "Extract Paper Metadata"
        case "paper_narration_preparation": return "Cleanup Content"
        case "paper_reference_extraction": return "Read Paper References"
        case "article_link_discovery": return "Find Linked Sources"
        case "paper_read_aloud_preparation": return "Prepare Paper for Text to Speech"
        case "podcast_speaker_identification": return "Identify Podcast Speakers"
        case "podcast_youtube_matching": return "Match Podcast on YouTube"
        case "read_aloud": return "Generate Text-to-Speech Audio"
        case "read_aloud_probe": return "Test Text-to-Speech Voice"
        case "realtime_voice": return "Voice Mode"
        case "realtime_review_preparation": return "Create Review Questions"
        case "rephrase_question": return "Rephrase Question"
        case "report_writing": return "Write Report"
        case "review_dictation": return "Transcribe Review Dictation"
        case "review_grading": return "Grade Review"
        case "review_speech": return "Generate Review Speech"
        case "slide_citation_extraction": return "Extract Slide Citations"
        case "slide_frame_classification": return "Deduplicate Slides"
        case "paper_figure_understanding": return "Understand Paper Figures"
        case "source_classification": return "Classify Source"
        case "topic_summarization": return "Merge Notebook Notes"
        case "transcript_formatting": return "Format Transcript"
        case "voice_agent": return "Run Voice Agent"
        case "voice_preview": return "Preview Voice"
        case "voice_review": return "Run Voice Review"
        default: return task.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Static list prices used to stamp `AIUsageEvent.estimatedCost` at record time.
///
/// Rates are USD list prices verified against provider pricing pages on
/// 2026-07-25 for Anthropic (platform.claude.com); OpenAI
/// developers.openai.com, Gemini ai.google.dev, Groq, Cerebras, Together AI
/// verified 2026-07-16, remaining secondary providers 2026-07-04; cached-input
/// rates for xAI and the OpenRouter catalog verified 2026-07-17. Speech and
/// transcription carry no rates here: they come from OpenRouter's catalog
/// (`OpenRouterAudioPrices`).
/// Cache-discount notes: Anthropic reads 0.1x with 1.25x/2x writes (explicit
/// breakpoints); OpenAI, Gemini 2.5+, xAI, Groq (GPT-OSS models only), and
/// most OpenRouter hosts cache automatically; Cerebras caches automatically
/// but bills cached reads at the full input rate (no discount to model).
/// Costs freeze the rate at event time and use the billable quantities the
/// provider reported. Unknown provider/model combinations return nil rather
/// than a guessed number — the usage pane surfaces those as unpriced.
enum AIProviderPricing {
    struct TokenRates {
        /// USD per 1M input tokens.
        let input: Double
        /// USD per 1M output tokens.
        let output: Double
        /// USD per 1M cached (cache-read) input tokens.
        var cachedInput: Double?
        /// USD per 1M cache-creation input tokens with the default 5-minute TTL
        /// (Anthropic-style cache writes, 1.25x base input).
        var cacheWrite: Double?
        /// USD per 1M cache-creation input tokens with a 1-hour TTL (2x base
        /// input on Anthropic). Falls back to `cacheWrite` when nil.
        var cacheWrite1h: Double?
        /// USD per 1M audio output tokens (Gemini TTS models). When set, audio
        /// output tokens are carved out of the text output count.
        var audioOutput: Double?
        /// USD per 1M image output tokens (Gemini image generation). When set,
        /// image output tokens are carved out of the text output count.
        var imageOutput: Double?
        /// USD per server-side web-search tool call (Anthropic and OpenAI both
        /// bill $10 per 1,000 searches on top of tokens).
        var perWebSearchCall: Double?
        /// Prompt-size tier: prompts above this many tokens bill at
        /// `longContextInput`/`longContextOutput` instead (Gemini Pro models).
        var longContextThreshold: Int?
        var longContextInput: Double?
        var longContextOutput: Double?
        /// Cache-read rate above the threshold, where the provider raises it
        /// too (OpenAI doubles cached input past 272k). Falls back to
        /// `cachedInput` when nil.
        var longContextCachedInput: Double?
        /// Anthropic reports `input_tokens` excluding cached tokens; OpenAI and
        /// Gemini report a prompt total that already includes them.
        var inputIncludesCached: Bool = true
        /// Gemini bills thought tokens as output but excludes them from
        /// `candidatesTokenCount`; OpenAI/Anthropic already include reasoning
        /// in their output counts.
        var outputExcludesReasoning: Bool = false
    }

    static func estimatedCostUSD(
        provider: String,
        model: String,
        report: AIUsageReport,
        at date: Date = Date()
    ) -> Double? {
        // OpenRouter's own word that the call cost nothing outranks any list
        // price: a rate card estimate here would be spend that never happened.
        if AIUsageParser.openRouterBilledNothing(rawUsageJSON: report.rawUsageJSON) { return 0 }
        let model = model.lowercased()
        let provider = provider.lowercased()

        var total: Double?
        func add(_ amount: Double?) {
            guard let amount else { return }
            total = (total ?? 0) + amount
        }

        if let characters = report.characterCount, characters > 0,
           let perMillionCharacters = ttsRatePerMillionCharacters(provider: provider, model: model) {
            add(Double(characters) / 1_000_000 * perMillionCharacters)
        }

        if let seconds = report.durationSeconds, seconds > 0,
           let perMinute = sttRatePerMinute(model: model) {
            add(seconds / 60 * perMinute)
        }

        // A speech or transcription model OpenRouter bills by its tokens
        // (gpt-4o-mini-transcribe, Gemini's voices) has no duration or
        // character rate above, and its response carries no cost: OpenRouter's
        // transcription endpoint answers `cost: 0`. Its price is the token rate
        // OpenRouter's audio catalog lists for that exact model, which outranks
        // a text row a name fragment might match (product owner, 2026-11-07:
        // calls left "not priced yet" "should not be an option").
        if let price = audioTokenPrice(provider: provider, model: model) {
            add(audioTokenCostUSD(price: price, report: report))
        } else if let rates = tokenRates(provider: provider, model: model, at: date) {
            add(tokenCostUSD(rates: rates, report: report))
        }

        // A picture model OpenRouter bills by the picture, the megapixel or
        // the image token has no text rate above; its price is the one the
        // Image API's directory lists, so a call whose response carried no
        // charge is still priced (product owner, 2026-10-29: "everything must
        // be priced").
        // The Image API's directory is the Mac's (`ImageGenerationCatalog.swift`
        // is not in the iPhone target, whose usage the proxy prices).
        #if os(macOS)
        if total == nil, (report.imageCount ?? 0) > 0,
           let price = ImageGenerationDirectory.snapshot.first(where: { $0.id.lowercased() == model })?.price {
            add(price.cost(pictures: report.imageCount ?? 1, imageTokens: report.imageOutputTokens ?? report.outputTokens))
        }
        #endif

        return total
    }

    // MARK: - Speech and transcription (OpenRouter's catalog)

    /// Every speech and transcription model is an OpenRouter model, priced
    /// from OpenRouter's catalog in the unit it bills the model by
    /// (`OpenRouterAudioPrices`; the product owner, 2026-09-26: "It never have
    /// hard-coded prices"). No provider's own rate card stands in (product owner,
    /// 2026-09-27: "no need for any other routes to models").
    ///
    /// A row an earlier build recorded on a maker's own API (OpenAI's
    /// `gpt-4o-mini-tts`, xAI's voices, Google's Gemini) is priced at
    /// OpenRouter's row for the same model, which passes the maker's price
    /// through, when OpenRouter lists one. A host's row (Groq, Together AI)
    /// names no maker and stays unpriced, as does a model OpenRouter does not
    /// price. `AIUsageTracker.repriceLedger` only prices rows with no recorded
    /// cost, so a cost already stored is never rewritten.
    private static func speechPriceSlug(provider: String, model: String) -> String? {
        let provider = provider.lowercased()
        if provider.contains("openrouter") { return model }
        return openRouterPriceSlug(provider: provider, model: model)
    }

    /// USD per million characters of text for a speech model. A model
    /// OpenRouter does not bill by the character — Gemini by tokens, Seed
    /// Audio by the second — has no rate here and keeps the cost OpenRouter
    /// reports for the request. An exact slug, never a substring: `gemini`
    /// alone would price three models with three different rates as one.
    private static func ttsRatePerMillionCharacters(provider: String, model: String) -> Double? {
        guard let slug = speechPriceSlug(provider: provider, model: model) else { return nil }
        return ArticleSpeechCatalog.ratePerMillionCharacters(forModel: slug)
    }

    /// Rate for the Settings model-picker price labels and the cost quotes
    /// before a listen: the accounting rate above, so the quote and the
    /// ledger's estimate agree; nil for a model OpenRouter does not bill by
    /// the character, which reads as "price unknown".
    static func ttsDisplayRatePerMillionCharacters(provider: String, model: String) -> Double? {
        ttsRatePerMillionCharacters(provider: provider, model: model)
    }

    /// Rate for the Settings model-picker price labels, scaled to the
    /// per-hour figure the label shows.
    ///
    /// Priced by the model's own slug, not by the provider slot a picker or
    /// an old row names: the picker's OpenAI slot once listed mostly
    /// OpenRouter slugs, so asking a table for "openai" missed every
    /// router-only model. Every model routes to OpenRouter now (2026-09-27).
    static func sttDisplayRatePerHour(model: String) -> Double? {
        sttRatePerMinute(model: model).map { $0 * 60 }
    }

    /// OpenRouter's catalog, in the unit it bills the model by: per second,
    /// minute or hour of audio for most, and no duration rate for a
    /// token-billed model, which `audioTokenPrice` prices by its tokens.
    /// `canonicalModel` names the slug the rail sends today, so a row an
    /// earlier build recorded on Groq or OpenAI under a bare id
    /// (`whisper-large-v3`) is priced at OpenRouter's row for that model.
    private static func sttRatePerMinute(model: String) -> Double? {
        OpenRouterAudioPrices.transcriptionUSDPerHour(
            slug: ManagedTranscriptionClient.canonicalModel(model)
        ).map { $0 / 60 }
    }

    /// OpenRouter's catalog price for a transcription or speech model it
    /// bills by input and output tokens; nil for one billed by duration or
    /// character, or not in the catalog. Only a row the catalog lists counts:
    /// `OpenRouterAudioPrices.price(for:kind:)` reads any `:free` slug as a
    /// free audio model, which would take a free text model off its own rule
    /// in `tokenRates`.
    private static func audioTokenPrice(provider: String, model: String) -> OpenRouterAudioPrices.Price? {
        let table = OpenRouterAudioPrices.current
        func listed(_ slug: String?, _ kind: OpenRouterAudioDirectory.Kind) -> OpenRouterAudioPrices.Price? {
            guard let key = slug?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let price = table[key], price.kind == kind, price.unit == .token
            else { return nil }
            return price
        }
        return listed(ManagedTranscriptionClient.canonicalModel(model), .transcription)
            ?? listed(speechPriceSlug(provider: provider, model: model), .speech)
    }

    /// A token-billed audio call at the catalog's rates: the tokens heard or
    /// read in at the input rate, the text or audio tokens produced at the
    /// output rate. Nil when the row recorded no tokens to price.
    private static func audioTokenCostUSD(price: OpenRouterAudioPrices.Price, report: AIUsageReport) -> Double? {
        let input = report.inputTokens ?? report.audioInputTokens ?? 0
        let output = report.outputTokens ?? report.audioOutputTokens ?? 0
        guard input > 0 || output > 0 else { return price.isFree ? 0 : nil }
        return Double(input) * price.rate + Double(output) * (price.outputRate ?? 0)
    }

    // MARK: - Remote list prices (OpenRouter model directory)

    /// One model's list prices as published by OpenRouter's public model
    /// directory (openrouter.ai/api/v1/models), normalized to USD per 1M
    /// tokens. The directory carries first-party passthrough prices for the
    /// closed labs (anthropic/, x-ai/, google/, openai/, meta/ slugs) as well
    /// as OpenRouter's cross-host prices, so one fetch keeps both the
    /// direct-API models and the OpenRouter-served catalog current.
    struct RemoteModelPrice: Codable, Equatable, Sendable {
        var input: Double?
        var output: Double?
        var cachedInput: Double?
        var cacheWrite: Double?
        var cacheWrite1h: Double?
        /// USD per web-search tool call.
        var perWebSearchCall: Double?
        /// ≥threshold prompt-token pricing tier (the directory's `overrides`).
        var longContextThreshold: Int?
        var longContextInput: Double?
        var longContextOutput: Double?
    }

    private static let remotePriceLock = NSLock()
    nonisolated(unsafe) private static var remotePricesBySlug: [String: RemoteModelPrice] = [:]
    nonisolated(unsafe) private static var didLoadPersistedRemotePrices = false
    nonisolated(unsafe) private static var remotePriceGenerationValue: UInt64 = 0

    /// Bumped whenever the remote price overlay changes, so price-derived
    /// caches (the sorted model catalog) can validate cheaply instead of
    /// re-sorting on every read.
    static var remotePriceGeneration: UInt64 {
        remotePriceLock.lock()
        defer { remotePriceLock.unlock() }
        return remotePriceGenerationValue
    }

    private static let remotePricesDefaultsKey = "aiPricing.openRouterRemotePrices"
    private static let remotePricesFetchedAtKey = "aiPricing.openRouterRemotePricesFetchedAt"

    /// When the remote table was last fetched from the network; nil = never.
    static var remotePricesFetchedAt: Date? {
        UserDefaults.standard.object(forKey: remotePricesFetchedAtKey) as? Date
    }

    /// Loads the persisted remote price table into memory. Idempotent and
    /// network-free; called once after launch and by the refresh triggers so
    /// cached prices apply before any fetch completes. Deliberately never
    /// called from `tokenRates` itself: with no explicit load the table stays
    /// empty and every rate comes from the hardcoded rows, which keeps unit
    /// tests deterministic.
    static func loadPersistedRemotePrices() {
        remotePriceLock.lock()
        defer { remotePriceLock.unlock() }
        guard !didLoadPersistedRemotePrices else { return }
        didLoadPersistedRemotePrices = true
        guard let data = UserDefaults.standard.data(forKey: remotePricesDefaultsKey),
              let table = try? JSONDecoder().decode([String: RemoteModelPrice].self, from: data)
        else { return }
        remotePricesBySlug = table
        remotePriceGenerationValue &+= 1
    }

    /// Replaces the remote price table and persists it with the fetch time.
    /// Returns true when any price actually changed, so callers republish UI
    /// state only on real changes.
    @discardableResult
    static func updateRemotePrices(_ table: [String: RemoteModelPrice], fetchedAt: Date) -> Bool {
        remotePriceLock.lock()
        didLoadPersistedRemotePrices = true
        let changed = remotePricesBySlug != table
        remotePricesBySlug = table
        if changed { remotePriceGenerationValue &+= 1 }
        remotePriceLock.unlock()
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: remotePricesDefaultsKey)
        }
        UserDefaults.standard.set(fetchedAt, forKey: remotePricesFetchedAtKey)
        return changed
    }

    /// The OpenRouter directory slug carrying this provider+model's list
    /// price. Hosts with host-specific pricing (Groq, Cerebras, Together,
    /// Fireworks, NVIDIA) return nil: OpenRouter's cross-host price is not
    /// what those hosts charge.
    /// Internal, not private, so a test can pin the mapping: the overlay is
    /// disabled under XCTest, so nothing else can observe which row it reads.
    /// The model goes through the same canonicalisation the routing slug
    /// uses (`OpenRouterSlugNormalization`): "gpt-5.6" is OpenAI's alias for
    /// the Sol row, and Anthropic's "claude-opus-4-8" is OpenRouter's
    /// "claude-opus-4.8". Without it the composer quoted the static list price
    /// beside OpenRouter's promotion label — a price nobody was paying.
    static func openRouterPriceSlug(provider: String, model: String) -> String? {
        // OpenRouter's own catalogue already stores full slugs.
        if provider == "openrouter" { return model }
        guard let vendor = vendorSegment(forPriceProvider: provider) else { return nil }
        // A lab model stored with its vendor segment is used as is.
        if model.contains("/") { return model }
        return "\(vendor)/\(OpenRouterSlugNormalization.canonicalModel(model, vendor: vendor))"
    }

    private static func vendorSegment(forPriceProvider provider: String) -> String? {
        switch provider {
        case "anthropic": return "anthropic"
        case "openai": return "openai"
        case "xai": return "x-ai"
        case "google", "gemini": return "google"
        case "meta": return "meta"
        default: return nil
        }
    }

    private static func remotePrice(provider: String, model: String) -> RemoteModelPrice? {
        // The hosted app may have a live OpenRouter directory snapshot in its
        // defaults domain. Unit tests verify the versioned built-in rate card
        // and must never inherit that machine-specific mutable overlay.
        if isRunningTests { return nil }
        remotePriceLock.lock()
        defer { remotePriceLock.unlock() }
        guard !remotePricesBySlug.isEmpty,
              let slug = openRouterPriceSlug(provider: provider, model: model)
        else { return nil }
        if let price = remotePricesBySlug[slug] { return price }
        // Dated ids (claude-opus-4-8-20260115) match their undated row.
        for pattern in ["-\\d{4}-\\d{2}-\\d{2}$", "-\\d{8}$"] {
            if let range = slug.range(of: pattern, options: .regularExpression) {
                return remotePricesBySlug[String(slug[..<range.lowerBound])]
            }
        }
        return nil
    }

    /// Kept local because this shared pricing file is built by both app
    /// targets, while the macOS-only `UITestConfiguration` lives in Models.
    // Process arguments, environment, and the loaded XCTest runtime do not
    // change after launch. Catalog sorting asks for rates from its comparison
    // closure many times; repeating ProcessInfo environment copies and ObjC
    // runtime class lookup there turned opening one model picker into a main-
    // thread stall under the debugger.
    private static let isRunningTests: Bool = {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { return true }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Numeric fields come from the directory where present; behavioral flags
    /// (cached-token exclusion, reasoning-token exclusion) and any field the
    /// directory lacks keep the hardcoded row's values.
    /// Applies the directory's effective user price over the built-in fallback.
    /// OpenRouter has already applied any provider promotion to these fields;
    /// multiplying a separately advertised discount here would double-discount.
    static func applyingRemote(_ remote: RemoteModelPrice, to base: TokenRates?) -> TokenRates? {
        guard let input = remote.input ?? base?.input,
              let output = remote.output ?? base?.output,
              // A 0/0 row is the directory's "not token-billed" (media models,
              // free tiers) — no price information, not a free price.
              input > 0 || output > 0
        else { return base }
        // Media-billed models (Gemini TTS/image, gpt-image) carve audio/image
        // output out at dedicated rates the directory doesn't model; their
        // hardcoded rows stay authoritative.
        if let base, base.audioOutput != nil || base.imageOutput != nil { return base }
        var merged = TokenRates(
            input: input,
            output: output,
            cachedInput: remote.cachedInput ?? base?.cachedInput,
            cacheWrite: remote.cacheWrite ?? base?.cacheWrite,
            cacheWrite1h: remote.cacheWrite1h ?? base?.cacheWrite1h,
            perWebSearchCall: remote.perWebSearchCall ?? base?.perWebSearchCall
        )
        merged.longContextThreshold = remote.longContextThreshold ?? base?.longContextThreshold
        merged.longContextInput = remote.longContextInput ?? base?.longContextInput
        merged.longContextOutput = remote.longContextOutput ?? base?.longContextOutput
        merged.longContextCachedInput = base?.longContextCachedInput
        if let base {
            merged.inputIncludesCached = base.inputIncludesCached
            merged.outputExcludesReasoning = base.outputExcludesReasoning
        }
        return merged
    }

    // MARK: - LLM token rates (USD per 1M tokens)

    /// Claude Sonnet 5 introductory pricing ($2/$10) runs through 2026-08-31;
    /// standard pricing ($3/$15) applies from 2026-09-01 00:00 UTC.
    private static let sonnet5IntroPricingEnd = Date(timeIntervalSince1970: 1_788_220_800)
    /// List-price rates: the hardcoded table below, overlaid with the latest
    /// remotely fetched prices (see `RemoteModelPrice`) when a fetch has run.
    static func tokenRates(provider: String, model: String, at date: Date = Date()) -> TokenRates? {
        let remote = remotePrice(provider: provider, model: model)
        // OpenRouter's `:free` variant is priced at zero by definition. The
        // built-in rows match on a model-name fragment, so without this the
        // free slug took its paid sibling's rate (nemotron-3-super:free billed
        // as nemotron-3-super), and the directory's 0/0 row for it reads as
        // "no price information" in `applyingRemote`. Only a positive price
        // the live directory now lists — the free period ended — outranks it.
        if provider == "openrouter", AIFreeModels.isFreeModelID(model) {
            if let remote, (remote.input ?? 0) > 0 || (remote.output ?? 0) > 0,
               let listed = applyingRemote(remote, to: nil) {
                return listed
            }
            return TokenRates(input: 0, output: 0, cachedInput: 0)
        }
        let base = builtinTokenRates(provider: provider, model: model, at: date)
        guard let remote else { return base }
        return applyingRemote(remote, to: base)
    }

    private static func builtinTokenRates(provider: String, model: String, at date: Date) -> TokenRates? {
        // OpenRouter — cross-host routed list prices for the catalog's pinned
        // open-weight models (openrouter.ai/api/v1/models, verified 2026-07-17).
        // These back the Settings price labels and the pre-flight estimate;
        // recorded events prefer the actual billed amount OpenRouter returns in
        // `usage.cost` (requested via `usage.include` on every OpenRouter call).
        // Gated on the provider because the same model names exist on other
        // hosts at their own prices.
        if provider == "openrouter" {
            // First-party models added from the OpenRouter directory keep
            // their maker's list prices (OpenRouter passes them through 1:1,
            // cache rates included) — reuse the direct-provider rows so cache
            // reads and writes get the same discounts in estimates. OpenRouter
            // normalizes usage to the OpenAI shape, where prompt_tokens
            // already includes cached and cache-write tokens, so flip the
            // Anthropic exclusion flag.
            if model.hasPrefix("anthropic/") {
                var rates = tokenRates(provider: "anthropic", model: String(model.dropFirst("anthropic/".count)), at: date)
                rates?.inputIncludesCached = true
                return rates
            }
            if model.hasPrefix("google/gemini") {
                return tokenRates(provider: "google", model: String(model.dropFirst("google/".count)), at: date)
            }
            if model.hasPrefix("x-ai/grok") {
                return tokenRates(provider: "xai", model: String(model.dropFirst("x-ai/".count)), at: date)
            }
            if (model.hasPrefix("openai/") && AIModelDefaults.isOpenAIReasoningModel(model))
                || model.hasPrefix("openai/gpt-4o")
                || model.hasPrefix("openai/text-embedding") {
                return tokenRates(provider: "openai", model: String(model.dropFirst("openai/".count)), at: date)
            }
            // Pinned open-weight catalog rows. Cache-read rates are OpenRouter's
            // cross-host `input_cache_read` prices (openrouter.ai/api/v1/models,
            // verified 2026-07-17); caching on these hosts is automatic, no
            // request annotation involved. Models without a cachedInput either
            // don't cache or bill cached reads at the full input rate
            // (gpt-oss-20b lists a cache-read price equal to its input price).
            if model.contains("deepseek-v4-pro") { return TokenRates(input: 0.435, output: 0.87, cachedInput: 0.003625) }
            if model.contains("deepseek-v4-flash") { return TokenRates(input: 0.098, output: 0.196, cachedInput: 0.0196) }
            if model.contains("kimi-k3") { return TokenRates(input: 3, output: 15, cachedInput: 0.30) }
            if model.contains("kimi-k2.6") { return TokenRates(input: 0.684, output: 3.42) }
            if model.contains("gpt-oss-120b") { return TokenRates(input: 0.037, output: 0.17) }
            if model.contains("gpt-oss-20b") { return TokenRates(input: 0.03, output: 0.13) }
            if model.contains("qwen3-235b-a22b-2507") { return TokenRates(input: 0.09, output: 0.55) }
            if model.contains("qwen3-32b") { return TokenRates(input: 0.08, output: 0.28) }
            if model.contains("glm-5.2") { return TokenRates(input: 0.9268, output: 2.9128, cachedInput: 0.17212) }
            if model.contains("glm-5.1") { return TokenRates(input: 0.966, output: 3.036) }
            if model.contains("glm-4.7") { return TokenRates(input: 0.40, output: 1.75, cachedInput: 0.08) }
            if model.contains("mistral-large-2512") {
                return TokenRates(input: 0.50, output: 1.50, cachedInput: 0.05)
            }
            if model.contains("mistral-small-2603") {
                return TokenRates(input: 0.15, output: 0.60, cachedInput: 0.015)
            }
            if model.contains("muse-spark") { return TokenRates(input: 1.25, output: 4.25, cachedInput: 0.15) }
            if model.contains("llama-4-maverick") { return TokenRates(input: 0.20, output: 0.80) }
            if model.contains("nemotron-3-ultra") { return TokenRates(input: 0.60, output: 3.60, cachedInput: 0.20) }
            if model.contains("nemotron-3-super") { return TokenRates(input: 0.21, output: 0.455, cachedInput: 0.06) }
            if model.contains("nemotron-3-nano") { return TokenRates(input: 0.05, output: 0.20) }
            return nil
        }

        // Anthropic — input excludes cached tokens; cache read 0.1x,
        // 5m cache write 1.25x, 1h cache write 2x; web search $10/1k calls.
        if model.hasPrefix("claude") {
            func anthropic(_ input: Double, _ output: Double) -> TokenRates {
                TokenRates(
                    input: input,
                    output: output,
                    cachedInput: input * 0.1,
                    cacheWrite: input * 1.25,
                    cacheWrite1h: input * 2,
                    perWebSearchCall: 0.01,
                    inputIncludesCached: false
                )
            }
            if model.contains("fable") || model.contains("mythos") { return anthropic(10, 50) }
            // Opus dropped to $5/$25 with 4.5; 4.0/4.1 and Opus 3 were $15/$75.
            if model.contains("opus-4-0") || model.contains("opus-4-1") || model.contains("opus-4-2025") {
                return anthropic(15, 75)
            }
            if model.contains("opus-5") || model.contains("opus-4") {
                return anthropic(5, 25)  // Opus 4.5 and later
            }
            if model.contains("opus") { return anthropic(15, 75) }
            if model.contains("3-5-haiku") { return anthropic(0.80, 4) }
            if model.contains("haiku") { return anthropic(1, 5) }
            if model.contains("sonnet-5") {
                return date < sonnet5IntroPricingEnd ? anthropic(2, 10) : anthropic(3, 15)
            }
            if model.contains("sonnet") { return anthropic(3, 15) }
            return nil
        }

        // OpenAI GPT family — web search on the Responses API is $10/1k calls
        // for gpt-5.x (search content tokens bill at normal model rates).
        // GPT Image 2 and the 2.5 pair (Flare, Sunburst) share one output
        // rate, so the prefix covers all three.
        if model.hasPrefix("gpt-image-2") {
            return TokenRates(input: 8, output: 30)
        }
        if model.hasPrefix("gpt-5.5-pro") || model.hasPrefix("gpt-5.4-pro") {
            return TokenRates(input: 30, output: 180, perWebSearchCall: 0.01)
        }
        // GPT-6 Astra (developers.openai.com, checked 2026-09-03): prompts over
        // 272k input tokens bill the whole request at 2x input and cache rates
        // and 1.5x output. Fast mode doubles every rate and is not offered.
        if model.hasPrefix("gpt-6-astra") {
            var rates = TokenRates(input: 10, output: 50, cachedInput: 1, cacheWrite: 12.5, perWebSearchCall: 0.01)
            rates.longContextThreshold = 272_000
            rates.longContextInput = 20
            rates.longContextCachedInput = 2
            rates.longContextOutput = 75
            return rates
        }
        if model.hasPrefix("gpt-5.6-terra") { return TokenRates(input: 2.5, output: 15, cachedInput: 0.25, perWebSearchCall: 0.01) }
        if model.hasPrefix("gpt-5.6-luna") { return TokenRates(input: 1, output: 6, cachedInput: 0.10, perWebSearchCall: 0.01) }
        if model.hasPrefix("gpt-5.6") { return TokenRates(input: 5, output: 30, cachedInput: 0.5, perWebSearchCall: 0.01) }  // Sol + "gpt-5.6" alias
        if model.hasPrefix("gpt-5.5") { return TokenRates(input: 5, output: 30, cachedInput: 0.5, perWebSearchCall: 0.01) }
        if model.hasPrefix("gpt-5.4-mini") { return TokenRates(input: 0.75, output: 4.5, cachedInput: 0.075, perWebSearchCall: 0.01) }
        if model.hasPrefix("gpt-5.4-nano") { return TokenRates(input: 0.20, output: 1.25, cachedInput: 0.02, perWebSearchCall: 0.01) }
        if model.hasPrefix("gpt-5.4") { return TokenRates(input: 2.5, output: 15, cachedInput: 0.25, perWebSearchCall: 0.01) }
        // The original GPT-5 line (August 2025). The dash after "gpt-5" keeps
        // these clear of the dotted generations above. Still named by the
        // podcast cleanup route, so it cannot lean on the remote overlay:
        // a launch that had not loaded it recorded thousands of such calls
        // with no cost. Rates checked against the OpenRouter directory's
        // first-party rows on 2026-09-25.
        if model.hasPrefix("gpt-5-nano") { return TokenRates(input: 0.05, output: 0.40, cachedInput: 0.005, perWebSearchCall: 0.01) }
        if model.hasPrefix("gpt-5-mini") { return TokenRates(input: 0.25, output: 2, cachedInput: 0.025, perWebSearchCall: 0.01) }
        if model == "gpt-5" || model.hasPrefix("gpt-5-20") {
            return TokenRates(input: 1.25, output: 10, cachedInput: 0.125, perWebSearchCall: 0.01)
        }
        // Embeddings bill input tokens only (same source and date).
        if model.hasPrefix("text-embedding-3-small") { return TokenRates(input: 0.02, output: 0) }
        if model.hasPrefix("text-embedding-3-large") { return TokenRates(input: 0.13, output: 0) }
        if model.hasPrefix("text-embedding-ada-002") { return TokenRates(input: 0.10, output: 0) }
        // gpt-4o family (the mobile driving-mode models). The -tts and
        // -transcribe variants are priced by characters/minutes above, not by
        // these token rates.
        if model.hasPrefix("gpt-4o"), !model.contains("-tts"), !model.contains("transcribe") {
            if model.hasPrefix("gpt-4o-mini") { return TokenRates(input: 0.15, output: 0.60, cachedInput: 0.075) }
            return TokenRates(input: 2.5, output: 10, cachedInput: 1.25)
        }

        // Google Gemini — candidatesTokenCount excludes thought tokens but
        // includes audio/image modality tokens, which bill at their own rates.
        if model.hasPrefix("gemini") {
            func gemini(_ input: Double, _ output: Double, cached: Double? = nil) -> TokenRates {
                TokenRates(input: input, output: output, cachedInput: cached, outputExcludesReasoning: true)
            }
            // TTS models are token-billed: text in + audio out per 1M tokens.
            if model.contains("tts") {
                if model.contains("2.5-flash") {
                    return TokenRates(input: 0.5, output: 10, audioOutput: 10, outputExcludesReasoning: true)
                }
                // 2.5-pro-preview-tts and 3.1-flash-tts-preview both $1/$20.
                return TokenRates(input: 1, output: 20, audioOutput: 20, outputExcludesReasoning: true)
            }
            if model.contains("flash-image") {
                return TokenRates(input: 0.5, output: 3, imageOutput: 60, outputExcludesReasoning: true)
            }
            if model.contains("3.5-flash") { return gemini(1.5, 9, cached: 0.15) }
            if model.contains("3-pro") || model.contains("3.1-pro") {
                var rates = gemini(2, 12)
                rates.longContextThreshold = 200_000
                rates.longContextInput = 4
                rates.longContextOutput = 18
                return rates
            }
            if model.contains("3-flash") { return gemini(0.5, 3, cached: 0.05) }
            if model.contains("2.5-pro") {
                var rates = gemini(1.25, 10, cached: 0.125)
                rates.longContextThreshold = 200_000
                rates.longContextInput = 2.5
                rates.longContextOutput = 15
                return rates
            }
            if model.contains("2.5-flash-lite") { return gemini(0.1, 0.4, cached: 0.01) }
            if model.contains("2.5-flash") { return gemini(0.3, 2.5, cached: 0.03) }
            if model.contains("2.0-flash") { return gemini(0.1, 0.4, cached: 0.025) }
            return nil
        }

        // xAI (docs.x.ai, verified 2026-07-17); caching is automatic, and every
        // chat model doubles input+output rates at ≥200k prompt tokens. Grok
        // Imagine image/video models bill per image/second, not per token, so
        // they stay unpriced here. Retired slugs (grok-3*) redirect server-side
        // to current models and bill at the standard $1.25/$2.50 tier.
        if model.hasPrefix("grok") {
            if model.contains("imagine") { return nil }
            func xai(_ input: Double, _ output: Double, cached: Double) -> TokenRates {
                var rates = TokenRates(input: input, output: output, cachedInput: cached)
                rates.longContextThreshold = 200_000
                rates.longContextInput = input * 2
                rates.longContextOutput = output * 2
                return rates
            }
            if model.contains("4.5") || model.contains("4.6") || model.contains("4.7") {
                return xai(2, 6, cached: 0.50)
            }
            if model.contains("build") { return xai(1, 2, cached: 0.20) }
            // grok-4.3, the grok-4.20 variants, and redirected grok-3* slugs.
            return xai(1.25, 2.5, cached: 0.20)
        }

        // OpenRouter-hosted Muse Spark list prices. Contributor is the same
        // model at a discounted rate in exchange for training-data consent.
        if model == "muse-spark-1.2-contributor" {
            return TokenRates(input: 0.10, output: 0.20, cachedInput: 0.002)
        }
        if model.hasPrefix("muse-spark") { return TokenRates(input: 1.25, output: 4.25, cachedInput: 0.15) }

        // NVIDIA Nemotron 3 hosted rates (integrate.api.nvidia.com, July 2026).
        // NVIDIA publishes no per-token price for Ultra on its own endpoint
        // (dev tier bills in credits); $0.50/$2.20 is the OpenRouter cross-host
        // reference rate (verified 2026-07-16).
        if model.contains("nemotron-3-ultra") { return TokenRates(input: 0.50, output: 2.20) }
        if model.contains("nemotron-3-super") { return TokenRates(input: 0.085, output: 0.40) }
        if model.contains("nemotron-3-nano") { return TokenRates(input: 0.05, output: 0.20) }

        // Thinking Machines' Inkling. Together AI serverless list price
        // (together.ai/pricing, 2026-07-16); Fireworks publishes no per-token
        // price for Inkling, so other hosts fall back to Thinking Machines'
        // first-party API rate ($1.87/$4.68, 50% launch discount, 2026-07-16).
        if model.contains("inkling") {
            if provider.contains("together") { return TokenRates(input: 1.20, output: 4.05) }
            return TokenRates(input: 1.87, output: 4.68)
        }

        // gpt-oss-120b is served by both Groq and Cerebras at different prices.
        if model.contains("gpt-oss-120b") {
            if provider.contains("cerebras") { return TokenRates(input: 0.35, output: 0.75) }
            return TokenRates(input: 0.15, output: 0.60, cachedInput: 0.075)  // Groq
        }
        // Groq prompt caching bills cached input at 50% of the input rate.
        if model.contains("gpt-oss-20b") { return TokenRates(input: 0.075, output: 0.30, cachedInput: 0.0375) }
        if model.contains("qwen3-32b") { return TokenRates(input: 0.29, output: 0.59) }

        // Cerebras developer-tier rates (cerebras.ai/pricing, 2026-07-16).
        // GLM 4.7 is preview-only, scheduled for deprecation 2026-08-17.
        // Qwen3 235B rate is from Cerebras' launch announcement; the model has
        // since moved to dedicated-endpoint custom pricing off the rate card.
        if model.contains("llama3.1-8b") { return TokenRates(input: 0.10, output: 0.10) }
        if model.contains("zai-glm-4.7") { return TokenRates(input: 2.25, output: 2.75) }
        if model.contains("qwen-3-235b") { return TokenRates(input: 0.60, output: 1.20) }

        return nil
    }

    private static func tokenCostUSD(rates: TokenRates, report: AIUsageReport) -> Double? {
        let cached = report.cachedInputTokens ?? 0

        // Cache writes: bill the 5m/1h TTL split when the provider itemized it;
        // otherwise everything at the default write rate.
        let write5m: Int
        let write1h: Int
        if report.cacheWrite5mInputTokens != nil || report.cacheWrite1hInputTokens != nil {
            write5m = report.cacheWrite5mInputTokens ?? 0
            write1h = report.cacheWrite1hInputTokens ?? 0
        } else {
            write5m = report.cacheCreationInputTokens ?? 0
            write1h = 0
        }

        var uncachedInput = report.inputTokens ?? 0
        if rates.inputIncludesCached {
            // OpenAI-style prompt totals include cached reads — and, on
            // OpenRouter's normalized usage, cache-write tokens too. Carve
            // both out so they bill only at their own rates below.
            uncachedInput = max(0, uncachedInput - cached - write5m - write1h)
        }

        var output = report.outputTokens ?? 0
        if rates.outputExcludesReasoning {
            output += report.reasoningTokens ?? 0
        }

        // Carve modality tokens out of the text output rate only when the model
        // prices them separately (Gemini TTS audio, Gemini image generation).
        var audioOutput = 0
        if rates.audioOutput != nil {
            audioOutput = report.audioOutputTokens ?? 0
            output = max(0, output - audioOutput)
        }
        var imageOutput = 0
        if rates.imageOutput != nil {
            imageOutput = report.imageOutputTokens ?? 0
            output = max(0, output - imageOutput)
        }

        let webSearches = report.webSearchCalls ?? 0

        guard uncachedInput > 0 || cached > 0 || write5m > 0 || write1h > 0
            || output > 0 || audioOutput > 0 || imageOutput > 0 || webSearches > 0 else { return nil }

        // Long-context tier (Gemini Pro): the whole request bills at the higher
        // rate once the prompt exceeds the threshold.
        var inputRate = rates.input
        var outputRate = rates.output
        var cachedInputRate = rates.cachedInput ?? inputRate
        if let threshold = rates.longContextThreshold,
           (report.inputTokens ?? 0) > threshold {
            inputRate = rates.longContextInput ?? inputRate
            outputRate = rates.longContextOutput ?? outputRate
            cachedInputRate = rates.longContextCachedInput ?? rates.cachedInput ?? inputRate
        }

        var cost = Double(uncachedInput) / 1_000_000 * inputRate
        cost += Double(output) / 1_000_000 * outputRate
        cost += Double(audioOutput) / 1_000_000 * (rates.audioOutput ?? outputRate)
        cost += Double(imageOutput) / 1_000_000 * (rates.imageOutput ?? outputRate)
        cost += Double(cached) / 1_000_000 * cachedInputRate
        cost += Double(write5m) / 1_000_000 * (rates.cacheWrite ?? inputRate)
        cost += Double(write1h) / 1_000_000 * (rates.cacheWrite1h ?? rates.cacheWrite ?? inputRate)

        // Batch API: Anthropic, OpenAI, and Gemini all bill batch traffic at
        // 50% of list token prices. Per-call tool fees are not discounted.
        if report.billedAtBatchRates {
            cost *= 0.5
        }

        cost += Double(webSearches) * (rates.perWebSearchCall ?? 0)
        return cost
    }
}

/// The lab-native model id → OpenRouter model segment rules, shared by the
/// routing slug (`OpenRouterModelID`, macOS) and the price overlay lookup
/// (`AIProviderPricing`, both targets) so the two can never name different
/// rows. Vendor is OpenRouter's author segment ("openai", "anthropic").
enum OpenRouterSlugNormalization {
    static func canonicalModel(_ model: String, vendor: String) -> String {
        switch vendor {
        case "openai":
            // "gpt-5.6" is OpenAI's own alias for the Sol tier; OpenRouter
            // lists the tiers explicitly and has no bare alias.
            return model == "gpt-5.6" ? "gpt-5.6-sol" : model
        case "anthropic":
            // Anthropic's API separates version components with dashes
            // ("claude-opus-4-8"); OpenRouter uses the marketing form with a
            // dot ("claude-opus-4.8"). Only a trailing pair of numbers
            // converts, which leaves "claude-sonnet-5" (one component) and
            // "claude-3-haiku" (number not trailing) untouched. A dated id
            // ("claude-opus-4-8-20260115") keeps its date after the version,
            // where the price overlay's undated-row fallback expects it;
            // treating the date as the version pair garbled both.
            let (undated, dateSuffix) = splittingDateSuffix(model)
            let parts = undated.split(separator: "-")
            guard parts.count >= 3,
                  let minor = parts.last, minor.allSatisfy(\.isNumber),
                  let major = parts.dropLast().last, major.allSatisfy(\.isNumber)
            else { return model }
            return parts.dropLast(2).joined(separator: "-") + "-\(major).\(minor)" + dateSuffix
        default:
            return model
        }
    }

    /// "claude-opus-4-8-20260115" → ("claude-opus-4-8", "-20260115"); an id
    /// without a trailing date comes back whole with an empty suffix.
    private static func splittingDateSuffix(_ model: String) -> (String, String) {
        for pattern in ["-\\d{4}-\\d{2}-\\d{2}$", "-\\d{8}$"] {
            if let range = model.range(of: pattern, options: .regularExpression) {
                return (String(model[..<range.lowerBound]), String(model[range]))
            }
        }
        return (model, "")
    }
}

#if os(macOS)
/// Paid AI requests in flight, for the rail's background-work list, and how
/// each is stopped. `AIService.call` is the one entry every library-processing
/// step goes through (paper metadata, text cleanup, formatting, titles); the
/// chat-model calls, streams, pictures, transcriptions and voice previews the
/// app makes on its own are listed through `track` at their own send sites.
/// A chat the learner is typing in is not listed: it has its own Stop. Mac
/// only: every caller is, and `AIProvider` (Models.swift) is not in the iPhone
/// target.
///
/// Everything here can be stopped (product owner, 2026-10-12: "any time a
/// process gets started … something that might actually cost money; we MUST
/// have a way to turn it off"). A stop is by step, not by source: a queue that
/// prepares a book's chapters for Listen moves to the next chapter the moment
/// one is stopped, so stopping one source would only move the spend along.
/// The step's requests in flight are cancelled. A step that runs on its own
/// (`staysStopped`) also stays stopped, on every Mac of the account, until
/// the learner resumes it: new requests for it are refused with
/// `AIStepStoppedError`. A step the learner asked for (a report, a picture)
/// is only cancelled; asking again runs it. Work the learner asks for
/// themselves (`AIUsageAttribution.learnerAsked`) runs through a stop.
final class AIInFlightCalls: @unchecked Sendable {
    static let shared = AIInFlightCalls(stops: .preferences)

    /// The registry the current task reports to: `shared`, except where a
    /// test binds one of its own, so its stops reach neither this Mac's
    /// settings nor other tests' calls.
    @TaskLocal static var current: AIInFlightCalls = .shared

    /// Synced: a stop is the learner's decision about the account's spend, and
    /// every Mac on it runs the same background queues.
    static let stoppedStepsKey = "aiSpend.stoppedSteps"

    /// Steps of a chat the learner is typing in: listed nowhere, since the chat
    /// shows them and has its own Stop. A scheduled task's chat is its own row.
    static let chatTurnSteps: Set<String> = ["chat", "chat_quiz_grading", "deep_research_chat"]

    /// Where the stopped steps are kept.
    struct StoppedStepsStore: Sendable {
        let read: @Sendable () -> [String]
        let write: @Sendable ([String]) -> Void

        static let preferences = StoppedStepsStore(
            read: { UserDefaults.standard.stringArray(forKey: AIInFlightCalls.stoppedStepsKey) ?? [] },
            write: { steps in
                if steps.isEmpty {
                    PreferenceStore.remove(forKey: AIInFlightCalls.stoppedStepsKey)
                } else {
                    PreferenceStore.set(steps, forKey: AIInFlightCalls.stoppedStepsKey)
                }
            }
        )

        /// Held in memory only, for tests.
        static func memory() -> StoppedStepsStore {
            let box = Box()
            return StoppedStepsStore(read: { box.steps }, write: { box.steps = $0 })
        }

        private final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [String] = []
            var steps: [String] {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
    }

    struct Entry: Sendable, Equatable {
        let id: UUID
        let taskLabel: String?
        let sourceTitle: String?
        let subjectID: String?
        let startedAt: Date
        /// The learner asked for this work themselves, so a stop of its step
        /// that outlasts the moment does not reach it.
        let learnerAsked: Bool
        /// The model the call is with now: a backup's, once the task's own
        /// model has failed it.
        var provider: AIProvider?
        var model: String?
        /// The learner stopped this call's step while it ran.
        var wasStopped = false

        /// The step a stop applies to: the task label, or "" for a call
        /// that names none.
        var step: String { taskLabel ?? "" }
    }

    /// A step the learner stopped, until they resume it.
    struct StoppedStep: Sendable, Equatable, Identifiable {
        let step: String
        var id: String { step }
        var name: String { AIInFlightCalls.stepName(step) }
    }

    private let stops: StoppedStepsStore
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var cancels: [UUID: @Sendable () -> Void] = [:]

    init(stops: StoppedStepsStore) {
        self.stops = stops
    }

    /// The step's name: as Settings shows a task, or as AI Usage names the
    /// rest (pictures, recordings, voices).
    static func stepName(_ step: String?) -> String {
        guard let step, !step.isEmpty else { return "Model call" }
        return AITask(rawValue: step)?.displayName ?? AIUsageTaskLabel.text(for: step)
    }

    /// Whether a stop of this step outlasts the moment: work that runs on its
    /// own stays stopped until the learner resumes it, while work they asked
    /// for is only cancelled, so asking again runs it (`AIUsageTaskNeed`).
    static func staysStopped(_ step: String) -> Bool {
        if step == AutomaticAudioStep.step { return true }
        guard !step.isEmpty else { return false }
        return AIUsageTaskNeed.of(taskKey: step) != .requested
    }

    /// Lists a request about to start; nil for a chat the learner is typing
    /// in, which is not listed. Throws `AIStepStoppedError` when the learner
    /// stopped its step, unless they asked for this work themselves.
    func begin(taskLabel: String?, sourceTitle: String?, subjectID: String?) throws -> UUID? {
        let step = taskLabel ?? ""
        guard !Self.chatTurnSteps.contains(step) else { return nil }
        let learnerAsked = AIUsageAttribution.learnerAsked
        if !learnerAsked, isStopped(step) {
            throw AIStepStoppedError(step: Self.stepName(taskLabel), staysStopped: true)
        }
        let entry = Entry(
            id: UUID(),
            taskLabel: taskLabel,
            sourceTitle: sourceTitle,
            subjectID: subjectID,
            startedAt: Date(),
            learnerAsked: learnerAsked
        )
        lock.withLock { entries[entry.id] = entry }
        return entry.id
    }

    /// How Stop reaches the request. A stop that landed between `begin` and
    /// here cancels it at once.
    func attach(_ id: UUID?, cancel: @escaping @Sendable () -> Void) {
        guard let id else { return }
        let cancelNow: Bool = lock.withLock {
            guard let entry = entries[id] else { return false }
            if entry.wasStopped { return true }
            cancels[id] = cancel
            return false
        }
        if cancelNow { cancel() }
    }

    func setModel(_ id: UUID?, provider: AIProvider, model: String) {
        guard let id else { return }
        lock.withLock {
            entries[id]?.provider = provider
            entries[id]?.model = model
        }
    }

    /// Ends the request's listing. True when the learner stopped it, so the
    /// caller can say so rather than report a bare cancellation.
    @discardableResult
    func end(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return lock.withLock {
            cancels.removeValue(forKey: id)
            return entries.removeValue(forKey: id)?.wasStopped ?? false
        }
    }

    /// Ends a request that failed, and gives the error to throw: the stop,
    /// when the learner's stop is why it ended.
    func end(_ id: UUID?, failure error: Error, step: String?) -> Error {
        guard end(id), AITransientErrorClassifier.isCancellation(error) else { return error }
        let step = step ?? ""
        return AIStepStoppedError(step: Self.stepName(step), staysStopped: Self.staysStopped(step))
    }

    /// Runs one paid request as a task of its own, listed while it runs, so a
    /// Stop can cancel it: cancelling aborts the request on the wire. The
    /// task inherits the caller's priority and task-locals, the ledger's
    /// attribution among them, and the caller's own cancellation reaches it.
    /// `body` gets the listing's id, nil when the request is not listed.
    func track<T: Sendable>(
        step: String?,
        sourceTitle: String? = AIUsageAttribution.sourceTitle,
        subjectID: String? = AIUsageAttribution.subjectID,
        _ body: @escaping @Sendable (UUID?) async throws -> T
    ) async throws -> T {
        guard let id = try begin(taskLabel: step, sourceTitle: sourceTitle, subjectID: subjectID) else {
            return try await body(nil)
        }
        let work = Task { try await body(id) }
        attach(id) { work.cancel() }
        // Nothing after the wait touches isolated state: at -O the hop back
        // after a wait inside withTaskCancellationHandler can be lost (the
        // pacer crash of 2026-10-12), so only this locked registry is used.
        do {
            let value = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            end(id)
            return value
        } catch {
            throw end(id, failure: error, step: step)
        }
    }

    /// Stops a step: cancels its requests in flight (the request on the wire
    /// is aborted; nothing is billed past what the provider already ran). A
    /// step that `staysStopped` refuses new requests until `resume`. Returns
    /// how many requests were cancelled.
    @discardableResult
    func stop(step: String) -> Int {
        if Self.staysStopped(step) {
            // Read, change and write outside the lock: a defaults write is
            // never made while holding one.
            var steps = stops.read()
            if !steps.contains(step) {
                steps.append(step)
                stops.write(steps)
            }
        }
        return cancelInFlight { $0.step == step }
    }

    func resume(step: String) {
        let steps = stops.read()
        guard steps.contains(step) else { return }
        stops.write(steps.filter { $0 != step })
    }

    func isStopped(_ step: String) -> Bool {
        stops.read().contains(step)
    }

    /// Steps the learner stopped, in the order they stopped them.
    var stoppedSteps: [StoppedStep] {
        stops.read().map { StoppedStep(step: $0) }
    }

    /// Cancels the requests in flight of every stopped step, as a stop made on
    /// another Mac arrives: what it refuses next is refused at `begin`, but
    /// what was already running here goes on until this.
    func cancelInFlightOfStoppedSteps() {
        let steps = Set(stops.read())
        guard !steps.isEmpty else { return }
        cancelInFlight { steps.contains($0.step) && !$0.learnerAsked && !$0.wasStopped }
    }

    @discardableResult
    private func cancelInFlight(where matches: (Entry) -> Bool) -> Int {
        let toCancel: [@Sendable () -> Void] = lock.withLock {
            var handles: [@Sendable () -> Void] = []
            for (id, entry) in entries where matches(entry) {
                entries[id]?.wasStopped = true
                if let cancel = cancels[id] { handles.append(cancel) }
            }
            return handles
        }
        // Outside the lock: cancelling runs the request's cancellation
        // handlers on this thread.
        toCancel.forEach { $0() }
        return toCancel.count
    }

    var snapshot: [Entry] {
        lock.withLock { Array(entries.values) }
    }
}

/// Automatic source audio (`AutomaticSourceAudioGenerationService`) is
/// stopped as one step: its speech requests are a narration's, so it is
/// listed and stopped as the run it is rather than by their label.
enum AutomaticAudioStep {
    static let step = "automatic_audio"
}
#endif
