import Foundation
import CryptoKit
import os

private let aiResponseCacheLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "AIResponseCache"
)

/// Advisory metadata explaining a router's already-effective catalog price.
/// Billing never derives a price from this label or percentage.
struct RouterModelPromotion: Sendable, Equatable {
    let label: String
    let discountBasisPoints: Int
    let endsAt: Date?
}

extension RouterModelPromotion {
    /// The promotion a catalog endpoint's `pricing.discount` (0.15 for 15%
    /// off) describes; nil outside the (0, 100)% range, or for a cut that
    /// rounds to 0% and so has no badge worth showing. Whole percents only on
    /// the badge: "88.70% off" beside a price is noise, and the exact cut
    /// still travels in `discountBasisPoints` for the struck-through list
    /// price.
    init?(discount: Double) {
        guard discount.isFinite, discount > 0, discount < 1 else { return nil }
        self.init(discountBasisPoints: Int((discount * 10_000).rounded()))
    }

    init?(discountBasisPoints basisPoints: Int) {
        guard basisPoints > 0, basisPoints < 10_000 else { return nil }
        let wholePercent = Int((Double(basisPoints) / 100).rounded())
        guard wholePercent > 0 else { return nil }
        self.init(label: "\(wholePercent)% off", discountBasisPoints: basisPoints, endsAt: nil)
    }

    /// The per-1M rate the router would bill without this promotion, recovered
    /// from the effective rate it quotes with the promotion applied. Display
    /// only: billing never reconstructs a price from a percentage.
    func listRate(fromEffective rate: Double) -> Double {
        rate / (1 - Double(discountBasisPoints) / 10_000)
    }

    /// The rate the router bills under this promotion, from a list rate that
    /// does not include it. The image and video directories quote the
    /// provider's own price, the catalog's `pricing_json`; OpenRouter's catalog
    /// shows that price less the discount (`display_pricing`: Wan 3.0 at $0.10
    /// a second listed, $0.085 shown at 15% off, 2026-09-29). Display only.
    func effectiveRate(fromList rate: Double) -> Double {
        rate * (1 - Double(discountBasisPoints) / 10_000)
    }

    /// "$1.2/$4.8" — the list pair behind an already-discounted effective pair,
    /// for Settings to strike through ahead of the price actually billed, so a
    /// "50% off" badge never leaves the reader guessing whether the figure
    /// beside it is before or after the cut. Nil when there is nothing to
    /// strike: no discount in the (0, 100)% range, or a list pair that rounds
    /// to the same label as the effective one — striking "$0.01" beside
    /// "$0.01" says nothing.
    func listPriceLabel(effectiveInput input: Double, effectiveOutput output: Double) -> String? {
        guard discountBasisPoints > 0, discountBasisPoints < 10_000 else { return nil }
        let list = AIModelListPrice.pairLabel(
            input: listRate(fromEffective: input), output: listRate(fromEffective: output))
        let effective = AIModelListPrice.pairLabel(input: input, output: output)
        return list == effective ? nil : list
    }
}

/// Every promotion OpenRouter's catalog listed at its last read, for every
/// kind of model: text, image, video, speech, transcription. The text
/// directory hands its own rows theirs (`OpenRouterDirectoryModel.promotion`);
/// Settings › Images and › Videos read theirs here, since the image and video
/// directories carry no discount. Filled by the read Settings › Chat makes too
/// (`OpenRouterCatalogAvailability`), so a pane that needs it awaits that.
enum OpenRouterPromotions {
    private static let latest = OSAllocatedUnfairLock<[String: RouterModelPromotion]>(initialState: [:])

    /// Lowercased slug → promotion; empty until a catalog read.
    static var current: [String: RouterModelPromotion] { latest.withLock { $0 } }

    static func record(_ table: [String: RouterModelPromotion]) {
        latest.withLock { $0 = table }
    }
}

/// One row of OpenRouter's public model directory (openrouter.ai/api/v1/models),
/// as consumed by the Settings model browser.
struct OpenRouterDirectoryModel: Identifiable, Sendable, Equatable {
    /// OpenRouter slug, e.g. "mistralai/mistral-large".
    let id: String
    /// Human name without the "Author: " prefix.
    let name: String
    /// That prefix: the maker as OpenRouter names it ("Z.ai", "Black Forest
    /// Labs"). Nil for a row whose name carries none.
    var makerName: String? = nil
    let inputUSDPerMTokens: Double?
    let outputUSDPerMTokens: Double?
    let contextLength: Int?
    /// Full per-1M list prices (cache, web search, long-context tier) feeding
    /// the remote price overlay; nil when the row carries no pricing object.
    let price: AIProviderPricing.RemoteModelPrice?
    /// Whether the row lists "tools" in `supported_parameters`. The chat agent
    /// sends the whole MCP tool catalog on every turn, so a model that can't
    /// accept tool definitions is not offerable — roughly a fifth of the
    /// directory (74 of 344 rows on 2026-07-18) falls in that bucket.
    let supportsTools: Bool
    /// Whether the directory explicitly lists `temperature`. Nil means the
    /// capability was absent from an older or incomplete directory response.
    let supportsTemperature: Bool?
    /// Whether the row lists `image` in `architecture.input_modalities`. The
    /// slide reader hands the model an image, so a text-only model can't do it;
    /// this flag lets the vision tasks default correctly and lets Settings warn.
    /// `nil` when the row declared no input modalities — unknown, not "no".
    let supportsVision: Bool?
    /// OpenRouter's selected endpoint promotion. The prices above already
    /// include it; this exists only to surface the discount in Settings.
    var promotion: RouterModelPromotion? = nil
    /// The directory's `created` stamp — when OpenRouter first listed the
    /// model. The catalog's newest-first order is built on it; nil when the
    /// row carried none, which sorts after every dated row.
    var createdAt: Date? = nil
    /// OpenRouter's dated identity for the slug ("anthropic/claude-sonnet-5-20260630"),
    /// the key its speed statistics are filed under. Nil when the row had none.
    var canonicalSlug: String? = nil
    /// The effort levels OpenRouter's catalog says the model takes, and the
    /// one it runs at when none is sent. Nil when the catalog was unreachable
    /// or the model has no effort control.
    var reasoningEfforts: OpenRouterReasoningEfforts? = nil
    /// The Hugging Face repository OpenRouter links for the model's weights
    /// ("zai-org/GLM-5.3-Flash"): set for an open-weight model, nil for one
    /// whose weights are not published.
    var huggingFaceID: String? = nil

    /// Whether the row charges nothing for input or output. The `:free`
    /// suffix is only a name; this is the price the row lists today.
    var isZeroPriced: Bool {
        inputUSDPerMTokens == 0 && outputUSDPerMTokens == 0
    }
}

/// One event-driven OpenRouter directory snapshot shared by Settings and the
/// price refresher. This coalesces the model and promotion metadata fetches so
/// opening Settings cannot issue duplicate catalog requests.
actor OpenRouterCatalogAvailability {
    static let shared = OpenRouterCatalogAvailability()

    private var cachedModels: [OpenRouterDirectoryModel]?
    private var cachedAt: Date?
    private var inFlight: Task<[OpenRouterDirectoryModel], Error>?
    private let freshnessInterval: TimeInterval = 5 * 60

    func models(forceRefresh: Bool = false) async throws -> [OpenRouterDirectoryModel] {
        if !forceRefresh,
           let cachedModels,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < freshnessInterval {
            return cachedModels
        }
        if let inFlight { return try await inFlight.value }

        let task = Task<[OpenRouterDirectoryModel], Error> {
            try await AIService().listOpenRouterModelDirectory()
        }
        inFlight = task
        do {
            let models = try await task.value
            cachedModels = models
            cachedAt = Date()
            inFlight = nil
            AIModelPriceRefresher.ingest(models)
            return models
        } catch {
            inFlight = nil
            throw error
        }
    }
}

/// One provider endpoint OpenRouter lists for a model, as
/// `/api/v1/models/{slug}/endpoints` describes it. A lab's service tiers are
/// separate endpoints with tier-suffixed tags — `openai/fast` beside `openai`,
/// `anthropic/fast` beside `anthropic` — each with its own published price.
/// That is what gives a speed an exact price on the OpenRouter rail: the
/// request names the tag in `provider.order`, OpenRouter bills that endpoint,
/// and the Worker reads the charge back from the generation record.
struct OpenRouterEndpointTier: Sendable, Equatable {
    /// OpenRouter's endpoint slug, e.g. "openai/fast" or "azure/eu".
    let tag: String
    let providerName: String
    /// USD per 1M tokens, promotion already applied by OpenRouter.
    let inputUSDPerMTokens: Double
    let outputUSDPerMTokens: Double
    let cachedInputUSDPerMTokens: Double?
    /// OpenRouter's promotion on this endpoint (0.5 = half price). Nil when the
    /// row carries none or a zero.
    let discount: Double?
    /// The request parameters this endpoint honours (`supported_parameters`).
    /// Nil when the row did not say, which never counts as support.
    var supportedParameters: Set<String>? = nil
    /// The weights' precision as the host reports it ("fp8", "fp4"); nil or
    /// "unknown" when it does not say.
    var quantization: String? = nil
    var contextLength: Int? = nil
    /// Percent of requests answered over the last 30 minutes; nil when
    /// OpenRouter has too little traffic to say.
    var uptimePercent: Double? = nil

    /// Whether a repeated prompt prefix is billed below the prompt rate here.
    /// OpenRouter's sticky routing only engages on such an endpoint, so this is
    /// the property that decides whether a conversation's cache can ever be hit.
    /// `supports_implicit_caching` is not used: it reads false for OpenAI's own
    /// endpoint, which caches every prompt over 1,024 tokens.
    var cachesPrompts: Bool {
        guard let cachedInputUSDPerMTokens else { return false }
        return cachedInputUSDPerMTokens < inputUSDPerMTokens
    }
}

enum OpenRouterSpeedTier {
    /// The suffix OpenRouter puts on a lab's fast-processing endpoint tag.
    static let fastSuffix = "/fast"
    /// The suffix on a lab's flex (lower-priority, cheaper) endpoint tag.
    static let flexSuffix = "/flex"

    /// The vendor segment of a slug ("openai" for "openai/gpt-5.6-sol"). A
    /// service-tier tag belongs to the lab that trained the model, so only a
    /// tag under this vendor counts as the model's own fast tier — a
    /// reseller's "turbo" endpoint is a different product.
    static func vendor(ofSlug slug: String) -> String? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slash = trimmed.firstIndex(of: "/"), slash > trimmed.startIndex else { return nil }
        return String(trimmed[..<slash])
    }

    /// The lab's fast endpoint for this slug, or nil when OpenRouter lists none.
    static func fastTier(for slug: String, in tiers: [OpenRouterEndpointTier]) -> OpenRouterEndpointTier? {
        guard let vendor = vendor(ofSlug: slug) else { return nil }
        return tiers.first { $0.tag.lowercased() == vendor + fastSuffix }
    }

    /// The lab's flex endpoint for this slug, or nil when OpenRouter lists none.
    static func flexTier(for slug: String, in tiers: [OpenRouterEndpointTier]) -> OpenRouterEndpointTier? {
        guard let vendor = vendor(ofSlug: slug) else { return nil }
        return tiers.first { $0.tag.lowercased() == vendor + flexSuffix }
    }

    /// The lab's standard endpoint for this slug — the row whose tag is the
    /// bare vendor — so the Speed menu can quote every tier from one source.
    static func standardTier(for slug: String, in tiers: [OpenRouterEndpointTier]) -> OpenRouterEndpointTier? {
        guard let vendor = vendor(ofSlug: slug) else { return nil }
        return tiers.first { $0.tag.lowercased() == vendor }
    }

    /// Whether a tag is a lab's service-tier endpoint, which OpenRouter never
    /// routes a standard request to.
    static func isServiceTier(_ tag: String) -> Bool {
        let lowered = tag.lowercased()
        return [fastSuffix, flexSuffix, "/priority"].contains { lowered.hasSuffix($0) }
    }

    /// The standard endpoints a request should be confined to so that its
    /// prompt cache can be hit: every one that bills cached reads below the
    /// prompt rate and honours each of `requiredParameters`. Nil when there is
    /// nothing to confine — every endpoint already caches, none does, or one
    /// of them does not list its parameters — because an `only` list that
    /// matches no endpoint fails the send outright.
    static func promptCachingEndpointTags(
        in tiers: [OpenRouterEndpointTier],
        requiredParameters: Set<String>
    ) -> [String]? {
        let standard = tiers.filter { !isServiceTier($0.tag) }
        let caching = standard.filter(\.cachesPrompts)
        guard !caching.isEmpty, caching.count < standard.count else { return nil }
        var tags: [String] = []
        for endpoint in caching {
            guard let supported = endpoint.supportedParameters else { return nil }
            guard requiredParameters.isSubset(of: supported) else { continue }
            let tag = endpoint.tag.lowercased()
            if !tags.contains(tag) { tags.append(tag) }
        }
        return tags.isEmpty ? nil : tags
    }

    /// The endpoint row a speed maps to for this slug: the one the request
    /// names in `provider.order` and the one the menu prices it from.
    static func tier(for speed: AISpeed, slug: String, in tiers: [OpenRouterEndpointTier]) -> OpenRouterEndpointTier? {
        switch speed {
        case .flex: return flexTier(for: slug, in: tiers)
        case .standard: return standardTier(for: slug, in: tiers)
        case .fast: return fastTier(for: slug, in: tiers)
        }
    }

    /// "50% off" for a 0.5 discount; nil for none. Whole percents only —
    /// OpenRouter's promotions are round numbers, and a fraction of a percent
    /// would read as noise in a menu subtitle.
    static func promotionLabel(discount: Double?) -> String? {
        guard let discount, discount > 0, discount < 1 else { return nil }
        return "\(Int((discount * 100).rounded()))% off"
    }

    /// The tier's promotion as the composer menu carries one: the label above
    /// with the fraction kept as basis points, so the menu line can put the
    /// price before the cut beside the price after it. Nil for no discount.
    static func promotion(discount: Double?) -> RouterModelPromotion? {
        guard let label = promotionLabel(discount: discount), let discount else { return nil }
        return RouterModelPromotion(
            label: label,
            discountBasisPoints: Int((discount * 10_000).rounded()),
            endsAt: nil
        )
    }

    /// Parse OpenRouter's endpoints response. Rows missing a tag or a price are
    /// dropped rather than guessed. A negative `status` is kept: it is
    /// OpenRouter's derank marker, which only moves the endpoint down the
    /// default routing order, and a request that names the tag in
    /// `provider.order` is still served by it. Flex in particular sits at
    /// -2 for GPT-5.6 Sol while its price is exact and it answers — it is a
    /// low-priority queue, so latency-based deranking is its normal state.
    /// Dropping it hid the whole Flex option from the Speed menu.
    static func parseEndpoints(_ data: Data) -> [OpenRouterEndpointTier] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let rows = payload["endpoints"] as? [[String: Any]]
        else { return [] }
        func usdPerMTokens(_ value: Any?) -> Double? {
            let perToken: Double?
            if let string = value as? String { perToken = Double(string) }
            else if let number = value as? NSNumber { perToken = number.doubleValue }
            else { perToken = nil }
            guard let perToken, perToken.isFinite, perToken >= 0 else { return nil }
            // OpenRouter quotes per token in decimal strings; the binary
            // product ("0.0000004" × 1e6) is 0.3999…, so settle to a
            // millionth of a dollar per 1M tokens, far below any list price.
            return (perToken * 1_000_000 * 1_000_000).rounded() / 1_000_000
        }
        return rows.compactMap { row in
            guard let tag = row["tag"] as? String, !tag.isEmpty,
                  let pricing = row["pricing"] as? [String: Any],
                  let input = usdPerMTokens(pricing["prompt"]),
                  let output = usdPerMTokens(pricing["completion"])
            else { return nil }
            let discount = (pricing["discount"] as? NSNumber)?.doubleValue
            return OpenRouterEndpointTier(
                tag: tag,
                providerName: row["provider_name"] as? String ?? tag,
                inputUSDPerMTokens: input,
                outputUSDPerMTokens: output,
                cachedInputUSDPerMTokens: usdPerMTokens(pricing["input_cache_read"]),
                discount: (discount ?? 0) > 0 ? discount : nil,
                supportedParameters: (row["supported_parameters"] as? [String]).map(Set.init),
                quantization: (row["quantization"] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 },
                contextLength: (row["context_length"] as? NSNumber)?.intValue,
                uptimePercent: (row["uptime_last_30m"] as? NSNumber)?.doubleValue
            )
        }
    }
}

/// Per-model endpoint lists from OpenRouter, fetched on demand and kept for a
/// few minutes. The synchronous cache is what `AIRequestOptionSupport` reads:
/// the speed control appears only once this has seen a fast endpoint for the
/// model, and a stored Fast pick is honoured on the wire only after the
/// dispatch path has primed the same cache. Memory only, on purpose — a
/// persisted table would let a unit-test host inherit this machine's answers.
actor OpenRouterEndpointTierCatalog {
    static let shared = OpenRouterEndpointTierCatalog()

    private struct Entry {
        let tiers: [OpenRouterEndpointTier]
        let fetchedAt: Date
    }

    nonisolated(unsafe) private static var entriesBySlug: [String: Entry] = [:]
    private static let entriesLock = NSLock()
    private static let freshnessInterval: TimeInterval = 5 * 60

    private var inFlight: [String: Task<[OpenRouterEndpointTier], Error>] = [:]

    /// The lab's fast endpoint for a slug, from what has already been fetched.
    nonisolated static func cachedFastTier(slug: String) -> OpenRouterEndpointTier? {
        cachedTier(slug: slug, speed: .fast)
    }

    /// The endpoint a speed maps to for a slug, from what has already been
    /// fetched; nil for a cold cache as much as for a tier OpenRouter lacks.
    nonisolated static func cachedTier(slug: String, speed: AISpeed) -> OpenRouterEndpointTier? {
        cachedTiers(slug: slug).flatMap { OpenRouterSpeedTier.tier(for: speed, slug: slug, in: $0) }
    }

    nonisolated static func cachedTiers(slug: String) -> [OpenRouterEndpointTier]? {
        entriesLock.lock()
        defer { entriesLock.unlock() }
        return entriesBySlug[slug.lowercased()]?.tiers
    }

    /// Store a slug's endpoint list. Tests seed the cache through this.
    nonisolated static func cache(_ tiers: [OpenRouterEndpointTier], for slug: String) {
        entriesLock.lock()
        entriesBySlug[slug.lowercased()] = Entry(tiers: tiers, fetchedAt: Date())
        entriesLock.unlock()
    }

    nonisolated static func clearCacheForTesting() {
        entriesLock.lock()
        entriesBySlug = [:]
        entriesLock.unlock()
    }

    private nonisolated static func freshEntry(slug: String) -> Entry? {
        entriesLock.lock()
        defer { entriesLock.unlock() }
        guard let entry = entriesBySlug[slug.lowercased()],
              Date().timeIntervalSince(entry.fetchedAt) < freshnessInterval
        else { return nil }
        return entry
    }

    /// Endpoint tiers for a slug, fetching when the cache is cold or stale.
    /// Concurrent callers for one slug share a fetch. No API key is required.
    func tiers(for slug: String, forceRefresh: Bool = false) async throws -> [OpenRouterEndpointTier] {
        let key = slug.lowercased()
        if !forceRefresh, let entry = Self.freshEntry(slug: key) { return entry.tiers }
        if let task = inFlight[key] { return try await task.value }
        let task = Task<[OpenRouterEndpointTier], Error> {
            try await Self.fetchTiers(slug: slug)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let tiers = try await task.value
        Self.cache(tiers, for: key)
        return tiers
    }

    private static func fetchTiers(slug: String) async throws -> [OpenRouterEndpointTier] {
        let path = slug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "https://openrouter.ai/api/v1/models/\(path)/endpoints") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return OpenRouterSpeedTier.parseEndpoints(data)
    }
}

/// OpenRouter's measured output speed for one endpoint of a model: the median
/// tokens per second over the last 30 minutes of real traffic.
struct OpenRouterEndpointSpeed: Sendable, Equatable {
    /// The endpoint slug, the same string as `OpenRouterEndpointTier.tag`
    /// ("openai/fast", "azure/eu").
    let tag: String
    let medianTokensPerSecond: Double
    let requestCount: Int
}

/// Output speed for the pickers, from the statistics behind OpenRouter's own
/// model page. The public `/models/{slug}/endpoints` API returns
/// `throughput_last_30m: null` to a request without a key (checked
/// 2026-09-22 on Sonnet 5, GPT-5.6 Sol, GLM 5.3 Flash and Gemini 3.5 Flash),
/// so this reads `/api/frontend/v1/stats/endpoint`, which the model page
/// itself calls. That route is undocumented: a response in any other shape
/// parses to nothing, and the pickers then show no speed rather than a guess.
enum OpenRouterModelSpeed {
    /// An endpoint needs this many requests in the window before its median
    /// counts. One request at 60 tok/s is an anecdote, and the Standard figure
    /// takes the fastest endpoint, so a thin sample would always win.
    static let minimumRequests = 20

    /// The speed a pick at this speed tier gets. Fast and Flex name their tier
    /// endpoint, so theirs is that endpoint's median. A Standard request is
    /// sorted by throughput (`OpenRouterRoutePreference`), so its figure is the
    /// fastest standard endpoint's. Nil when no endpoint has enough traffic.
    static func tokensPerSecond(
        for speed: AISpeed,
        slug: String,
        in endpoints: [OpenRouterEndpointSpeed]
    ) -> Double? {
        let measured = endpoints.filter { $0.requestCount >= minimumRequests }
        switch speed {
        case .fast, .flex:
            guard let vendor = OpenRouterSpeedTier.vendor(ofSlug: slug) else { return nil }
            let tag = vendor + (speed == .fast ? OpenRouterSpeedTier.fastSuffix : OpenRouterSpeedTier.flexSuffix)
            return measured.first { $0.tag.lowercased() == tag }?.medianTokensPerSecond
        case .standard:
            return measured
                .filter { !OpenRouterSpeedTier.isServiceTier($0.tag) }
                .map(\.medianTokensPerSecond)
                .max()
        }
    }

    /// "61 tok/s". Whole tokens: the median moves by more than one between
    /// fetches, so a decimal would only be noise.
    static func label(tokensPerSecond: Double) -> String {
        "\(Int(tokensPerSecond.rounded())) tok/s"
    }

    static let explanation = "Output speed is OpenRouter's median over the last 30 minutes, on the host ForeverLM routes to."

    /// The variant OpenRouter files a slug's statistics under: the part after
    /// the colon ("free" for `…:free`), else "standard". A `:free` id shares
    /// its permaslug with the paid model, so asking for "standard" quoted the
    /// paid hosts' speed: Nemotron 3 Ultra (free) read 142 tok/s, its paid
    /// host's median, while NVIDIA's free host ran at 23 (2026-09-28).
    static func variant(ofSlug slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let colon = trimmed.lastIndex(of: ":") else { return "standard" }
        let variant = trimmed[trimmed.index(after: colon)...]
        return variant.isEmpty ? "standard" : String(variant)
    }

    static func parseStats(_ data: Data) -> [OpenRouterEndpointSpeed] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let tag = row["provider_slug"] as? String, !tag.isEmpty,
                  let stats = row["stats"] as? [String: Any],
                  let median = (stats["p50_throughput"] as? NSNumber)?.doubleValue,
                  median.isFinite, median > 0
            else { return nil }
            let count = (stats["throughput_request_count"] as? NSNumber)?.intValue
                ?? (stats["request_count"] as? NSNumber)?.intValue
                ?? 0
            return OpenRouterEndpointSpeed(tag: tag, medianTokensPerSecond: median, requestCount: count)
        }
    }
}

/// The page on openrouter.ai that describes a model — its providers, prices,
/// speed and benchmarks — for the pickers to link to.
enum OpenRouterModelPage {
    static func url(provider: AIProvider, model: String) -> URL? {
        url(slug: OpenRouterModelID.slug(provider: provider, model: model))
    }

    static func url(slug: String) -> URL? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/"),
              let path = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://openrouter.ai/\(path)")
    }
}

/// Per-model endpoint speeds, fetched on demand and kept for a few minutes,
/// like `OpenRouterEndpointTierCatalog`. Memory only.
actor OpenRouterModelSpeedCatalog {
    static let shared = OpenRouterModelSpeedCatalog()

    private struct Entry {
        let speeds: [OpenRouterEndpointSpeed]
        let fetchedAt: Date
    }

    nonisolated(unsafe) private static var entriesBySlug: [String: Entry] = [:]
    private static let entriesLock = NSLock()
    private static let freshnessInterval: TimeInterval = 5 * 60

    private var inFlight: [String: Task<[OpenRouterEndpointSpeed], Error>] = [:]

    nonisolated static func cachedSpeeds(slug: String) -> [OpenRouterEndpointSpeed]? {
        entriesLock.lock()
        defer { entriesLock.unlock() }
        return entriesBySlug[slug.lowercased()]?.speeds
    }

    /// The figure a picker prints for this slug at this speed, from what has
    /// already been fetched.
    nonisolated static func cachedTokensPerSecond(slug: String, speed: AISpeed) -> Double? {
        cachedSpeeds(slug: slug).flatMap {
            OpenRouterModelSpeed.tokensPerSecond(for: speed, slug: slug, in: $0)
        }
    }

    /// Store a slug's speeds. Tests seed the cache through this.
    nonisolated static func cache(_ speeds: [OpenRouterEndpointSpeed], for slug: String) {
        entriesLock.lock()
        entriesBySlug[slug.lowercased()] = Entry(speeds: speeds, fetchedAt: Date())
        entriesLock.unlock()
    }

    private nonisolated static func freshEntry(slug: String) -> Entry? {
        entriesLock.lock()
        defer { entriesLock.unlock() }
        guard let entry = entriesBySlug[slug.lowercased()],
              Date().timeIntervalSince(entry.fetchedAt) < freshnessInterval
        else { return nil }
        return entry
    }

    /// Endpoint speeds for a slug. The statistics are filed under the dated
    /// permaslug, which the directory carries; a slug the directory does not
    /// list has none to fetch. Concurrent callers for one slug share a fetch.
    func speeds(for slug: String) async throws -> [OpenRouterEndpointSpeed] {
        let key = slug.lowercased()
        if let entry = Self.freshEntry(slug: key) { return entry.speeds }
        if let task = inFlight[key] { return try await task.value }
        let task = Task<[OpenRouterEndpointSpeed], Error> {
            let directory = try await OpenRouterCatalogAvailability.shared.models()
            guard let permaslug = directory.first(where: { $0.id.lowercased() == key })?.canonicalSlug else {
                return []
            }
            return try await Self.fetchSpeeds(permaslug: permaslug, variant: OpenRouterModelSpeed.variant(ofSlug: key))
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let speeds = try await task.value
        Self.cache(speeds, for: key)
        return speeds
    }

    private static func fetchSpeeds(permaslug: String, variant: String) async throws -> [OpenRouterEndpointSpeed] {
        var components = URLComponents(string: "https://openrouter.ai/api/frontend/v1/stats/endpoint")
        components?.queryItems = [
            URLQueryItem(name: "latencyMetric", value: "latency"),
            URLQueryItem(name: "perfWorkload", value: "text_generation"),
            URLQueryItem(name: "permaslug", value: permaslug),
            URLQueryItem(name: "variant", value: variant),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return OpenRouterModelSpeed.parseStats(data)
    }
}

extension AIService {

    // MARK: - Unified Task-Based Call

    /// Single-turn LLM call using a resolved task config. Eliminates the 3-way provider switch.
    /// `imageJPEGData` attaches one image to the user turn for vision-capable models.
    ///
    /// `validateResponse` throws when a reply is one the work cannot use. Such a reply is
    /// not an answer: it is never kept in the response cache, a cached one is asked for
    /// again, and the error moves the call on to the next backup model. A model that
    /// cannot do the task is no longer taken at its word: on 2026-09-27 the free router
    /// handed a slide to a safety classifier, whose "User Safety: safe" was taken as the
    /// slide's read. A router's classifier pick is now refused for every task
    /// (`AIError.safetyClassifierAnswer`); a validator still catches every other reply
    /// its work cannot use.
    func call(
        config: AITaskConfig,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double? = nil,
        imageJPEGData: Data? = nil,
        allowsReasoningInflation: Bool = true,
        disablesReasoning: Bool = false,
        allowsResponseCache: Bool = true,
        jsonMode: Bool = false,
        webSearch: Bool = false,
        validateResponse: (@Sendable (String) throws -> Void)? = nil,
        sourceTitle: String? = AIUsageAttribution.sourceTitle,
        subjectID: String? = AIUsageAttribution.subjectID,
        subjectType: String? = AIUsageAttribution.subjectType,
        activityID: String? = AIUsageAttribution.activityID
    ) async throws -> String {
        let resolvedActivityID = AIUsageAttribution.resolvedActivityID(
            activityID,
            sessionID: AIUsageAttribution.sessionID,
            fallback: UUID().uuidString
        )
        // Listed for the background-work list, where Stop cancels it
        // (`AIInFlightCalls.track`): the backup chain does not go on after a
        // cancellation.
        return try await AIInFlightCalls.current.track(
            step: config.taskLabel,
            sourceTitle: sourceTitle,
            subjectID: subjectID
        ) { inFlightID in
            try await self.runWithBackups(
                inFlightID: inFlightID,
                config: config,
                system: system,
                user: user,
                maxTokens: maxTokens,
                temperature: temperature,
                imageJPEGData: imageJPEGData,
                allowsReasoningInflation: allowsReasoningInflation,
                disablesReasoning: disablesReasoning,
                allowsResponseCache: allowsResponseCache,
                jsonMode: jsonMode,
                webSearch: webSearch,
                validateResponse: validateResponse,
                sourceTitle: sourceTitle,
                subjectID: subjectID,
                subjectType: subjectType,
                activityID: resolvedActivityID
            )
        }
    }

    private func runWithBackups(
        inFlightID: UUID?,
        config: AITaskConfig,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?,
        imageJPEGData: Data?,
        allowsReasoningInflation: Bool,
        disablesReasoning: Bool,
        allowsResponseCache: Bool,
        jsonMode: Bool,
        webSearch: Bool,
        validateResponse: (@Sendable (String) throws -> Void)?,
        sourceTitle: String?,
        subjectID: String?,
        subjectType: String?,
        activityID resolvedActivityID: String
    ) async throws -> String {
        // A background task's backup models answer when its own cannot.
        return try await AIBackupModels.run(primary: config) { candidate in
            let config = KeychainService.routedTextConfig(candidate)
            if config.isBackup {
                // Budgeting trims a request to fit a model's window. A backup
                // is never sent a trimmed request: one whose window cannot
                // take all of it is passed over for the next.
                let budgeted = Self.budgetedOneShotRequest(
                    provider: config.provider,
                    model: config.model,
                    system: system,
                    user: user,
                    requestedMaxTokens: maxTokens
                )
                guard budgeted.system == system, budgeted.user == user else {
                    throw AIError.apiError("\(config.model) was passed over as a backup: its context window cannot take this whole request.")
                }
            }
            AIInFlightCalls.current.setModel(inFlightID, provider: config.provider, model: config.model)
            return try await self.callOneShot(
                route: AITaskModelRoute(provider: config.provider, model: config.model),
                apiKey: config.apiKey,
                taskLabel: config.taskLabel,
                effort: config.effort,
                system: system,
                user: user,
                maxTokens: maxTokens,
                temperature: temperature,
                imageJPEGData: imageJPEGData,
                allowsReasoningInflation: allowsReasoningInflation,
                disablesReasoning: disablesReasoning,
                allowsResponseCache: allowsResponseCache,
                jsonMode: jsonMode,
                webSearch: webSearch,
                validateResponse: validateResponse,
                sourceTitle: sourceTitle,
                subjectID: subjectID,
                subjectType: subjectType,
                activityID: resolvedActivityID
            )
        }
    }

    private func callOneShot(
        route: AITaskModelRoute,
        apiKey: String,
        taskLabel: String?,
        effort: AIEffort?,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?,
        imageJPEGData: Data?,
        allowsReasoningInflation: Bool,
        disablesReasoning: Bool,
        allowsResponseCache: Bool,
        jsonMode: Bool,
        webSearch: Bool,
        validateResponse: (@Sendable (String) throws -> Void)?,
        sourceTitle: String?,
        subjectID: String?,
        subjectType: String?,
        activityID: String?
    ) async throws -> String {
        let requestEffort = disablesReasoning ? nil : effort
        // Budget for the configured model's context window and reasoning policy.
        let budgeted = Self.budgetedOneShotRequest(
            provider: route.provider,
            model: route.model,
            system: system,
            user: user,
            requestedMaxTokens: maxTokens
        )
        let effectiveMaxTokens = allowsReasoningInflation
            ? Self.effectiveReasoningAwareMaxTokens(
                budgeted.maxTokens,
                provider: route.provider,
                model: route.model
            )
            : budgeted.maxTokens
        let requestKey = Self.oneShotRequestKey(
            route: route,
            taskLabel: taskLabel,
            system: budgeted.system,
            user: budgeted.user,
            maxTokens: effectiveMaxTokens,
            temperature: temperature,
            effort: requestEffort,
            disablesReasoning: disablesReasoning,
            jsonMode: jsonMode,
            webSearch: webSearch,
            imageJPEGData: imageJPEGData
        )
        if let existing = oneShotRequestsInFlight[requestKey] {
            return try await waitForOneShot(requestKey, existing)
        }

        let canReuseResponse = allowsResponseCache && taskLabel?.isEmpty == false
        // OpenRouter's own cache keeps a reply before anything here has judged
        // it. A router picks the model per request, so caching there would hold
        // one bad pick for a day: the router's safety-classifier verdict came
        // back on every retry. This cache keeps only replies that passed.
        let asksProviderCache = canReuseResponse && !AIUsageReport.isOpenRouterRouter(route.model)
        let requestTask = Task<String, Error> {
            if canReuseResponse, let storage = self.responseCacheStorage {
                do {
                    // A reply kept before its work could say it was unusable is asked
                    // for again rather than replayed.
                    if let cached = try await storage.cachedAIResponse(
                        for: requestKey,
                        notOlderThan: Date().addingTimeInterval(-24 * 60 * 60)
                    ), Self.isUsable(cached, validateResponse) {
                        return cached
                    }
                } catch {
                    aiResponseCacheLogger.warning(
                        "Could not read deterministic AI response cache: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            let response = try await AIUsageAttribution.$activityID.withValue(activityID) {
                try await AIUsageAttribution.$subjectType.withValue(subjectType) {
                    try await AIUsageAttribution.$subjectID.withValue(subjectID) {
                        try await AIUsageAttribution.$sourceTitle.withValue(sourceTitle) {
                            try await AIUsageAttribution.$task.withValue(taskLabel) {
                                try await AIResponseCachePolicy.$deterministic.withValue(asksProviderCache) {
                                    try await self.callOpenAICompatible(
                                        provider: route.provider,
                                        apiKey: apiKey,
                                        system: budgeted.system,
                                        userMessage: budgeted.user,
                                        maxTokens: effectiveMaxTokens,
                                        temperature: temperature,
                                        jsonMode: jsonMode,
                                        effort: requestEffort,
                                        disablesReasoning: disablesReasoning,
                                        imageJPEGData: imageJPEGData,
                                        webSearch: webSearch,
                                        model: route.model
                                    )
                                }
                            }
                        }
                    }
                }
            }
            // An answer the work cannot use is thrown as the work's own error and never
            // kept: the backup chain moves on, and asking again asks the model again.
            try validateResponse?(response)
            if canReuseResponse, let storage = self.responseCacheStorage {
                do {
                    try await storage.saveCachedAIResponse(response, for: requestKey)
                } catch {
                    aiResponseCacheLogger.warning(
                        "Could not save deterministic AI response cache: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return response
        }
        let request = OneShotRequestInFlight(id: UUID(), task: requestTask)
        oneShotRequestsInFlight[requestKey] = request
        Task {
            let result = await requestTask.result
            self.finishOneShot(requestKey, requestID: request.id, with: result)
        }
        return try await waitForOneShot(requestKey, request)
    }

    /// Waits for a shared one-shot request as `task.value` would, except that
    /// cancelling this caller ends its wait at once with `CancellationError`,
    /// whatever the other callers do. The lookup that found `request` and the
    /// registration below run in one stretch on the actor, so the request
    /// cannot finish unseen in between.
    private func waitForOneShot(_ key: String, _ request: OneShotRequestInFlight) async throws -> String {
        let requestID = request.id
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                oneShotRequestsInFlight[key]?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.leaveOneShot(key, requestID: requestID, waiterID: waiterID) }
        }
    }

    /// A caller was cancelled: resume it, and when no one is left waiting,
    /// stop the network call and let the next identical request start its own.
    private func leaveOneShot(_ key: String, requestID: UUID, waiterID: UUID) {
        guard var request = oneShotRequestsInFlight[key], request.id == requestID else { return }
        request.waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            oneShotRequestsInFlight[key] = nil
            request.task.cancel()
        } else {
            oneShotRequestsInFlight[key] = request
        }
    }

    /// The network call ended: every caller still waiting gets its result.
    private func finishOneShot(_ key: String, requestID: UUID, with result: Result<String, Error>) {
        guard let request = oneShotRequestsInFlight[key], request.id == requestID else { return }
        oneShotRequestsInFlight[key] = nil
        for waiter in request.waiters.values {
            waiter.resume(with: result)
        }
    }

    /// Whether a reply passes its caller's check. With no check, every reply does.
    private static func isUsable(
        _ response: String,
        _ validate: (@Sendable (String) throws -> Void)?
    ) -> Bool {
        guard let validate else { return true }
        return (try? validate(response)) != nil
    }

    /// Process-local identity for simultaneous one-shot work. The proxy uses
    /// its own independently computed fingerprint for the persistent breaker;
    /// this digest exists only to avoid concurrent OpenRouter cache misses.
    private static func oneShotRequestKey(
        route: AITaskModelRoute,
        taskLabel: String?,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?,
        effort: AIEffort?,
        disablesReasoning: Bool,
        jsonMode: Bool,
        webSearch: Bool,
        imageJPEGData: Data?
    ) -> String {
        let imageDigest = imageJPEGData.map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } ?? ""
        let material = [
            route.provider.rawValue,
            route.model,
            taskLabel ?? "",
            system,
            user,
            String(maxTokens),
            temperature.map { String($0) } ?? "",
            effort?.rawValue ?? "effort-default",
            disablesReasoning ? "reasoning-off" : "reasoning-default",
            jsonMode ? "json" : "text",
            webSearch ? "web-search" : "no-web-search",
            imageDigest,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// How much room a reasoning model needs beyond the answer it is asked for.
    ///
    /// A model that thinks before answering spends those tokens against the same budget as
    /// the reply, so a budget sized for the visible answer can be consumed entirely by
    /// thinking and leave the answer truncated in the middle of a word. Nothing downstream
    /// can tell that apart from a model that had nothing to say: slide citation extraction
    /// measured Gemini 3.5 Flash spending 960 of 1024 tokens on thoughts and truncating its
    /// JSON, and reported 14 of 29 slides as unreadable.
    ///
    /// This only moves a ceiling. No provider bills for tokens that are never generated, so a
    /// budget larger than the answer costs nothing, while one smaller than the thinking costs
    /// the entire call — which is why it is generous rather than measured.
    static func reasoningInflatedMaxTokens(_ requested: Int) -> Int {
        max(requested * 8, 4096)
    }

    static func effectiveReasoningAwareMaxTokens(
        _ requested: Int,
        provider: AIProvider,
        model: String
    ) -> Int {
        // OpenAI inflates inside its own adapter, which every OpenAI entry point passes
        // through; inflating here as well would apply the multiplier twice.
        guard provider != .openai else { return requested }

        // Every other host now serves models that reason before answering — Claude's extended
        // thinking, Gemini's thoughts, Grok, GPT OSS, Nemotron, Muse Spark. The floors this
        // replaces were per-provider guesses from when OpenAI had the only reasoning models,
        // and they had drifted into deciding which providers were allowed to think.
        //
        // Clamped to what the window can actually give back, because the multiplier can
        // otherwise ask a small-window model (Cerebras llama-3.1-8b at 8k) for more output
        // than its context leaves once the prompt is in.
        return Self.cappedResponseTokens(
            provider: provider,
            model: model,
            requestedMaxTokens: Self.reasoningInflatedMaxTokens(requested)
        )
    }

    /// Multi-turn LLM call using a resolved task config.
    func callChat(
        config: AITaskConfig,
        system: String,
        messages: [(role: String, content: String)],
        maxTokens: Int
    ) async throws -> String {
        let config = KeychainService.routedTextConfig(config)
        let route = AITaskModelRoute(provider: config.provider, model: config.model)
        // `maxTokens` describes the requested visible result. Reasoning models
        // count hidden thinking against the same provider limit, so reserve the
        // same headroom used by one-shot tasks. The model's real context window
        // remains the hard upper bound.
        let effectiveMaxTokens = Self.effectiveReasoningAwareMaxTokens(
            maxTokens,
            provider: route.provider,
            model: route.model
        )
        let budgeted = Self.budgetedChatRequest(
            provider: route.provider,
            model: route.model,
            system: system,
            messages: messages,
            requestedMaxTokens: effectiveMaxTokens
        )
        // Listed for the background-work list, where Stop cancels it: a
        // chat's history fold, a review's grade, the PDF finder's browsing.
        let messages = budgeted.messages
        return try await AIInFlightCalls.current.track(step: config.taskLabel) { inFlightID in
            AIInFlightCalls.current.setModel(inFlightID, provider: route.provider, model: route.model)
            return try await AIUsageAttribution.$task.withValue(config.taskLabel) {
                try await self.callOpenAICompatibleChat(
                    provider: route.provider,
                    apiKey: config.apiKey,
                    system: budgeted.system,
                    messages: messages,
                    maxTokens: budgeted.maxTokens,
                    model: route.model,
                    effort: config.effort
                )
            }
        }
    }
    
    /// Prepare a source's review guide: the questions and strong answers a
    /// review reads beside the source's text (today's memory review among
    /// them), so a tutor grades from a prepared curriculum rather than
    /// discovering it turn by turn.
    func prepareSourceReviewGuide(
        source: AIUsageSource,
        sourceText: String,
        config: AITaskConfig
    ) async throws -> String {
        let response = try await AIUsageAttribution.withSource(source) {
            try await call(
                config: config,
                system: AITask.realtimeReviewPreparation.effectivePrompt
                    ?? Prompts.realtimeReviewPreparation,
                user: """
                SOURCE TITLE: \(source.title)

                SOURCE TEXT:
                \(sourceText)
                """,
                maxTokens: 2_000,
                temperature: 0.0
            )
        }
        let guide = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guide.isEmpty else { throw AIError.invalidResponse }
        return guide
    }

    func suggestReviewSessionTitle(
        from assistantResponse: String,
        userMessage: String? = nil,
        config: AITaskConfig
    ) async throws -> String? {
        let trimmed = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var userPrompt = String(trimmed.prefix(3_000))
        if let userMessage {
            let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedUser.isEmpty {
                userPrompt = """
                Learner message:
                \(String(trimmedUser.prefix(1_000)))

                Assistant response:
                \(userPrompt)
                """
            }
        }
        let response = try await call(
            config: config,
            system: Prompts.reviewSessionTitle,
            user: userPrompt,
            maxTokens: 40,
            temperature: 0.0
        )
        let title = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`#* "))
        guard !title.isEmpty else { return nil }
        return title.count <= 80 ? title : String(title.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
    
    // MARK: - Docs: Edit with AI

    /// Revise one passage of a Doc on the writer's instruction. Runs on the
    /// Docs model (`KeychainService.resolveDocsConfig`) through the chat's
    /// billing path, and lands in the ledger as `doc_edit`. The answer is the passage's replacement;
    /// the editor shows it before anything is written.
    func editDocPassage(_ request: DocPassageEditRequest, config: AITaskConfig) async throws -> String {
        var config = config
        config.taskLabel = "doc_edit"
        // Room for the passage to grow — a list from a paragraph, a sentence
        // added — without inviting an essay. New text with no passage to size
        // it by (Generate) gets room for a section.
        // A visualization is a whole HTML document, scripts and styles inline.
        let maxTokens = request.writesVisualization
            ? 8_000
            : request.writesNewText
                ? 3_000
                : min(8_000, max(1_200, request.passage.count / 2 + 800))
        return try await callChat(
            config: config,
            system: request.writesVisualization ? Prompts.docVisualization : Prompts.docPassageEdit,
            messages: [(role: "user", content: Prompts.docPassageEditUserMessage(request))],
            maxTokens: maxTokens
        )
    }

    // MARK: - Multi-turn Chat

    /// Generic multi-turn chat with a system prompt and message history.
    func chat(
        system: String,
        messages: [(role: String, content: String)],
        config: AITaskConfig,
        maxTokens: Int = 2000
    ) async throws -> String {
        return try await callChat(config: config, system: system, messages: messages, maxTokens: maxTokens)
    }

    /// Format one transcript chunk using the user's configured transcript-formatting model.
    func formatTranscriptChunk(
        _ transcript: String,
        system: String,
        config: AITaskConfig,
        maxTokens: Int,
        sourceTitle: String? = AIUsageAttribution.sourceTitle,
        subjectID: String? = AIUsageAttribution.subjectID,
        subjectType: String? = AIUsageAttribution.subjectType,
        activityID: String? = AIUsageAttribution.activityID
    ) async throws -> String {
        try await call(
            config: config,
            system: system,
            user: transcript,
            maxTokens: maxTokens,
            temperature: 0.1,
            sourceTitle: sourceTitle,
            subjectID: subjectID,
            subjectType: subjectType,
            activityID: activityID
        )
    }

    /// Generic multi-turn chat that yields text deltas as the provider streams
    /// them. Deltas are batched at the producer (at most one yield per ~50ms or
    /// 512 buffered characters) so a fast provider can't flood the consuming
    /// actor — typically the main actor — with per-token hops.
    func streamChat(
        system: String,
        volatileSystem: String = "",
        messages: [(role: String, content: String)],
        config: AITaskConfig,
        maxTokens: Int = 2000,
        webSearch: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                var lastYield = Date.distantPast
                do {
                    try await self.streamChat(
                        config: config,
                        system: system,
                        volatileSystem: volatileSystem,
                        messages: messages,
                        maxTokens: maxTokens,
                        webSearch: webSearch
                    ) { delta in
                        buffer += delta
                        let now = Date()
                        if now.timeIntervalSince(lastYield) >= 0.05 || buffer.count >= 512 {
                            continuation.yield(buffer)
                            buffer = ""
                            lastYield = now
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    // Deliver any buffered partial text before failing, so retry
                    // logic can carry the partial answer forward as a continuation.
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func streamChat(
        config: AITaskConfig,
        system: String,
        volatileSystem: String = "",
        messages: [(role: String, content: String)],
        maxTokens: Int,
        webSearch: Bool = false,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let config = KeychainService.routedTextConfig(config)
        await Self.primeOpenRouterSpeedTier(for: config)
        try await streamChatOnce(
            route: AITaskModelRoute(provider: config.provider, model: config.model),
            config: config,
            system: system,
            volatileSystem: volatileSystem,
            messages: messages,
            maxTokens: maxTokens,
            webSearch: webSearch,
            onDelta: onDelta
        )
    }

    /// A Fast or Flex pick on the OpenRouter rail is honoured only if the
    /// model's tier endpoint is known, and `supportedSpeeds` reads a
    /// synchronous cache. Fill it here so a pick stored before this launch is
    /// not silently dropped to standard on the first send. A fetch failure
    /// leaves the cache empty and the request goes out at standard speed —
    /// the gate below never guesses.
    ///
    /// A standard send also reads that cache, for the endpoints that cache
    /// prompts (`applyOpenRouterPayloadExtras`), but never waits on it: the
    /// refresh runs beside the send, and a cold first send just goes out
    /// unconfined. OpenRouter only makes a conversation sticky on an endpoint
    /// that caches, so the next turn is confined and pinned from then on.
    static func primeOpenRouterSpeedTier(for config: AITaskConfig) async {
        guard routesThroughOpenRouter(config.provider) else { return }
        guard let speed = config.speed, speed != .standard else {
            let model = config.model
            Task { _ = try? await OpenRouterEndpointTierCatalog.shared.tiers(for: model) }
            return
        }
        // The catalog shares one fetch among its callers, and a caller's
        // Stop does not reach it; a stopped chat stops waiting here and lets
        // the fetch fill the cache on its own. The request after it then
        // fails at once, cancelled.
        let model = config.model
        _ = try? await CancellableWait.run {
            try await OpenRouterEndpointTierCatalog.shared.tiers(for: model)
        }
    }

    private func streamChatOnce(
        route: AITaskModelRoute,
        config: AITaskConfig,
        system: String,
        volatileSystem: String,
        messages: [(role: String, content: String)],
        maxTokens: Int,
        webSearch: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        // Trim the request for the configured model.
        let budgeted = Self.budgetedChatRequest(
            provider: route.provider,
            model: route.model,
            system: volatileSystem.isEmpty ? system : system + volatileSystem,
            messages: messages,
            requestedMaxTokens: maxTokens
        )
        // budgetedChatRequest truncates the system tail. If it fired, the split
        // point is gone and the volatile tail may be partly or wholly cut, so
        // send the budgeted string as one stable block rather than guessing
        // where the boundary landed. Cache reuse is already lost at that point
        // (the prefix changed), matching the emergency-truncation path.
        let wasTruncated = budgeted.system.count < (system.count + volatileSystem.count)
        let stableSystem = wasTruncated ? budgeted.system : system
        let tailSystem = wasTruncated ? "" : volatileSystem
        let messages = budgeted.messages
        let maxTokens = budgeted.maxTokens
        // One path for every provider. The stable head and volatile tail stay
        // separate all the way down rather than being concatenated here: the
        // OpenAI-compatible adapter needs them apart to place the cache
        // breakpoint at the end of the stable head, which is what keeps the
        // cached prefix byte-identical across turns.
        try await AIUsageAttribution.$task.withValue(config.taskLabel) {
            let effort = config.effort.flatMap {
                AIRequestOptionSupport.supportedEfforts(
                    provider: route.provider,
                    model: route.model
                ).contains($0) ? $0 : nil
            }
            let speed = config.speed.flatMap {
                AIRequestOptionSupport.supportedSpeeds(
                    provider: route.provider,
                    model: route.model
                ).contains($0) ? $0 : nil
            }
            try await streamOpenAICompatibleChat(
                provider: route.provider,
                apiKey: config.apiKey,
                system: stableSystem, volatileSystem: tailSystem,
                messages: messages, maxTokens: maxTokens, model: route.model,
                effort: effort, speed: speed, webSearch: webSearch,
                onDelta: onDelta)
        }
    }

    // The Anthropic Files API client lived here: upload, list, and delete
    // against api.anthropic.com with a raw provider key. It had no call sites —
    // chat attachments were never wired to it — and the key it needed no longer
    // exists, so it could only have failed. Removed rather than ported.
    //
    // If attachments are built, OpenRouter takes a PDF as a `file` content part
    // (base64 data URL or plain URL) on any model, and its file-parser plugin
    // OCRs for models without native file input. That needs no upload step and
    // no per-provider client. AnthropicFile stays in Models.swift only because
    // it is Codable and may appear in archived state.

    /// Returns the preferred (pinned) models for a provider. No API call needed.
    static func preferredModels(for provider: AIProvider) -> [String] {
        AIModelDefaults.preferredModels(for: provider)
    }

    /// Parses the advisory promotion metadata used by OpenRouter's own model
    /// catalog. The documented models API remains the effective-price source;
    /// if this auxiliary shape changes, prices still refresh and badges simply
    /// disappear until the metadata contract is repaired.
    static func openRouterPromotionTable(from data: Data) -> [String: RouterModelPromotion] {
        openRouterPromotionTable(rows: openRouterCatalogRows(from: data))
    }

    /// The rows of OpenRouter's frontend catalog, parsed once for every table
    /// read from it: the response runs to megabytes.
    static func openRouterCatalogRows(from data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return [] }
        return rows
    }

    /// Slug → the effort levels the frontend catalog lists under
    /// `reasoning_config`, the only place OpenRouter publishes them: the public
    /// directory's `supported_parameters` says only that `reasoning_effort` is
    /// accepted, not which levels. They differ per model — GLM 5.3 Flash takes
    /// low/high/max and defaults to max, DeepSeek V4 Flash takes high/xhigh
    /// (checked 2026-09-27). Keyed by the endpoint's variant slug, so a
    /// `:free` or `:batch` id finds its own row.
    static func openRouterReasoningEffortTable(rows: [[String: Any]]) -> [String: OpenRouterReasoningEfforts] {
        var table: [String: OpenRouterReasoningEfforts] = [:]
        for row in rows {
            guard let config = row["reasoning_config"] as? [String: Any],
                  config["supports_reasoning_effort"] as? Bool == true,
                  let efforts = config["supported_reasoning_efforts"] as? [String],
                  !efforts.isEmpty else { continue }
            let endpoint = row["endpoint"] as? [String: Any]
            let slug = ((endpoint?["model_variant_slug"] as? String) ?? (row["slug"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let slug, !slug.isEmpty else { continue }
            table[slug] = OpenRouterReasoningEfforts(
                efforts: efforts.map { $0.lowercased() },
                defaultEffort: (config["default_reasoning_effort"] as? String)?.lowercased()
            )
        }
        return table
    }

    /// The variant slugs whose endpoint the frontend catalog marks as
    /// training on prompts (`endpoint.data_policy.training`), the only place
    /// OpenRouter publishes it. Keyed like the effort table, so a `:free`
    /// variant is judged by its own host: Nemotron 3 Ultra's free endpoint
    /// trains, its paid ones do not (checked 2026-09-28). Nil when no row
    /// carried a data policy at all, so a changed shape keeps the last answer
    /// rather than clearing every label.
    static func openRouterTrainingSlugs(rows: [[String: Any]]) -> Set<String>? {
        var sawPolicy = false
        var slugs: Set<String> = []
        for row in rows {
            guard let endpoint = row["endpoint"] as? [String: Any],
                  let policy = endpoint["data_policy"] as? [String: Any] else { continue }
            sawPolicy = true
            guard policy["training"] as? Bool == true else { continue }
            let slug = ((endpoint["model_variant_slug"] as? String) ?? (row["slug"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let slug, !slug.isEmpty { slugs.insert(slug) }
        }
        return sawPolicy ? slugs : nil
    }

    static func openRouterPromotionTable(rows: [[String: Any]]) -> [String: RouterModelPromotion] {
        var table: [String: RouterModelPromotion] = [:]
        for row in rows {
            guard let slug = (row["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !slug.isEmpty,
                  let endpoint = row["endpoint"] as? [String: Any],
                  let pricing = endpoint["pricing"] as? [String: Any],
                  let discount = (pricing["discount"] as? NSNumber)?.doubleValue,
                  let promotion = RouterModelPromotion(discount: discount) else { continue }
            table[slug] = promotion
        }
        return table
    }

    /// The directory request. No `supported_parameters` filter, on purpose:
    /// with `supported_parameters=tools` OpenRouter quotes each model at its
    /// cheapest tool-capable endpoint, which for OpenAI's models is the Flex
    /// tier — half the Standard price the default route actually bills
    /// (verified 2026-09-10: GPT-5.6 Sol came back at $1/$5 filtered and
    /// $2/$10 unfiltered, and the proxy ledger billed $2/$10). The composer
    /// then quoted $1/$5 beside a Speed submenu saying Standard was $2/$10.
    /// Tool support is still read from each row's `supported_parameters`
    /// (`OpenRouterDirectoryModel.supportsTools`), and every consumer that
    /// needs a tool-capable model filters on it.
    static let openRouterDirectoryURL = URL(string: "https://openrouter.ai/api/v1/models?sort=most-popular")!

    /// Fetch OpenRouter's full public model directory with display names,
    /// per-token prices, and context windows — backs the "search all
    /// OpenRouter models" browser in Settings. OpenRouter sorts this response
    /// by tokens processed in the last week so the browser can show a live
    /// popular-model list without hardcoding model IDs. No API key required.
    func listOpenRouterModelDirectory() async throws -> [OpenRouterDirectoryModel] {
        let modelRequest: URLRequest = {
            var request = URLRequest(url: Self.openRouterDirectoryURL)
            request.httpMethod = "GET"
            return request
        }()
        let promotionRequest: URLRequest = {
            var request = URLRequest(
                url: URL(string: "https://openrouter.ai/api/frontend/v1/catalog/models")!
            )
            request.httpMethod = "GET"
            return request
        }()

        async let modelResponse = session.foreverLMData(for: modelRequest)
        async let promotionResponse: (Data, URLResponse)? = try? await session.foreverLMData(for: promotionRequest)
        let (data, response) = try await modelResponse
        let catalogRows = await promotionResponse.map { Self.openRouterCatalogRows(from: $0.0) } ?? []
        // The same catalog prices the speech and transcription models, with
        // the units the directory lacks (`OpenRouterAudioPrices`).
        OpenRouterAudioPrices.ingest(catalogRows: catalogRows)
        let promotions = Self.openRouterPromotionTable(rows: catalogRows)
        // Every kind's, for the media panes, whose directories carry none. A
        // catalog that could not be read keeps the last table.
        if !catalogRows.isEmpty { OpenRouterPromotions.record(promotions) }
        let reasoningEfforts = Self.openRouterReasoningEffortTable(rows: catalogRows)
        // Which models train on prompts, for the label every picker shows and
        // the Data & Privacy switch hides by. A changed answer is applied as
        // the switch applies its own: a chat on a newly hidden model goes back
        // to the default, and the pickers rebuild.
        if let training = Self.openRouterTrainingSlugs(rows: catalogRows),
           AIDataPolicy.recordObservedTrainingSlugs(training) {
            DispatchQueue.main.async {
                AIModelCatalog.dataPolicyDidChange()
            }
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let message = extractAPIErrorMessage(from: data)
                ?? "OpenRouter models request failed (\(http.statusCode))."
            throw AIError.apiError(message)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = json?["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row -> OpenRouterDirectoryModel? in
            guard let id = row["id"] as? String,
                  // "~"-prefixed ids are rolling aliases of other rows.
                  !id.hasPrefix("~") else { return nil }
            // The directory backs text-chat pickers only: drop models that
            // generate anything besides text (image models like Nano Banana,
            // audio/video like Lyria/Veo). Rows without modality info pass.
            if let architecture = row["architecture"] as? [String: Any],
               let outputs = architecture["output_modalities"] as? [String],
               !outputs.isEmpty,
               outputs != ["text"] { return nil }
            let rawName = (row["name"] as? String) ?? id
            // Directory names are "Author: Model"; the maker grouping already
            // says who made it, so keep just the model part, and the author
            // apart for the makers the catalog has no name for.
            let authorRange = rawName.range(of: ": ")
            let name = authorRange.map { String(rawName[$0.upperBound...]) } ?? rawName
            let makerName = authorRange.map { String(rawName[..<$0.lowerBound]) }
            let pricing = row["pricing"] as? [String: Any]
            func usd(_ value: Any?) -> Double? {
                (value as? String).flatMap(Double.init) ?? (value as? Double)
            }
            func usdPerMTokens(_ value: Any?) -> Double? {
                usd(value).map { $0 * 1_000_000 }
            }
            // A model that cannot be priced cannot be offered: the managed
            // proxy resolves a price before forwarding and fails closed
            // without one, so listing it would put a guaranteed 403 in the
            // picker. The dynamic routers (openrouter/auto and its siblings)
            // quote -1 because they choose a model at request time; a row
            // with no pricing at all is the same problem in a different shape.
            // Free models quote 0 and are kept.
            func isPriceable(_ value: Any?) -> Bool {
                guard let parsed = usd(value) else { return false }
                return parsed >= 0
            }
            guard isPriceable(pricing?["prompt"]), isPriceable(pricing?["completion"]) else { return nil }
            var price: AIProviderPricing.RemoteModelPrice?
            if let pricing {
                var parsed = AIProviderPricing.RemoteModelPrice(
                    input: usdPerMTokens(pricing["prompt"]),
                    output: usdPerMTokens(pricing["completion"]),
                    cachedInput: usdPerMTokens(pricing["input_cache_read"]),
                    cacheWrite: usdPerMTokens(pricing["input_cache_write"]),
                    cacheWrite1h: usdPerMTokens(pricing["input_cache_write_1h"]),
                    // web_search is already USD per call, not per token.
                    perWebSearchCall: usd(pricing["web_search"])
                )
                // Long-context tier: the lowest-threshold override entry.
                if let overrides = pricing["overrides"] as? [[String: Any]],
                   let tier = overrides
                       .compactMap({ entry in (entry["min_prompt_tokens"] as? Int).map { ($0, entry) } })
                       .min(by: { $0.0 < $1.0 }) {
                    parsed.longContextThreshold = tier.0
                    parsed.longContextInput = usdPerMTokens(tier.1["prompt"])
                    parsed.longContextOutput = usdPerMTokens(tier.1["completion"])
                }
                price = parsed
            }
            // `image` in the declared input modalities is the authoritative,
            // never-stale answer to "can this read a slide". Absent modalities
            // stay `nil` (unknown) rather than guessing, so the vision warning
            // only ever fires on a model the directory positively calls text-only.
            let inputModalities = (row["architecture"] as? [String: Any])?["input_modalities"] as? [String]
            let supportsVision = inputModalities.map { $0.contains("image") }
            // `created` is Unix seconds. Zero or negative is no date, not 1970.
            let createdSeconds = (row["created"] as? Double) ?? (row["created"] as? Int).map(Double.init)
            let createdAt = createdSeconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return OpenRouterDirectoryModel(
                id: id,
                name: name,
                makerName: makerName,
                inputUSDPerMTokens: usdPerMTokens(pricing?["prompt"]),
                outputUSDPerMTokens: usdPerMTokens(pricing?["completion"]),
                contextLength: row["context_length"] as? Int,
                price: price,
                // Absent `supported_parameters` reads as capable, matching the
                // modality filter above: schema drift should not empty the
                // browser, and a wrong guess surfaces as a provider 4xx.
                supportsTools: (row["supported_parameters"] as? [String])
                    .map { $0.contains("tools") } ?? true,
                supportsTemperature: (row["supported_parameters"] as? [String])
                    .map { $0.contains("temperature") },
                supportsVision: supportsVision,
                promotion: promotions[id.lowercased()],
                createdAt: createdAt,
                canonicalSlug: (row["canonical_slug"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                reasoningEfforts: reasoningEfforts[id.lowercased()],
                huggingFaceID: (row["hugging_face_id"] as? String)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

}

// MARK: - Remote Price Refresh

/// Event-triggered refresh of the remote list-price tables overlaid onto
/// `AIProviderPricing`'s hardcoded rates — OpenRouter's public directory,
/// which publishes the effective user price including temporary promotions.
/// No timers: the chat model picker and
/// Settings catalog call `refreshIfStale()` when they appear, cooldown-limited
/// to one fetch per five minutes, and a directory fetch the Settings model
/// browser makes anyway is folded in via `ingest(_:)`.
///
/// Launch calls it too, which is not a view event. The tables are what stamps
/// `estimatedCost` on every recorded call, and most of what the ledger records
/// is background work — formatting a transcript, cleaning up content — that
/// runs without anyone opening a picker. Leaving the load to the first picker
/// visit is how thousands of rows were once recorded with no cost at all.
enum AIModelPriceRefresher {
    /// Promotions can begin or end during one app session. A five-minute
    /// freshness window keeps a day-old sale price off the pickers (and a
    /// newly discounted one on them).
    static let freshnessInterval: TimeInterval = 5 * 60
    private static let inFlightLock = NSLock()
    nonisolated(unsafe) private static var isRefreshing = false

    /// Whether a price table needs fetching. A table that has never been
    /// fetched is stale, not fresh.
    static func isStale(_ fetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= freshnessInterval
    }

    /// Safe to call from view `onAppear`: returns immediately; the cache
    /// load, cooldown check, and any fetch all run off the main actor.
    static func refreshIfStale() {
        let alreadyRunning = inFlightLock.withLock {
            let running = isRefreshing
            if !running { isRefreshing = true }
            return running
        }
        guard !alreadyRunning else { return }
        Task.detached(priority: .utility) {
            defer {
                inFlightLock.withLock { isRefreshing = false }
            }
            AIProviderPricing.loadPersistedRemotePrices()
            // A failed fetch is not an error surface: the hardcoded table and
            // any previously cached fetch keep pricing, and the next picker
            // or Settings visit retries after the cooldown.
            // The shared availability actor ingests a successful snapshot.
            if isStale(AIProviderPricing.remotePricesFetchedAt) {
                _ = try? await OpenRouterCatalogAvailability.shared.models()
            }
            // With the freshest table in hand, price any stored row that was
            // recorded before its rate was known.
            await AIUsageTracker.repriceLedger()
        }
    }

    /// Folds a fetched directory into the remote price table, keeping only
    /// slugs the app can price: the closed labs' first-party passthrough rows
    /// plus the pinned and user-added OpenRouter models. Republishes the
    /// picker-refresh notification only when a price actually changed.
    static func ingest(_ rows: [OpenRouterDirectoryModel]) {
        // A free pick is checked against what each `:free` id costs in this
        // read, and the price watch compares the models the learner uses with
        // the read before it.
        AIFreeModelPrices.record(Dictionary(
            rows.filter { AIFreeModels.isFreeModelID($0.id) }.map { ($0.id, $0.isZeroPriced) },
            uniquingKeysWith: { $1 }
        ))
        AIModelPriceWatch.observe(rows)
        let mappedAuthorPrefixes = ["anthropic/", "x-ai/", "google/", "openai/", "meta/"]
        let keepIDs = Set(AIModelDefaults.preferredOpenRouter)
            .union(AIModelCatalog.customOpenRouterModels.map(\.id))
        var table: [String: AIProviderPricing.RemoteModelPrice] = [:]
        var vision: [String: Bool] = [:]
        var contextLengths: [String: Int] = [:]
        var releaseDates: [String: Date] = [:]
        var reasoningEfforts: [String: OpenRouterReasoningEfforts] = [:]
        for row in rows {
            // Capability is captured for every row that declared it, not just the
            // priced/pinned ones: any model the user can pin to a vision task has
            // come through this fetch, and the Settings warning reads this map.
            if let supportsVision = row.supportsVision { vision[row.id] = supportsVision }
            // Likewise the window: every slug OpenRouter serves publishes its
            // own, and the budgeter has no other source for most of them.
            if let contextLength = row.contextLength, contextLength > 0 {
                contextLengths[row.id] = contextLength
            }
            // And the listing date, for every row: the catalog's newest-first
            // order reads this table for the closed labs' models too, so it has
            // to cover more than the priced slugs.
            if let createdAt = row.createdAt { releaseDates[row.id] = createdAt }
            // And the effort levels, for every row: the closed labs' models
            // are routed here too, and the composer's effort control reads it.
            if let efforts = row.reasoningEfforts { reasoningEfforts[row.id] = efforts }
            guard let price = row.price else { continue }
            let slug = row.id.lowercased()
            guard keepIDs.contains(row.id) || mappedAuthorPrefixes.contains(where: slug.hasPrefix)
            else { continue }
            table[slug] = price
        }
        // Cache before the price guard: a fetch that parsed capabilities but no
        // priceable rows should still refresh what Settings knows about vision.
        AIModelCatalog.cacheOpenRouterVision(vision)
        AIModelCatalog.cacheOpenRouterContextLengths(contextLengths)
        let releaseDatesChanged = AIModelCatalog.cacheOpenRouterReleaseDates(releaseDates)
        let effortsChanged = AIModelCatalog.cacheOpenRouterReasoningEfforts(reasoningEfforts)
        // An empty parse (schema drift, truncated response) must not clobber
        // a previously good table.
        guard !table.isEmpty else {
            if releaseDatesChanged || effortsChanged { postProviderDidChange() }
            return
        }
        if AIProviderPricing.updateRemotePrices(table, fetchedAt: Date()) || releaseDatesChanged || effortsChanged {
            postProviderDidChange()
        }
    }

    /// The picker-refresh notification: Settings and the chat picker rebuild
    /// their cards on it, so a changed price or a newly dated model reorders
    /// the groups without a reopen.
    private static func postProviderDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }
}
