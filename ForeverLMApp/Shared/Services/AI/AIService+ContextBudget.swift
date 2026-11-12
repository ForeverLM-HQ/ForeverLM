import Foundation

// Central context-window budgeting for EVERY provider.
//
// Each model has a finite context window shared by input and output. The chat
// path builds a system prompt that can carry up to ~500k characters of attached
// source text — fine for Claude/Gemini, but it overflows smaller windows (some
// Groq/Cerebras models are ~8–32k) and surfaces as "Exceeded model context
// window size".
//
// Rather than patch each provider, we trim the request to fit BEFORE it is
// dispatched, in the three central entry points (`call`, `callChat`,
// `streamChat`). The system prompt keeps its head (core instructions) and loses
// its tail (where source text is appended); the conversation keeps its most
// recent turns. The response-token budget is also capped so it can't claim more
// of the window than is left after the input.
//
// This is sizing, not masking: it mirrors the hard source trims the codebase
// already applies (the iOS review brain's 12k-char cap, the 500k upstream cap).
// Truncation is always made visible with a note pointing to retrieve_sources.
extension AIService {

    /// The context window, in tokens, an authoritative source has published for
    /// this exact model — or nil when none has.
    ///
    /// Every model has its own window, so there is no "reasonable default":
    /// a guessed number reaches the composer's context gauge as if it were
    /// measured, and makes the budgeter trim sources that would have fit. The
    /// resolution order is therefore lookup, lookup, lookup, nil:
    ///
    /// 1. `publishedContextWindows` — the lab's documented window for a model
    ///    the app pins (or pinned, so stored selections still resolve).
    /// 2. The host's own directory. OpenRouter publishes `context_length` per
    ///    model; the app caches the table on every directory fetch.
    /// 3. The window captured when the user promoted a directory model.
    /// 4. nil. Callers skip trimming and the UI says the window is not
    ///    published; nothing invents a figure.
    ///
    /// The value is what the budgeter must respect, which for GPT-6 Astra is
    /// its 922k input cap rather than its 1.05M total window.
    static func contextWindowTokens(provider: AIProvider, model: String) -> Int? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch provider {
        case .anthropic, .openai, .gemini, .xai, .meta:
            if let published = publishedContextWindow(provider: provider, model: trimmed) {
                return published
            }
            // The closed labs' own model lists carry no window, so the next
            // authority is OpenRouter's listing of the same model.
            return AIModelCatalog.openRouterDirectoryContextLength(
                OpenRouterModelID.slug(provider: provider, model: trimmed)
            )
        case .groq, .cerebras, .together, .fireworks, .nvidia:
            return publishedContextWindow(provider: provider, model: trimmed)
        case .openRouter:
            return openRouterContextWindow(slug: trimmed)
        }
    }

    /// OpenRouter slugs: the lab's published figure for a closed-lab model,
    /// then OpenRouter's own `context_length` for the slug, then the length
    /// captured when the user added the model from the directory.
    private static func openRouterContextWindow(slug: String) -> Int? {
        if let delegated = labContextWindow(vendorQualified: slug) {
            return delegated
        }
        if let directory = AIModelCatalog.openRouterDirectoryContextLength(slug) {
            return directory
        }
        if let custom = AIModelCatalog.customContextLength(forOpenRouterModel: slug), custom > 0 {
            return custom
        }
        return nil
    }

    /// "anthropic/claude-opus-4.8" → Anthropic's published window for
    /// "claude-opus-4-8". Only the closed labs are delegated; an open-weight
    /// slug ("deepseek/…", "meta-llama/…") is answered by the host's directory.
    private static func labContextWindow(vendorQualified slug: String) -> Int? {
        let lowered = slug.lowercased()
        let delegations: [(prefix: String, provider: AIProvider)] = [
            ("anthropic/", .anthropic),
            ("openai/", .openai),
            ("google/", .gemini),
            ("x-ai/", .xai),
            ("meta/", .meta),
        ]
        for delegation in delegations where lowered.hasPrefix(delegation.prefix) {
            let bare = String(slug.dropFirst(delegation.prefix.count))
            return publishedContextWindow(provider: delegation.provider, model: bare)
        }
        return nil
    }

    private static func publishedContextWindow(provider: AIProvider, model: String) -> Int? {
        var key = model.lowercased()
        if provider == .anthropic {
            // OpenRouter spells versions with a dot ("claude-opus-4.8") where
            // Anthropic uses a dash, and Anthropic's dated aliases
            // ("claude-sonnet-4-5-20250929") name the same model as the bare ID.
            key = key.replacingOccurrences(of: ".", with: "-")
            if let range = key.range(of: #"-\d{8}$"#, options: .regularExpression) {
                key.removeSubrange(range)
            }
            if key.hasSuffix("-fast") {
                key.removeLast("-fast".count)
            }
        }
        return publishedContextWindows[provider]?[key]
    }

    /// Documented context windows, keyed by the exact model ID the provider
    /// accepts. Only models the app pins or has pinned appear here; a model
    /// that is missing is answered by a directory or reported as unknown,
    /// never by a neighbour's figure. Sources are the labs' model pages,
    /// checked on the dates in the comments.
    static let publishedContextWindows: [AIProvider: [String: Int]] = [
        .anthropic: [
            // 1M at standard pricing for the current line (verified 2026-07-25).
            "claude-sonnet-5": 1_000_000,
            "claude-fable-5": 1_000_000,
            "claude-opus-5": 1_000_000,
            "claude-sonnet-4-6": 1_000_000,
            "claude-opus-4-6": 1_000_000,
            "claude-opus-4-7": 1_000_000,
            "claude-opus-4-8": 1_000_000,
            // The pre-4.6 aliases ("claude-sonnet-4-0", "claude-opus-4-0") name
            // one dated snapshot each, not the latest 4.x model. Claude Sonnet 4
            // is the one earlier model with the 1M window; Claude Opus 4 is
            // 200k (Anthropic's model pages and OpenRouter's directory agree,
            // checked 2026-09-07).
            "claude-sonnet-4": 1_000_000,
            "claude-sonnet-4-0": 1_000_000,
            "claude-opus-4": 200_000,
            "claude-opus-4-0": 200_000,
            // 200k for Haiku 4.5 and the pre-4.6 line. Sonnet 4.5's 1M is a
            // beta header on the Claude API, so its documented figure stands
            // even though OpenRouter lists the model at 1M.
            "claude-haiku-4-5": 200_000,
            "claude-sonnet-4-5": 200_000,
            "claude-opus-4-5": 200_000,
            "claude-opus-4-1": 200_000,
            "claude-3-7-sonnet": 200_000,
            "claude-3-5-sonnet": 200_000,
            "claude-3-5-haiku": 200_000,
        ],
        .openai: [
            // Astra and the GPT-5.6 line: 1,050,000 total, input capped at
            // 922,000 (developers.openai.com, Astra checked 2026-09-03, the
            // 5.6 models 2026-09-07). The input cap is the figure a prompt
            // has to fit; OpenRouter lists the 1.05M total, which a prompt
            // cannot use. Bare "gpt-5.6" is OpenAI's alias for Sol.
            "gpt-6-astra": 922_000,
            "gpt-5.6": 922_000,
            "gpt-5.6-sol": 922_000,
            "gpt-5.6-terra": 922_000,
            "gpt-5.6-luna": 922_000,
            // GPT-5.5: 1,050,000 with no stated input cap (checked 2026-09-07).
            "gpt-5.5": 1_050_000,
            "gpt-4o": 128_000,
        ],
        .gemini: [
            // Google documents 1,048,576 input tokens for these.
            "gemini-3.5-flash": 1_048_576,
            "gemini-3-pro-preview": 1_048_576,
            "gemini-3-flash-preview": 1_048_576,
            "gemini-2.5-pro": 1_048_576,
            "gemini-2.5-flash": 1_048_576,
            "gemini-2.5-flash-lite": 1_048_576,
            "gemini-2.0-flash": 1_048_576,
        ],
        .xai: [
            "grok-4.3": 1_000_000,
            "grok-4.7": 500_000,
            "grok-4.6": 500_000,
            // grok-4.5's window is not on xAI's model page; OpenRouter's
            // listing of x-ai/grok-4.5 answers for it. The retired Grok 3
            // line documented 131,072.
            "grok-3": 131_072,
            "grok-3-mini": 131_072,
            "grok-3-mini-fast": 131_072,
        ],
        .meta: [
            "muse-spark-1.2": 1_048_576,
            "muse-spark-1.2-contributor": 1_048_576,
            "muse-spark-1.1": 1_048_576,
        ],
        // Retired hosts: only the windows those hosts documented for the
        // models the app pinned. Stored selections on these hosts are reset
        // to Anthropic before a request is sent, so these serve Settings only.
        .groq: [
            "openai/gpt-oss-120b": 131_072,
            "openai/gpt-oss-20b": 131_072,
            "qwen/qwen3-32b": 131_072,
        ],
        .cerebras: [
            "gpt-oss-120b": 65_536,
            "llama3.1-8b": 8_192,
        ],
        .together: [
            // Together serves Inkling at 524,288 tokens, half the model's own
            // 1M (together.ai/models/inkling, checked 2026-09-07); the table
            // carried the model's figure, not the host's, until then.
            "thinkingmachines/inkling": 524_288,
            "thinkingmachines/inkling-nvfp4": 524_288,
        ],
        .fireworks: [
            "accounts/fireworks/models/inkling": 1_000_000,
        ],
        .nvidia: [
            "nvidia/nemotron-3-ultra-550b-a55b": 1_000_000,
            "nvidia/nemotron-3-super-120b-a12b": 1_000_000,
            "nvidia/nemotron-3-nano-30b-a3b": 262_144,
        ],
    ]

    /// Rough characters-per-token. English averages ~4; we keep the estimate
    /// here and absorb its imprecision via the utilization factor below.
    static let approxCharsPerToken = 4

    /// Fraction of the window we actually fill, leaving slack for the
    /// char→token estimate being imperfect and for chat-template / tool-schema
    /// overhead the provider adds on top of our text.
    private static let contextWindowUtilization = 0.85
    private static let contextOverheadTokens = 512

    /// Share of the input budget the resident source block may claim.
    ///
    /// The block is resent on every turn and every tool round, so it is the
    /// one part of the request whose size the app decides rather than the
    /// conversation. Half leaves the other half for instructions, history,
    /// tool schemas, and the tool results a turn accumulates; the emergency
    /// trim in `budgetedChatRequest` still stands behind it.
    private static let sourceContextShare = 0.5

    /// Hard ceiling on the resident source block, in tokens, whatever the
    /// window. A share of a million-token window is ~400k tokens resent on every
    /// round, and a cold cache turns each rewrite of it into a multi-dollar
    /// call (a teach-back over a whole notebook measured 330k tokens a call:
    /// $2.65 per rewrite, 4 rewrites, $10.61 of one chat's $15.17). Past the
    /// ceiling a source is read on demand with `retrieve_sources`, which
    /// appends only the passage asked for.
    static let sourceContextMaxTokens = 100_000

    static let budgetSourceTruncationNote =
        "\n\n[Attached source text truncated to fit this model's context window. Use retrieve_sources for focused passages from omitted text.]"
    static let budgetHistoryTruncationNote =
        "[Earlier conversation truncated to fit this model's context window.]\n\n"

    /// Whether a system prompt is stable enough that a cache breakpoint pays for
    /// itself.
    ///
    /// Emergency budget truncation cuts the system prompt at
    /// `inputCharacterBudget - turnsSize`, and `turnsSize` grows every turn — so
    /// the head lands on a different boundary each request and no write is ever
    /// read back. Marking it anyway is not merely wasted, it is *more expensive
    /// than not caching*: a write costs 1.25x base input at the 5-minute TTL and
    /// 2x at the 1-hour TTL, against 1x for an unmarked prefix. Breaking even on
    /// a 5-minute write needs the same prefix re-read within the TTL roughly 28%
    /// of the time; a boundary that moves every turn is nowhere near that.
    ///
    /// Detected from the payload rather than threaded through as a flag: both
    /// truncation sites (`budgetedChatRequest` and the native-tool path) append
    /// this note as a suffix, so every marker builder can ask the question
    /// itself and no future call site can forget to pass the flag along.
    static func systemPromptIsCacheable(_ system: String) -> Bool {
        !system.hasSuffix(budgetSourceTruncationNote)
    }

    /// The input budget in characters a request may carry for a given
    /// provider+model after reserving the response budget — the same arithmetic
    /// `budgetedChatRequest` trims against, exposed so callers can anticipate
    /// trimming (e.g. compact accumulated tool results) before it happens.
    ///
    /// Nil when no window is published for the model: there is nothing to fit
    /// to, so callers send the request as assembled and let the provider
    /// answer for its own limit.
    static func inputCharacterBudget(
        provider: AIProvider,
        model: String,
        requestedMaxTokens: Int
    ) -> Int? {
        guard let window = contextWindowTokens(provider: provider, model: model) else { return nil }
        let effectiveWindow = max(1_024, Int(Double(window) * contextWindowUtilization))

        // Response may claim the requested budget, but never more than a quarter
        // of the window — that cap only bites on small windows, leaving room for
        // the input. Large-window models keep their full requested budget.
        let responseTokens = min(max(256, requestedMaxTokens), max(256, effectiveWindow / 4))

        let inputTokenBudget = max(256, effectiveWindow - contextOverheadTokens - responseTokens)
        return inputTokenBudget * approxCharsPerToken
    }

    /// Characters of verbatim source text a chat may keep resident for a given
    /// provider+model — the text dropped-in sources load in full, before the
    /// model has to reach for `retrieve_sources`.
    ///
    /// Derived from the window rather than fixed, so a book dropped into a chat
    /// on a million-token model loads whole instead of stopping at the fourth
    /// chapter, while a small-window model gets a head that actually fits.
    /// Nil when no window is published: the caller keeps its standing figure,
    /// nothing here invents one.
    static func sourceContextCharacterBudget(
        provider: AIProvider,
        model: String,
        requestedMaxTokens: Int
    ) -> Int? {
        guard let input = inputCharacterBudget(
            provider: provider,
            model: model,
            requestedMaxTokens: requestedMaxTokens
        ) else { return nil }
        return max(0, min(Int(Double(input) * sourceContextShare), sourceContextMaxTokens * approxCharsPerToken))
    }

    /// The response-token budget a request may claim for a given provider+model:
    /// the requested budget, capped so it can never claim more than a quarter of
    /// the effective window. Same arithmetic `budgetedChatRequest` applies.
    /// With no published window the cap does not apply and the request keeps
    /// its own budget.
    static func cappedResponseTokens(
        provider: AIProvider,
        model: String,
        requestedMaxTokens: Int
    ) -> Int {
        guard let window = contextWindowTokens(provider: provider, model: model) else {
            return requestedMaxTokens
        }
        let effectiveWindow = max(1_024, Int(Double(window) * contextWindowUtilization))
        return min(max(256, requestedMaxTokens), max(256, effectiveWindow / 4))
    }

    /// Trim a multi-turn chat request to fit the model's context window.
    /// Returns the trimmed system prompt, trimmed messages, and a response-token
    /// budget guaranteed to leave room for the input within the window.
    static func budgetedChatRequest(
        provider: AIProvider,
        model: String,
        system: String,
        messages: [(role: String, content: String)],
        requestedMaxTokens: Int
    ) -> (system: String, messages: [(role: String, content: String)], maxTokens: Int) {
        // No published window: nothing to fit to, so the request goes as built.
        guard let inputCharBudget = inputCharacterBudget(
            provider: provider,
            model: model,
            requestedMaxTokens: requestedMaxTokens
        ) else {
            return (system, messages, requestedMaxTokens)
        }
        let responseTokens = cappedResponseTokens(
            provider: provider,
            model: model,
            requestedMaxTokens: requestedMaxTokens
        )

        let systemCount = system.count
        let messagesCount = messages.reduce(0) { $0 + $1.content.count + perMessageOverheadChars }

        if systemCount + messagesCount <= inputCharBudget {
            return (system, messages, responseTokens)
        }

        // Keep the most recent turns; give the conversation up to half the budget.
        let messagesBudget = min(messagesCount, inputCharBudget / 2)
        let trimmedMessages = trimMessagesToBudget(messages, budget: messagesBudget)
        let trimmedMessagesCount = trimmedMessages.reduce(0) { $0 + $1.content.count + perMessageOverheadChars }

        // System keeps its head (instructions); its tail (attached source) is dropped.
        let systemBudget = max(0, inputCharBudget - trimmedMessagesCount)
        let trimmedSystem = systemCount <= systemBudget
            ? system
            : String(system.prefix(systemBudget)) + budgetSourceTruncationNote

        return (trimmedSystem, trimmedMessages, responseTokens)
    }

    /// Trim a single-turn (system + user) request to fit the model's window.
    static func budgetedOneShotRequest(
        provider: AIProvider,
        model: String,
        system: String,
        user: String,
        requestedMaxTokens: Int
    ) -> (system: String, user: String, maxTokens: Int) {
        let budgeted = budgetedChatRequest(
            provider: provider,
            model: model,
            system: system,
            messages: [(role: "user", content: user)],
            requestedMaxTokens: requestedMaxTokens
        )
        return (budgeted.system, budgeted.messages.first?.content ?? "", budgeted.maxTokens)
    }

    // MARK: - Internals

    /// Approximate per-message structural overhead (role markers, separators)
    /// the provider adds around each turn, charged in characters. Read by
    /// callers that size a request's parts to fit (`sourceIdeaTextParts`).
    static let perMessageOverheadChars = 16

    /// Keep whole messages from the most recent backward until the budget is
    /// exhausted. The latest message is always kept — truncated from its front
    /// (preserving the end, where the user's actual ask lives) if it alone
    /// exceeds the budget.
    private static func trimMessagesToBudget(
        _ messages: [(role: String, content: String)],
        budget: Int
    ) -> [(role: String, content: String)] {
        var kept: [(role: String, content: String)] = []
        var remaining = budget

        for message in messages.reversed() {
            let cost = message.content.count + perMessageOverheadChars
            if cost <= remaining {
                kept.append(message)
                remaining -= cost
            } else if kept.isEmpty {
                // Always keep at least the latest message, truncated to fit.
                let take = max(0, remaining - perMessageOverheadChars - budgetHistoryTruncationNote.count)
                let content = take >= message.content.count
                    ? message.content
                    : budgetHistoryTruncationNote + String(message.content.suffix(take))
                kept.append((role: message.role, content: content))
                break
            } else {
                // Older turns drop off once the budget is spent.
                break
            }
        }

        return kept.reversed()
    }
}
