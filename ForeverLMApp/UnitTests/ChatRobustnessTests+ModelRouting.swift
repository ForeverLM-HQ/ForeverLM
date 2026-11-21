// Chat robustness tests: model selection, routing and own-key rules.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

extension ChatRobustnessTests {
    @Test("Chat model selection always includes the default model")
    func enabledChatModelsIncludeDefault() {
        let selected: Set<String> = ["xai|grok-4.5", "openrouter|meta/muse-spark-1.2"]
        let normalized = AIModelCatalog.includingRequiredDefault(
            selected,
            requiredDefaultID: "anthropic|claude-sonnet-5"
        )

        #expect(normalized.contains("anthropic|claude-sonnet-5"))
        #expect(normalized.isSuperset(of: selected))
        #expect(
            AIModelCatalog.includingRequiredDefault(selected, requiredDefaultID: nil) == selected
        )
    }

    @Test("OpenRouter is a transport switch, not a duplicate model catalog")
    func routerModesDoNotDuplicateModels() {
        let openRouterClaude = KeychainService.routedTextSelection(
            provider: .anthropic,
            model: "claude-opus-4-8",
            mode: .openRouter
        )
        #expect(openRouterClaude.provider == .openRouter)
        #expect(openRouterClaude.model == "anthropic/claude-opus-4.8")

        let openRouterOpenAI = KeychainService.routedTextSelection(
            provider: .openai,
            model: "gpt-5.6",
            mode: .openRouter
        )
        #expect(openRouterOpenAI.provider == .openRouter)
        #expect(openRouterOpenAI.model == "openai/gpt-5.6-sol")

        let openRouterLongTail = KeychainService.routedTextSelection(
            provider: .openRouter,
            model: "deepseek/deepseek-v4-pro",
            mode: .openRouter
        )
        #expect(openRouterLongTail.provider == .openRouter)
        #expect(openRouterLongTail.model == "deepseek/deepseek-v4-pro")

        let grok = KeychainService.routedTextSelection(
            provider: .xai,
            model: "grok-4.3",
            mode: .openRouter
        )
        #expect(grok.provider == .openRouter)
        #expect(grok.model == "x-ai/grok-4.3")
    }

    @Test("OpenRouter is the only text router, and stored choices are preserved")
    func productRoutingOverridesStoredPreferences() {
        let storedKey = AIModelPreferenceKey.textRoutingMode
        let previousStored = UserDefaults.standard.string(forKey: storedKey)
        defer { UserDefaults.standard.set(previousStored, forKey: storedKey) }

        // The wire token is a transport name, not this enum's case name.
        #expect(AITextRoutingMode(serverToken: " OpenRouter ") == .openRouter)
        // A router this build does not know names nothing.
        #expect(AITextRoutingMode(serverToken: "otherrouter") == nil)
        // No first-party text transport exists to name.
        #expect(AITextRoutingMode(serverToken: "direct") == nil)
        #expect(AITextRoutingMode(serverToken: "first_party") == nil)
        #expect(AITextRoutingMode(serverToken: "") == nil)

        // The test pins "no own key" rather than reading the developer's
        // Keychain, since an own key names its router itself.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        #expect(AITextRoutingMode.shippedDefault == .openRouter)
        #expect(AITextRoutingMode.allCases == [.openRouter])

        UserDefaults.standard.set(AITextRoutingMode.openRouter.rawValue, forKey: storedKey)
        #expect(KeychainService.textRoutingMode == .shippedDefault)
        #expect(UserDefaults.standard.string(forKey: storedKey) == AITextRoutingMode.openRouter.rawValue)
        #expect(
            KeychainService.routedTextSelection(provider: .anthropic, model: "claude-sonnet-5")
                .provider == .openRouter
        )
    }

    /// Runs `body` with the managed-AI sign-in state pinned, then restores the
    /// real session. `routedTextConfig` substitutes a credential only while
    /// signed in, so without this the two dispatch tests passed or failed with
    /// whatever the Dev app last did (2026-09-09: green at 18:25, red at 18:37,
    /// no code change). The lock keeps concurrent callers from seeing each
    /// other's pin.
    private static let managedSignInLock = NSLock()
    private func withManagedSignIn(_ signedIn: Bool, _ body: () -> Void) {
        Self.managedSignInLock.lock()
        defer { Self.managedSignInLock.unlock() }
        let saved = ManagedAI.signedInOverrideForTesting
        ManagedAI.signedInOverrideForTesting = signedIn
        defer { ManagedAI.signedInOverrideForTesting = saved }
        body()
    }

    @Test("Dispatch re-routes a direct config after OpenRouter-only is enabled")
    func dispatchReappliesOpenRouterRouting() {
        var stale = AITaskConfig(
            provider: .gemini,
            apiKey: "managed-session",
            model: "gemini-3.5-flash"
        )
        stale.taskLabel = AITask.paperBrowserAgent.rawValue

        withManagedSignIn(true) {
            let routed = KeychainService.routedTextConfig(stale, mode: .openRouter)
            #expect(routed.provider == .openRouter)
            #expect(routed.model == "google/gemini-3.5-flash")
            #expect(routed.apiKey.isEmpty)
            #expect(routed.taskLabel == AITask.paperBrowserAgent.rawValue)
        }

        withManagedSignIn(false) {
            let routed = KeychainService.routedTextConfig(stale, mode: .openRouter)
            #expect(routed.provider == .openRouter)
            #expect(routed.model == "google/gemini-3.5-flash")
            #expect(routed.apiKey == "managed-session")
        }
    }

    @Test("OpenRouter promotion metadata applies to every catalog model generically")
    func openRouterPromotionMetadata() throws {
        let payload = Data(#"""
        {
          "data": [
            {
              "slug": "openai/gpt-5.6-sol",
              "endpoint": { "pricing": { "discount": 0.5 } }
            },
            {
              "slug": "google/gemini-future",
              "endpoint": { "pricing": { "discount": 0.125 } }
            },
            {
              "slug": "invalid/markup",
              "endpoint": { "pricing": { "discount": -0.1 } }
            }
          ]
        }
        """#.utf8)

        let promotions = AIService.openRouterPromotionTable(from: payload)

        #expect(promotions["openai/gpt-5.6-sol"]?.label == "50% off")
        #expect(promotions["openai/gpt-5.6-sol"]?.discountBasisPoints == 5_000)
        // A fractional cut rounds to a whole percent on the badge; the exact
        // figure stays in the basis points for the struck list price.
        #expect(promotions["google/gemini-future"]?.label == "13% off")
        #expect(promotions["google/gemini-future"]?.discountBasisPoints == 1_250)
        #expect(promotions["invalid/markup"] == nil)
    }

    @Test("Which models train comes from each variant's own endpoint in OpenRouter's catalog")
    func openRouterTrainingSlugsReadEachVariant() throws {
        let payload = Data(#"""
        {
          "data": [
            {"slug": "nvidia/nemotron-3-ultra", "endpoint": {
              "model_variant_slug": "nvidia/nemotron-3-ultra:free",
              "data_policy": {"training": true, "retainsPrompts": true}}},
            {"slug": "nvidia/nemotron-3-ultra", "endpoint": {
              "model_variant_slug": "nvidia/nemotron-3-ultra",
              "data_policy": {"training": false, "retainsPrompts": false}}},
            {"slug": "Meta/Muse-Spark-1.3-Contributor", "endpoint": {
              "data_policy": {"training": true}}},
            {"slug": "qwen/qwen3.8-max", "endpoint": null}
          ]
        }
        """#.utf8)
        let rows = AIService.openRouterCatalogRows(from: payload)

        // The free variant is judged by its own host, not the paid model's;
        // a row without a variant slug files under its model's.
        #expect(AIService.openRouterTrainingSlugs(rows: rows) == [
            "nvidia/nemotron-3-ultra:free", "meta/muse-spark-1.3-contributor"
        ])
        // A catalog that carries no data policy anywhere says nothing, so the
        // last answer stands rather than every label clearing.
        let shapeless = AIService.openRouterCatalogRows(from: Data(#"{"data": [{"slug": "a/b", "endpoint": {}}]}"#.utf8))
        #expect(AIService.openRouterTrainingSlugs(rows: shapeless) == nil)
        #expect(AIService.openRouterTrainingSlugs(rows: []) == nil)
    }

    @Test("A :free model's speed is read from its own variant, not the paid hosts'")
    func speedVariantFollowsTheSlug() {
        #expect(OpenRouterModelSpeed.variant(ofSlug: "nvidia/nemotron-3-ultra-550b-a55b:free") == "free")
        #expect(OpenRouterModelSpeed.variant(ofSlug: " Z-AI/GLM-5.3-Flash ") == "standard")
        #expect(OpenRouterModelSpeed.variant(ofSlug: "openrouter/free") == "standard")
        #expect(OpenRouterModelSpeed.variant(ofSlug: "lab/model:") == "standard")
    }

    private static func directoryModel(
        _ id: String,
        maker: String? = nil,
        tools: Bool = true,
        created: TimeInterval? = nil,
        price: (input: Double, output: Double) = (1, 2),
        promotion: RouterModelPromotion? = nil
    ) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id, name: id.split(separator: "/").last.map(String.init) ?? id, makerName: maker,
            inputUSDPerMTokens: price.input, outputUSDPerMTokens: price.output, contextLength: 128_000,
            price: nil, supportsTools: tools, supportsTemperature: nil, supportsVision: nil,
            promotion: promotion,
            createdAt: created.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("Settings › Chat's suggestions resolve to the catalog, then the directory, and wait while it loads")
    func chatModelSuggestions() {
        // A native id is matched by the slug it translates to.
        let opus = AIModelCatalogEntry(maker: .anthropic, provider: .anthropic, modelID: "claude-opus-4-8")
        let entries = [opus]
        let directory = [
            Self.directoryModel("qwen/qwen3.8-omni-flash", maker: "Qwen"),
            Self.directoryModel("lab/toolless", tools: false),
            Self.directoryModel("meta/trains", maker: "Meta")
        ]
        let suggested = [
            "anthropic/claude-opus-4.8", "qwen/qwen3.8-omni-flash", "lab/toolless",
            "meta/trains", "lab/not-listed"
        ]
        let offered: (String) -> Bool = { $0 != "meta/trains" }

        let loaded = ChatModelLists.build(
            suggested: suggested, entries: entries, enabledIDs: [],
            directory: directory, isOffered: offered)
        // A model that cannot call tools, one the learner's settings rule
        // out, and one the loaded directory lacks are left out.
        #expect(loaded.suggestions == [
            .catalog(opus, slug: "anthropic/claude-opus-4.8"),
            .directory(directory[0])
        ])

        // Before the directory answers, an uncatalogued suggestion waits in
        // its place rather than appearing later.
        let loading = ChatModelLists.build(
            suggested: suggested, entries: entries, enabledIDs: [],
            directory: nil, isOffered: offered)
        #expect(loading.suggestions.map(\.slug) == [
            "anthropic/claude-opus-4.8", "qwen/qwen3.8-omni-flash", "lab/toolless", "lab/not-listed"
        ])
        #expect(loading.suggestions[1] == .pending(slug: "qwen/qwen3.8-omni-flash"))
    }

    /// The directory's prices on 2026-09-30.
    @Test("A suggestion shows its family's newest release; Background's only while it stays a tier below Chat's")
    func suggestionsShowNewestRelease() {
        let directory = [
            Self.directoryModel("google/gemini-3.1-flash-lite", maker: "Google", created: 1, price: (0.25, 1.5)),
            Self.directoryModel("google/gemini-3.5-flash-lite", maker: "Google", created: 5, price: (0.3, 2.5)),
            Self.directoryModel("google/gemini-3.8-flash", maker: "Google", created: 9, price: (0.75, 3.75)),
            Self.directoryModel("x-ai/grok-4.3", maker: "xAI", created: 2, price: (1.25, 2.5)),
            Self.directoryModel("x-ai/grok-4.6", maker: "xAI", created: 6, price: (2, 6)),
            Self.directoryModel("x-ai/grok-4.7", maker: "xAI", created: 8, price: (2, 6)),
            Self.directoryModel("x-ai/grok-4.9", maker: "xAI", tools: false, created: 10),
            Self.directoryModel("deepseek/deepseek-v4-flash", maker: "DeepSeek", created: 3, price: (0.08, 0.16)),
            Self.directoryModel("deepseek/deepseek-v4.1-flash", maker: "DeepSeek", created: 7, price: (0.02, 0.4)),
        ]
        let chat = ChatModelLists.build(
            suggested: ["google/gemini-3.5-flash-lite", "x-ai/grok-4.6", "deepseek/deepseek-v4.1-flash"],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true })
        // A release that cannot call tools is no successor in a chat list.
        #expect(chat.suggestions.map(\.slug) == [
            "google/gemini-3.5-flash-lite", "x-ai/grok-4.7", "deepseek/deepseek-v4.1-flash"
        ])

        let chatPicks = ["google/gemini-3.8-flash", "x-ai/grok-4.7", "deepseek/deepseek-v4.1-flash"]
            .compactMap { slug in directory.first { $0.id == slug } }
        let background = ChatModelLists.build(
            suggested: ["google/gemini-3.1-flash-lite", "x-ai/grok-4.3", "deepseek/deepseek-v4-flash"],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true },
            allowsNewerRelease: { ChatModelLists.isTierBelow($0, chatSuggestions: chatPicks) })
        // Gemini's newer Flash Lite still costs less than Chat's Gemini; every
        // Grok after 4.3 costs what Chat's does, and DeepSeek's newer Flash
        // is Chat's own pick.
        #expect(background.suggestions.map(\.slug) == [
            "google/gemini-3.5-flash-lite", "x-ai/grok-4.3", "deepseek/deepseek-v4-flash"
        ])
        // A maker Chat suggests nothing from moves no Background pick.
        #expect(!ChatModelLists.isTierBelow(directory[1], chatSuggestions: []))
    }

    @Test("Settings › Chat's Free list is the slugs it is given, as the catalog or directory carries them")
    func chatModelFreeList() {
        let router = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: "openrouter/free")
        let gemma = Self.directoryModel("google/gemma-4-31b-it:free", maker: "Google", price: (0, 0))
        let trains = Self.directoryModel("nvidia/nemotron-3-super:free", maker: "NVIDIA", price: (0, 0))
        let directory = [gemma, trains, Self.directoryModel("openrouter/free", price: (0, 0))]

        let built = ChatModelLists.build(
            suggested: ["google/gemma-4-31b-it:free"],
            free: ["openrouter/free", "google/gemma-4-31b-it:free", "nvidia/nemotron-3-super:free", "lab/gone:free"],
            entries: [router],
            enabledIDs: [router.id],
            directory: directory,
            // The Data & Privacy switch hides a free model whose host trains.
            isOffered: { $0 != trains.id })
        // A catalogued pick keeps its catalog row; one Suggested already
        // lists, one the settings rule out, and one OpenRouter dropped go.
        #expect(built.free == [.catalog(router, slug: "openrouter/free")])
        #expect(built.suggestions == [.directory(gemma)])

        // Waiting for the directory, the picks hold their places.
        let loading = ChatModelLists.build(
            suggested: [], free: ["openrouter/free", "google/gemma-4-31b-it:free"],
            entries: [router], enabledIDs: [], directory: nil, isOffered: { _ in true })
        #expect(loading.free == [
            .catalog(router, slug: "openrouter/free"), .pending(slug: "google/gemma-4-31b-it:free")
        ])
    }

    @Test("Settings › Chat's browser narrows to free or discounted models, and counts each")
    func chatModelBrowserFilters() {
        let half = RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil)
        let directory = [
            Self.directoryModel("z-ai/glm-5.3-flash", maker: "Z.ai", created: 2, promotion: half),
            Self.directoryModel("z-ai/glm-5.2", maker: "Z.ai", created: 1),
            Self.directoryModel("nvidia/nemotron-3-ultra:free", maker: "NVIDIA", created: 1, price: (0, 0)),
            Self.directoryModel("stealth/space-bunny", created: 1, price: (0, 0)),
            Self.directoryModel("cohere/free-toolless:free", maker: "Cohere", tools: false, price: (0, 0)),
            Self.directoryModel("cohere/ruled-out:free", maker: "Cohere", price: (0, 0))
        ]
        func build(_ filters: Set<ModelBrowserFilter>) -> ChatModelLists.Built {
            ChatModelLists.build(
                suggested: [], entries: [], enabledIDs: [], directory: directory,
                filters: filters, isOffered: { $0 != "cohere/ruled-out:free" })
        }

        let all = build([])
        #expect(all.makers.map(\.id) == ["maker:zai", "maker:nvidia", "stealth"])
        // Only models the chat could offer count: not one without tools, not
        // one the learner's settings rule out. Zero-priced is free, suffix or not.
        #expect(all.filterCounts == [.free: 2, .discounted: 1])

        let free = build([.free])
        #expect(free.makers.map(\.id) == ["maker:nvidia", "stealth"])
        #expect(free.makers.flatMap(\.models).map(\.id) == ["nvidia/nemotron-3-ultra:free", "stealth/space-bunny"])
        #expect(free.filterCounts == all.filterCounts)

        #expect(build([.discounted]).makers.flatMap(\.models).map(\.id) == ["z-ai/glm-5.3-flash"])
        // Both on list either kind.
        #expect(build([.free, .discounted]).makers.flatMap(\.models).map(\.id) == [
            "z-ai/glm-5.3-flash", "nvidia/nemotron-3-ultra:free", "stealth/space-bunny"
        ])
        #expect(ModelBrowserFilter.phrase([.discounted, .free]) == "free or discounted")
    }

    @Test("Settings › Chat's directory goes by maker, the catalog's makers first, newest model first")
    func chatModelDirectoryMakers() {
        let directory = [
            Self.directoryModel("~anthropic/claude-opus-latest", maker: "Anthropic", created: 2),
            Self.directoryModel("anthropic/claude-new", maker: "Anthropic", created: 3),
            Self.directoryModel("anthropic/claude-old", maker: "Anthropic", created: 1),
            Self.directoryModel("meta-llama/llama-9", maker: "Meta", created: 1),
            Self.directoryModel("meta/muse-9", maker: "Meta", created: 2),
            Self.directoryModel("upstage/solar-1", maker: "Upstage", created: 1),
            Self.directoryModel("upstage/solar-2", maker: "Upstage", created: 2),
            Self.directoryModel("cohere/command", maker: "Cohere", created: 1),
            Self.directoryModel("openrouter/free", created: 1),
            Self.directoryModel("stealth/space-bunny", created: 1),
            Self.directoryModel("cohere/toolless", maker: "Cohere", tools: false),
            Self.directoryModel("cohere/ruled-out", maker: "Cohere")
        ]
        let built = ChatModelLists.build(
            suggested: [], entries: [], enabledIDs: [],
            directory: directory, isOffered: { $0 != "cohere/ruled-out" })

        #expect(built.makers.map(\.id) == [
            "maker:anthropic", "maker:meta", "upstage", "cohere", "maker:other", "stealth"
        ])
        #expect(built.makers.map(\.identity.name) == [
            "Anthropic", "Meta", "Upstage", "Cohere", "OpenRouter", "stealth"
        ])
        // A moving alias files under the maker it points into, and Meta's two
        // vendor slugs are one maker.
        #expect(built.makers[0].models.map(\.id) == [
            "anthropic/claude-new", "~anthropic/claude-opus-latest", "anthropic/claude-old"
        ])
        #expect(built.makers[1].models.map(\.id) == ["meta/muse-9", "meta-llama/llama-9"])
        // The catalog's makers draw their bundled logo; the rest openrouter.ai's.
        #expect(built.makers[0].identity.logo == .anthropic)
        #expect(built.makers[2].identity.logo == nil)
        #expect(built.makers[2].identity.vendor == "upstage")
        #expect(built.makers[3].models.map(\.id) == ["cohere/command"])
    }

    @Test("A promoted row strikes the list price beside the price billed, never the same figure twice")
    func promotionListPriceLabel() {
        func promotion(_ basisPoints: Int) -> RouterModelPromotion {
            RouterModelPromotion(label: "\(basisPoints / 100)% off", discountBasisPoints: basisPoints, endsAt: nil)
        }
        // The directory quotes the discounted price; the list price behind it
        // is what OpenRouter's own page strikes through.
        #expect(promotion(8_000).listPriceLabel(effectiveInput: 0.04, effectiveOutput: 0.15) == "$0.2/$0.75")
        #expect(promotion(5_000).listPriceLabel(effectiveInput: 2, effectiveOutput: 10) == "$4/$20")
        // A fractional cut ("56.10% off") still lands on a clean two-decimal pair.
        #expect(promotion(5_610).listPriceLabel(effectiveInput: 0.58, effectiveOutput: 1.74) == "$1.32/$3.96")
        // Nothing to strike: a free model, a cut too small to move the rounded
        // label, or a promotion outside the (0, 100)% range.
        #expect(promotion(5_000).listPriceLabel(effectiveInput: 0, effectiveOutput: 0) == nil)
        #expect(promotion(100).listPriceLabel(effectiveInput: 0.01, effectiveOutput: 0.01) == nil)
        #expect(promotion(0).listPriceLabel(effectiveInput: 1, effectiveOutput: 2) == nil)
        #expect(promotion(10_000).listPriceLabel(effectiveInput: 1, effectiveOutput: 2) == nil)
    }

    @Test("Disabled and removed chat models cannot become the effective selection")
    func disabledChatModelsAreNotSelectable() throws {
        let muse12 = try #require(AIModelCatalog.entry(
            provider: .meta,
            modelID: AIModelDefaults.latestMuseSpark
        ))
        let claude = try #require(AIModelCatalog.entry(
            provider: .anthropic,
            modelID: AIModelDefaults.defaultAnthropic
        ))
        let enabled = Set([muse12.id])

        #expect(AIModelCatalog.isEnabledChatSelection(
            provider: muse12.provider,
            modelID: muse12.modelID,
            enabledIDs: enabled
        ))
        #expect(!AIModelCatalog.isEnabledChatSelection(
            provider: claude.provider,
            modelID: claude.modelID,
            enabledIDs: enabled
        ))
        // Offered again since 2026-09-14: a stored tick selects it unless the
        // Data & Privacy switch is hiding the models that train.
        #expect(AIModelCatalog.isEnabledChatSelection(
            provider: .meta,
            modelID: AIModelDefaults.museSparkContributor,
            enabledIDs: enabled.union([
                AIModelCatalogEntry(maker: .meta, provider: .meta, modelID: AIModelDefaults.museSparkContributor).id,
            ])
        ) == !AIModelCatalog.hidesTrainingModels)
        #expect(!AIModelCatalog.isEnabledChatSelection(
            provider: .meta,
            modelID: "muse-spark-1.1",
            enabledIDs: enabled
        ))
    }

    @Test("The model picker shows every enabled model on a configured provider")
    func modelPickerShowsEnabledConfiguredModels() throws {
        let claude = try #require(
            AIModelCatalog.entry(
                provider: .anthropic,
                modelID: AIModelDefaults.defaultAnthropic
            )
        )
        let muse = try #require(
            AIModelCatalog.entry(
                provider: .meta,
                modelID: AIModelDefaults.latestMuseSpark
            )
        )
        let llama = try #require(
            AIModelCatalog.entry(
                provider: .openRouter,
                modelID: "meta-llama/llama-4-maverick"
            )
        )
        let groups = [
            AIModelCatalog.MakerGroup(maker: .anthropic, entries: [claude]),
            AIModelCatalog.MakerGroup(maker: .meta, entries: [muse, llama]),
        ]
        let entries = InlineModelPicker.menuEntries(
            groups: groups,
            enabledIDs: [claude.id, muse.id, llama.id],
            configuredProviders: [.anthropic, .meta, .openRouter]
        )

        #expect(entries.map(\.id) == [claude.id, muse.id, llama.id])
        #expect(InlineModelPicker.isEntryAvailable(
            muse,
            configuredProviders: [.anthropic, .meta, .openRouter]
        ))
        #expect(InlineModelPicker.isEntryAvailable(
            claude,
            configuredProviders: [.anthropic, .meta, .openRouter]
        ))
    }

    @Test("An empty picker on a signed-in account never asks for Apple sign-in")
    func emptyPickerNoticeNamesTheRealCause() {
        // The 2026-09-05 report: the session is valid and the menu was blank.
        #expect(InlineModelPicker.emptyMenuNotice(hasConfiguredProviders: true) == .noModelsAvailable)
        // Only a Mac with no usable provider — no managed session — is told to sign in.
        #expect(InlineModelPicker.emptyMenuNotice(hasConfiguredProviders: false) == .signInRequired)
    }

    @Test("The model chip names the effort: the pick, else the model's own, and none for a model without one")
    func modelChipNamesTheEffort() {
        let offered: [AIEffort] = [.low, .medium, .high]
        #expect(InlineModelPicker.chipEffort(selected: nil, supported: offered, modelDefault: .medium) == .medium)
        #expect(InlineModelPicker.chipEffort(selected: .high, supported: offered, modelDefault: .medium) == .high)
        // A pick the model does not take is not sent, so the chip names the default.
        #expect(InlineModelPicker.chipEffort(selected: .max, supported: offered, modelDefault: .medium) == .medium)
        #expect(InlineModelPicker.chipEffort(selected: .high, supported: [], modelDefault: .medium) == nil)
    }

    @Test("Retired Muse Spark selections are rejected instead of substituted")
    func retiredMuseSparkSelectionIsRejected() {
        let isRetired = AIModelDefaults.isRetiredChatModel(
            provider: .openRouter,
            model: AIModelDefaults.retiredOpenRouterMuseSpark
        )

        #expect(isRetired)
        #expect(
            AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.latestMuseSpark) != nil
        )
    }

    @Test("Muse Spark Contributor is offered again and flagged as training on every route")
    func museSparkContributorTrainsOnInputs() {
        // Retired 2026-09-10 while the router's account refused it; back on
        // 2026-09-14 — The product owner wants it "even if they train on my data" — with
        // the Data & Privacy switch as the way to keep it out of the pickers.
        // Not retired on any route, flagged on both, and the full tier is not.
        #expect(!AIModelDefaults.isRetiredChatModel(
            provider: .meta,
            model: AIModelDefaults.museSparkContributor
        ))
        #expect(!AIModelDefaults.isRetiredChatModel(
            provider: .openRouter,
            model: "meta/\(AIModelDefaults.museSparkContributor)"
        ))
        #expect(AIModelDefaults.isRetiredChatModel(
            provider: .openRouter,
            model: AIModelDefaults.retiredOpenRouterMuseSpark
        ))
        #expect(AIModelDefaults.trainsOnInputs(
            provider: .meta,
            model: AIModelDefaults.museSparkContributor
        ))
        #expect(AIModelDefaults.trainsOnInputs(
            provider: .openRouter,
            model: "meta/\(AIModelDefaults.museSparkContributor)"
        ))
        #expect(!AIModelDefaults.trainsOnInputs(
            provider: .meta,
            model: AIModelDefaults.latestMuseSpark
        ))
        #expect(AIModelDefaults.preferredMeta == [AIModelDefaults.latestMuseSpark, AIModelDefaults.museSparkContributor])
        #expect(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.latestMuseSpark) != nil)
    }

    @Test("Chat distinguishes Apple sign-in from an unavailable managed model")
    func chatConfigurationErrorsNameTheMissingRequirement() {
        #expect(
            ReviewSessionManager.chatConfigFailureMessageForTesting(
                isSignedIn: false,
                provider: .meta
            ) == "Sign in with Apple to use ForeverLM AI."
        )
        #expect(
            ReviewSessionManager.chatConfigFailureMessageForTesting(
                isSignedIn: true,
                provider: .meta
            ) == "The selected chat model isn't available. Choose another model, or check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
        )
        #expect(
            !ReviewSessionManager.chatConfigFailureMessageForTesting(
                isSignedIn: true,
                provider: .openRouter
            ).contains("Sign in with Apple")
        )
    }

    @Test("Reasoning opt-out asks first-generation GPT-5 models for minimal effort, not none")
    func lowestReasoningEffortRespectsMandatoryReasoningModels() {
        // OpenRouter rejects `none` for these with a 400: "Reasoning is
        // mandatory for this endpoint and cannot be disabled."
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5-nano") == "minimal")
        #expect(AIService.lowestReasoningEffort(model: "gpt-5-mini") == "minimal")
        #expect(AIService.lowestReasoningEffort(model: "gpt-5") == "minimal")
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5-2025-08-07") == "minimal")
        // Later generations, chat-tuned variants, and other vendors accept none.
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5.6-luna") == "none")
        #expect(AIService.lowestReasoningEffort(model: "gpt-5.1") == "none")
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5-chat-latest") == "none")
        #expect(AIService.lowestReasoningEffort(model: "anthropic/claude-sonnet-5") == "none")
        // GPT-6 rejects none and minimal; low is its documented floor.
        #expect(AIService.lowestReasoningEffort(model: "gpt-6-astra") == "low")
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-6-astra") == "low")
    }

    @Test("A refused reasoning opt-out is recognised and the model asks for low from then on")
    func mandatoryReasoningRefusalIsRememberedPerModel() {
        let body = Data(#"{"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled.","code":400}}"#.utf8)
        #expect(AIService.isMandatoryReasoningRefusal(status: 400, body: body))
        #expect(!AIService.isMandatoryReasoningRefusal(status: 429, body: body))
        #expect(!AIService.isMandatoryReasoningRefusal(status: 400, body: Data(#"{"error":{"message":"Bad request"}}"#.utf8)))

        let slug = "test-vendor/mandatory-reasoning-\(UUID().uuidString)"
        #expect(AIService.lowestReasoningEffort(model: slug) == "none")
        AIService.MandatoryReasoningModels.insert(slug)
        #expect(AIService.lowestReasoningEffort(model: slug) == "low")
        #expect(AIService.lowestReasoningEffort(model: slug.uppercased()) == "low")
    }

    @Test("A paper parked behind a refused reasoning opt-out resumes on its own")
    func mandatoryReasoningCleanupFailureResumes() {
        let message = StudioArticle.paperContentCleanupFailureMessage(
            "Reasoning is mandatory for this endpoint and cannot be disabled. [OpenRouter request failed (400)]"
        )
        #expect(PaperContentPreparationService.isTransientIngestionFailure(message))
    }

    @Test("Every GPT-5-and-later gate reads one generation number")
    func openAIGenerationDrivesTheReasoningGates() {
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-5") == 5)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-5.6-sol") == 5)
        #expect(AIModelDefaults.openAIGeneration(of: "openai/gpt-5.6-luna") == 5)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-6-astra") == 6)
        #expect(AIModelDefaults.openAIGeneration(of: " OpenAI/GPT-6-Astra ") == 6)
        // Names that merely start with digits are not generations of the line.
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-4o") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-4o-mini-transcribe") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-image-2") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-oss-120b") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "claude-sonnet-5") == nil)

        // The gates that used to spell "gpt-5" each follow the number, bare or
        // routed, so Astra inherits the reasoning-model request shape.
        for model in ["gpt-6-astra", "openai/gpt-6-astra", "gpt-5.6-sol"] {
            #expect(AIService.openAIModelRequiresDefaultTemperature(model))
        }
        #expect(!AIService.openAIModelRequiresDefaultTemperature("gpt-4o"))

        // Astra's and the GPT-5.6 line's budget is their 922k input cap, not
        // the 1.05M window that includes output; GPT-5.5 documents no input
        // cap, so its budget is the 1.05M window; gpt-4o is 128k.
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-6-astra") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-6-astra") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-5.6-sol") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-5.6") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-5.5") == 1_050_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-4o") == 128_000)

        // The same lab models reached through OpenRouter keep the lab's
        // published window (the input cap, where the lab states one; OpenRouter
        // lists the 1.05M total), whichever spelling the slug uses.
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-5.6-sol") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-6-astra") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "anthropic/claude-opus-4.8") == 1_000_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-sonnet-4-5-20250929") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "google/gemini-3.5-flash") == 1_048_576)

        // The 2026-09-07 audit of the pinned table against the labs' pages and
        // OpenRouter's directory: Claude Opus 4 is a 200k model (only Sonnet 4
        // of that generation has 1M), under its bare name, its "-0" alias and
        // its dated snapshot alike; Together serves Inkling at 524k, half the
        // model's own window, so the host's figure is the budget there.
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-4") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-4-0") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-4-20250514") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "anthropic/claude-opus-4") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-sonnet-4-0") == 1_000_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-sonnet-4") == 1_000_000)
        #expect(AIService.contextWindowTokens(provider: .together, model: "thinkingmachines/inkling") == 524_288)
        #expect(AIService.contextWindowTokens(provider: .together, model: "thinkingmachines/inkling-nvfp4") == 524_288)
    }

    @Test("A context window is published, directory-listed, or unknown — never a default")
    func contextWindowNeverDefaults() {
        let openRouterKey = AIModelCatalog.openRouterContextLengthKey
        let defaults = UserDefaults.standard
        let savedOpenRouter = defaults.data(forKey: openRouterKey)
        defer {
            if let savedOpenRouter {
                defaults.set(savedOpenRouter, forKey: openRouterKey)
            } else {
                defaults.removeObject(forKey: openRouterKey)
            }
        }
        defaults.removeObject(forKey: openRouterKey)

        // Nothing published and no directory row: unknown, not a neighbour's
        // figure and not a per-host constant.
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "moonshotai/kimi-k2.6") == nil)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-4.1-mini") == nil)
        #expect(AIService.contextWindowTokens(provider: .xai, model: "grok-4.5") == nil)
        #expect(AIService.contextWindowTokens(provider: .cerebras, model: "zai-glm-4.7") == nil)

        // OpenRouter's directory answers for every slug it serves — and for a
        // closed-lab model the published table omits, on the lab's own route.
        AIModelCatalog.cacheOpenRouterContextLengths([
            "moonshotai/kimi-k2.6": 262_144,
            "openai/gpt-oss-120b": 131_072,
            "x-ai/grok-4.5": 2_000_000,
        ])
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "moonshotai/kimi-k2.6") == 262_144)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-oss-120b") == 131_072)
        #expect(AIService.contextWindowTokens(provider: .xai, model: "grok-4.5") == 2_000_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "x-ai/grok-4.5") == 2_000_000)

        // With no window there is nothing to fit to: the budgeter leaves the
        // request exactly as built instead of trimming against a guess.
        let system = String(repeating: "s", count: 600_000)
        let unbudgeted = AIService.budgetedChatRequest(
            provider: .xai,
            model: "grok-4.6-unlisted",
            system: system,
            messages: [(role: "user", content: "hi")],
            requestedMaxTokens: 9_000
        )
        #expect(unbudgeted.system.count == system.count)
        #expect(unbudgeted.maxTokens == 9_000)
        #expect(AIService.inputCharacterBudget(provider: .xai, model: "grok-4.6-unlisted", requestedMaxTokens: 9_000) == nil)
        #expect(AIService.cappedResponseTokens(provider: .xai, model: "grok-4.6-unlisted", requestedMaxTokens: 9_000) == 9_000)
    }

    @Test("resident source budget follows the selected model's context window")
    func sourceContextBudgetFollowsContextWindow() throws {
        // A dropped-in book used to stop at 64k characters whatever the model.
        // The budget is now a share of the model's input budget, so a
        // million-token window holds more than a 256k one, and both hold more
        // than the old constant.
        let millionWindow = try #require(AIService.sourceContextCharacterBudget(
            provider: .anthropic, model: "claude-opus-5", requestedMaxTokens: 8_000
        ))
        let quarterMillionWindow = try #require(AIService.sourceContextCharacterBudget(
            provider: .openai, model: "gpt-5.6-sol", requestedMaxTokens: 8_000
        ))
        #expect(millionWindow >= quarterMillionWindow)
        #expect(quarterMillionWindow > 64_000)

        // The share is capped: half of a million-token window is ~400k tokens
        // resent every round, and one cold cache rewrite of it cost $2.65.
        let input = try #require(AIService.inputCharacterBudget(
            provider: .anthropic, model: "claude-opus-5", requestedMaxTokens: 8_000
        ))
        let ceiling = AIService.sourceContextMaxTokens * AIService.approxCharsPerToken
        #expect(input / 2 > ceiling)
        #expect(millionWindow == ceiling)
        #expect(quarterMillionWindow <= ceiling)

        // No published window: nothing to derive from, so the caller keeps its
        // standing figure instead of budgeting against a guess.
        #expect(AIService.sourceContextCharacterBudget(
            provider: .xai, model: "grok-4.6-unlisted", requestedMaxTokens: 8_000
        ) == nil)
    }

    @Test("A failure at the proxy is named after ForeverLM, not the provider")
    func unreachableServiceIsNamedHonestly() throws {
        // What a sinkholed or down proxy actually produces: a URLError whose
        // failing URL is ForeverLM's, for a request the provider never saw.
        let proxied = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey:
                    "https://ai.foreverlm.com/v1/proxy/openrouter/api/v1/chat/completions"
            ]
        )
        var renamed: String?
        if case AIError.serviceUnreachable(let text) = ManagedAI.namingUnreachableService(proxied) {
            renamed = text
        }
        #expect(renamed?.contains("ai.foreverlm.com") == true)
        #expect(renamed?.contains("never got to the AI provider") == true)
        // Retrying is still right — the rename must not change what the error
        // is, only what it says it is.
        #expect(AITransientErrorClassifier.isTransient(AIError.serviceUnreachable(renamed ?? "")))

        // The same failure against the provider itself, as the direct rail
        // produces, is the provider's to own and passes through untouched.
        let direct = URLError(
            .timedOut,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://openrouter.ai/api/v1/chat/completions"]
        )
        #expect(ManagedAI.namingUnreachableService(direct) is URLError)

        // A refusal the proxy answered with is a real answer, not an
        // unreachable service.
        let refused = AIError.httpError(status: 401, message: "Sign in again.", retryAfterSeconds: nil)
        #expect(ManagedAI.namingUnreachableService(refused) is AIError)
        #expect(!AITransientErrorClassifier.isTransient(refused))
    }

    @Test("An own OpenRouter key sends the call straight to OpenRouter")
    func ownOpenRouterKeyBypassesTheProxy() throws {
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.setValue("Bearer ", forHTTPHeaderField: "Authorization")
        ManagedAI.rewrite(&request)

        #expect(request.url?.host == "openrouter.ai")
        #expect(request.url?.path == "/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test-key")
        // The proxy's own header would be a live credential handed to a party
        // that has no use for it.
        #expect(request.value(forHTTPHeaderField: ManagedAI.ownKeyHeader) == nil)
        // Attribution is for ForeverLM's ledger, which is local on this rail.
        // What the learner is studying is not OpenRouter's business.
        for header in [
            "X-ForeverLM-Task",
            "X-ForeverLM-Source-Title",
            "X-ForeverLM-Subject-ID",
            "X-ForeverLM-Subject-Type",
            "X-ForeverLM-Activity-ID",
            "X-ForeverLM-Platform",
            "X-ForeverLM-Build"
        ] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }

        // Only that key's own router leaves the device with it. Any other host
        // is pointed nowhere, and the key does not travel with it.
        var elsewhere = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        ManagedAI.rewrite(&elsewhere)
        #expect(elsewhere.url == ManagedAI.noKeyURL)
        #expect(elsewhere.value(forHTTPHeaderField: ManagedAI.ownKeyHeader) == nil)
        for (_, value) in elsewhere.allHTTPHeaderFields ?? [:] {
            #expect(!value.contains("sk-or-test-key"))
        }
    }

    @Test("With no own key no provider request goes anywhere")
    func withoutAnOwnKeyNothingLeaves() throws {
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        #expect(!ManagedAI.sendsOwnKeyDirect(toHost: "openrouter.ai"))
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        ManagedAI.rewrite(&request)
        #expect(request.url == ManagedAI.noKeyURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A request with no route fails with the sentence that says to add a key")
    func blockedRequestSaysToAddAKey() throws {
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        ManagedAI.rewrite(&request)
        let error = URLError(.unsupportedURL, userInfo: [NSURLErrorFailingURLErrorKey: try #require(request.url)])
        let service = try #require(ManagedAI.blockedRequestError(error))
        #expect(service.code == "no_own_key")
        #expect(service.message.contains("OpenRouter key"))
        // Any other unsupported URL is not ours to rename.
        #expect(ManagedAI.blockedRequestError(URLError(.unsupportedURL, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "ftp://example.com")!,
        ])) == nil)
    }

    @Test("A lab's own API has no route, and nothing of its URL is kept")
    func labHostsEndAtTheNoRouteURL() throws {
        // OpenRouter is the only router. The hosts that once had a route of
        // their own end where any unknown host does, carrying nothing of their
        // URL, not even a `?key=`.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        for url in [
            "https://api.openai.com/v1/audio/speech",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:streamGenerateContent?alt=sse&key=stray-key",
            "https://api.meta.ai/v1/chat/completions",
            "https://api.x.ai/v1/images/generations",
            "https://api.example.com/v1/anything?api_key=stray-key",
        ] {
            var request = URLRequest(url: URL(string: url)!)
            ManagedAI.rewrite(&request)
            #expect(request.url == ManagedAI.noKeyURL)
            #expect(request.url?.query == nil)
        }

        // With a key, OpenRouter's own query passes through whole, direct.
        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        var lookup = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/generation?id=gen-1")!)
        ManagedAI.rewrite(&lookup)
        #expect(lookup.url?.host == "openrouter.ai")
        #expect(lookup.url?.path == "/api/v1/generation")
        #expect(lookup.url?.query == "id=gen-1")
    }

    @Test("The direct rail asks OpenRouter for the cost the proxy would have priced")
    func directRailRequestsBilledCost() throws {
        var proxied: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "messages": [["role": "user", "content": "Hello"]]
        ]
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        AIService.applyOpenRouterPayloadExtras(&proxied, provider: .openRouter)
        #expect(proxied["usage"] == nil)

        var direct: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "messages": [["role": "user", "content": "Hello"]]
        ]
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        AIService.applyOpenRouterPayloadExtras(&direct, provider: .openRouter)
        #expect((direct["usage"] as? [String: Bool])?["include"] == true)
    }

    @Test("Claude and GPT on the learner's own OpenRouter key are pinned to their lab's endpoint, so BYOK applies")
    func ownKeyLabModelsRunOnTheirLabEndpoint() throws {
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        func body(_ model: String) -> [String: Any] {
            ["model": model, "messages": [["role": "user", "content": "Hello"]] as [[String: Any]]]
        }

        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        var claude = body("anthropic/claude-opus-5.5")
        AIService.applyOpenRouterPayloadExtras(&claude, provider: .openRouter)
        let routing = try #require(claude["provider"] as? [String: Any])
        #expect(routing["order"] as? [String] == ["anthropic"])
        #expect(routing["allow_fallbacks"] as? Bool == false)
        #expect(routing["only"] == nil)

        // A GPT model OpenAI serves itself runs on OpenAI's endpoint, not
        // Azure or Bedrock, so an OpenAI key added to OpenRouter applies.
        // Slugs of this test's own: other suites clear the shared cache.
        func tier(_ tag: String, _ host: String) -> OpenRouterEndpointTier {
            OpenRouterEndpointTier(
                tag: tag, providerName: host, inputUSDPerMTokens: 1, outputUSDPerMTokens: 4,
                cachedInputUSDPerMTokens: nil, discount: nil
            )
        }
        OpenRouterEndpointTierCatalog.cache(
            [tier("azure", "Azure"), tier("openai", "OpenAI"), tier("amazon-bedrock/global", "Amazon Bedrock")],
            for: "openai/byok-test-gpt"
        )
        var gpt = body("openai/byok-test-gpt")
        AIService.applyOpenRouterPayloadExtras(&gpt, provider: .openRouter)
        let gptRouting = try #require(gpt["provider"] as? [String: Any])
        #expect(gptRouting["order"] as? [String] == ["openai"])
        #expect(gptRouting["allow_fallbacks"] as? Bool == false)

        // OpenAI's open weights run only on other hosts: the throughput route stays.
        OpenRouterEndpointTierCatalog.cache([tier("groq", "Groq"), tier("deepinfra/bf16", "DeepInfra")], for: "openai/byok-test-oss")
        var openWeights = body("openai/byok-test-oss")
        AIService.applyOpenRouterPayloadExtras(&openWeights, provider: .openRouter)
        #expect((openWeights["provider"] as? [String: Any])?["order"] == nil)

        // An OpenAI model whose endpoints were never read is OpenAI's own and
        // is pinned too; its open weights are not.
        var unread = body("openai/byok-test-unread")
        AIService.applyOpenRouterPayloadExtras(&unread, provider: .openRouter)
        #expect((unread["provider"] as? [String: Any])?["order"] as? [String] == ["openai"])
        var unreadOSS = body("openai/gpt-oss-byok-test")
        AIService.applyOpenRouterPayloadExtras(&unreadOSS, provider: .openRouter)
        #expect((unreadOSS["provider"] as? [String: Any])?["order"] == nil)

        // Another lab's model keeps the throughput route.
        var other = body("deepseek/deepseek-v4.1-flash")
        AIService.applyOpenRouterPayloadExtras(&other, provider: .openRouter)
        #expect((other["provider"] as? [String: Any])?["order"] == nil)

        // A Speed tier names its own endpoint and is left alone.
        var pinned = body("anthropic/claude-opus-5.5")
        pinned["provider"] = ["order": ["anthropic/fast"], "allow_fallbacks": false] as [String: Any]
        AIService.pinLabModelToItsOwnEndpoint(&pinned)
        #expect((pinned["provider"] as? [String: Any])?["order"] as? [String] == ["anthropic/fast"])

        // No own key: the proxy's rail keeps OpenRouter's routing.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        var proxied = body("anthropic/claude-opus-5.5")
        AIService.applyOpenRouterPayloadExtras(&proxied, provider: .openRouter)
        #expect((proxied["provider"] as? [String: Any])?["order"] == nil)
    }

    @Test("A first-party lab has no text endpoint; Muse Spark's text travels OpenRouter")
    func firstPartyLabsHaveNoTextEndpoint() throws {
        // The labs are model families on the routers. ForeverLM sends their
        // own hosts nothing, so a text call that skipped routing fails loudly.
        for provider in [AIProvider.anthropic, .openai, .gemini, .xai, .meta] {
            #expect(AIService.openAICompatibleChatEndpoint(for: provider) == nil)
            #expect(!AIService.routesThroughOpenRouter(provider))
        }
        #expect(AIService.routesThroughOpenRouter(.openRouter))
        #expect(
            AIService.openAICompatibleChatEndpoint(for: .openRouter)
                == "https://openrouter.ai/api/v1/chat/completions"
        )
        let routed = KeychainService.routedTextSelection(
            provider: .meta,
            model: "muse-spark-1.2",
            mode: .openRouter
        )
        #expect(routed.provider == .openRouter)
        #expect(routed.model == "meta/muse-spark-1.2")

        // Offered again; hidden only while the Data & Privacy switch is on.
        #expect(
            (AIModelCatalog.entry(
                provider: .meta,
                modelID: AIModelDefaults.museSparkContributor
            ) != nil) == !AIModelCatalog.hidesTrainingModels
        )
        #expect(
            AIService.contextWindowTokens(
                provider: .meta,
                model: AIModelDefaults.museSparkContributor
            ) == 1_048_576
        )
    }

    @Test("Effort reaches OpenRouter in its reasoning object, so Claude streams a thinking summary")
    func effortTravelsInOpenRouterReasoningObject() throws {
        var routed: [String: Any] = [:]
        AIService.applyReasoningEffort(.high, provider: .openRouter, to: &routed)
        #expect((routed["reasoning"] as? [String: String]) == ["effort": "high"])
        #expect(routed["reasoning_effort"] == nil)
    }

    @Test("OpenRouter GPT-5 requests omit unsupported temperature")
    func openRouterGPT5OmitsTemperature() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Extract paper metadata."],
            ["role": "user", "content": "Front matter"],
        ]
        let luna = try AIService.prepareOpenAICompatiblePayload(
            [
                "model": "openai/gpt-5.6-luna",
                "messages": messages,
                "max_tokens": 4_096,
                "temperature": 0.0,
            ],
            provider: .openRouter
        )
        #expect(luna["model"] as? String == "openai/gpt-5.6-luna")
        #expect(luna["temperature"] == nil)
        #expect(luna["max_tokens"] as? Int == 4_096)

        let deepSeek = try AIService.prepareOpenAICompatiblePayload(
            [
                "model": "deepseek/deepseek-v4-pro",
                "messages": messages,
                "max_tokens": 4_096,
                "temperature": 0.0,
            ],
            provider: .openRouter
        )
        #expect(deepSeek["temperature"] as? Double == 0.0)
    }

    @Test("Claude Opus 5.5 is the offered flagship with its admitted OpenRouter slug")
    func opusFiveCatalogAndRouting() {
        #expect(AIModelDefaults.latestClaude == "claude-opus-5-5")
        #expect(AIModelDefaults.preferredAnthropic.contains("claude-opus-5-5"))
        #expect(!AIModelDefaults.preferredAnthropic.contains("claude-opus-4-8"))
        #expect(
            OpenRouterModelID.slug(provider: .anthropic, model: "claude-opus-5-5")
                == "anthropic/claude-opus-5.5"
        )
        // Speed never changes the slug: OpenRouter's fast tier is a separate
        // endpoint of the same model, chosen through `provider.order`, so the
        // model id and its prompt cache stay shared across speeds.
        #expect(
            OpenRouterModelID.slug(provider: .anthropic, model: "claude-opus-5-5")
                == "anthropic/claude-opus-5.5"
        )
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-5-5") == 1_000_000)
        // The shipped defaults are the newest release of each pick's family.
        #expect(AIModelDefaults.defaultAnthropic == "claude-sonnet-5-5")
        #expect(AIModelDefaults.preferredAnthropic.contains("claude-fable-5-2"))
        #expect(AIModelDefaults.preferredAnthropic.contains("claude-haiku-5-5"))
        #expect(AIModelDefaults.defaultOpenAI == "gpt-6.2-sol")
        #expect(AIModelDefaults.latestGemini == "gemini-3.8-flash")
    }
}
