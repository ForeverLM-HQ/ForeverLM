import Foundation
import Testing
@testable import ForeverLM

/// Every AI Models pane's Suggested list and "All models on OpenRouter"
/// (`OpenRouterModelBrowser`, and Chat's and Background's
/// `OpenRouterModelTable`): the search, the maker grouping the media panes
/// share, and the lists themselves.
@Suite("Model browser")
struct ModelBrowserTests {
    private struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        var maker = ""
    }

    private static func fields(_ model: Model) -> [String] {
        [model.name, model.id]
    }

    @Test("A search matches every word, across case, accents and punctuation")
    func searchMatchesWords() {
        let astra = ["GPT-6 Astra", "openai/gpt-6-astra", "OpenAI"]
        for query in ["gpt 6", "gpt-6", "GPT6", "astra openai", "  Astra  "] {
            #expect(ModelSearch.matches(terms: ModelSearch.terms(query), fields: astra), "\(query)")
        }
        #expect(!ModelSearch.matches(terms: ModelSearch.terms("gpt 7"), fields: astra))

        // A dotted version is one word, so it finds its model and not every
        // model that has both digits somewhere.
        let flash38 = ["Gemini 3.8 Flash", "google/gemini-3.8-flash"]
        let flashLite31 = ["Gemini 3.1 Flash Lite", "google/gemini-3.1-flash-lite"]
        #expect(ModelSearch.matches(terms: ModelSearch.terms("3.8 flash"), fields: flash38))
        #expect(!ModelSearch.matches(terms: ModelSearch.terms("3.8 flash"), fields: flashLite31))

        #expect(ModelSearch.matches(terms: ModelSearch.terms("eclair"), fields: ["Éclair 2"]))
        #expect(ModelSearch.terms("   ").isEmpty)
        #expect(ModelSearch.matches(terms: [], fields: ["anything"]))
    }

    @Test("A search keeps only the makers with a match, and a maker's name matches its models")
    func searchNarrowsMakers() {
        let anthropic = ChatModelLists.MakerIdentity(name: "Anthropic", logo: .anthropic, vendor: "anthropic")
        let openAI = ChatModelLists.MakerIdentity(name: "OpenAI", logo: .openai, vendor: "openai")
        let makers = [
            ModelBrowserMaker(id: "maker:anthropic", identity: anthropic, models: [
                Model(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5"),
                Model(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5"),
            ]),
            ModelBrowserMaker(id: "maker:openai", identity: openAI, models: [
                Model(id: "openai/gpt-6-luna", name: "GPT-6 Luna"),
            ]),
        ]

        let haiku = ModelSearch.narrowed(makers, to: ModelSearch.terms("haiku"), fields: Self.fields)
        #expect(haiku.map(\.id) == ["maker:anthropic"])
        #expect(haiku.first?.models.map(\.id) == ["anthropic/claude-haiku-4.5"])

        let byMaker = ModelSearch.narrowed(makers, to: ModelSearch.terms("anthropic"), fields: Self.fields)
        #expect(byMaker.first?.models.count == 2)

        #expect(ModelSearch.narrowed(makers, to: ModelSearch.terms("sora"), fields: Self.fields).isEmpty)
        #expect(ModelSearch.narrowed(makers, to: [], fields: Self.fields).map(\.id) == ["maker:anthropic", "maker:openai"])
    }

    @Test("Media makers lead with the chat catalog's makers, then the rest by size, each model in the order given")
    func mediaMakersGroupAndOrder() {
        let models = [
            Model(id: "recraft/recraft-v4.1", name: "Recraft V4.1", maker: "Recraft"),
            Model(id: "black-forest-labs/flux.2-pro", name: "FLUX.2 Pro", maker: "Black Forest Labs"),
            Model(id: "x-ai/grok-imagine-image-2.0", name: "Grok Imagine Image 2.0", maker: "SpaceXAI"),
            Model(id: "recraft/recraft-v3", name: "Recraft V3", maker: "Recraft"),
            Model(id: "openai/gpt-image-2", name: "GPT Image 2", maker: "OpenAI"),
            Model(id: "meta/muse-image", name: "Muse Image", maker: "Meta"),
            Model(id: "meta-llama/llama-image", name: "Llama Image", maker: "Meta Llama"),
        ]
        let makers = MediaModelLists.makers(models, slug: \.id, makerName: \.maker)

        #expect(makers.map(\.identity.name) == ["OpenAI", "xAI", "Meta", "Recraft", "Black Forest Labs"])
        // Meta's two vendor slugs are one maker.
        #expect(makers.first { $0.identity.name == "Meta" }?.models.count == 2)
        #expect(makers.first { $0.identity.name == "Recraft" }?.models.map(\.id) == ["recraft/recraft-v4.1", "recraft/recraft-v3"])
        // A maker the chat does not know draws openrouter.ai's logo.
        #expect(makers.last?.identity.logo == nil)
        #expect(makers.last?.identity.vendor == "black-forest-labs")

        #expect(MediaModelLists.identity(ofSlug: "recraft/recraft-v4.1-flash", in: makers).name == "Recraft")
    }

    @Test("Suggestions keep the list's order and drop what the directory no longer lists")
    func mediaSuggestions() {
        let models = [
            Model(id: "google/veo-3.1-fast", name: "Veo 3.1 Fast"),
            Model(id: "openai/sora-2-pro", name: "Sora 2 Pro"),
            Model(id: "runway/gen-4.5", name: "Gen-4.5"),
        ]
        let suggested = MediaModelLists.suggestions(
            ["openai/sora-2-pro", "gone/model", "Google/Veo-3.1-Fast"], in: models, slug: \.id,
            listedAt: { _ in nil })
        #expect(suggested.map(\.id) == ["openai/sora-2-pro", "google/veo-3.1-fast"])

        // A newer release of a suggested family stands in for it.
        let released = models + [Model(id: "google/veo-3.2-fast", name: "Veo 3.2 Fast")]
        let dated = ["google/veo-3.1-fast": 1.0, "google/veo-3.2-fast": 2.0, "openai/sora-2-pro": 1.0]
        #expect(MediaModelLists.suggestions(
            ["openai/sora-2-pro", "google/veo-3.1-fast"], in: released, slug: \.id,
            listedAt: { dated[$0.id].map(Date.init(timeIntervalSince1970:)) }
        ).map(\.id) == ["openai/sora-2-pro", "google/veo-3.2-fast"])

        // The model the pane opened on is pinned above only when Suggested
        // does not show it, and only when the directory still lists it.
        #expect(MediaModelLists.pinned(openedOn: "google/veo-3.1-fast", in: models, suggested: suggested, slug: \.id) == nil)
        #expect(MediaModelLists.pinned(openedOn: "runway/gen-4.5", in: models, suggested: suggested, slug: \.id)?.id == "runway/gen-4.5")
        #expect(MediaModelLists.pinned(openedOn: "gone/model", in: models, suggested: suggested, slug: \.id) == nil)
        #expect(MediaModelLists.pinned(openedOn: nil, in: models, suggested: suggested, slug: \.id) == nil)
    }

    @Test("A media browser narrows to free or discounted models, and counts each")
    func mediaFilters() {
        let models = [
            Model(id: "deepgram/flux-tts:free", name: "Flux TTS"),
            Model(id: "assemblyai/universal-3-5-pro", name: "Universal 3.5 Pro"),
            Model(id: "openai/gpt-image-2", name: "GPT Image 2"),
            Model(id: "alibaba/wan-3.0", name: "Wan 3.0"),
        ]
        let free: Set<String> = ["deepgram/flux-tts:free"]
        let discounted: Set<String> = ["assemblyai/universal-3-5-pro", "alibaba/wan-3.0"]
        func isFree(_ model: Model) -> Bool { free.contains(model.id) }
        func isDiscounted(_ model: Model) -> Bool { discounted.contains(model.id) }
        func narrowed(_ filters: Set<ModelBrowserFilter>) -> [String] {
            MediaModelLists.filtered(models, by: filters, isFree: isFree, isDiscounted: isDiscounted).map(\.id)
        }

        #expect(narrowed([]) == models.map(\.id))
        #expect(narrowed([.free]) == ["deepgram/flux-tts:free"])
        #expect(narrowed([.discounted]) == ["assemblyai/universal-3-5-pro", "alibaba/wan-3.0"])
        // Both on list either kind, in the order given.
        #expect(narrowed([.free, .discounted]) == [
            "deepgram/flux-tts:free", "assemblyai/universal-3-5-pro", "alibaba/wan-3.0"
        ])
        #expect(MediaModelLists.filterCounts(models, isFree: isFree, isDiscounted: isDiscounted)
                == [.free: 1, .discounted: 2])
        #expect(ModelBrowserFilter.subject("image models", filters: []) == "image models")
        #expect(ModelBrowserFilter.subject("image models", filters: [.discounted, .free])
                == "free or discounted image models")
    }

    @Test("A media promotion is shown at the price OpenRouter's catalog quotes")
    func mediaPromotionPrices() {
        // Wan 3.0 on 2026-09-29: the video directory's $0.10 a second is the
        // provider's price; OpenRouter's catalog shows $0.085, 15% off.
        let wan = RouterModelPromotion(discount: 0.15)
        #expect(wan?.label == "15% off")
        #expect(wan?.discountBasisPoints == 1_500)
        #expect(wan.map { VideoGenerationCatalog.rateLabel($0.effectiveRate(fromList: 0.1)) } == "$0.085")
        // No badge outside the (0, 100)% range, or for a cut that rounds to 0%.
        #expect(RouterModelPromotion(discount: 0) == nil)
        #expect(RouterModelPromotion(discount: 1) == nil)
        #expect(RouterModelPromotion(discount: -0.1) == nil)
        #expect(RouterModelPromotion(discount: 0.004) == nil)

        let picture = ImageGenerationPrice.perImage(0.04)
        #expect(picture.amountLabel == "$0.04")
        #expect(picture.mapped { $0 / 2 }.label == "$0.02 a picture")
        #expect(ImageGenerationPrice.perMillionTokens(8).amountLabel == "$8")

        func video(_ rates: [VideoGenerationCatalog.Resolution: Double], byTokens: Bool = false) -> VideoGenerationModel {
            VideoGenerationModel(
                id: "acme/film", name: "Film", maker: "Acme", detail: "", createdAt: nil,
                durations: [8], resolutions: [.hd], aspectRatios: [], makesSound: true,
                usdPerSecond: rates, pricedByTokens: byTokens)
        }
        #expect(video([.hd: 0]).isFree)
        #expect(!video([.hd: 0, .fullHD: 0.1]).isFree)
        // No published rate, or one only a finished clip reveals, is not free.
        #expect(!video([:]).isFree)
        #expect(!video([.hd: 0], byTokens: true).isFree)
    }

    @Test("Every Suggested list names one model per maker")
    func suggestedListsOnePerMaker() {
        let lists: [String: [String]] = [
            "chat": AIModelDefaults.suggestedChatModels,
            "background": AIModelDefaults.suggestedBackgroundModels,
            "background images": AIModelDefaults.suggestedBackgroundImageModels,
            "images": ImageGenerationCatalog.suggestedModelIDs,
            "videos": VideoGenerationCatalog.suggestedModelIDs,
            "speech": ArticleSpeechCatalog.suggestedModelIDs,
            "transcription": TranscriptionModelCatalog.suggestedModelIDs,
        ]
        for (name, slugs) in lists {
            #expect(!slugs.isEmpty, "\(name)")
            let vendors = slugs.map(ChatModelLists.vendor(ofSlug:))
            #expect(Set(vendors).count == vendors.count, "\(name): \(vendors)")
            #expect(slugs.allSatisfy { $0.contains("/") && $0 == $0.lowercased() }, "\(name)")
        }
        #expect(AIModelDefaults.suggestedBackgroundModels.contains(AIModelDefaults.defaultOpenRouter))
    }

    @Test("The table's Price column sorts the cheapest first, unpriced last, ties as given")
    func costSortCheapestFirst() {
        let prices: [String: Double?] = ["a/a": 5, "b/b": nil, "c/c": 1, "d/d": 5, "e/e": 0]
        let rows = ["a/a", "b/b", "c/c", "d/d", "e/e"].map { slug in
            let price = prices[slug] ?? nil
            return ModelTableRow(
                OpenRouterDirectoryModel(
                    id: slug, name: slug,
                    inputUSDPerMTokens: price, outputUSDPerMTokens: price, contextLength: nil, price: nil,
                    supportsTools: true, supportsTemperature: nil, supportsVision: nil
                ),
                in: .empty
            )
        }
        let sorted = rows.sorted(using: [KeyPathComparator(\ModelTableRow.cost)])
        #expect(sorted.map(\.id) == ["e/e", "c/c", "a/a", "d/d", "b/b"])
        #expect(rows.allSatisfy { !$0.isCatalogued })

        #expect(ModelCostOrder.blended(input: 2, output: 6) == 3)
        #expect(ModelCostOrder.blended(input: nil, output: 6) == nil)
    }

    private static func directoryModel(
        _ id: String,
        input: Double? = 1,
        output: Double? = 2,
        context: Int? = nil,
        vision: Bool? = nil,
        weights: String? = nil,
        listed: Date? = nil
    ) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id, name: id,
            inputUSDPerMTokens: input, outputUSDPerMTokens: output, contextLength: context, price: nil,
            supportsTools: true, supportsTemperature: nil, supportsVision: vision,
            createdAt: listed,
            huggingFaceID: weights
        )
    }

    @Test("The Model column's features read what the directory lists, and an unknown is not a yes")
    func tableFeatures() {
        let open = Self.directoryModel("x/open", context: 1_000_000, vision: true, weights: "x/Open")
        let closed = Self.directoryModel("x/closed", context: 262_000)
        #expect(ModelTableFeature.readsImages.matches(open))
        #expect(!ModelTableFeature.readsImages.matches(closed))
        #expect(ModelTableFeature.openWeights.matches(open))
        #expect(!ModelTableFeature.openWeights.matches(closed))
        #expect(!ModelTableFeature.reasoning.matches(closed))
    }

    @Test("Each column filters on its own value, and every filter must pass")
    func tableColumnFilters() {
        let free = ModelTableRow(Self.directoryModel("a/free", input: 0, output: 0, context: 128_000, vision: true), in: .empty)
        let cheap = ModelTableRow(Self.directoryModel("b/cheap", input: 0.2, output: 0.8, context: 1_000_000), in: .empty)
        let dear = ModelTableRow(Self.directoryModel("c/dear", input: 15, output: 75, context: 200_000), in: .empty)
        let unpriced = ModelTableRow(Self.directoryModel("d/unpriced", input: nil, output: nil), in: .empty)
        func admitted(_ filters: ModelTableFilters, speed: Double? = nil, chosen: Bool = false) -> [String] {
            [free, cheap, dear, unpriced]
                .filter { filters.admits($0, isNew: $0.id == "b/cheap", speed: speed, hasChosenProvider: chosen) }
                .map(\.id)
        }

        #expect(ModelTableFilters().isEmpty)
        #expect(admitted(ModelTableFilters()) == ["a/free", "b/cheap", "c/dear", "d/unpriced"])

        // Price bands go by the blended figure the column sorts on.
        #expect(ModelTablePriceBand.of(free.model) == .free)
        #expect(ModelTablePriceBand.of(cheap.model) == .underOne)
        #expect(ModelTablePriceBand.of(dear.model) == .twentyAndUp)
        #expect(ModelTablePriceBand.of(unpriced.model) == .unlisted)
        #expect(admitted(ModelTableFilters(prices: [.free, .twentyAndUp])) == ["a/free", "c/dear"])

        // A context floor keeps windows at or over it; an unpublished one is none.
        #expect(admitted(ModelTableFilters(minimumContext: 200_000)) == ["b/cheap", "c/dear"])

        // Every column's filter must pass.
        var both = ModelTableFilters(features: [.readsImages])
        both.minimumContext = 256_000
        #expect(both.isActive(.model) && both.isActive(.context) && !both.isActive(.price))
        #expect(admitted(both).isEmpty)
        both.clear(.context)
        #expect(admitted(both) == ["a/free"])

        #expect(admitted(ModelTableFilters(onlyNew: true)) == ["b/cheap"])

        // No speed read passes no Speed filter.
        let fast = ModelTableFilters(minimumSpeed: 50)
        #expect(admitted(fast).isEmpty)
        #expect(admitted(fast, speed: 49.6).isEmpty)
        #expect(admitted(fast, speed: 50).count == 4)

        #expect(admitted(ModelTableFilters(provider: .chosen)).isEmpty)
        #expect(admitted(ModelTableFilters(provider: .automatic)).count == 4)
        #expect(admitted(ModelTableFilters(provider: .chosen), chosen: true).count == 4)
    }

    @Test("A header sorts either way, unpriced last going up, ties as given")
    func tableSort() {
        let rows = [
            ModelTableRow(Self.directoryModel("a/a", input: 5, output: 5), in: .empty),
            ModelTableRow(Self.directoryModel("b/b", input: nil, output: nil), in: .empty),
            ModelTableRow(Self.directoryModel("c/c", input: 1, output: 1), in: .empty),
            ModelTableRow(Self.directoryModel("d/d", input: 5, output: 5), in: .empty),
        ]
        #expect(ModelTableSort.sorted(rows, by: .price, ascending: true).map(\.id) == ["c/c", "a/a", "d/d", "b/b"])
        #expect(ModelTableSort.sorted(rows, by: .price, ascending: false).map(\.id).first == "b/b")
        #expect(ModelTableSort.sorted(rows, by: .model, ascending: false).map(\.id) == ["d/d", "c/c", "b/b", "a/a"])
        // A column that does not sort keeps the pane's order.
        #expect(ModelTableSort.sorted(rows, by: .speed, ascending: true).map(\.id) == rows.map(\.id))
    }

    @Test("A Refresh names what OpenRouter lists that the read before did not, and New covers a week")
    func directoryRefresh() {
        let before = [Self.directoryModel("a/one"), Self.directoryModel("b/two")]
        let after = before + [Self.directoryModel("C/Three")]
        let refresh = ModelDirectoryRefresh(before: before, after: after)
        #expect(refresh.newIDs == ["C/Three"])
        #expect(ModelDirectoryRefresh(before: after, after: before).newIDs.isEmpty)

        #expect(ModelDirectoryRefresh.summary([]) == "No new models on OpenRouter.")
        #expect(ModelDirectoryRefresh.summary(["Zeta 2"]) == "New on OpenRouter: Zeta 2.")
        #expect(ModelDirectoryRefresh.summary(["A", "B", "C", "D"]) == "4 new models on OpenRouter.")

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = ModelTableRow(Self.directoryModel("x/recent", listed: now.addingTimeInterval(-6 * 86_400)), in: .empty)
        let old = ModelTableRow(Self.directoryModel("x/old", listed: now.addingTimeInterval(-8 * 86_400)), in: .empty)
        let undated = ModelTableRow(Self.directoryModel("x/undated"), in: .empty)
        #expect(recent.isListedRecently(asOf: now))
        #expect(!old.isListedRecently(asOf: now))
        #expect(!undated.isListedRecently(asOf: now))
    }

    @Test("A model row's marks are one grey line, in a fixed order, and none at all says nothing")
    func modelRowMarks() {
        #expect(ChatModelRow.marks(isDefault: false, isRecommended: false, promotion: nil, backupRank: nil) == nil)
        #expect(ChatModelRow.marks(isDefault: false, isRecommended: false, promotion: "", backupRank: nil) == nil)
        #expect(ChatModelRow.marks(isDefault: true, isRecommended: false, promotion: nil, backupRank: nil) == "Default")
        #expect(
            ChatModelRow.marks(isDefault: false, isRecommended: true, promotion: "50% off", backupRank: 2)
                == "Recommended · 50% off · Backup 2"
        )
    }

    // MARK: Your Models (product owner, 2026-11-07)

    @Test("Your Models: adding appends once, removing and moving keep the rest in order")
    func yourModelsEdits() {
        let list = ["a/one", "b/two", "c/three"]
        #expect(ChatModelShortlist.normalized([" A/One ", "a/one", "", "b/two"]) == ["a/one", "b/two"])
        #expect(ChatModelShortlist.adding(["d/four", "B/Two"], to: list) == ["a/one", "b/two", "c/three", "d/four"])
        #expect(ChatModelShortlist.removing("B/TWO", from: list) == ["a/one", "c/three"])
        #expect(ChatModelShortlist.moving("c/three", by: -1, in: list) == ["a/one", "c/three", "b/two"])
        #expect(ChatModelShortlist.moving("a/one", by: -1, in: list) == list)
        #expect(ChatModelShortlist.moving("c/three", by: 5, in: list) == list)
        #expect(ChatModelShortlist.moving("x/absent", by: 1, in: list) == list)
    }

    @Test("Your Models: a dragged row takes the place of the row it is dropped on, from either side")
    func yourModelsDrag() {
        let list = ["a/one", "b/two", "c/three", "d/four"]
        #expect(ChatModelShortlist.moving("a/one", onto: "c/three", in: list) == ["b/two", "c/three", "a/one", "d/four"])
        #expect(ChatModelShortlist.moving("d/four", onto: "b/two", in: list) == ["a/one", "d/four", "b/two", "c/three"])
        #expect(ChatModelShortlist.moving("x/new", onto: "b/two", in: list) == ["a/one", "x/new", "b/two", "c/three", "d/four"])
        #expect(ChatModelShortlist.moving("a/one", onto: "x/absent", in: list) == ["b/two", "c/three", "d/four", "a/one"])
    }

    @Test("A kept list replaces Suggested and Free as it stands: its order, no newer release swapped in")
    func pinnedListReplacesSuggestions() {
        let directory = [
            Self.directoryModel("x/old", listed: Date(timeIntervalSince1970: 1)),
            Self.directoryModel("x/new", listed: Date(timeIntervalSince1970: 2)),
            Self.directoryModel("y/free:free", input: 0, output: 0),
            Self.directoryModel("z/other"),
        ]
        let pinned = ChatModelLists.build(
            suggested: ["x/old"], free: ["y/free:free"], pinned: ["Z/Other", "x/old", "z/other", "w/unlisted"],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true })
        #expect(pinned.suggestions.map(\.slug) == ["z/other", "x/old"])
        #expect(pinned.free.isEmpty)

        let fresh = ChatModelLists.build(
            suggested: ["x/old"], free: ["y/free:free"],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true })
        #expect(fresh.free.map(\.slug) == ["y/free:free"])

        let emptied = ChatModelLists.build(
            suggested: ["x/old"], free: ["y/free:free"], pinned: [],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true })
        #expect(emptied.suggestions.isEmpty && emptied.free.isEmpty)
    }

    @Test("Background keeps one Your Models for text work and one for work that reads images, apart from Chat's")
    func backgroundYourModelsKeys() {
        let keys = [
            ChatModelShortlist.preferenceKey,
            ChatModelShortlist.backgroundKey(readsImages: false),
            ChatModelShortlist.backgroundKey(readsImages: true),
        ]
        #expect(Set(keys).count == 3)
        #expect(keys.allSatisfy { SyncedPreferenceKeys.isSynced($0) })
    }
}
