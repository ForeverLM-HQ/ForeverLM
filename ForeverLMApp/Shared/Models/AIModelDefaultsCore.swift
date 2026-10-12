import Foundation

/// Model identifiers needed by lightweight app targets that do not compile the
/// desktop model catalog. The full macOS catalog extends this namespace in
/// `AIModelDefaults.swift`.
enum AIModelDefaults {
    /// Account defaults used by every client when no preference record exists.
    /// These are product defaults, not runtime fallbacks: once a route is stored,
    /// malformed or unavailable preferences fail closed instead of reaching here.
    static let mobileDefaultChatProvider = "Anthropic (Claude)"
    static let mobileDefaultChatModel = "claude-sonnet-5"
    static let mobileDefaultBackgroundProvider = "OpenRouter"
    static let mobileDefaultBackgroundModel = "deepseek/deepseek-v4-flash"
    static let mobileDefaultBackgroundMultimodalProvider = "OpenRouter"
    static let mobileDefaultBackgroundMultimodalModel = "google/gemini-2.5-flash"

    /// OpenAI's frontier tier as of 2026-09-03: $10/$50 per million tokens,
    /// a 1.05M-token window, and `xhigh`/`max` reasoning. Pinned but not the
    /// default: OpenAI is opening it to Trusted Access Program enterprises
    /// first and API access for everyone else is still "coming", so a request
    /// on a key without access is refused by OpenAI and surfaced as-is.
    static let openAIAstra = "gpt-6-astra"

    /// OpenRouter's Free Models Router: each request goes to one of the free
    /// models that is up and can take what the request needs (tools, images),
    /// so it fails and times out less than any one free model. Listed at $0,
    /// without the `:free` suffix every other free model carries. Setup's
    /// recommended free pick (product owner, 2026-09-27).
    static let openRouterFreeRouter = "openrouter/free"

    /// Stable fixture used only by the opt-in live API test. Production read-
    /// aloud preparation resolves its `AITask` route from synced Settings.
    static let paperTextToSpeechPreparation = "openai/gpt-5.6-luna"

    /// Batch transcription's product default, for dictation after the mic
    /// closes and for recordings: GPT-4o mini Transcribe under its OpenRouter
    /// slug, because every transcription goes to OpenRouter (2026-09-27). The
    /// bare id an earlier build stored is read as this one
    /// (`ManagedTranscriptionClient.canonicalModel`).
    static let batchTranscription = "openai/gpt-4o-mini-transcribe"
}

extension AIModelDefaults {
    /// The GPT generation number of an OpenAI model id: 5 for "gpt-5.6-sol",
    /// 6 for "gpt-6-astra", nil for "gpt-4o", "gpt-image-2", or a non-GPT id.
    /// Accepts the bare id or a routed slug ("openai/gpt-6-astra"), because
    /// OpenRouter addresses models by the latter and a prefix test on
    /// the whole string silently stops matching once the vendor is prepended.
    ///
    /// This reads the version component of a structured identifier, which is
    /// why it is code and not a model call: it decides how a request is shaped
    /// (reasoning controls, temperature, cache key, context budget), and every
    /// GPT-5-and-later gate in the app derives from it so a new generation is
    /// one number, not a dozen scattered prefix tests.
    static func openAIGeneration(of model: String) -> Int? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = normalized.split(separator: "/").last.map(String.init) ?? normalized
        guard bare.hasPrefix("gpt-") else { return nil }
        let digits = bare.dropFirst("gpt-".count).prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = bare.dropFirst("gpt-".count + digits.count)
        // "gpt-4o" is a name, not generation 4 of the reasoning line; only a
        // bare number ("gpt-5"), a minor version ("gpt-5.6") or a tier suffix
        // ("gpt-6-astra") counts.
        guard rest.isEmpty || rest.first == "." || rest.first == "-" else { return nil }
        return Int(digits)
    }

    /// GPT-5 and every later generation: reasoning models that reject an
    /// explicit temperature, count thinking inside `max_completion_tokens`,
    /// accept `reasoning_effort`, and honour `prompt_cache_key`.
    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        (openAIGeneration(of: model) ?? 0) >= 5
    }

    /// The `reasoning.effort` values a generation accepts. GPT-5 takes
    /// low/medium/high; GPT-6 adds xhigh and max (developers.openai.com,
    /// checked 2026-09-03). Wire values, shared with the iOS route store.
    static func openAIReasoningEfforts(for model: String) -> [String] {
        guard let generation = openAIGeneration(of: model), generation >= 5 else { return [] }
        return generation >= 6 ? ["low", "medium", "high", "xhigh", "max"] : ["low", "medium", "high"]
    }
}
