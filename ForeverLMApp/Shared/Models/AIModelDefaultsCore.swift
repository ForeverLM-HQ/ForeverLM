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

    /// The model Canvas Voice starts on (`KeychainService.seedCanvasVoiceRoute`):
    /// a spoken canvas edit is waited on, and the Background model it would
    /// otherwise follow can take many seconds (DeepSeek V4 Pro took 18 s). The
    /// eval of 2026-10-13 (KnowledgeMapVoice+Eval.swift: 16 spoken requests,
    /// three runs, reasoning off) put DeepSeek V4.1 Flash first: 48 of 48
    /// right, 0.62 s to the first edit (p90 0.79 s), the cheapest. Claude
    /// Haiku 5.5 was 48 of 48 at 0.94 s, Gemini 3.8 Flash 48 of 48 at 1.9 s,
    /// gpt-oss-120b 45 of 48 at 0.66 s; Apple's on-device model 9 of 16 at 2.8 s.
    static let canvasVoice = "deepseek/deepseek-v4.1-flash"

    /// The model Card Answer Check starts on
    /// (`KeychainService.seedCardAnswerCheckRoute`): a verdict and one line,
    /// waited on at each Check, so a fast cheap paid model, the one Canvas
    /// Voice's eval put first. A learner whose Default Model was a free one
    /// had every check fail when that free endpoint went away.
    static let cardAnswerCheck = "deepseek/deepseek-v4.1-flash"

    /// The model Go Deeper starts on (`KeychainService.seedGoDeeperRoute`):
    /// a question or a few sentences of reply, waited on at each press, so
    /// the same fast paid model as Card Answer Check.
    static let goDeeper = "deepseek/deepseek-v4.1-flash"
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

    /// The minor version of an OpenAI model id: 6 for "gpt-5.6-sol", nil for
    /// "gpt-6-astra" (no minor) or a non-GPT id. Same bare-or-routed rule as
    /// `openAIGeneration(of:)`.
    static func openAIMinorVersion(of model: String) -> Int? {
        guard let generation = openAIGeneration(of: model) else { return nil }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let afterGeneration = bare.dropFirst("gpt-".count + String(generation).count)
        guard afterGeneration.first == "." else { return nil }
        let digits = afterGeneration.dropFirst().prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// GPT-5.6 and every later generation. OpenRouter lists these with
    /// `supports_implicit_caching: false` and a priced cache write: the provider
    /// caches automatically but bills every written token at 1.25x the input
    /// price whether or not the prefix is ever read, and keeps the entry only
    /// minutes. Earlier GPT-5 models write for free, and `gpt-oss` is an
    /// open-weight model with ordinary implicit caching; neither is matched here
    /// (openrouter.ai/docs/guides/best-practices/prompt-caching, 2026-10-15).
    static func openAIBillsCacheWrites(_ model: String) -> Bool {
        guard let generation = openAIGeneration(of: model) else { return false }
        if generation > 5 { return true }
        return generation == 5 && (openAIMinorVersion(of: model) ?? 0) >= 6
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

/// How a model reaches OpenRouter's prompt cache.
///
/// Ground truth per model is `GET /api/v1/models/{slug}/endpoints`, whose
/// selected endpoint carries `supports_implicit_caching` and an
/// `input_cache_read` / `input_cache_write` price. We classify statically rather
/// than fetching that at request time — a network call in the request-building
/// path would add a failure mode to every chat turn — so a new model family
/// means checking those fields (`scripts/openrouter-cache-audit.py`). The
/// default is `.implicit`, and a family that falls through to it silently loses
/// its cache: that is what happened to GPT-5.6 and later, which list
/// `supports_implicit_caching: false` and bill each written token at 1.25x.
enum OpenRouterCachePolicy: Equatable {
    /// `supports_implicit_caching: true` — the provider caches repeated
    /// prefixes on its own. Sticky routing only; annotating the payload is
    /// unnecessary and some providers reject unknown fields.
    case implicit
    /// Explicit `cache_control` breakpoints, optionally with a `ttl`.
    case explicitBreakpoints(ttl: String?)
    /// No cache read pricing on the endpoint: nothing to buy.
    case unsupported
    /// Endpoint prices `input_cache_read` but reports
    /// `supports_implicit_caching: false`, and whether it honors
    /// `cache_control` is undocumented. Treated as sticky-routing-only until
    /// measured, because sending a parameter the provider rejects fails the
    /// whole request.
    case unverified

    /// Alibaba/Qwen endpoints OpenRouter documents as requiring `cache_control`.
    ///
    /// deepseek-v3.2 is retained from the original list even though OpenRouter's
    /// current docs put DeepSeek in the implicit-caching bucket: it has shipped
    /// this way, so the annotation is at worst redundant. Drop it only with a
    /// measurement, not on the strength of the doc page.
    private static let explicitBreakpointSlugs: Set<String> = [
        "deepseek/deepseek-v3.2",
        "qwen/qwen3-max",
        "qwen/qwen-plus",
        "qwen/qwen3.6-plus",
        "qwen/qwen3-coder-plus",
        "qwen/qwen3-coder-flash",
    ]

    /// Priced cache reads, no implicit caching, no documented `cache_control`.
    /// Muse Spark: input_cache_read $0.15/M vs prompt $1.25/M, but
    /// `supports_implicit_caching: false` (checked 2026-08-07), so today it
    /// caches nothing. Worth measuring — that is an 88% discount on the whole
    /// attached-source block.
    private static let unverifiedCacheSlugs: Set<String> = [
        "meta/muse-spark-1.2",
        "meta/muse-spark-1.1",
    ]

    /// Do not infer Alibaba support from the `qwen/` prefix: OpenRouter excludes
    /// snapshots and supports only the enumerated endpoints. Gemini explicit
    /// caching is normalized by OpenRouter for cache-capable Gemini models.
    static func policy(for model: String) -> OpenRouterCachePolicy {
        let lowered = model.lowercased()

        // Anthropic is the only family for which OpenRouter documents a `ttl`
        // on `cache_control`.
        if lowered.hasPrefix("anthropic/") {
            return .explicitBreakpoints(ttl: "1h")
        }
        if lowered.hasPrefix("google/gemini") {
            return .explicitBreakpoints(ttl: nil)
        }
        // GPT-5.6 and later: OpenRouter turns an Anthropic-style `cache_control`
        // block marker into OpenAI's `prompt_cache_breakpoint` and drops the
        // `ttl`; a marked prefix is kept at least 30 minutes, where the
        // automatic entry the provider writes on its own lasts about a minute.
        if lowered.hasPrefix("openai/"), AIModelDefaults.openAIBillsCacheWrites(lowered) {
            return .explicitBreakpoints(ttl: nil)
        }
        if explicitBreakpointSlugs.contains(lowered) {
            return .explicitBreakpoints(ttl: nil)
        }
        if unverifiedCacheSlugs.contains(lowered) {
            return .unverified
        }
        return .implicit
    }
}
