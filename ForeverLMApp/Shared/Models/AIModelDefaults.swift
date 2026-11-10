import Foundation

/// Translates the app's provider-native model IDs into OpenRouter slugs.
///
/// Every OpenRouter-backed chat request uses slugs addressed as
/// `{vendor}/{model}` and does not use the labs' own IDs verbatim. Three rules
/// cover the whole pinned catalogue; all eleven pinned models were checked
/// against the live directory on 2026-07-25:
///
/// | app | OpenRouter | rule |
/// |---|---|---|
/// | `claude-sonnet-5` | `anthropic/claude-sonnet-5` | vendor prefix |
/// | `claude-opus-4-8` | `anthropic/claude-opus-4.8` | prefix + version dash→dot |
/// | `gpt-5.6` | `openai/gpt-5.6-sol` | prefix + alias expansion |
///
/// Deliberately not a stored table: the catalogue is edited often, and a table
/// would drift silently until a model 404'd mid-chat. These rules are derived
/// from each lab's own naming convention, so a new model of an existing family
/// maps without an edit here.
enum OpenRouterModelID {

    /// OpenRouter's vendor segment for a provider. Note `x-ai`, which matches
    /// neither the enum case nor xAI's own host name.
    static func vendor(for provider: AIProvider) -> String? {
        switch provider {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .gemini: return "google"
        case .xai: return "x-ai"
        case .meta: return "meta"
        // Open-weight hosts were retired in favour of OpenRouter, and their
        // stored model IDs are already OpenRouter slugs.
        case .openRouter, .groq, .cerebras, .together, .fireworks, .nvidia:
            return nil
        }
    }

    /// The slug to send to OpenRouter for a provider-native model ID.
    ///
    /// An ID that already carries a vendor segment is used as the base slug:
    /// the OpenRouter catalogue stores full slugs, so only the closed labs'
    /// native IDs need translating.
    ///
    /// Speed is not part of the slug. OpenRouter serves a lab's fast tier as a
    /// separate *endpoint* of the same model (`openai/fast`, `anthropic/fast`),
    /// selected through `provider.order` — see `OpenRouterSpeedTier` — so the
    /// model id, and with it the prompt cache key, is the same at every speed.
    static func slug(provider: AIProvider, model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("/"), let vendor = vendor(for: provider) {
            return "\(vendor)/\(canonicalModel(trimmed, provider: provider))"
        }
        return trimmed
    }

    /// The alias and version-form rules live in `OpenRouterSlugNormalization`
    /// so the price overlay, built for both targets, names the same row.
    private static func canonicalModel(_ model: String, provider: AIProvider) -> String {
        guard let vendor = vendor(for: provider) else { return model }
        return OpenRouterSlugNormalization.canonicalModel(model, vendor: vendor)
    }
}

/// A model's effort control as OpenRouter's catalog publishes it under
/// `reasoning_config`. Wire strings are kept verbatim, so the cache says
/// exactly what OpenRouter said, even a level a later catalog adds before the
/// app has an `AIEffort` for it; `AIRequestOptionSupport` decides what to offer.
struct OpenRouterReasoningEfforts: Codable, Equatable, Sendable {
    /// `supported_reasoning_efforts`, lowercased, in the catalog's own order.
    let efforts: [String]
    /// `default_reasoning_effort`: the level the model runs at when no effort
    /// is sent. Nil when the catalog names none.
    let defaultEffort: String?
}

extension AIModelDefaults {
    /// Unit-test fixture only; the live cache diagnostic resolves Chat settings.
    static let promptCacheDiagnosticFixture = "anthropic/claude-haiku-4.5"
    /// Explicitly authorized one-off historical podcast cleanup route.
    static let podcastCleanupMaintenance = "gpt-5-nano"
    static let latestClaude = "claude-opus-5"
    static let latestGemini = "gemini-3.5-flash"
    static let defaultAnthropic = "claude-sonnet-5"
    /// OpenAI's alias for "gpt-5.6-sol".
    static let defaultOpenAI = "gpt-5.6"
    static let defaultGemini = latestGemini

    /// Gemini Flash on OpenRouter — Background › Multimodal's shipped model
    /// (`KeychainService.defaultBackgroundMultimodalTaskRoute`). The general
    /// OpenRouter default is text-only, so work that reads an image needs a
    /// model of its own. The cost estimator already maps `google/gemini*`
    /// OpenRouter slugs to Google's rates, and the managed proxy prices it live.
    static let visionOpenRouter = "google/gemini-2.5-flash"

    // Pinned lists carry only the latest generation of each model class
    // (Sonnet, Opus, Flash, Pro, …). When a lab ships a successor, the
    // superseded model is dropped here; pricing and display names keep the
    // old IDs so stored selections and usage history still resolve.
    static let preferredAnthropic = [
        "claude-sonnet-5",
        "claude-fable-5",
        latestClaude,
        "claude-haiku-4-5",
    ]

    // gemini-3-pro-preview was shut down 2026-03-09; its display name survives
    // in AIModelDisplayName so stored selections still render.
    static let preferredGemini = [
        latestGemini,
        "gemini-2.5-flash-lite",
    ]

    // Together, Groq, Cerebras, Fireworks, and NVIDIA are retired chat hosts:
    // their pinned lists survive only so stored selections keep resolving, and
    // their models are served through OpenRouter instead (below). Together was
    // retired because the Cloudflare AI Gateway cannot front api.together.xyz,
    // so its spend never showed up alongside every other provider's; Inkling
    // went with it, having no OpenRouter listing to fall back to.
    static let defaultTogether = "thinkingmachines/Inkling"
    static let defaultFireworks = "accounts/fireworks/models/inkling"
    static let defaultNVIDIA = "nvidia/nemotron-3-ultra-550b-a55b"

    static let preferredTogether = [defaultTogether]
    static let preferredFireworks = [defaultFireworks]
    static let preferredNVIDIA = [
        defaultNVIDIA,
        "nvidia/nemotron-3-super-120b-a12b",
        "nvidia/nemotron-3-nano-30b-a3b",
    ]

    // OpenRouter is the managed Gateway's host for the curated cross-provider
    // catalog, so one centrally stored Provider Key covers DeepSeek, Kimi, Qwen,
    // GLM, GPT OSS, Mistral, Muse Spark, Nemotron, and the multimodal default.
    // The Chinese labs' models are offered
    // ONLY through OpenRouter's US-routed inference — the labs' own APIs
    // (api.deepseek.com, api.moonshot.ai) are deliberately not integrated.
    // Slugs are OpenRouter's cross-host model IDs (verified against
    // openrouter.ai/api/v1/models 2026-08-07). Grouped per maker so the
    // catalog can present models under the lab that trained them rather than
    // the host that serves them.
    //
    // Every maker carries at least two entries where the maker has at least
    // two models: a collapsed group tops up to two cards from the curated list
    // only (never from the async directory), so a single pinned model renders
    // a lone card beside the toggle.
    static let openRouterDeepSeek = ["deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro"]
    static let openRouterMoonshot = ["moonshotai/kimi-k3", "moonshotai/kimi-k2.6"]
    static let openRouterOpenAI = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"]
    static let openRouterQwen = ["qwen/qwen3-32b", "qwen/qwen3-235b-a22b-2507"]
    static let openRouterZAI = ["z-ai/glm-5.2", "z-ai/glm-5.1"]
    static let openRouterMistral = [
        "mistralai/mistral-large-2512",
        "mistralai/mistral-small-2603",
    ]
    static let latestMuseSpark = "muse-spark-1.2"
    /// Meta's discounted tier, priced for training consent: its one host
    /// trains on prompts. Offered and labelled, and hidden while the Data &
    /// Privacy switch is on — see `trainsOnInputs`. Retired 2026-09-10 while
    /// the router's account refused it; back since 2026-09-14.
    static let museSparkContributor = "muse-spark-1.2-contributor"
    static let latestOpenRouterMuseSpark = "meta/\(latestMuseSpark)"
    static let retiredOpenRouterMuseSpark = "meta/muse-spark-1.1"
    static let openRouterMeta = [latestOpenRouterMuseSpark, "meta-llama/llama-4-maverick"]
    static let openRouterNVIDIA = [
        "nvidia/nemotron-3-ultra-550b-a55b",
        "nvidia/nemotron-3-super-120b-a12b",
        "nvidia/nemotron-3-nano-30b-a3b",
    ]
    static let defaultOpenRouter = "deepseek/deepseek-v4-flash"

    static let preferredOpenRouter =
        openRouterDeepSeek + openRouterMoonshot + openRouterOpenAI
        + openRouterQwen + openRouterZAI + openRouterMistral
        + openRouterMeta + openRouterNVIDIA + [visionOpenRouter]

    /// Models a stored selection may still name but no managed route can
    /// serve. A retired selection is refused, never substituted: the model
    /// the learner picked and the one that would answer differ in price.
    /// Muse Spark 1.1 left OpenRouter.
    static func isRetiredChatModel(provider: AIProvider, model: String) -> Bool {
        provider == .openRouter && model == retiredOpenRouterMuseSpark
    }

    // MARK: - Suggested chat models

    /// Settings › Chat's Suggested list, as OpenRouter slugs in the order it
    /// shows them: one model per maker, "the top model that's still somewhat
    /// affordable" (product owner, 2026-09-28). Picked by hand, then shown as the
    /// newest release of each pick's family OpenRouter lists
    /// (`AIModelCatalog.newestReleases`, 2026-09-30), so Gemini 3.9 Flash
    /// would take Gemini 3.8 Flash's place the day OpenRouter lists it. A
    /// new family (Gemini 4 Argon beside Gemini Flash) still takes an edit
    /// here: whether it is affordable is the judgment this list exists to
    /// make. DeepSeek V4.1 Flash stands in for the "V4.5 Flash" asked for,
    /// which OpenRouter did not list that day, and Mistral Small 4 is the
    /// model OpenRouter lists as Mistral 4.
    static let suggestedChatModels = [
        "anthropic/claude-opus-5.5",
        "openai/gpt-6-astra",
        "google/gemini-3.8-flash",
        "x-ai/grok-4.7",
        "deepseek/deepseek-v4.1-flash",
        "qwen/qwen3.8-omni-flash",
        "z-ai/glm-5.3-flash",
        "mistralai/mistral-small-2603",
        "meta/muse-spark-1.3-contributor",
        "nvidia/nemotron-3-ultra-550b-a55b",
        "thinkingmachines/inkling",
    ]

    /// Settings › Background's Suggested list for work that reads text, as
    /// Settings › Chat suggests its own, one model per maker, but a price tier
    /// down: background work runs unattended over every source, so the
    /// maker's cheap tier is the one to suggest (product owner, 2026-09-28: the
    /// chat's layout "for voice, images, videos, and background"). Every one
    /// takes tools, as the directory said on 2026-09-28: Haiku 4.5 $1/$5,
    /// GPT-6 Luna $0.10/$0.50, Gemini 3.1 Flash Lite $0.25/$1.50, Grok 4.3
    /// $1.25/$2.50, DeepSeek V4 Flash (the shipped default) $0.14/$0.28,
    /// Qwen3.8 Flash $0.15/$0.47, GLM 5.3 Flash $0.15/$0.50, Mistral Small 4
    /// $0.15/$0.60, Muse Glimmer 30B $0.30/$1.20 (not Muse Spark's
    /// Contributor tier, which trains on what it is sent), Nemotron 3 Super
    /// $0.08/$0.45, Inkling Small $0.45/$1.20. Shown as each family's newest
    /// release, as Chat's are, but only one still cheaper than the maker's
    /// Chat suggestion (`ChatModelLists.isTierBelow`): on 2026-09-30 that
    /// made Gemini 3.1 Flash Lite show as 3.5 Flash Lite ($0.30/$2.50) and
    /// kept Grok 4.3, whose successors cost what Grok 4.7 does.
    static let suggestedBackgroundModels = [
        "anthropic/claude-haiku-4.5",
        "openai/gpt-6-luna",
        "google/gemini-3.1-flash-lite",
        "x-ai/grok-4.3",
        defaultOpenRouter,
        "qwen/qwen3.8-flash",
        "z-ai/glm-5.3-flash",
        "mistralai/mistral-small-2603",
        "meta/muse-glimmer-30b",
        "nvidia/nemotron-3-super-120b-a12b",
        "thinkingmachines/inkling-small",
    ]

    /// The same for work that reads images: each maker's cheap tier that
    /// does, so DeepSeek's is V4.1 Flash, and NVIDIA, whose cheap Nemotrons
    /// read only text, has none.
    static let suggestedBackgroundImageModels = [
        "anthropic/claude-haiku-4.5",
        "openai/gpt-6-luna",
        "google/gemini-3.1-flash-lite",
        "x-ai/grok-4.3",
        "deepseek/deepseek-v4.1-flash",
        "qwen/qwen3.8-flash",
        "z-ai/glm-5.3-flash",
        "mistralai/mistral-small-2603",
        "meta/muse-glimmer-30b",
        "thinkingmachines/inkling-small",
    ]

    /// Whether the host serving this model trains on what is sent to it —
    /// `AIDataPolicy.trainsOnInputs(modelSlug:)`, keyed on the OpenRouter slug the
    /// managed rail actually requests, so the Meta route's bare id and
    /// OpenRouter's qualified slug agree.
    static func trainsOnInputs(provider: AIProvider, model: String) -> Bool {
        AIDataPolicy.trainsOnInputs(modelSlug: OpenRouterModelID.slug(provider: provider, model: model))
    }

    // Terra and Luna must be pinned explicitly or the extra-list prefix filter
    // would hide them as gpt-5.6 variants. Astra sits after the default on
    // purpose: it is the stronger tier, but OpenAI has not opened it to every
    // API account yet, so Sol keeps the default until it has.
    static let preferredOpenAI = [defaultOpenAI, openAIAstra, "gpt-5.6-terra", "gpt-5.6-luna"]
    static let preferredGroq = ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3-32b"]
    static let preferredCerebras = ["gpt-oss-120b", "llama3.1-8b", "zai-glm-4.7", "qwen-3-235b-a22b-instruct-2507"]
    // grok-4.3 is the workhorse tier ($1.25/$2.50, 1M context), grok-4.7 the
    // frontier tier ($2/$6, 500k; docs.x.ai, verified 2026-09-22). grok-4.5
    // and grok-4.6 are superseded frontier releases. The grok-3* slugs are
    // retired (they redirect server-side to current models) and live on only in
    // pricing/display-name tables so stored selections keep resolving.
    static let preferredXAI = ["grok-4.3", "grok-4.7"]
    // Contributor trains on prompts and is hidden by the Data & Privacy
    // switch: see `trainsOnInputs`.
    static let preferredMeta = [latestMuseSpark, museSparkContributor]

    /// Curated (pinned) models for a provider — usable without a model-list API call.
    static func preferredModels(for provider: AIProvider) -> [String] {
        switch provider {
        case .openai:    return preferredOpenAI
        case .anthropic: return preferredAnthropic
        case .groq:      return preferredGroq
        case .cerebras:  return preferredCerebras
        case .xai:       return preferredXAI
        case .gemini:    return preferredGemini
        case .meta:      return preferredMeta
        case .together:  return preferredTogether
        case .fireworks: return preferredFireworks
        case .nvidia:    return preferredNVIDIA
        case .openRouter: return preferredOpenRouter
        }
    }
}

/// One selectable chat model: the lab that made it, its canonical lab or
/// OpenRouter identity, and that identity's model ID.
struct AIModelCatalogEntry: Identifiable, Hashable {
    let maker: AIModelMaker
    let provider: AIProvider
    let modelID: String
    /// Display name carried by user-added OpenRouter models (from OpenRouter's
    /// directory). Nil for pinned entries, which resolve via AIModelDisplayName.
    var customName: String? = nil

    var id: String { "\(provider.slashToken)|\(modelID)" }

    var displayName: String {
        customName ?? AIModelDisplayName.textModelName(modelID, provider: provider)
    }

    /// Whether every host serving this model trains on prompts. Such an
    /// entry is labelled wherever it is listed and hidden while the Data &
    /// Privacy switch is on — see `AIModelCatalog.hidesTrainingModels`.
    var trainsOnInputs: Bool {
        AIModelDefaults.trainsOnInputs(provider: provider, model: modelID)
    }
}

/// List prices for catalog models, shared by the Settings cards and the
/// composer model menu so both quote the same figure. Rates come from the
/// static pricing table (kept fresh by `AIModelPriceRefresher`), falling back
/// to the prices captured when a directory model was added. Unknown models
/// return nil — callers show nothing rather than a guessed number.
enum AIModelListPrice {
    /// USD per 1M input/output tokens from the pricing table alone.
    static func rates(provider: AIProvider, modelID: String) -> (input: Double, output: Double)? {
        AIProviderPricing.textTokenRates(provider: provider, model: modelID)
            .map { (input: $0.input, output: $0.output) }
    }

    /// Table rates, then the prices a user-added directory model carried.
    static func rates(for entry: AIModelCatalogEntry) -> (input: Double, output: Double)? {
        if let rates = rates(provider: entry.provider, modelID: entry.modelID) {
            return rates
        }
        if let custom = AIModelCatalog.customOpenRouterModel(id: entry.modelID),
           let input = custom.inputUSDPerMTokens,
           let output = custom.outputUSDPerMTokens {
            return (input, output)
        }
        return nil
    }

    /// "$3/$15" — the compact input/output pair used on the Settings cards.
    static func label(provider: AIProvider, modelID: String) -> String? {
        rates(provider: provider, modelID: modelID).map { pairLabel(input: $0.input, output: $0.output) }
    }

    /// "$3/$15" — the compact input/output pair used on the Settings cards.
    static func label(for entry: AIModelCatalogEntry) -> String? {
        rates(for: entry).map { pairLabel(input: $0.input, output: $0.output) }
    }

    /// "$3/$15" — the pair every Settings price label is built from, so a
    /// struck-through list price and the effective price beside it are
    /// formatted identically.
    static func pairLabel(input: Double, output: Double) -> String {
        "\(dollars(input))/\(dollars(output))"
    }

    /// "$0.6" — at most two decimals, no grouping, so prices stay compact.
    static func dollars(_ value: Double) -> String {
        let formatted = value.formatted(
            .number
                .precision(.fractionLength(0...2))
                .grouping(.never)
        )
        return "$\(formatted)"
    }
}

/// The model-first catalog behind the chat model picker and the "Chat"
/// section in Settings, grouped by model maker. The pickers offer a short
/// default set; everything else in the catalog is opt-in, stored as an
/// *enabled* set the user grows by ticking models in Settings.
enum AIModelCatalog {
    private static let enabledIDsKey = "chatModels.enabledIDs"

    /// The models the pickers offer before the user opts into more: the
    /// recommended default plus one strong pick per major lab.
    private static let defaultEnabledIDs: Set<String> = Set(
        [
            (AIProvider.anthropic, AIModelDefaults.defaultAnthropic),
            (AIProvider.anthropic, "claude-fable-5"),
            (AIProvider.anthropic, "claude-haiku-4-5"),
            (AIProvider.openai, AIModelDefaults.defaultOpenAI),
            (AIProvider.gemini, AIModelDefaults.latestGemini),
        ].map { AIModelCatalogEntry(maker: .other, provider: $0.0, modelID: $0.1).id }
    )

    struct MakerGroup {
        let maker: AIModelMaker
        let entries: [AIModelCatalogEntry]

        /// Unique API hosts serving this maker's models, in catalog order.
        var hosts: [AIProvider] {
            var seen = Set<AIProvider>()
            return entries.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
        }
    }

    /// Catalog order: the closed-model labs first, then the open-weight makers.
    /// Muse Spark is temporarily served by Meta's first-party Model API; Llama
    /// remains an OpenRouter model.
    private static let pinnedMakerGroups: [MakerGroup] = [
        MakerGroup(maker: .anthropic, entries: entries(.anthropic, .anthropic, AIModelDefaults.preferredAnthropic)),
        MakerGroup(
            maker: .openai,
            entries: entries(.openai, .openai, AIModelDefaults.preferredOpenAI)
                + entries(.openai, .openRouter, AIModelDefaults.openRouterOpenAI)
        ),
        MakerGroup(maker: .google, entries: entries(.google, .gemini, AIModelDefaults.preferredGemini)),
        MakerGroup(maker: .xai, entries: entries(.xai, .xai, AIModelDefaults.preferredXAI)),
        MakerGroup(maker: .deepseek, entries: entries(.deepseek, .openRouter, AIModelDefaults.openRouterDeepSeek)),
        MakerGroup(maker: .moonshot, entries: entries(.moonshot, .openRouter, AIModelDefaults.openRouterMoonshot)),
        MakerGroup(maker: .qwen, entries: entries(.qwen, .openRouter, AIModelDefaults.openRouterQwen)),
        MakerGroup(maker: .zai, entries: entries(.zai, .openRouter, AIModelDefaults.openRouterZAI)),
        MakerGroup(
            maker: .mistral,
            entries: entries(.mistral, .openRouter, AIModelDefaults.openRouterMistral)
        ),
        MakerGroup(
            maker: .meta,
            entries: entries(.meta, .meta, AIModelDefaults.preferredMeta)
                + entries(.meta, .openRouter, ["meta-llama/llama-4-maverick"])
        ),
        MakerGroup(maker: .nvidia, entries: entries(.nvidia, .openRouter, AIModelDefaults.openRouterNVIDIA)),
    ]

    private static func entries(
        _ maker: AIModelMaker, _ provider: AIProvider, _ modelIDs: [String]
    ) -> [AIModelCatalogEntry] {
        modelIDs.map { AIModelCatalogEntry(maker: maker, provider: provider, modelID: $0) }
    }

    /// Pinned groups plus any user-added OpenRouter models, each merged into
    /// its maker's group (unknown authors land in the trailing "Other Models"
    /// group). Within every group the newest model leads — see
    /// `orderedNewestFirst` — so a lab's latest release is the first card the
    /// learner sees, and the order moves on its own as releases land.
    /// Settings' expanded grid folds the directory's other models of the
    /// maker into that same order (`orderedGroupCards`).
    /// Computed so additions/removals show up on the next render; the
    /// custom list is a few UserDefaults-backed rows, so rebuilding is cheap.
    static var makerGroups: [MakerGroup] {
        let groups = catalogSnapshot().makerGroups
        guard hidesTrainingModels || AIModelAccess.current != nil else { return groups }
        return groups.compactMap { group in
            let entries = group.entries.filter(isOffered)
            return entries.isEmpty ? nil : MakerGroup(maker: group.maker, entries: entries)
        }
    }

    /// Whether "Don't show models that train on my data" is on. Read at every
    /// catalog access rather than baked into the snapshot: the switch is a
    /// synced preference that can flip from another device mid-launch, and
    /// the filter is one pass over a few dozen entries.
    static var hidesTrainingModels: Bool { AIDataPolicy.hidesTrainingModels }

    /// Whether the catalog offers an entry right now: everything in the
    /// snapshot except, while the switch is on, the models that train, and
    /// for a subsidized account the models its access does not cover
    /// (`AIModelAccess`).
    private static func isOffered(_ entry: AIModelCatalogEntry) -> Bool {
        !(hidesTrainingModels && entry.trainsOnInputs)
            && AIModelAccess.allows(slug: OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID))
    }

    /// Whether the catalog would offer a model today, catalogued or not: the
    /// test Settings › Chat puts a directory model it lists to.
    static func wouldOffer(provider: AIProvider, modelID: String) -> Bool {
        isOffered(AIModelCatalogEntry(maker: .other, provider: provider, modelID: modelID))
    }

    /// The Data & Privacy switch changed, here or on another device. A chat
    /// whose session model is now hidden goes back to the default — the
    /// picker cannot show a model it no longer lists — and every open picker
    /// and Settings pane rebuilds.
    static func dataPolicyDidChange() {
        if hidesTrainingModels {
            for entry in catalogSnapshot().allEntries where entry.trainsOnInputs {
                KeychainService.resetChatSessionSelectionIfMatching(provider: entry.provider, model: entry.modelID)
            }
        }
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The sorted catalog is consulted from view bodies on every render
    /// (`entry(provider:modelID:)`, `displayName`), and rebuilding it means
    /// decoding the custom-model blobs from UserDefaults and sorting every
    /// group through the release-date and pricing tables — milliseconds that
    /// turned into visible click latency when multiplied across a render
    /// pass. Rebuild only when an input actually changed: the custom-model
    /// blob (compared as raw Data, an in-memory dictionary
    /// read), the remote price overlay, and the release-date table (each a
    /// generation counter bumped on ingest).
    private struct CatalogSnapshot {
        let customData: Data?
        let pricingGeneration: UInt64
        let releaseDateGeneration: UInt64
        let makerGroups: [MakerGroup]
        let allEntries: [AIModelCatalogEntry]
        let entriesByID: [String: AIModelCatalogEntry]
    }

    private static let catalogSnapshotLock = NSLock()
    nonisolated(unsafe) private static var cachedCatalogSnapshot: CatalogSnapshot?

    private static func catalogSnapshot() -> CatalogSnapshot {
        let defaults = UserDefaults.standard
        let customData = defaults.data(forKey: customModelsKey)
        let generation = AIProviderPricing.remotePriceGeneration
        let releaseDateGeneration = openRouterReleaseDateGeneration
        catalogSnapshotLock.lock()
        defer { catalogSnapshotLock.unlock() }
        if let cached = cachedCatalogSnapshot,
           cached.customData == customData,
           cached.pricingGeneration == generation,
           cached.releaseDateGeneration == releaseDateGeneration {
            return cached
        }
        let groups = buildMakerGroups()
        let entries = groups.flatMap(\.entries)
        var byID: [String: AIModelCatalogEntry] = [:]
        byID.reserveCapacity(entries.count)
        for entry in entries where byID[entry.id] == nil {
            byID[entry.id] = entry
        }
        let snapshot = CatalogSnapshot(
            customData: customData,
            pricingGeneration: generation,
            releaseDateGeneration: releaseDateGeneration,
            makerGroups: groups,
            allEntries: entries,
            entriesByID: byID
        )
        cachedCatalogSnapshot = snapshot
        return snapshot
    }

    private static func buildMakerGroups() -> [MakerGroup] {
        let custom = customOpenRouterModels
        var customPrices: [String: (input: Double, output: Double)] = [:]
        for model in custom {
            if let input = model.inputUSDPerMTokens, let output = model.outputUSDPerMTokens {
                let id = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: model.id).id
                customPrices[id] = (input, output)
            }
        }
        func newestFirst(_ group: MakerGroup) -> MakerGroup {
            MakerGroup(maker: group.maker, entries: orderedNewestFirst(group.entries, customPrices: customPrices))
        }
        // A model the learner added from the directory keeps its own card, so
        // the successor that would carry the same id is dropped; otherwise
        // the picker lists it twice.
        let customIDs = Set(custom.map {
            AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: $0.id).id
        })
        let pinnedGroups = pinnedMakerGroups.map(withDirectorySuccessors).map { group in
            MakerGroup(
                maker: group.maker,
                entries: group.entries.filter { !customIDs.contains($0.id) }
            )
        }
        guard !custom.isEmpty else { return pinnedGroups.map(newestFirst) }
        var extrasByMaker: [AIModelMaker: [AIModelCatalogEntry]] = [:]
        for model in custom {
            let entry = AIModelCatalogEntry(
                maker: maker(forOpenRouterSlug: model.id),
                provider: .openRouter,
                modelID: model.id,
                customName: model.name
            )
            extrasByMaker[entry.maker, default: []].append(entry)
        }
        var groups = pinnedGroups.map { group in
            extrasByMaker[group.maker].map { MakerGroup(maker: group.maker, entries: group.entries + $0) } ?? group
        }
        for maker in AIModelMaker.allCases where !groups.contains(where: { $0.maker == maker }) {
            if let extras = extrasByMaker[maker] {
                groups.append(MakerGroup(maker: maker, entries: extras))
            }
        }
        // Every id appears once across the catalog, whichever route put it
        // there first.
        var seen: Set<String> = []
        return groups.map { group in
            newestFirst(MakerGroup(maker: group.maker, entries: group.entries.filter { seen.insert($0.id).inserted }))
        }
    }

    /// A pinned group plus every newer version the OpenRouter directory lists
    /// of a model the group pins. The pinned lists are typed by hand, so on
    /// their own they lag each release: Grok 4.7 shipped while the xAI group
    /// still led with 4.5, and the new model sat behind "more…". A directory
    /// slug succeeds a pinned model when it has the same family — the id with
    /// every version number blanked, so `grok-4.7` is a `grok-#` like
    /// `grok-4.5`, and `gemini-3.9-flash` a `gemini-#-flash` — a higher
    /// version, and a later directory listing than the pinned model (xAI's
    /// `grok-4.20` predates `grok-4.3`, so the number alone misleads). It joins the group on its OpenRouter route, which the managed
    /// proxy prices live, so no rate or window is guessed for it; the
    /// newest-first sort then puts it in front. The pinned model stays, so a
    /// selection of it keeps resolving. Once the successor is pinned on the
    /// lab's own route it dedups against that entry and this adds nothing.
    private static func withDirectorySuccessors(_ group: MakerGroup) -> MakerGroup {
        let listed = openRouterReleaseDateLock.withLock { loadedOpenRouterReleaseDateTable() }
            .mapValues { Date(timeIntervalSince1970: $0) }
        return MakerGroup(
            maker: group.maker,
            entries: group.entries + directorySuccessors(of: group.entries, listed: listed)
        )
    }

    /// The directory slugs that succeed one of `entries` — see
    /// `withDirectorySuccessors`. Only the newest successor per family is
    /// returned, and only slugs of the entries' own vendor. `listed` maps each
    /// directory slug (lowercased) to when the directory first listed it.
    static func directorySuccessors(
        of entries: [AIModelCatalogEntry],
        listed: [String: Date]
    ) -> [AIModelCatalogEntry] {
        guard let maker = entries.first?.maker else { return [] }
        let present = Set(entries.map {
            modelVersionKey(OpenRouterModelID.slug(provider: $0.provider, model: $0.modelID))
        })
        var newestPinned: [String: (vendor: String, version: [Int], listed: Date?)] = [:]
        for entry in entries {
            let slug = OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID).lowercased()
            guard let parsed = parsedModelVersion(slug) else { continue }
            let date = listed[slug]
            if let current = newestPinned[parsed.family] {
                newestPinned[parsed.family] = (
                    current.vendor,
                    current.version.lexicographicallyPrecedes(parsed.version) ? parsed.version : current.version,
                    [current.listed, date].compactMap { $0 }.max()
                )
            } else {
                newestPinned[parsed.family] = (parsed.vendor, parsed.version, date)
            }
        }
        var successors: [String: (slug: String, version: [Int])] = [:]
        for (slug, date) in listed {
            guard !present.contains(modelVersionKey(slug)),
                  let parsed = parsedModelVersion(slug),
                  let pinned = newestPinned[parsed.family],
                  pinned.vendor == parsed.vendor,
                  pinned.version.lexicographicallyPrecedes(parsed.version),
                  pinned.listed.map({ date > $0 }) ?? true
            else { continue }
            if let current = successors[parsed.family],
               !current.version.lexicographicallyPrecedes(parsed.version) {
                continue
            }
            successors[parsed.family] = (slug, parsed.version)
        }
        return successors.values
            .sorted { $0.slug < $1.slug }
            .map { AIModelCatalogEntry(maker: maker, provider: .openRouter, modelID: $0.slug) }
    }

    /// A hand-picked Suggested list as OpenRouter lists models today: each
    /// slug, or the newest release of its family listed since — the same
    /// successor `withDirectorySuccessors` finds — so a lab's new release
    /// takes its predecessor's place without a code change (product owner,
    /// 2026-09-30: "this should happen automatically"). `listed` maps each
    /// slug the list may offer (lowercased) to when OpenRouter first listed
    /// it; `allows` says whether a successor may take the place of the slug
    /// it succeeds, and the newest one it allows does. A slug nothing
    /// allowed succeeds stays as picked, and a slug two picks roll to is
    /// listed once.
    static func newestReleases(
        of slugs: [String],
        listed: [String: Date],
        allows: (_ successor: String, _ slug: String) -> Bool = { _, _ in true }
    ) -> [String] {
        var seen: Set<String> = []
        return slugs.compactMap { slug in
            let own = slug.lowercased()
            // The pick's own listing stays in, whatever `allows` says: the
            // successor test compares listing dates against it.
            let candidates = listed.filter { $0.key == own || allows($0.key, own) }
            let pick = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: slug)
            let newest = directorySuccessors(of: [pick], listed: candidates).first?.modelID ?? slug
            return seen.insert(newest.lowercased()).inserted ? newest : nil
        }
    }

    /// `newestReleases`' `listed` from directory rows: each slug, lowercased,
    /// with the date OpenRouter first listed it. A row with no date is left
    /// out, so it never counts as a release.
    static func listingDates<Row>(
        _ rows: [Row], slug: (Row) -> String, listedAt: (Row) -> Date?
    ) -> [String: Date] {
        var dates: [String: Date] = [:]
        for row in rows {
            guard let date = listedAt(row) else { continue }
            dates[slug(row).lowercased()] = date
        }
        return dates
    }

    /// Cross-host identity of a slug's model: "claude-opus-4.8" and a native
    /// "claude-opus-4-8" read the same.
    private static func modelVersionKey(_ slug: String) -> String {
        (slug.split(separator: "/").last.map(String.init) ?? slug)
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
    }

    /// "x-ai/grok-4.7" → vendor "x-ai", family "grok-#", version [4, 7].
    /// Every numeric dash-separated token (optionally "v"-prefixed, as in
    /// "deepseek-v4") is a version component; nil for a slug with no version
    /// or with a variant suffix (":batch", ":free"), which never counts as a
    /// release of its own.
    static func parsedModelVersion(_ slug: String) -> (vendor: String, family: String, version: [Int])? {
        let lower = slug.lowercased()
        guard !lower.contains(":") else { return nil }
        let parts = lower.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var family: [String] = []
        var version: [Int] = []
        for token in parts[1].split(separator: "-").map(String.init) {
            let prefixed = token.hasPrefix("v") && token.count > 1
            let digits = prefixed ? String(token.dropFirst()) : token
            let components = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            if !digits.isEmpty, components.allSatisfy({ $0 != nil }) {
                family.append(prefixed ? "v#" : "#")
                version += components.compactMap { $0 }
                // Components of distinct tokens never merge: "4-8" and "48" differ.
                version.append(-1)
            } else {
                family.append(token)
            }
        }
        guard !version.isEmpty else { return nil }
        return (parts[0], family.joined(separator: "-"), version)
    }

    /// A maker's catalog entries, newest release first. Release dates come
    /// from the OpenRouter directory snapshot (`openRouterDirectoryReleaseDate`)
    /// through each entry's directory slug; list price from the static pricing
    /// table, with user-added directory prices covering slugs the table
    /// doesn't know. Entries the directory has not dated yet, and same-day
    /// releases, fall back to the price order, then keep their pinned order.
    private static func orderedNewestFirst(
        _ entries: [AIModelCatalogEntry],
        customPrices: [String: (input: Double, output: Double)]
    ) -> [AIModelCatalogEntry] {
        func rates(_ entry: AIModelCatalogEntry) -> (input: Double, output: Double)? {
            if let rates = AIProviderPricing.textTokenRates(provider: entry.provider, model: entry.modelID) {
                return (rates.input, rates.output)
            }
            return customPrices[entry.id]
        }
        return orderedNewestFirst(
            Array(entries.enumerated()),
            releaseDate: { releaseDate(for: $0.element) },
            rates: { rates($0.element) },
            tieBreak: { $0.offset < $1.offset }
        )
        .map(\.element)
    }

    /// The order every maker group is shown in, on both routing rails: the
    /// newest release first, so a lab's latest model leads its group and a
    /// new release takes the front on the fetch that first dates it. Two
    /// models the directory dates identically (or not at all) fall back to
    /// list price, most expensive first — a dated model always precedes an
    /// undated one — and `tieBreak` settles what is left.
    static func orderedNewestFirst<Item>(
        _ items: [Item],
        releaseDate: (Item) -> Date?,
        rates: (Item) -> (input: Double, output: Double)?,
        tieBreak: (Item, Item) -> Bool
    ) -> [Item] {
        items.sorted { lhs, rhs in
            if let byDate = newestFirstOrder(releaseDate(lhs), releaseDate(rhs)) { return byDate }
            if let byPrice = priceDescendingOrder(rates(lhs), rates(rhs)) { return byPrice }
            return tieBreak(lhs, rhs)
        }
    }

    /// Newer before older, dated before undated; nil when the pair is
    /// indistinguishable by release date.
    static func newestFirstOrder(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?): return l == r ? nil : l > r
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return nil
        }
    }

    /// Descending list price (input rate, then output rate), priced before
    /// unpriced; nil when the pair is indistinguishable by price.
    static func priceDescendingOrder(
        _ lhs: (input: Double, output: Double)?,
        _ rhs: (input: Double, output: Double)?
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l.input != r.input { return l.input > r.input }
            if l.output != r.output { return l.output > r.output }
            return nil
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return nil
        }
    }

    /// One card of a maker's group in Settings: a catalog entry, or a model
    /// OpenRouter's directory lists under that maker that the catalog does
    /// not carry.
    enum GroupCard: Identifiable {
        case catalog(AIModelCatalogEntry)
        case directory(OpenRouterDirectoryModel)

        var id: String {
            switch self {
            case .catalog(let entry): return entry.id
            case .directory(let model): return "directory|\(model.id)"
            }
        }

        /// The id a request names: the entry's model id, or the directory slug.
        var modelID: String {
            switch self {
            case .catalog(let entry): return entry.modelID
            case .directory(let model): return model.id
            }
        }
    }

    /// A maker's whole group, as Settings shows it: the catalog's entries and
    /// the directory's other models of that maker in one newest-first order,
    /// whose head is what the collapsed group shows (`collapsedGroupCards`).
    /// The product owner (2026-09-27), of the expanded xAI group: "why are these not
    /// sorted right?" It showed the two lists one after the other, each
    /// sorted on its own, so the directory's Grok 4.6 and 4.5 came after the
    /// catalog's older Grok 4.3.
    ///
    /// The rule is `orderedNewestFirst`'s, over both lists. Each card is
    /// dated and priced where its own list is: an entry from the catalog's
    /// release-date and pricing tables (the defaults), a directory model from
    /// its row. So the entries keep among themselves the order the catalog
    /// gives them. What the rule leaves tied puts a catalog entry first, in
    /// catalog order, then the directory models by name.
    static func orderedGroupCards(
        entries: [AIModelCatalogEntry],
        directoryModels: [OpenRouterDirectoryModel],
        entryReleaseDate: (AIModelCatalogEntry) -> Date? = { AIModelCatalog.releaseDate(for: $0) },
        entryRates: (AIModelCatalogEntry) -> (input: Double, output: Double)? = { AIModelListPrice.rates(for: $0) }
    ) -> [GroupCard] {
        // Keyed once per card: the table lookups stay out of the comparisons.
        struct Keyed {
            let card: GroupCard
            /// The entry's place in the catalog's order; nil for a directory model.
            let catalogIndex: Int?
            let name: String
            let released: Date?
            let rates: (input: Double, output: Double)?
        }
        let catalog = entries.enumerated().map { index, entry in
            Keyed(
                card: .catalog(entry),
                catalogIndex: index,
                name: entry.displayName,
                released: entryReleaseDate(entry),
                rates: entryRates(entry)
            )
        }
        let listed = directoryModels.map { model in
            Keyed(
                card: .directory(model),
                catalogIndex: nil,
                name: model.name,
                released: model.createdAt,
                rates: model.inputUSDPerMTokens.map { (input: $0, output: model.outputUSDPerMTokens ?? 0) }
            )
        }
        return orderedNewestFirst(
            catalog + listed,
            releaseDate: \.released,
            rates: \.rates,
            tieBreak: { lhs, rhs in
                switch (lhs.catalogIndex, rhs.catalogIndex) {
                case let (left?, right?): return left < right
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none):
                    let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    return byName == .orderedSame ? lhs.card.modelID < rhs.card.modelID : byName == .orderedAscending
                }
            }
        )
        .map(\.card)
    }

    /// The cards a collapsed group shows before its "more…" toggle: `limit`
    /// of them, every selected card first (a selection is never hidden),
    /// topped up from the front of `cards` — the group's `orderedGroupCards`
    /// order, which they keep. The product owner (2026-09-28), of the collapsed xAI
    /// group reading Grok 4.7, Grok 4.3: "this sorting is really strange".
    /// Only the catalog's two pinned cards were eligible, so the directory's
    /// newer Grok 4.6 and 4.5 waited behind "5 more…".
    static func collapsedGroupCards(
        _ cards: [GroupCard],
        limit: Int,
        isSelected: (GroupCard) -> Bool
    ) -> [GroupCard] {
        var keptIDs = Set(cards.filter(isSelected).map(\.id))
        for card in cards where keptIDs.count < limit {
            keptIDs.insert(card.id)
        }
        return cards.filter { keptIDs.contains($0.id) }
    }

    /// When the directory first listed the model a catalog entry names. The
    /// closed labs' native IDs translate through the same slug mapper the
    /// price overlay uses. Nil until a fetch has dated the slug.
    static func releaseDate(for entry: AIModelCatalogEntry) -> Date? {
        openRouterDirectoryReleaseDate(OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID))
    }

    /// Every offered entry, in catalog order; see `isOffered`.
    static var allEntries: [AIModelCatalogEntry] {
        let entries = catalogSnapshot().allEntries
        guard hidesTrainingModels else { return entries }
        return entries.filter(isOffered)
    }

    /// OpenRouter directory slugs already represented by cards in the catalog.
    /// Closed-lab entries use provider-native IDs, so normalize them through
    /// the same mapper used by live requests before comparing them with the
    /// directory. User-added OpenRouter entries are included automatically.
    /// Reads the snapshot, not `allEntries`: a model the Data & Privacy switch
    /// hides is still catalogued, so the directory browser does not offer it
    /// back as an extra.
    static var cataloguedOpenRouterSlugs: Set<String> {
        Set(catalogSnapshot().allEntries.map {
            OpenRouterModelID.slug(provider: $0.provider, model: $0.modelID)
        })
    }

    static func entries(for provider: AIProvider) -> [AIModelCatalogEntry] {
        allEntries.filter { $0.provider == provider }
    }

    /// The catalog entry for a stored provider + model selection, if it is
    /// still offered. Retired-host selections return nil, and so does a model
    /// the Data & Privacy switch hides.
    static func entry(provider: AIProvider, modelID: String) -> AIModelCatalogEntry? {
        guard let entry = catalogSnapshot().entriesByID[
            AIModelCatalogEntry(maker: .other, provider: provider, modelID: modelID).id
        ], isOffered(entry) else { return nil }
        return entry
    }

    static func displayName(provider: AIProvider, modelID: String) -> String {
        entry(provider: provider, modelID: modelID)?.displayName
            ?? AIModelDisplayName.textModelName(modelID, provider: provider)
    }

    /// The name the model picker shows: a free model ends in "(free)"
    /// (product owner, 2026-09-27), once. A `:free` id is usually named so already;
    /// a stealth model OpenRouter lists at $0/$0 ("Space Bunny Alpha") is not.
    static func pickerName(provider: AIProvider, modelID: String) -> String {
        let name = displayName(provider: provider, modelID: modelID)
        // "Free Models Router" already says it (product owner, 2026-10-06).
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == AIModelDefaults.openRouterFreeRouter { return name }
        return markingFree(name, isFree: isFree(provider: provider, modelID: modelID))
    }

    /// Free to run: a free OpenRouter variant, or a list price of nothing.
    static func isFree(provider: AIProvider, modelID: String) -> Bool {
        if AIFreeModels.isFreeSelection(provider: provider, model: modelID) { return true }
        let rates = entry(provider: provider, modelID: modelID).flatMap { AIModelListPrice.rates(for: $0) }
            ?? AIModelListPrice.rates(provider: provider, modelID: modelID)
        guard let rates else { return false }
        return rates.input == 0 && rates.output == 0
    }

    static func markingFree(_ name: String, isFree: Bool) -> String {
        guard isFree, name.range(of: "(free)", options: .caseInsensitive) == nil else { return name }
        return "\(name) (free)"
    }

    // MARK: - User-added OpenRouter models

    /// A model the user promoted from OpenRouter's full directory into the
    /// catalog. Name, prices, and context window are captured from the
    /// directory at add time — they back the Settings price label and the
    /// context budgeter; actual billing always comes from OpenRouter's
    /// per-request `usage.cost`.
    struct CustomOpenRouterModel: Codable, Equatable, Sendable {
        let id: String
        let name: String
        var inputUSDPerMTokens: Double?
        var outputUSDPerMTokens: Double?
        var contextLength: Int?
        /// Captured from the directory's `supported_parameters`. Optional so
        /// blobs persisted before this field existed still decode — the whole
        /// array decode is `try?`, so a required field would silently wipe
        /// every user-added model. Nil means "added before we checked".
        var supportsTools: Bool?
        /// Captured from `supported_parameters`; nil keeps previously persisted
        /// custom-model blobs decoding and means capability unknown.
        var supportsTemperature: Bool? = nil
        /// Captured from the directory's `architecture.input_modalities`. Same
        /// back-compat contract as `supportsTools`: optional so old blobs decode,
        /// nil meaning "unknown", which never triggers the Settings vision warning.
        var supportsVision: Bool?
    }

    private static let customModelsKey = "chatModels.openRouterCustom"

    static var customOpenRouterModels: [CustomOpenRouterModel] {
        guard let data = UserDefaults.standard.data(forKey: customModelsKey) else { return [] }
        let decoded = (try? JSONDecoder().decode([CustomOpenRouterModel].self, from: data)) ?? []
        // A directory model can become pinned in a later app release. Keep its
        // existing enabled ID, but stop treating the now-built-in card as a
        // removable custom duplicate.
        return decoded.filter { !AIModelDefaults.preferredOpenRouter.contains($0.id) }
    }

    static func customOpenRouterModel(id: String) -> CustomOpenRouterModel? {
        customOpenRouterModels.first { $0.id == id }
    }

    // MARK: - OpenRouter vision capability snapshot

    /// Slug → accepts image input, captured from the directory's
    /// `architecture.input_modalities` on the same fetch that refreshes prices
    /// (`AIModelPriceRefresher.ingest`). A device-local derived cache, not user
    /// intent, so it lives in plain `UserDefaults` like the remote price table:
    /// it does not sync, and there is nothing to reconcile across devices.
    private static let openRouterVisionKey = "aiCapabilities.openRouterVision"

    /// Whether a directory slug was last seen accepting image input. `nil` means
    /// no fetch has recorded it yet — callers treat that as unknown and do not
    /// warn, so a capable model is never wrongly flagged before the first fetch.
    static func openRouterModelSupportsVision(_ slug: String) -> Bool? {
        guard let data = UserDefaults.standard.data(forKey: openRouterVisionKey),
              let table = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return nil }
        return table[slug]
    }

    /// Replace the cached vision snapshot. An empty table is ignored so a failed
    /// or drifted fetch never erases a good one, matching the price cache.
    static func cacheOpenRouterVision(_ table: [String: Bool]) {
        guard !table.isEmpty, let data = try? JSONEncoder().encode(table) else { return }
        UserDefaults.standard.set(data, forKey: openRouterVisionKey)
    }

    // MARK: - Directory context windows

    /// Slug → `context_length`, captured from OpenRouter's directory on the
    /// same fetch that refreshes prices, for every row that published one.
    /// This is the authority for what OpenRouter serves: the request budgeter
    /// and the context gauge read it rather than assuming a window. Device-
    /// local derived cache, like the vision snapshot above.
    static let openRouterContextLengthKey = "aiCapabilities.openRouterContextLength"

    static func openRouterDirectoryContextLength(_ slug: String) -> Int? {
        directoryContextLength(slug, key: openRouterContextLengthKey)
    }

    private static func directoryContextLength(_ id: String, key: String) -> Int? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let table = try? JSONDecoder().decode([String: Int].self, from: data),
              let length = table[id.lowercased()], length > 0
        else { return nil }
        return length
    }

    /// Replace a directory context table. Keys are stored lowercased. An
    /// empty table is ignored so a failed or drifted fetch never erases a
    /// good one, matching the price and vision caches.
    static func cacheOpenRouterContextLengths(_ table: [String: Int]) {
        cacheDirectoryContextLengths(table, key: openRouterContextLengthKey)
    }

    private static func cacheDirectoryContextLengths(_ table: [String: Int], key: String) {
        let normalized = table.reduce(into: [String: Int]()) { result, entry in
            guard entry.value > 0 else { return }
            result[entry.key.lowercased()] = entry.value
        }
        guard !normalized.isEmpty, let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Directory release dates

    /// Slug → the directory's `created` stamp (Unix seconds), captured from
    /// OpenRouter on the same fetch that refreshes prices, for every row. It
    /// is what puts a lab's newest model first in its group: the directory
    /// dates every model it serves — the closed labs' too — so no release date is ever
    /// typed into the app, and a model that ships tomorrow leads its group on
    /// the fetch that first lists it. Device-local derived cache, like the
    /// context-window table above, with an in-memory copy because the sorted
    /// catalog consults it from view bodies.
    static let openRouterReleaseDateKey = "aiCapabilities.openRouterReleaseDate"

    private static let openRouterReleaseDateLock = NSLock()
    nonisolated(unsafe) private static var openRouterReleaseDateTable: [String: Double]?
    nonisolated(unsafe) private static var openRouterReleaseDateGenerationValue: UInt64 = 0

    /// Bumped whenever the release-date table changes, so the sorted catalog
    /// snapshot can validate cheaply instead of re-sorting on every read.
    static var openRouterReleaseDateGeneration: UInt64 {
        openRouterReleaseDateLock.withLock { openRouterReleaseDateGenerationValue }
    }

    /// When OpenRouter's directory first listed a slug; nil until a fetch has
    /// recorded it. Callers treat nil as unknown, never as "old".
    static func openRouterDirectoryReleaseDate(_ slug: String) -> Date? {
        let table = openRouterReleaseDateLock.withLock { loadedOpenRouterReleaseDateTable() }
        return table[slug.lowercased()].map { Date(timeIntervalSince1970: $0) }
    }

    /// Replace the cached release-date table. Keys are stored lowercased. An
    /// empty table is ignored so a failed or drifted fetch never erases a
    /// good one, matching the price, vision and context caches. Returns true
    /// when a date actually changed, so callers republish the catalog only
    /// when its order can have moved.
    @discardableResult
    static func cacheOpenRouterReleaseDates(_ table: [String: Date]) -> Bool {
        let normalized = table.reduce(into: [String: Double]()) { result, entry in
            let seconds = entry.value.timeIntervalSince1970
            guard seconds > 0 else { return }
            result[entry.key.lowercased()] = seconds
        }
        guard !normalized.isEmpty, let data = try? JSONEncoder().encode(normalized) else { return false }
        let changed: Bool = openRouterReleaseDateLock.withLock {
            let current = loadedOpenRouterReleaseDateTable()
            guard current != normalized else { return false }
            openRouterReleaseDateTable = normalized
            openRouterReleaseDateGenerationValue &+= 1
            return true
        }
        guard changed else { return false }
        UserDefaults.standard.set(data, forKey: openRouterReleaseDateKey)
        return true
    }

    /// Caller holds `openRouterReleaseDateLock`. The first read decodes the
    /// persisted table; an absent table reads as empty, not as a failure.
    private static func loadedOpenRouterReleaseDateTable() -> [String: Double] {
        if let table = openRouterReleaseDateTable { return table }
        let table = UserDefaults.standard.data(forKey: openRouterReleaseDateKey)
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        openRouterReleaseDateTable = table
        return table
    }

    // MARK: - Directory reasoning efforts

    /// Slug → the effort levels OpenRouter's catalog lists for the model,
    /// captured on the same fetch that refreshes prices, for every row that
    /// publishes them. It is the authority for which levels the effort control
    /// offers on every model, Claude and GPT included, so a model that gains an
    /// effort control or a level upstream gets it here on the next fetch.
    /// Device-local derived cache with an in-memory copy, because the
    /// composer's effort control consults it from a view body.
    static let openRouterReasoningEffortsKey = "aiCapabilities.openRouterReasoningEfforts"

    private static let openRouterReasoningEffortsLock = NSLock()
    nonisolated(unsafe) private static var openRouterReasoningEffortsTable: [String: OpenRouterReasoningEfforts]?

    /// Stands in for the cached table within one task and its children, so a
    /// test can describe the catalog without writing the shared defaults that
    /// parallel suites read. Keys lowercased; an empty table is a catalog
    /// never read.
    @TaskLocal static var openRouterReasoningEffortsOverride: [String: OpenRouterReasoningEfforts]? = nil

    private static var currentOpenRouterReasoningEfforts: [String: OpenRouterReasoningEfforts] {
        if let override = openRouterReasoningEffortsOverride { return override }
        return openRouterReasoningEffortsLock.withLock { loadedOpenRouterReasoningEffortsTable() }
    }

    /// Whether any catalog read has been recorded. A stored table is never
    /// empty, since an empty read is not written.
    static var hasReadOpenRouterReasoningEfforts: Bool {
        !currentOpenRouterReasoningEfforts.isEmpty
    }

    /// What the catalog last said about a slug's effort control; nil until a
    /// fetch has recorded it, or when the model has none. Callers treat nil as
    /// "no effort control offered", never as a guessed range.
    static func openRouterReasoningEfforts(_ slug: String) -> OpenRouterReasoningEfforts? {
        currentOpenRouterReasoningEfforts[slug.lowercased()]
    }

    /// Replace the cached effort table. Keys are stored lowercased. An empty
    /// table is ignored so a failed catalog fetch never erases a good one,
    /// matching the other directory caches. Returns true when the table
    /// changed, so callers republish and the composer redraws its control.
    @discardableResult
    static func cacheOpenRouterReasoningEfforts(_ table: [String: OpenRouterReasoningEfforts]) -> Bool {
        let normalized = table.reduce(into: [String: OpenRouterReasoningEfforts]()) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        guard !normalized.isEmpty, let data = try? JSONEncoder().encode(normalized) else { return false }
        let changed: Bool = openRouterReasoningEffortsLock.withLock {
            guard loadedOpenRouterReasoningEffortsTable() != normalized else { return false }
            openRouterReasoningEffortsTable = normalized
            return true
        }
        guard changed else { return false }
        UserDefaults.standard.set(data, forKey: openRouterReasoningEffortsKey)
        return true
    }

    /// Caller holds `openRouterReasoningEffortsLock`. An absent table reads as
    /// empty, not as a failure.
    private static func loadedOpenRouterReasoningEffortsTable() -> [String: OpenRouterReasoningEfforts] {
        if let table = openRouterReasoningEffortsTable { return table }
        let table = UserDefaults.standard.data(forKey: openRouterReasoningEffortsKey)
            .flatMap { try? JSONDecoder().decode([String: OpenRouterReasoningEfforts].self, from: $0) } ?? [:]
        openRouterReasoningEffortsTable = table
        return table
    }

    /// Context window captured from OpenRouter's directory when the user
    /// added the model, consulted by the request budgeter when the cached
    /// directory table has no row for the slug.
    static func customContextLength(forOpenRouterModel modelID: String) -> Int? {
        customOpenRouterModel(id: modelID)?.contextLength
    }

    static func isCustom(_ entry: AIModelCatalogEntry) -> Bool {
        switch entry.provider {
        case .openRouter:
            return customOpenRouterModel(id: entry.modelID) != nil
        default:
            return false
        }
    }

    /// `enableForChat` false catalogs the model without offering it in the
    /// chat's picker: a free model picked for background work only.
    static func addCustomOpenRouterModel(_ model: CustomOpenRouterModel, enableForChat: Bool = true) {
        // The chat agent has no tool-less mode: every turn ships the MCP tool
        // catalog, so a model that can't accept tool definitions would 4xx and
        // silently drop the session to the text protocol. Refuse it at the door.
        guard model.supportsTools != false else { return }
        guard !AIModelDefaults.preferredOpenRouter.contains(model.id) else { return }
        var models = customOpenRouterModels
        guard !models.contains(where: { $0.id == model.id }) else { return }
        models.append(model)
        persistCustomModels(models)
        // Adding a model from the directory is itself the opt-in.
        if enableForChat {
            let entryID = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: model.id).id
            persistEnabledIDs(enabledIDs.union([entryID]))
        }
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    static func removeCustomOpenRouterModel(id: String) {
        let entryID = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: id).id
        // A default must remain selectable. The Settings context menu disables
        // this action too, but keep the invariant here so another caller cannot
        // remove the catalog row behind the stored default.
        guard entryID != defaultEntry?.id else { return }
        let models = customOpenRouterModels.filter { $0.id != id }
        persistCustomModels(models)
        persistEnabledIDs(enabledIDs.subtracting([entryID]))
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    private static func persistCustomModels(_ models: [CustomOpenRouterModel]) {
        if models.isEmpty {
            PreferenceStore.remove(forKey: customModelsKey)
        } else if let data = try? JSONEncoder().encode(models) {
            PreferenceStore.set(data, forKey: customModelsKey)
        }
    }

    /// Maps an OpenRouter slug's author segment to the maker whose catalog
    /// group it belongs in; unrecognized authors fall into "Other Models".
    static func maker(forOpenRouterSlug slug: String) -> AIModelMaker {
        let author = slug.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        switch author {
        case "openai": return .openai
        case "anthropic": return .anthropic
        case "google": return .google
        case "x-ai": return .xai
        case "deepseek": return .deepseek
        case "moonshotai": return .moonshot
        case "qwen": return .qwen
        case "z-ai": return .zai
        case "mistralai": return .mistral
        case "thinkingmachines": return .thinkingMachines
        case "meta", "meta-llama": return .meta
        case "nvidia": return .nvidia
        default: return .other
        }
    }

    /// The model that starts every new chat session, if it is still present in
    /// the catalog. Provider + model are one identity: OpenAI-hosted and
    /// OpenRouter-hosted copies of the same model are deliberately distinct.
    static var defaultEntry: AIModelCatalogEntry? {
        let provider = KeychainService.aiProvider
        return entry(provider: provider, modelID: KeychainService.model(for: provider))
    }

    static func isDefault(_ entry: AIModelCatalogEntry) -> Bool {
        defaultEntry?.id == entry.id
    }

    /// Promotes a catalog model to the chat default and makes it visible in
    /// the picker in the same operation. Store the enabled id first so the
    /// provider-change notification can never publish an unavailable default.
    static func setDefault(_ entry: AIModelCatalogEntry) {
        guard AIModelCatalog.entry(provider: entry.provider, modelID: entry.modelID) != nil else { return }
        persistEnabledIDs(enabledIDs.union([entry.id]), requiredDefaultID: entry.id)
        KeychainService.setDefaultChatRoute(provider: entry.provider, model: entry.modelID)
    }

    /// The entry IDs currently offered in the pickers. Falls back to the
    /// short default set until the user changes anything. The default is
    /// joined at read time as well as write time, so preferences written by an
    /// older build cannot leave the current default hidden.
    static var enabledIDs: Set<String> {
        var stored = UserDefaults.standard.stringArray(forKey: enabledIDsKey).map { Set($0) }
            ?? defaultEnabledIDs
        let oldMuseID = AIModelCatalogEntry(
            maker: .meta,
            provider: .openRouter,
            modelID: AIModelDefaults.latestOpenRouterMuseSpark
        ).id
        if stored.remove(oldMuseID) != nil {
            stored.insert(AIModelCatalogEntry(
                maker: .meta,
                provider: .meta,
                modelID: AIModelDefaults.latestMuseSpark
            ).id)
        }
        return includingRequiredDefault(stored, requiredDefaultID: defaultEntry?.id)
    }

    static func isEnabled(_ entry: AIModelCatalogEntry) -> Bool {
        enabledIDs.contains(entry.id)
    }

    /// Whether a provider/model pair is currently allowed in the chat picker.
    /// Saved sessions can name models that have since been disabled or removed
    /// from the catalog; those historical identities remain displayable, but
    /// they must not become the route for a new turn.
    static func isEnabledChatSelection(
        provider: AIProvider,
        modelID: String,
        enabledIDs: Set<String>
    ) -> Bool {
        guard let entry = entry(provider: provider, modelID: modelID) else { return false }
        return enabledIDs.contains(entry.id)
    }

    static func isEnabledChatSelection(provider: AIProvider, modelID: String) -> Bool {
        isEnabledChatSelection(
            provider: provider,
            modelID: modelID,
            enabledIDs: enabledIDs
        )
    }

    static func setEnabled(_ enabled: Bool, for entry: AIModelCatalogEntry) {
        var ids = enabledIDs
        if enabled {
            ids.insert(entry.id)
        } else {
            ids.remove(entry.id)
        }
        persistEnabledIDs(ids)
        if !enabled {
            KeychainService.resetChatSessionSelectionIfMatching(
                provider: entry.provider,
                model: entry.modelID
            )
        }
        // Reuses the picker-refresh notification so any open chat picker
        // rebuilds its menu immediately.
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// Pure normalization kept visible to tests: no path may publish a model
    /// set that excludes a known default.
    static func includingRequiredDefault(
        _ ids: Set<String>,
        requiredDefaultID: String?
    ) -> Set<String> {
        guard let requiredDefaultID else { return ids }
        return ids.union([requiredDefaultID])
    }

    private static func persistEnabledIDs(
        _ ids: Set<String>,
        requiredDefaultID: String? = defaultEntry?.id
    ) {
        let normalized = includingRequiredDefault(ids, requiredDefaultID: requiredDefaultID)
        PreferenceStore.set(normalized.sorted(), forKey: enabledIDsKey)
    }
}

/// Embedding backend for semantic source search. ForeverLM embeds exclusively with
/// Apple's on-device NaturalLanguage models — no API key, no network, no external
/// provider. The model id doubles as the per-model key under which vectors are
/// stored in the `embeddings` table, so changing it retires the old vectors rather
/// than mixing incompatible ones into the same index.
///
/// The active model is `NLContextualEmbedding` (transformer, subword tokenizer).
/// It replaced `NLEmbedding.sentenceEmbedding`, whose fixed vocabulary had no entry
/// for domain terms like gene symbols: "GDF15" was out-of-vocabulary, so swapping it
/// for another unknown token left the sentence vector 99.4% unchanged and a search
/// for "GDF15" could not rank GDF15 papers above unrelated ones. The contextual model
/// tokenizes such terms into subwords and represents them.
enum EmbeddingSettings {
    /// Apple's on-device NaturalLanguage contextual embedding (transformer, 512-dim).
    static let contextualModel = "apple-nl-contextual"
    static let contextualDimensions = 512

    /// Canonical model id; also the DB embedding key.
    static var modelID: String { contextualModel }

    /// Vector dimensions produced by the model.
    static var dimensions: Int { contextualDimensions }

    /// Hard token cap of the contextual model. Input beyond this is silently dropped
    /// by the framework — a passage past the cap embeds identically no matter what
    /// follows — so chunking must keep every chunk under it.
    static let maximumSequenceLength = 256

    /// Chunk sizing, in words, derived from the token cap. English runs ~1.7 subword
    /// tokens per word, so ~120 words of body plus a title prefix lands near 215
    /// tokens: comfortably inside 256 with room for long titles.
    static let chunkTargetWordCount = 120
    static let chunkOverlapWordCount = 30

    /// Longest title prefix (in words) prepended to a chunk before embedding.
    static let chunkTitlePrefixWordCount = 16

    /// Similarity search is **rank-based**, not threshold-based. Mean-pooled
    /// contextual embeddings are strongly anisotropic: two entirely unrelated texts
    /// score cosine 0.78–0.93, so any small absolute cutoff admits everything and a
    /// high one is brittle. Callers take the top-K and let rank fusion decide.
    static let similarityThreshold: Float = 0
}
