import Testing
@testable import ForeverLM

@Suite("AI Model Display Names")
struct AIModelDisplayNameTests {

    @Test("Claude aliases render as human-readable model-family names")
    func claudeAliasName() {
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.latestClaude,
                provider: .anthropic,
                includeProvider: true
            ) == "Opus 5"
        )
    }

    @Test("Claude 5 family model IDs render as readable names")
    func claudeFiveFamilyNames() {
        #expect(
            AIModelDisplayName.textModelName(
                "claude-opus-5",
                provider: .anthropic,
                includeProvider: true
            ) == "Opus 5"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "claude-fable-5",
                provider: .anthropic,
                includeProvider: true
            ) == "Fable 5"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "claude-sonnet-5",
                provider: .anthropic,
                includeProvider: true
            ) == "Sonnet 5"
        )
    }

    @Test("Claude dated variants hide release dates and bare family aliases")
    func claudeDatedVariantName() {
        #expect(
            AIModelDisplayName.textModelName(
                "claude-sonnet-4-6-2025-05-14",
                provider: .anthropic,
                includeProvider: true
            ) == "Sonnet 4.6"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "claude-sonnet-4-20250514",
                provider: .anthropic,
                includeProvider: true
            ) == "Sonnet 4.6"
        )
    }

    @Test("GPT-6 Astra renders as a readable name bare and as a routed slug")
    func gptSixAstraName() {
        #expect(
            AIModelDisplayName.textModelName(
                "gpt-6-astra",
                provider: .openai,
                includeProvider: true
            ) == "GPT-6 Astra"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "openai/gpt-6-astra",
                provider: .openRouter,
                includeProvider: false
            ) == "GPT-6 Astra"
        )
    }

    @Test("GPT-5.6 family model IDs render as readable names")
    func gptFiveSixFamilyNames() {
        #expect(
            AIModelDisplayName.textModelName(
                "gpt-5.6",
                provider: .openai,
                includeProvider: true
            ) == "GPT-5.6 Sol"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "gpt-5.6-terra",
                provider: .openai,
                includeProvider: true
            ) == "GPT-5.6 Terra"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "gpt-5.6-sol-2026-07-09",
                provider: .openai,
                includeProvider: true
            ) == "GPT-5.6 Sol"
        )
    }

    @Test("Cerebras model IDs render as readable names")
    func cerebrasModelNames() {
        #expect(
            AIModelDisplayName.textModelName(
                "gpt-oss-120b",
                provider: .cerebras,
                includeProvider: true
            ) == "GPT OSS 120B"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "qwen-3-235b-a22b-instruct-2507",
                provider: .cerebras,
                includeProvider: true
            ) == "Qwen 3 235B Instruct"
        )
    }

    @Test("Inkling model IDs render the same name on both hosting providers")
    func inklingModelNames() {
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.defaultTogether,
                provider: .together,
                includeProvider: true
            ) == "Inkling"
        )
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.defaultFireworks,
                provider: .fireworks,
                includeProvider: true
            ) == "Inkling"
        )
    }

    @Test("Nemotron 3 model IDs render as readable names")
    func nemotronModelNames() {
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.defaultNVIDIA,
                provider: .nvidia,
                includeProvider: true
            ) == "Nemotron 3 Ultra"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "nvidia/nemotron-3-super-120b-a12b",
                provider: .nvidia,
                includeProvider: true
            ) == "Nemotron 3 Super"
        )
    }

    @Test("An OpenRouter :free variant reads as the model plus (free)")
    func openRouterVariantSuffixName() {
        // Named the way OpenRouter's directory names it, never with the tag
        // glued onto the last slug token ("Nemotron 3 Ultra 550B A55b:free").
        let slug = "nvidia/nemotron-3-ultra-550b-a55b:free"
        #expect(AIModelDisplayName.textModelName(slug, provider: .openRouter) == "Nemotron 3 Ultra (free)")
        #expect(
            AIModelDisplayName.textModelName(slug, provider: .openRouter, compact: true)
                == "Nemotron 3 Ultra (free)"
        )
    }

    @Test("OpenRouter slugs for Chinese-lab models render as readable names")
    func openRouterChineseLabModelNames() {
        #expect(
            AIModelDisplayName.textModelName(
                "moonshotai/kimi-k3",
                provider: .openRouter,
                includeProvider: true
            ) == "Kimi K3"
        )
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.defaultOpenRouter,
                provider: .openRouter,
                includeProvider: true
            ) == "DeepSeek V4 Flash"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "deepseek/deepseek-v4-pro",
                provider: .openRouter,
                includeProvider: true
            ) == "DeepSeek V4 Pro"
        )
    }

    @Test("Muse Spark 1.2 renders as a human-readable name")
    func museSparkName() {
        #expect(
            AIModelDisplayName.textModelName(
                "meta/\(AIModelDefaults.latestMuseSpark)",
                provider: .openRouter,
                includeProvider: true
            ) == "Muse Spark 1.2"
        )
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.museSparkContributor,
                provider: .meta,
                includeProvider: true
            ) == "Muse Spark 1.2 Contributor"
        )
    }

    @Test("Gemini 3 model IDs render as readable names")
    func geminiThreeModelNames() {
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.latestGemini,
                provider: .gemini,
                includeProvider: true
            ) == "Gemini 3.5 Flash"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "gemini-3-pro-preview",
                provider: .gemini,
                includeProvider: true
            ) == "Gemini 3 Pro Preview"
        )
    }

    @Test("The OpenRouter vision slug renders without the maker prefix")
    func openRouterVisionSlugName() {
        // Settings shows this as the slide reader's resolved default, and the
        // warning names the model; both must read "Gemini 2.5 Flash", not the
        // generic "Google / Gemini 2.5 Flash" fallback.
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.visionOpenRouter,
                provider: .openRouter
            ) == "Gemini 2.5 Flash"
        )
    }

    @Test("A maker-prefixed slug reads the same as its bare model ID")
    func makerPrefixedSlugMatchesBareName() {
        // Paper Text-to-Speech Preparation stores the OpenRouter slug, which used
        // to fall through to the generic "Openai / gpt 5.6 Luna" while every
        // other Settings row showed the curated name.
        #expect(
            AIModelDisplayName.textModelName(
                AIModelDefaults.paperTextToSpeechPreparation,
                provider: .openRouter
            ) == "GPT-5.6 Luna"
        )
        #expect(
            AIModelDisplayName.textModelName(
                "anthropic/claude-opus-5",
                provider: .openRouter
            ) == "Opus 5"
        )
    }

    @Test("An unknown maker-prefixed slug drops the maker segment")
    func unknownSlugDropsMakerPrefix() {
        #expect(
            AIModelDisplayName.textModelName(
                "openai/gpt-9.1-nova",
                provider: .openRouter
            ) == "GPT 9.1 Nova"
        )
    }
}

@Suite("AI Model Catalog")
struct AIModelCatalogTests {

    @Test("Catalog models use canonical OpenRouter slugs for browser deduplication")
    func cataloguedOpenRouterSlugs() {
        let slugs = AIModelCatalog.cataloguedOpenRouterSlugs

        #expect(slugs.contains("anthropic/claude-fable-5"))
        #expect(slugs.contains("anthropic/claude-haiku-4.5"))
        #expect(slugs.contains("openai/gpt-5.6-sol"))
        #expect(slugs.contains("openai/gpt-6-astra"))
        #expect(slugs.contains("google/gemini-3.5-flash"))
        #expect(slugs.contains("x-ai/grok-4.7"))
        #expect(slugs.contains("meta/\(AIModelDefaults.latestMuseSpark)"))
        #expect(slugs.contains(AIModelDefaults.defaultOpenRouter))
        #expect(slugs.contains("mistralai/mistral-large-2512"))
        #expect(slugs.contains("mistralai/mistral-small-2603"))
    }

    /// The product owner (2026-09-22), seeing Grok 4.5 lead the xAI group after Grok
    /// 4.7 shipped: the latest model must lead without anyone editing a
    /// pinned list. A newer directory version of a pinned family joins the
    /// group on its OpenRouter route.
    @Test("A newer directory release of a pinned family joins its group")
    func directorySuccessorsJoinPinnedGroup() {
        let pinned = [
            AIModelCatalogEntry(maker: .xai, provider: .xai, modelID: "grok-4.3"),
            AIModelCatalogEntry(maker: .xai, provider: .xai, modelID: "grok-4.5"),
        ]
        func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86_400) }
        let xaiListing: [String: Date] = [
            "x-ai/grok-4.20": day(10), "x-ai/grok-4.3": day(20), "x-ai/grok-4.3:batch": day(20),
            "x-ai/grok-4.5": day(30), "x-ai/grok-4.6": day(40), "x-ai/grok-4.7": day(50),
            "x-ai/grok-build-0.1": day(45), "openai/grok-9": day(60),
        ]
        let successors = AIModelCatalog.directorySuccessors(of: pinned, listed: xaiListing)
        // grok-4.20 numbers higher but was listed before 4.5; the newest wins.
        #expect(successors.map(\.modelID) == ["x-ai/grok-4.7"])
        #expect(successors.allSatisfy { $0.provider == .openRouter && $0.maker == .xai })

        // Pinned on its own route, the successor dedups: nothing added.
        let current = pinned + [AIModelCatalogEntry(maker: .xai, provider: .xai, modelID: "grok-4.7")]
        #expect(AIModelCatalog.directorySuccessors(of: current, listed: xaiListing).isEmpty)

        let claude = AIModelCatalog.directorySuccessors(
            of: [AIModelCatalogEntry(maker: .anthropic, provider: .anthropic, modelID: "claude-opus-4-8")],
            listed: [
                "anthropic/claude-opus-4.8": day(1), "anthropic/claude-opus-5": day(2),
                "anthropic/claude-sonnet-6": day(3),
            ]
        )
        #expect(claude.map(\.modelID) == ["anthropic/claude-opus-5"])

        let gemini = AIModelCatalog.directorySuccessors(
            of: [AIModelCatalogEntry(maker: .google, provider: .gemini, modelID: "gemini-3.8-flash")],
            listed: [
                "google/gemini-3.9-flash-preview": day(2), "google/gemini-3.9-flash": day(3),
                "google/gemini-3.5-flash": day(0),
            ]
        )
        #expect(gemini.map(\.modelID) == ["google/gemini-3.9-flash"])

        // An undated pinned model still takes a higher-numbered successor.
        let undated = AIModelCatalog.directorySuccessors(
            of: [AIModelCatalogEntry(maker: .xai, provider: .xai, modelID: "grok-4.5")],
            listed: ["x-ai/grok-4.7": day(1)]
        )
        #expect(undated.map(\.modelID) == ["x-ai/grok-4.7"])
    }

    /// A Suggested list shows each pick as its family's newest release, so
    /// a new release needs no code change (2026-09-30).
    @Test("A Suggested pick shows as the newest release of its family")
    func suggestedPicksShowNewestRelease() {
        func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86_400) }
        let listed: [String: Date] = [
            "google/gemini-3.1-flash-lite": day(1), "google/gemini-3.1-flash-lite-preview": day(0),
            "google/gemini-3.5-flash-lite": day(5), "google/gemini-3.8-flash": day(9),
            "x-ai/grok-4.20": day(0), "x-ai/grok-4.3": day(2), "x-ai/grok-4.6": day(6),
            "x-ai/grok-4.7": day(8), "thinkingmachines/inkling": day(3),
        ]
        #expect(AIModelCatalog.newestReleases(
            of: ["google/gemini-3.1-flash-lite", "x-ai/grok-4.3", "thinkingmachines/inkling", "gone/model-1"],
            listed: listed
        ) == ["google/gemini-3.5-flash-lite", "x-ai/grok-4.7", "thinkingmachines/inkling", "gone/model-1"])

        // The newest release `allows` lets in takes the place; none, and the
        // pick stays. Grok 4.20 numbers higher than 4.3 but came first.
        let allowed = AIModelCatalog.newestReleases(of: ["x-ai/grok-4.3"], listed: listed) { successor, slug in
            #expect(slug == "x-ai/grok-4.3")
            return successor != "x-ai/grok-4.7"
        }
        #expect(allowed == ["x-ai/grok-4.6"])
        #expect(AIModelCatalog.newestReleases(of: ["x-ai/grok-4.3"], listed: listed) { _, _ in false } == ["x-ai/grok-4.3"])

        // Two picks that roll to one release list it once.
        #expect(AIModelCatalog.newestReleases(
            of: ["google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite"], listed: listed
        ) == ["google/gemini-3.5-flash-lite"])
    }

    @Test("Mistral directory models get their own maker group")
    func mistralMakerGroup() {
        #expect(
            AIModelCatalog.maker(forOpenRouterSlug: "mistralai/mistral-large-2512")
                == .mistral
        )
        // Membership, not order: the group's order follows the directory's
        // listing dates, which a test host may or may not have cached.
        #expect(
            AIModelCatalog.makerGroups
                .first(where: { $0.maker == .mistral })
                .map { Set($0.entries.map(\.modelID)) } == Set(AIModelDefaults.openRouterMistral)
        )
    }
}

/// Within a maker, the newest model leads. The product owner (2026-09-10), looking at
/// Gemini 3.1 Pro Preview ahead of the newer Gemini 3.8 Flash: "make sure
/// that the latest models are always shown here first … this should update
/// over time". The order is built on OpenRouter's directory `created` stamp,
/// never on a date typed into the app, so the rule here is the fallback
/// ladder: date, then price, then the caller's tie-break.
@Suite("Model Catalog Newest-First Order")
struct ModelCatalogNewestFirstOrderTests {
    private struct Row: Equatable {
        let id: String
        let released: Date?
        let rates: (input: Double, output: Double)?

        static func == (lhs: Row, rhs: Row) -> Bool { lhs.id == rhs.id }
    }

    private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400) }

    private func order(_ rows: [Row]) -> [String] {
        AIModelCatalog.orderedNewestFirst(
            rows,
            releaseDate: \.released,
            rates: \.rates,
            tieBreak: { $0.id < $1.id }
        ).map(\.id)
    }

    @Test("A newer, cheaper model leads an older, dearer one")
    func newestLeadsRegardlessOfPrice() {
        let rows = [
            Row(id: "pro-preview", released: day(0), rates: (1, 6)),
            Row(id: "flash", released: day(200), rates: (0.38, 1.88)),
            Row(id: "flash-lite", released: day(-300), rates: (0.1, 0.4)),
        ]
        #expect(order(rows) == ["flash", "pro-preview", "flash-lite"])
    }

    @Test("Same-day releases fall back to list price, most expensive first")
    func sameDayFallsBackToPrice() {
        let rows = [
            Row(id: "sol", released: day(0), rates: (1, 5)),
            Row(id: "terra", released: day(0), rates: (3, 12)),
            Row(id: "luna", released: day(0), rates: (1, 8)),
        ]
        #expect(order(rows) == ["terra", "luna", "sol"])
    }

    @Test("A dated model precedes an undated one; undated ones keep the price order")
    func undatedTrail() {
        let rows = [
            Row(id: "undated-cheap", released: nil, rates: (0.2, 0.8)),
            Row(id: "dated-old", released: day(-1000), rates: (0.1, 0.1)),
            Row(id: "undated-dear", released: nil, rates: (5, 25)),
            Row(id: "unpriced", released: nil, rates: nil),
        ]
        #expect(order(rows) == ["dated-old", "undated-dear", "undated-cheap", "unpriced"])
    }

    @Test("With no dates and no prices, the caller's tie-break decides")
    func tieBreakLast() {
        let rows = [Row(id: "b", released: nil, rates: nil), Row(id: "a", released: nil, rates: nil)]
        #expect(order(rows) == ["a", "b"])
        #expect(AIModelCatalog.newestFirstOrder(nil, nil) == nil)
        #expect(AIModelCatalog.newestFirstOrder(day(1), day(1)) == nil)
        #expect(AIModelCatalog.newestFirstOrder(day(2), day(1)) == true)
        #expect(AIModelCatalog.newestFirstOrder(nil, day(1)) == false)
        #expect(AIModelCatalog.priceDescendingOrder((1, 2), (1, 2)) == nil)
        #expect(AIModelCatalog.priceDescendingOrder((1, 3), (1, 2)) == true)
    }

    @Test("A catalog entry's release date resolves through its directory slug")
    func releaseDateResolvesThroughSlug() {
        // The alias "gpt-5.6" is listed on OpenRouter as the Sol tier, and a
        // user-added OpenRouter row carries its directory slug already. Both
        // read as unknown until a fetch has dated the slug.
        let sol = AIModelCatalogEntry(maker: .openai, provider: .openai, modelID: "gpt-5.6")
        let added = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: "acme/specialist-1")
        let cached = AIModelCatalog.openRouterDirectoryReleaseDate("openai/gpt-5.6-sol")
        #expect(AIModelCatalog.releaseDate(for: sol) == cached)
        #expect(AIModelCatalog.releaseDate(for: added) == AIModelCatalog.openRouterDirectoryReleaseDate("acme/specialist-1"))
    }

    private func listed(
        _ id: String,
        _ name: String,
        released: Date?,
        rates: (input: Double, output: Double)?
    ) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id,
            name: name,
            inputUSDPerMTokens: rates?.input,
            outputUSDPerMTokens: rates?.output,
            contextLength: nil,
            price: nil,
            supportsTools: true,
            supportsTemperature: nil,
            supportsVision: nil,
            createdAt: released
        )
    }

    /// A catalog entry with the date and price its tables give it.
    private struct Pinned {
        let entry: AIModelCatalogEntry
        let released: Date?
        let rates: (input: Double, output: Double)?
    }

    private func pinned(
        _ maker: AIModelMaker,
        _ provider: AIProvider,
        _ modelID: String,
        released: Date?,
        rates: (input: Double, output: Double)?
    ) -> Pinned {
        Pinned(entry: AIModelCatalogEntry(maker: maker, provider: provider, modelID: modelID), released: released, rates: rates)
    }

    private func groupCards(_ entries: [Pinned], _ directory: [OpenRouterDirectoryModel]) -> [AIModelCatalog.GroupCard] {
        AIModelCatalog.orderedGroupCards(
            entries: entries.map(\.entry),
            directoryModels: directory,
            entryReleaseDate: { entry in entries.first(where: { $0.entry.id == entry.id })?.released },
            entryRates: { entry in entries.first(where: { $0.entry.id == entry.id })?.rates }
        )
    }

    private func groupOrder(_ entries: [Pinned], _ directory: [OpenRouterDirectoryModel]) -> [String] {
        let cards = groupCards(entries, directory)
        #expect(Set(cards.map(\.id)).count == cards.count, "every card has its own id")
        return cards.map(\.modelID)
    }

    /// The product owner (2026-09-27), of the xAI group in Settings, expanded: "why are
    /// these not sorted right?" It read Grok 4.7, Grok 4.3, then Grok 4.6,
    /// 4.5, Build 0.1, 4.3 (batch) and 4.20: the catalog's two cards, then
    /// the directory's five, each list sorted on its own.
    @Test("An expanded group is one newest-first list, the directory's models among the catalog's")
    func expandedGroupIsOneOrder() {
        let xai = groupOrder(
            [
                pinned(.xai, .xai, "grok-4.7", released: day(50), rates: (2, 6)),
                pinned(.xai, .xai, "grok-4.3", released: day(20), rates: (1.25, 2.5)),
            ],
            [
                listed("x-ai/grok-4.20", "Grok 4.20", released: day(10), rates: (1.25, 2.5)),
                listed("x-ai/grok-4.5", "Grok 4.5", released: day(30), rates: (2, 6)),
                listed("x-ai/grok-4.3:batch", "Grok 4.3 (batch)", released: day(20), rates: (1, 2)),
                listed("x-ai/grok-4.6", "Grok 4.6", released: day(40), rates: (2, 6)),
                listed("x-ai/grok-build-0.1", "Grok Build 0.1", released: day(25), rates: (1, 2)),
            ]
        )
        // Grok 4.3 and its batch variant share a listing day; the dearer leads.
        #expect(xai == [
            "grok-4.7", "x-ai/grok-4.6", "x-ai/grok-4.5", "x-ai/grok-build-0.1",
            "grok-4.3", "x-ai/grok-4.3:batch", "x-ai/grok-4.20",
        ])

        // Every maker, not xAI alone: a directory release newer than the
        // catalog's newest leads the group.
        let google = groupOrder(
            [
                pinned(.google, .gemini, "gemini-3.5-flash", released: day(100), rates: (0.38, 1.88)),
                pinned(.google, .gemini, "gemini-2.5-flash-lite", released: day(0), rates: (0.1, 0.4)),
            ],
            [
                listed("google/gemma-4-31b-it", "Gemma 4 31B", released: day(60), rates: (0.1, 0.3)),
                listed("google/gemini-3.6-pro-preview", "Gemini 3.6 Pro Preview", released: day(120), rates: (2, 12)),
            ]
        )
        #expect(google == [
            "google/gemini-3.6-pro-preview", "gemini-3.5-flash", "google/gemma-4-31b-it", "gemini-2.5-flash-lite",
        ])
    }

    /// The product owner (2026-09-28), of the same group collapsed: "this sorting is
    /// really strange". It read Grok 4.7, Grok 4.3 and "5 more…": only the
    /// catalog's two cards could show, so the directory's newer Grok 4.6
    /// waited behind the toggle.
    @Test("A collapsed group shows the front of the expanded order, and every selection")
    func collapsedGroupIsTheExpandedFront() {
        let catalog = [
            pinned(.xai, .xai, "grok-4.7", released: day(50), rates: (2, 6)),
            pinned(.xai, .xai, "grok-4.3", released: day(20), rates: (1.25, 2.5)),
        ]
        let cards = groupCards(catalog, [
            listed("x-ai/grok-4.20", "Grok 4.20", released: day(10), rates: (1.25, 2.5)),
            listed("x-ai/grok-4.5", "Grok 4.5", released: day(30), rates: (2, 6)),
            listed("x-ai/grok-4.6", "Grok 4.6", released: day(40), rates: (2, 6)),
        ])
        func collapsed(_ cards: [AIModelCatalog.GroupCard], selecting ids: Set<String> = []) -> [String] {
            AIModelCatalog.collapsedGroupCards(cards, limit: 2, isSelected: { ids.contains($0.modelID) })
                .map(\.modelID)
        }

        #expect(collapsed(cards) == ["grok-4.7", "x-ai/grok-4.6"])
        // A selection is never hidden, and keeps its place in the order.
        #expect(collapsed(cards, selecting: ["grok-4.3"]) == ["grok-4.7", "grok-4.3"])
        #expect(collapsed(cards, selecting: ["x-ai/grok-4.20"]) == ["grok-4.7", "x-ai/grok-4.20"])
        // More selections than the limit show them all, and nothing else.
        #expect(
            collapsed(cards, selecting: ["grok-4.3", "x-ai/grok-4.5", "x-ai/grok-4.20"])
                == ["x-ai/grok-4.5", "grok-4.3", "x-ai/grok-4.20"]
        )
        // Until the directory loads, the catalog's cards are the whole order.
        #expect(collapsed(groupCards(catalog, [])) == ["grok-4.7", "grok-4.3"])
    }

    @Test("Ties the rule leaves open put the catalog first, in its own order, then the directory by name")
    func expandedGroupTies() {
        let first = pinned(.other, .openRouter, "acme/first", released: day(5), rates: (1, 1))
        let second = pinned(.other, .openRouter, "acme/second", released: day(5), rates: (1, 1))
        let order = groupOrder(
            [first, second],
            [
                listed("acme/zeta", "Zeta", released: day(5), rates: (1, 1)),
                listed("acme/alpha", "Alpha", released: day(5), rates: (1, 1)),
                listed("acme/undated", "Undated", released: nil, rates: (9, 9)),
                listed("acme/unpriced", "Unpriced", released: nil, rates: nil),
            ]
        )
        #expect(order == ["acme/first", "acme/second", "acme/alpha", "acme/zeta", "acme/undated", "acme/unpriced"])
        // Nothing from the directory: the catalog's order stands as it is.
        #expect(groupOrder([second, first], []) == ["acme/second", "acme/first"])
    }
}

/// The fix for a vision task inheriting a text-only Background model
/// (DeepSeek on OpenRouter, which 404s on the slide image it is handed).
@Suite("Vision Model Resolution")
struct VisionModelResolutionTests {

    @Test("Every image-attaching task requires vision")
    func imageAttachingTasksRequireVision() {
        let expected: Set<AITask> = [
            .slideFrameClassification,
            .slideCitationExtraction,
            .paperFigureUnderstanding,
        ]
        for task in AITask.allCases {
            #expect(task.requiresVision == expected.contains(task),
                    "requiresVision wrong for \(task.rawValue)")
        }
    }

    @Test("A vision task never defaults to OpenRouter's text-only model")
    func openRouterVisionDefaultIsNotTextModel() {
        // The regression guard for the reported bug: with Background on
        // OpenRouter, the shipped default is DeepSeek V4 Flash — text-only.
        let visionDefault = KeychainService.defaultBackgroundMultimodalTaskRoute.model
        #expect(visionDefault != AIModelDefaults.defaultOpenRouter)
        #expect(visionDefault == AIModelDefaults.visionOpenRouter)
        #expect(AIModelDefaults.preferredOpenRouter.contains(visionDefault))
        // The estimator and the vision request builder both key off the
        // `google/gemini` prefix, so the chosen slug has to carry it.
        #expect(visionDefault.hasPrefix("google/gemini"))
    }

    @Test("The closed labs are treated as multimodal")
    func closedLabsSupportVision() {
        // Their currently-offered models all take image input, so the oracle is
        // confident about them without a directory lookup — an arbitrary model
        // string still resolves true.
        for provider in [AIProvider.anthropic, .openai, .gemini, .xai] {
            #expect(
                KeychainService.modelSupportsVision(provider: provider, model: "anything") == true,
                "expected \(provider.rawValue) to report vision support"
            )
        }
    }

    @Test("A retired host's vision support is unknown, not a warning")
    func retiredHostVisionUnknown() {
        // nil, never false: an unknown capability must not trigger the Settings
        // warning, which fires only on a definite "can't see".
        #expect(KeychainService.modelSupportsVision(provider: .groq, model: "gpt-oss-120b") == nil)
    }

    @Test("Muse Spark 1.2 exposes its pinned multimodal capability")
    func museSparkSupportsVision() {
        #expect(KeychainService.modelSupportsVision(
            provider: .openRouter,
            model: "meta/\(AIModelDefaults.latestMuseSpark)"
        ) == true)
    }
}
