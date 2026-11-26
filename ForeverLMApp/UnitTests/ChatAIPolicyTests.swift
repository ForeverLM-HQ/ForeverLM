// AI data policy and OpenRouter speed tier tests.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// The "Don't let AI providers keep my data" switch: what it puts on the wire,
/// where it stays off the wire, and how OpenRouter's refusal reads back.
@Suite("AI data policy", .serialized)
struct AIDataPolicyTests {
    /// Runs `body` with the switch in the given state and restores whatever the
    /// developer's own defaults held.
    private func withDataPolicy(deny: Bool, _ body: () async throws -> Void) async throws {
        let key = AIDataPolicy.denyDataCollectionKey
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set(deny, forKey: key)
        try await body()
    }

    @Test("OpenRouter bodies carry data_collection deny only while the switch is on")
    func openRouterBodiesCarryTheDenyPreferenceOnlyWhenOn() async throws {
        let payload: [String: Any] = [
            "model": "deepseek/deepseek-v4-flash",
            "messages": [["role": "user", "content": "Summarise the abstract."]],
            "max_tokens": 512,
        ]

        try await withDataPolicy(deny: true) {
            let prepared = try AIService.prepareOpenAICompatiblePayload(payload, provider: .openRouter)
            #expect(AIDataPolicy.payloadDeniesDataCollection(prepared))
            let provider = try #require(prepared["provider"] as? [String: Any])
            #expect(provider["data_collection"] as? String == "deny")

            // First-party routes take no such flag; nothing is invented for them.
            let openAI = try AIService.prepareOpenAICompatiblePayload(payload, provider: .openai)
            #expect(openAI["provider"] == nil)
        }

        try await withDataPolicy(deny: false) {
            let prepared = try AIService.prepareOpenAICompatiblePayload(payload, provider: .openRouter)
            // Only the fastest-endpoint sort rides along; no data policy.
            #expect((prepared["provider"] as? [String: Any])?["data_collection"] == nil)
            #expect((prepared["provider"] as? [String: Any])?["sort"] as? String == "throughput")
            #expect(!AIDataPolicy.payloadDeniesDataCollection(prepared))
        }
    }

    @Test("Existing provider preferences survive the deny flag")
    func denyFlagKeepsOtherProviderPreferences() {
        var payload: [String: Any] = ["provider": ["order": ["Together"]]]
        AIDataPolicy.applyDenyDataCollection(to: &payload)
        let provider = payload["provider"] as? [String: Any]
        #expect(provider?["order"] as? [String] == ["Together"])
        #expect(provider?["data_collection"] as? String == "deny")
    }

    @Test("The phone's OpenRouter body carries the flag from its resolved route")
    func mobileRouteCarriesTheFlag() throws {
        func body(deny: Bool) throws -> [String: Any] {
            let route = ResolvedAITextRoute(
                task: .chat,
                provider: "OpenRouter",
                model: "deepseek/deepseek-v4-flash",
                deniesDataCollection: deny
            )
            let request = try MobileOpenRouterChat.request(
                route: route,
                system: "You answer from the source.",
                messages: [(role: "user", content: "What is the main claim?")],
                maxTokens: 256
            )
            let data = try #require(request.httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(AIDataPolicy.payloadDeniesDataCollection(try body(deny: true)))
        let open = try body(deny: false)
        #expect(!AIDataPolicy.payloadDeniesDataCollection(open))
        #expect((open["provider"] as? [String: Any])?["sort"] as? String == "throughput")
    }

    @Test("A streamed answer is gathered whole, past keepalives and thinking frames")
    func streamedAnswerGathersTheWholeText() {
        var answer = MobileOpenRouterChat.StreamedAnswer()
        for line in [
            ": OPENROUTER PROCESSING",
            "",
            #"data: {"model":"vendor/model-a","choices":[{"delta":{"reasoning":"thinking"}}]}"#,
            #"data: {"model":"vendor/model-a","choices":[{"delta":{"content":"{\"adaptations\""}}]}"#,
            ": OPENROUTER PROCESSING",
            #"data: {"choices":[{"delta":{"content":":[]}"}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"after the end"}}]}"#,
        ] {
            answer.consume(line: line)
        }
        #expect(answer.text == #"{"adaptations":[]}"#)
        #expect(answer.servedModel == "vendor/model-a")
        #expect(answer.isFinished)
        #expect(answer.providerError == nil)
    }

    @Test("A stream the provider ends with an error says so instead of passing as an answer")
    func streamedAnswerKeepsTheProvidersError() {
        var answer = MobileOpenRouterChat.StreamedAnswer()
        answer.consume(line: #"data: {"choices":[{"delta":{"content":"{\"adapt"}}]}"#)
        answer.consume(line: #"data: {"error":{"code":502,"message":"Upstream provider is overloaded"}}"#)
        answer.consume(line: #"data: {"choices":[{"delta":{"content":"ations\":[]}"}}]}"#)
        #expect(answer.providerError == "Upstream provider is overloaded")
        #expect(answer.isFinished)
        #expect(answer.text == #"{"adapt"#)
    }

    @Test("OpenRouter's data-policy refusal names the switch, only while it is on")
    func dataPolicyRefusalNamesTheSwitch() async throws {
        let refusal = #"{"error":{"message":"No endpoints found matching your data policy","code":404}}"#
        let service = AIService()

        try await withDataPolicy(deny: true) {
            let message = try #require(await service.extractAPIErrorMessage(from: Data(refusal.utf8)))
            #expect(message.contains(AIDataPolicy.switchTitle))
            #expect(message.contains(AIDataPolicy.settingsLocation))
            #expect(message.hasSuffix("The provider said: No endpoints found matching your data policy"))
            #expect(message.count <= AIProviderErrorText.maximumDisplayLength)

            // Any other refusal is the provider's own words, untouched.
            let rateLimit = #"{"error":{"message":"Rate limit reached"}}"#
            #expect(await service.extractAPIErrorMessage(from: Data(rateLimit.utf8)) == "Rate limit reached")
        }

        try await withDataPolicy(deny: false) {
            #expect(await service.extractAPIErrorMessage(from: Data(refusal.utf8))
                == "No endpoints found matching your data policy")
        }
    }

    /// OpenRouter's answer to Muse Spark 1.2 Contributor on 2026-09-10, verbatim.
    static let trainingRefusalText = "0 endpoints out of 1 requested are available matching your guardrail "
        + "restrictions and data policy. We removed them for the following reasons (an endpoint may have "
        + "matched multiple reasons): Paid model training violation (account settings): 1 endpoint excluded; "
        + "configurable at https://openrouter.ai/settings/privacy"

    @Test("The account's training refusal is translated whether or not the switch is on")
    func trainingRefusalIsTranslatedWithoutTheSwitch() async throws {
        let refusal = try JSONSerialization.data(withJSONObject: [
            "error": ["message": Self.trainingRefusalText, "code": 404],
        ])
        let service = AIService()

        for deny in [false, true] {
            try await withDataPolicy(deny: deny) {
                let message = try #require(await service.extractAPIErrorMessage(from: refusal))
                #expect(message.hasPrefix("This model is served only by hosts that train on what you send them"))
                // The switch is not the way out of an account-level exclusion.
                #expect(!message.contains(AIDataPolicy.switchTitle))
                #expect(message.contains("The provider said: 0 endpoints out of 1 requested"))
                #expect(message.count <= AIProviderErrorText.maximumDisplayLength)
            }
        }
    }

    @Test("The switch hides the models that train from every catalog read")
    func switchHidesTrainingModels() async throws {
        let contributor = AIModelCatalogEntry(
            maker: .meta, provider: .meta, modelID: AIModelDefaults.museSparkContributor
        )
        let contributorSlug = "meta/\(AIModelDefaults.museSparkContributor)"

        try await withDataPolicy(deny: false) {
            #expect(!AIModelCatalog.hidesTrainingModels)
            let entry = try #require(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.museSparkContributor))
            #expect(entry.trainsOnInputs)
            #expect(AIModelCatalog.makerGroups.flatMap(\.entries).contains(where: { $0.id == contributor.id }))
            #expect(AIModelCatalog.allEntries.contains(where: { $0.id == contributor.id }))
            #expect(AIModelCatalog.isEnabledChatSelection(
                provider: .meta, modelID: AIModelDefaults.museSparkContributor, enabledIDs: [contributor.id]
            ))
            // No row says the model trains: that is OpenRouter's to say. The
            // picker is the main actor's, so the row is read on it.
            await MainActor.run {
                #expect(InlineModelPicker.modelRowSubtitle(
                    rates: (input: 0.1, output: 0.2), promotion: nil, currentSpeedQuote: nil
                ) == "$0.1/$0.2")
                #expect(InlineModelPicker.modelRowSubtitle(rates: nil, promotion: nil, currentSpeedQuote: nil) == nil)
                #expect(InlineModelPicker.modelRowSubtitle(
                    rates: nil, promotion: nil, currentSpeedQuote: nil, isRecommended: true
                ) == "Recommended")
            }
        }

        try await withDataPolicy(deny: true) {
            #expect(AIModelCatalog.hidesTrainingModels)
            #expect(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.museSparkContributor) == nil)
            #expect(!AIModelCatalog.makerGroups.flatMap(\.entries).contains { $0.trainsOnInputs })
            #expect(!AIModelCatalog.allEntries.contains { $0.trainsOnInputs })
            #expect(!AIModelCatalog.isEnabledChatSelection(
                provider: .meta, modelID: AIModelDefaults.museSparkContributor, enabledIDs: [contributor.id]
            ))
            // Still catalogued for the directory browser, so it is not offered
            // back as an extra while hidden.
            #expect(AIModelCatalog.cataloguedOpenRouterSlugs.contains(contributorSlug))
            // The full tier is untouched, and Meta's group survives.
            #expect(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.latestMuseSpark) != nil)
            #expect(AIModelCatalog.makerGroups.contains(where: { $0.maker == .meta }))
        }
    }

    @Test("Refusal detection reads the words, not the status")
    func refusalDetectionReadsTheWords() {
        #expect(AIDataPolicy.isDataPolicyRefusal("No endpoints found matching your data policy"))
        #expect(AIDataPolicy.isDataPolicyRefusal("Provider rejected: data_collection=deny excludes all hosts"))
        #expect(!AIDataPolicy.isDataPolicyRefusal("No endpoints found that support image input"))
        #expect(!AIDataPolicy.isDataPolicyRefusal("Rate limit reached"))

        // The account-level exclusion mentions "data policy" too; it is told
        // apart by the training clause and wins.
        #expect(AIDataPolicy.isTrainingPolicyRefusal(Self.trainingRefusalText))
        #expect(AIDataPolicy.isDataPolicyRefusal(Self.trainingRefusalText))
        #expect(!AIDataPolicy.isTrainingPolicyRefusal("No endpoints found matching your data policy"))
        #expect(!AIDataPolicy.isTrainingPolicyRefusal("Rate limit reached"))
    }

    @Test("The switch is a synced preference")
    func switchIsSynced() {
        #expect(SyncedPreferenceKeys.isSynced(AIDataPolicy.denyDataCollectionKey))
    }
}

@Suite("OpenRouter speed tiers", .serialized)
struct OpenRouterSpeedTierTests {
    /// Trimmed from OpenRouter's live `/models/openai/gpt-5.6-sol/endpoints`
    /// answer on 2026-09-10: the lab's three service tiers plus two resellers.
    static let solEndpointsJSON = """
    {"data":{"id":"openai/gpt-5.6-sol","name":"OpenAI: GPT-5.6 Sol","endpoints":[
      {"name":"OpenAI | openai/gpt-5.6-sol-20260709","tag":"openai/flex","provider_name":"OpenAI","status":-2,
       "pricing":{"prompt":"0.000001","completion":"0.000005","input_cache_read":"0.0000001","discount":0.5}},
      {"name":"OpenAI | openai/gpt-5.6-sol-20260709","tag":"openai","provider_name":"OpenAI","status":0,
       "pricing":{"prompt":"0.000002","completion":"0.00001","input_cache_read":"0.0000002","discount":0.5}},
      {"name":"OpenAI | openai/gpt-5.6-sol-20260709","tag":"openai/fast","provider_name":"OpenAI","status":0,
       "pricing":{"prompt":"0.000004","completion":"0.00002","input_cache_read":"0.0000004","discount":0.5}},
      {"name":"Azure | openai/gpt-5.6-sol-20260709","tag":"azure/eu","provider_name":"Azure","status":0,
       "pricing":{"prompt":"0.0000055","completion":"0.000033","input_cache_read":"0.00000055","discount":0}},
      {"name":"Broken | openai/gpt-5.6-sol-20260709","tag":"broken/fast","provider_name":"Broken","status":-3,
       "pricing":{"prompt":"0.000001","completion":"0.000001"}},
      {"name":"No price","tag":"nowhere","provider_name":"Nowhere","status":0,"pricing":{}}
    ]}}
    """

    static var solTiers: [OpenRouterEndpointTier] {
        OpenRouterSpeedTier.parseEndpoints(Data(solEndpointsJSON.utf8))
    }

    @Test("Endpoint rows parse into priced tiers, keeping deranked ones and dropping unpriced ones")
    func endpointsParse() throws {
        let tiers = Self.solTiers
        // Flex is at status -2 in the live answer — OpenRouter's derank
        // marker, not an outage — and must still be offered; the row with
        // no price is the only one that goes.
        #expect(tiers.map(\.tag) == ["openai/flex", "openai", "openai/fast", "azure/eu", "broken/fast"])
        let fast = try #require(OpenRouterSpeedTier.fastTier(for: "openai/gpt-5.6-sol", in: tiers))
        #expect(fast.tag == "openai/fast")
        #expect(fast.providerName == "OpenAI")
        #expect(fast.inputUSDPerMTokens == 4)
        #expect(fast.outputUSDPerMTokens == 20)
        #expect(fast.cachedInputUSDPerMTokens == 0.4)
        #expect(fast.discount == 0.5)
        let standard = try #require(OpenRouterSpeedTier.standardTier(for: "openai/gpt-5.6-sol", in: tiers))
        #expect(standard.tag == "openai")
        #expect(standard.inputUSDPerMTokens == 2)
        #expect(standard.outputUSDPerMTokens == 10)
        let flex = try #require(OpenRouterSpeedTier.flexTier(for: "openai/gpt-5.6-sol", in: tiers))
        #expect(flex.tag == "openai/flex")
        #expect(flex.inputUSDPerMTokens == 1)
        #expect(flex.outputUSDPerMTokens == 5)
        #expect(OpenRouterSpeedTier.tier(for: .flex, slug: "openai/gpt-5.6-sol", in: tiers) == flex)
        #expect(OpenRouterSpeedTier.tier(for: .standard, slug: "openai/gpt-5.6-sol", in: tiers) == standard)
        #expect(OpenRouterSpeedTier.tier(for: .fast, slug: "openai/gpt-5.6-sol", in: tiers) == fast)
        // Azure's row carries no promotion, so its discount reads as none.
        #expect(tiers.last?.discount == nil)
    }

    @Test("Only the lab's own fast tier counts")
    func fastTierBelongsToTheLab() {
        let reseller = [OpenRouterEndpointTier(
            tag: "deepinfra/fast", providerName: "DeepInfra",
            inputUSDPerMTokens: 1, outputUSDPerMTokens: 2,
            cachedInputUSDPerMTokens: nil, discount: nil)]
        #expect(OpenRouterSpeedTier.fastTier(for: "openai/gpt-5.6-sol", in: reseller) == nil)
        #expect(OpenRouterSpeedTier.fastTier(for: "no-vendor-slug", in: Self.solTiers) == nil)
        #expect(OpenRouterSpeedTier.vendor(ofSlug: "Anthropic/claude-opus-5") == "anthropic")
    }

    @Test("Ultrafast is the lab's tier above fast, and never a standard host")
    func ultrafastTier() throws {
        // Trimmed from OpenRouter's live `/models/openai/gpt-6.2-sol/endpoints`
        // answer on 2026-11-25: fast at twice the standard price, ultrafast at three times.
        let tiers = [
            OpenRouterEndpointTier(tag: "openai", providerName: "OpenAI",
                                   inputUSDPerMTokens: 2, outputUSDPerMTokens: 10,
                                   cachedInputUSDPerMTokens: 0.1, discount: nil),
            OpenRouterEndpointTier(tag: "openai/fast", providerName: "OpenAI",
                                   inputUSDPerMTokens: 4, outputUSDPerMTokens: 20,
                                   cachedInputUSDPerMTokens: 0.2, discount: nil),
            OpenRouterEndpointTier(tag: "openai/ultrafast", providerName: "OpenAI",
                                   inputUSDPerMTokens: 6, outputUSDPerMTokens: 30,
                                   cachedInputUSDPerMTokens: 0.3, discount: nil),
        ]
        let slug = "openai/gpt-6.2-sol"
        let ultrafast = try #require(OpenRouterSpeedTier.tier(for: .ultrafast, slug: slug, in: tiers))
        #expect(ultrafast.tag == "openai/ultrafast")
        #expect(OpenRouterSpeedTier.tier(for: .fast, slug: slug, in: tiers)?.tag == "openai/fast")
        #expect(OpenRouterSpeedTier.isServiceTier("openai/ultrafast"))
        #expect(OpenRouterSpeedTier.tier(for: .ultrafast, slug: "openai/gpt-5.6-sol", in: Self.solTiers) == nil)
        #expect(AISpeed.allCases == [.flex, .standard, .fast, .ultrafast])
        let speeds = [
            OpenRouterEndpointSpeed(tag: "openai", medianTokensPerSecond: 90, requestCount: 50),
            OpenRouterEndpointSpeed(tag: "openai/ultrafast", medianTokensPerSecond: 400, requestCount: 50),
        ]
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .ultrafast, slug: slug, in: speeds) == 400)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: slug, in: speeds) == 90)
    }

    @Test("Promotion labels name whole percents only")
    func promotionLabels() {
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 0.5) == "50% off")
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 0.25) == "25% off")
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 0) == nil)
        #expect(OpenRouterSpeedTier.promotionLabel(discount: nil) == nil)
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 1) == nil)
        // The composer menu carries the fraction too, so it can strike the
        // list price beside the discounted one.
        #expect(OpenRouterSpeedTier.promotion(discount: 0.5)
            == RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil))
        #expect(OpenRouterSpeedTier.promotion(discount: 0.25)?.discountBasisPoints == 2_500)
        #expect(OpenRouterSpeedTier.promotion(discount: 0) == nil)
        #expect(OpenRouterSpeedTier.promotion(discount: nil) == nil)
        #expect(OpenRouterSpeedTier.promotion(discount: 1) == nil)
    }

    @Test("Speed is offered only where OpenRouter lists a tier endpoint for the routed slug, cheapest first")
    func speedSupportFollowsTheRoute() {
        let slug = "openai/gpt-5.6-sol"
        OpenRouterEndpointTierCatalog.cache(Self.solTiers, for: slug)
        defer { OpenRouterEndpointTierCatalog.cache([], for: slug) }

        // The composer's canonical identity, on the OpenRouter route: OpenAI
        // publishes both a flex and a fast tier, listed as a price ladder.
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openai, model: "gpt-5.6", routingMode: .openRouter) == [.flex, .standard, .fast])
        // The dispatch path's routed identity.
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openRouter, model: slug, routingMode: .openRouter) == [.flex, .standard, .fast])
        // A lab with only a fast tier (Anthropic) offers Standard and Fast; one
        // with only a flex tier offers Flex and Standard; a lab with neither
        // offers no Speed control even though its endpoints are known.
        let opus = "anthropic/claude-opus-5"
        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "anthropic", providerName: "Anthropic",
                                   inputUSDPerMTokens: 5, outputUSDPerMTokens: 25, cachedInputUSDPerMTokens: nil, discount: nil),
            OpenRouterEndpointTier(tag: "anthropic/fast", providerName: "Anthropic",
                                   inputUSDPerMTokens: 30, outputUSDPerMTokens: 150, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: opus)
        defer { OpenRouterEndpointTierCatalog.cache([], for: opus) }
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .anthropic, model: "claude-opus-5", routingMode: .openRouter) == [.standard, .fast])
        let flexOnly = "openai/gpt-5.6-luna"
        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "openai", providerName: "OpenAI",
                                   inputUSDPerMTokens: 0.2, outputUSDPerMTokens: 1.2, cachedInputUSDPerMTokens: nil, discount: nil),
            OpenRouterEndpointTier(tag: "openai/flex", providerName: "OpenAI",
                                   inputUSDPerMTokens: 0.1, outputUSDPerMTokens: 0.6, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: flexOnly)
        defer { OpenRouterEndpointTierCatalog.cache([], for: flexOnly) }
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openai, model: "gpt-5.6-luna", routingMode: .openRouter) == [.flex, .standard])
        let plain = "nvidia/nemotron-3-ultra"
        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "nvidia", providerName: "NVIDIA",
                                   inputUSDPerMTokens: 0.62, outputUSDPerMTokens: 3.12, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: plain)
        defer { OpenRouterEndpointTierCatalog.cache([], for: plain) }
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openRouter, model: plain, routingMode: .openRouter).isEmpty)
        // A model whose endpoints have not been fetched offers nothing yet.
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .anthropic, model: "claude-sonnet-5", routingMode: .openRouter).isEmpty)
        #expect(AIRequestOptionSupport.openRouterSpeedSlug(
            provider: .anthropic, model: "claude-opus-4-8", routingMode: .openRouter) == "anthropic/claude-opus-4.8")
    }

    @Test("Fast and Flex name the lab's tier endpoint in provider.order and forbid fallbacks")
    func fastRequestTargetsTheTier() throws {
        let slug = "openai/gpt-5.6-sol"
        OpenRouterEndpointTierCatalog.cache(Self.solTiers, for: slug)
        defer { OpenRouterEndpointTierCatalog.cache([], for: slug) }
        func payload() -> [String: Any] {
            [
                "model": slug,
                "messages": [
                    ["role": "system", "content": "instructions"],
                    ["role": "user", "content": "question"],
                ] as [[String: Any]],
            ]
        }

        var fast = payload()
        AIService.applyOpenRouterPayloadExtras(&fast, provider: .openRouter, speed: .fast)
        let provider = try #require(fast["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["openai/fast"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        // The model id is unchanged, so the prompt cache is shared across speeds.
        #expect(fast["model"] as? String == slug)

        var flex = payload()
        AIService.applyOpenRouterPayloadExtras(&flex, provider: .openRouter, speed: .flex)
        let flexProvider = try #require(flex["provider"] as? [String: Any])
        #expect(flexProvider["order"] as? [String] == ["openai/flex"])
        #expect(flexProvider["allow_fallbacks"] as? Bool == false)

        var standard = payload()
        AIService.applyOpenRouterPayloadExtras(&standard, provider: .openRouter, speed: .standard)
        #expect((standard["provider"] as? [String: Any])?["order"] == nil)

        var unknownTier = payload()
        unknownTier["model"] = "anthropic/claude-opus-5"
        AIService.applyOpenRouterPayloadExtras(&unknownTier, provider: .openRouter, speed: .fast)
        #expect((unknownTier["provider"] as? [String: Any])?["order"] == nil)

        // An existing provider preference (the data-policy switch) is kept.
        var merged = payload()
        merged["provider"] = ["data_collection": "deny"]
        AIService.applyOpenRouterSpeedTier(to: &merged, speed: .fast)
        let mergedProvider = try #require(merged["provider"] as? [String: Any])
        #expect(mergedProvider["data_collection"] as? String == "deny")
        #expect(mergedProvider["order"] as? [String] == ["openai/fast"])
    }

    @Test("A standard OpenRouter send goes to the fastest endpoint that caches the prompt")
    func standardSendSortsByThroughputAmongCachingEndpoints() throws {
        func endpoint(_ tag: String, cached: Double?, parameters: Set<String>? = ["tools", "reasoning", "max_tokens"]) -> OpenRouterEndpointTier {
            OpenRouterEndpointTier(tag: tag, providerName: tag, inputUSDPerMTokens: 0.15, outputUSDPerMTokens: 0.6,
                                   cachedInputUSDPerMTokens: cached, discount: nil, supportedParameters: parameters)
        }
        let slug = "openai/gpt-oss-120b"
        let mixed = [
            endpoint("cerebras/fp16", cached: nil),
            endpoint("fireworks", cached: 0.03),
            endpoint("groq", cached: 0.075),
            endpoint("together", cached: 0.15), // cached == prompt: nothing to gain
            endpoint("novita/fp4", cached: 0.03, parameters: ["max_tokens"]),
        ]
        OpenRouterEndpointTierCatalog.cache(mixed, for: slug)
        defer { OpenRouterEndpointTierCatalog.cache([], for: slug) }

        var chat: [String: Any] = [
            "model": slug,
            "messages": [["role": "system", "content": "s"], ["role": "user", "content": "q"]] as [[String: Any]],
            "tools": [["type": "function"]] as [[String: Any]],
        ]
        // The switch withholds `only`; pin it off, then restore the developer's own.
        let policyKey = AIDataPolicy.denyDataCollectionKey
        let savedPolicy = UserDefaults.standard.object(forKey: policyKey)
        defer {
            if let savedPolicy { UserDefaults.standard.set(savedPolicy, forKey: policyKey) }
            else { UserDefaults.standard.removeObject(forKey: policyKey) }
        }
        UserDefaults.standard.set(false, forKey: policyKey)
        AIService.applyOpenRouterPayloadExtras(&chat, provider: .openRouter, speed: .standard)
        let provider = try #require(chat["provider"] as? [String: Any])
        #expect(provider["sort"] as? String == "throughput")
        // The endpoint without tools is dropped, so the send cannot fail on it.
        #expect(provider["only"] as? [String] == ["fireworks", "groq"])

        // Every endpoint caches (GLM 5.3 Flash's 30 hosts): nothing to confine.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("z-ai/fp8", cached: 0.03), endpoint("wafer", cached: 0.02)],
            requiredParameters: ["tools"]) == nil)
        // None caches: nothing to confine to.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("cerebras", cached: nil), endpoint("sambanova", cached: nil)],
            requiredParameters: []) == nil)
        // An endpoint that does not list its parameters could be the only fit: leave routing open.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("cerebras", cached: nil), endpoint("fireworks", cached: 0.03, parameters: nil)],
            requiredParameters: []) == nil)
        // Service tiers never join a standard request's list.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("openai", cached: nil), endpoint("openai/flex", cached: 0.1)],
            requiredParameters: []) == nil)
    }

    @Test("The caching filter stands down under the data-policy switch, and a Speed pick keeps its endpoint")
    func cachingFilterYieldsToDataPolicyAndSpeedPicks() {
        var denied: [String: Any] = ["model": "m", "provider": ["data_collection": "deny"]]
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &denied, cachingEndpointTags: ["fireworks"])
        let deniedProvider = denied["provider"] as? [String: Any]
        #expect(deniedProvider?["sort"] as? String == "throughput")
        #expect(deniedProvider?["only"] == nil)

        var pinned: [String: Any] = ["model": "m", "provider": ["order": ["openai/fast"], "allow_fallbacks": false]]
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &pinned, cachingEndpointTags: ["fireworks"])
        let pinnedProvider = pinned["provider"] as? [String: Any]
        #expect(pinnedProvider?["sort"] == nil)
        #expect(pinnedProvider?["only"] == nil)

        #expect(OpenRouterRoutePreference.requiredParameters(of: [
            "tools": [["type": "function"]], "reasoning_effort": "low", "response_format": ["type": "json_object"],
        ]) == ["tools", "reasoning", "response_format"])
        #expect(OpenRouterRoutePreference.requiredParameters(of: ["tools": [Any]()]).isEmpty)
    }

    @Test("A host chosen for a task names it, or asks for the cheapest, and a task follows its Background default's choice")
    func hostPreferencePinsOrSortsTheRoute() throws {
        var cheapest: [String: Any] = ["model": "z-ai/glm-5.3"]
        OpenRouterHostPreference(mode: .cheapest).apply(to: &cheapest)
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &cheapest)
        #expect((cheapest["provider"] as? [String: Any])?["sort"] as? String == "price")

        var pinned: [String: Any] = ["model": "z-ai/glm-5.3"]
        OpenRouterHostPreference(mode: .host, tag: "deepinfra/fp4", hostName: "DeepInfra", allowsFallback: false)
            .apply(to: &pinned)
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &pinned, cachingEndpointTags: ["fireworks"])
        let provider = try #require(pinned["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["deepinfra/fp4"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        #expect(provider["sort"] == nil)
        #expect(provider["only"] == nil)

        #expect(!OpenRouterHostPreference(mode: .host, tag: " ").isValid)
        #expect(OpenRouterHostPreference(mode: .cheapest, tag: "ignored").tag == nil)
        #expect(OpenRouterHostPreference.key(slot: "background.text", slug: "Z-AI/GLM-5.3")
            == "aiHost.background.text|z-ai/glm-5.3")

        #expect(AIService.openRouterHostSlots(forTaskLabel: "chat") == ["chat"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: nil).isEmpty)
        // A chat's title runs on Background's model, so it follows that row.
        #expect(AIService.openRouterHostSlots(forTaskLabel: "chat_title") == ["background.text"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: "chat_quiz_grading") == ["chat"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: "read_aloud").isEmpty)
        // A background task follows its Background model's row alone: no
        // task has a host choice of its own.
        #expect(AIService.openRouterHostSlots(forTaskLabel: AITask.paperMetadata.rawValue) == ["background.text"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: AITask.paperFigureUnderstanding.rawValue) == ["background.images"])
    }

    @Test("Endpoint rows carry their supported parameters")
    func endpointRowsCarrySupportedParameters() throws {
        let json = #"{"data":{"endpoints":[{"tag":"fireworks","provider_name":"Fireworks","pricing":{"prompt":"0.00000015","completion":"0.0000006","input_cache_read":"0.00000003"},"supported_parameters":["tools","reasoning"]}]}}"#
        let row = try #require(OpenRouterSpeedTier.parseEndpoints(Data(json.utf8)).first)
        #expect(row.supportedParameters == ["tools", "reasoning"])
        #expect(row.cachesPrompts)
    }

    @Test("The directory is fetched without a tool filter, which priced OpenAI models at their Flex tier")
    func directoryRequestCarriesNoParameterFilter() throws {
        let components = try #require(URLComponents(url: AIService.openRouterDirectoryURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "openrouter.ai")
        #expect(components.path == "/api/v1/models")
        let names = Set((components.queryItems ?? []).map(\.name))
        #expect(!names.contains("supported_parameters"))
    }

    @Test("Output speed comes from OpenRouter's measured medians, per tier, and follows the price in the Speed submenu only")
    func composerOutputSpeedCopy() throws {
        // The shape /api/frontend/v1/stats/endpoint returned for GPT-5.6 Sol on
        // 2026-09-22, trimmed to the fields read. azure/us had no traffic.
        let body = """
        {"data":[
          {"provider_slug":"openai/flex","stats":{"p50_throughput":48,"throughput_request_count":1316}},
          {"provider_slug":"openai","stats":{"p50_throughput":49,"throughput_request_count":54399}},
          {"provider_slug":"openai/fast","stats":{"p50_throughput":84,"throughput_request_count":641}},
          {"provider_slug":"amazon-bedrock/us-east-1","stats":{"p50_throughput":81,"throughput_request_count":1083}},
          {"provider_slug":"azure","stats":{"p50_throughput":52,"throughput_request_count":30311}},
          {"provider_slug":"lone-host","stats":{"p50_throughput":400,"throughput_request_count":1}},
          {"provider_slug":"azure/us","stats":null}
        ]}
        """
        let speeds = OpenRouterModelSpeed.parseStats(Data(body.utf8))
        #expect(speeds.count == 6)
        let slug = "openai/gpt-5.6-sol"
        // Fast and Flex are their tier endpoint; Standard is the fastest
        // standard host with enough traffic — never the one-request outlier.
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .fast, slug: slug, in: speeds) == 84)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .flex, slug: slug, in: speeds) == 48)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: slug, in: speeds) == 81)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: slug, in: []) == nil)
        #expect(OpenRouterModelSpeed.parseStats(Data("{\"data\":{}}".utf8)).isEmpty)
        #expect(OpenRouterModelSpeed.label(tokensPerSecond: 60.6) == "61 tok/s")

        let fast = try #require(InlineModelPicker.speedRates(
            for: .fast, slug: slug, tiers: Self.solTiers, standardFallback: nil, speeds: speeds))
        #expect(fast.subtitle == "\(Self.struck("$8/$40")) $4/$20 · 50% off · 84 tok/s")
        // The model rows quote the price alone (product owner, 2026-09-23), even
        // for the selected model whose speed quote carries a figure.
        #expect(fast.priceLine == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 2, output: 10), promotion: nil, currentSpeedQuote: fast)
            == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        #expect(!InlineModelPicker.priceUnitHeader.contains("speed"))
        #expect(InlineModelPicker.speedPriceUnitHeader
            == "Price per million tokens, input/output · output speed")

        #expect(OpenRouterModelPage.url(slug: "anthropic/claude-sonnet-5")?.absoluteString
            == "https://openrouter.ai/anthropic/claude-sonnet-5")
        #expect(OpenRouterModelPage.url(provider: .openRouter, model: "z-ai/glm-5.3-flash")?.absoluteString
            == "https://openrouter.ai/z-ai/glm-5.3-flash")
        #expect(OpenRouterModelPage.url(slug: "no-vendor") == nil)
    }

    @Test("The composer quotes each speed from its own endpoint row and names the promotion once")
    func composerSpeedAndPromotionCopy() throws {
        let slug = "openai/gpt-5.6-sol"
        let tiers = Self.solTiers
        let fast = try #require(InlineModelPicker.speedRates(
            for: .fast, slug: slug, tiers: tiers, standardFallback: (input: 5, output: 30)))
        #expect(fast.input == 4)
        #expect(fast.output == 20)
        #expect(fast.subtitle == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        let standard = try #require(InlineModelPicker.speedRates(
            for: .standard, slug: slug, tiers: tiers, standardFallback: (input: 5, output: 30)))
        #expect(standard.input == 2)
        #expect(standard.output == 10)
        #expect(standard.subtitle == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        let flex = try #require(InlineModelPicker.speedRates(
            for: .flex, slug: slug, tiers: tiers, standardFallback: (input: 5, output: 30)))
        #expect(flex.input == 1)
        #expect(flex.output == 5)
        #expect(flex.subtitle == "\(Self.struck("$2/$10")) $1/$5 · 50% off")
        // No endpoint list yet: Standard falls back to the list price with the
        // route's own promotion label; Flex and Fast have nothing to quote.
        let fallback = try #require(InlineModelPicker.speedRates(
            for: .standard, slug: slug, tiers: [], standardFallback: (input: 2, output: 10),
            standardFallbackPromotion: Self.halfOff))
        #expect(fallback.input == 2)
        #expect(fallback.output == 10)
        #expect(fallback.subtitle == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        #expect(InlineModelPicker.speedRates(
            for: .fast, slug: slug, tiers: [], standardFallback: (input: 5, output: 30)) == nil)
        #expect(InlineModelPicker.speedRates(
            for: .flex, slug: slug, tiers: [], standardFallback: (input: 5, output: 30)) == nil)

        // A promoted line leads the in/out pair with the list pair, struck
        // through, so "50% off" cannot be read as still to come (product owner,
        // 2026-09-21). The strike is the U+0336 overlay, the only one a
        // macOS menu subtitle keeps; a list figure that rounds to the
        // effective label is left alone, and a free model has nothing to
        // strike.
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 2, output: 10), promotion: Self.halfOff)
            == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 2, output: 10), promotion: Self.halfOff)
            == "$\u{0336}4\u{0336}/\u{0336}$\u{0336}2\u{0336}0\u{0336} $2/$10 · 50% off")
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 2.5, output: 15), promotion: nil)
            == "$2.5/$15")
        #expect(InlineModelPicker.menuSubtitle(
            rates: (input: 0.01, output: 1),
            promotion: RouterModelPromotion(label: "1% off", discountBasisPoints: 100, endsAt: nil))
            == "\(Self.struck("$0.01/$1.01")) $0.01/$1 · 1% off")
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 0, output: 0), promotion: Self.halfOff)
            == "$0/$0 · 50% off")
        #expect(InlineModelPicker.menuSubtitle(
            rates: (input: 2, output: 10),
            promotion: RouterModelPromotion(label: "Free week", discountBasisPoints: 10_000, endsAt: nil))
            == "$2/$10 · Free week")
        #expect(InlineModelPicker.struckThrough("$20") == "$\u{0336}2\u{0336}0\u{0336}")

        // The selected model's row is priced from the speed it is set to, so
        // it can never contradict the Speed submenu; every other row (and the
        // selected one before the endpoint list arrives) quotes the directory.
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 1, output: 5), promotion: Self.halfOff, currentSpeedQuote: standard)
            == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 1, output: 5), promotion: Self.halfOff, currentSpeedQuote: fast)
            == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 1, output: 5), promotion: Self.halfOff, currentSpeedQuote: nil)
            == "\(Self.struck("$2/$10")) $1/$5 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(rates: nil, promotion: nil, currentSpeedQuote: nil) == nil)

        let entry = AIModelCatalogEntry(maker: .openai, provider: .openai, modelID: "gpt-5.6")
        let directory = [OpenRouterDirectoryModel(
            id: slug, name: "GPT-5.6 Sol",
            inputUSDPerMTokens: 2, outputUSDPerMTokens: 10, contextLength: 1_050_000,
            price: nil, supportsTools: true, supportsTemperature: nil, supportsVision: true,
            promotion: RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil))]
        #expect(InlineModelPicker.promotion(for: entry, routingMode: .openRouter, directory: directory) == Self.halfOff)
    }

    /// OpenRouter's half-price promotion as the directory carries it.
    static let halfOff = RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil)

    /// The text with the combining long stroke overlay after every character
    /// — the strikethrough a macOS menu subtitle can actually draw.
    static func struck(_ text: String) -> String {
        text.map { "\($0)\u{0336}" }.joined()
    }
}
