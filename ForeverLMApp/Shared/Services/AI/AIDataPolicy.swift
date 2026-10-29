import Foundation

/// The learner's answer to "may a model that trains on what I send it be
/// offered to me?" — one switch, off by default, that follows the account.
///
/// ForeverLM's own servers never store prompt or response text: the managed
/// proxy's ledger holds provider, model, token counts and cost, nothing the
/// learner wrote. What happens *after* the proxy is a different question.
/// The first-party rails (Anthropic, OpenAI, Google's paid API, xAI) do not
/// train on API traffic under their terms. OpenRouter itself does not train
/// on inputs, but the model hosts behind it each have their own retention and
/// training practices. Some models are priced for exactly that: Meta's Muse
/// Spark Contributor, whose discount is paid in training consent, and most
/// free endpoints — NVIDIA's, Thinking Machines', Poolside's and Liquid's
/// `:free` variants each run on one host that trains on prompts (OpenRouter's
/// catalog, 2026-09-28).
///
/// The switch does two things, both in the learner's favour:
///
/// - **Hides the models that train.** `trainsOnInputs(modelSlug:)` names
///   them; the catalog leaves them out of every picker, Settings › AI Models, and the
///   MCP catalogue while the switch is on, and a chat whose session model was
///   one of them goes back to the default. With the switch off they are
///   offered, unlabelled: no row says a model trains (product owner, 2026-10-07:
///   that is OpenRouter's to say).
/// - **Routes the rest to hosts that keep nothing.** OpenRouter's per-request
///   `provider.data_collection` preference excludes hosts that may store or
///   train on prompts; the switch is that preference, surfaced. A model whose
///   every host keeps prompts then has nowhere left to go, and OpenRouter
///   refuses with a "data policy" error, translated here into a message that
///   names this setting so the learner knows which of the two to change.
///
/// Until 2026-09-14 ForeverLM's OpenRouter *account* excluded paid endpoints
/// that train, for every learner, and Contributor was retired as unservable.
/// The product owner wanted the model back — "even if they train on my data" — with the
/// switch as the way to keep it out of sight, so the account allows those
/// endpoints and this switch is the learner's own line. OpenRouter's request
/// fields can tighten an account policy but never loosen it, so should the
/// account ever exclude them again, the refusal ("Paid model training
/// violation (account settings)") is recognised and translated without naming
/// the switch, because the switch cannot lift it.
///
/// Foundation-only so both the Mac and the phone compile it. The Mac reads
/// `UserDefaults` (the synced preference row is hydrated there); the phone
/// reads the account row itself through `MobileModelPreferenceStore` and
/// carries the answer on its resolved route.
enum AIDataPolicy {
    /// Synced preference key. Listed in `SyncedPreferenceKeys.synced`. The
    /// name predates the hiding half of the switch and stays so the row keeps
    /// syncing between builds.
    static let denyDataCollectionKey = "aiPrivacy.denyDataCollection"

    /// The value OpenRouter's `provider.data_collection` takes when hosts that
    /// may store or train on prompts are excluded.
    static let openRouterDenyValue = "deny"

    /// Whether the switch is on, as this device last saw it. On the Mac the
    /// synced row lands in `UserDefaults`, so this is the account's answer; the
    /// phone does not rely on it and reads the row directly.
    static var deniesDataCollection: Bool {
        UserDefaults.standard.bool(forKey: denyDataCollectionKey)
    }

    /// The same switch, read for what it hides: models whose hosts train.
    static var hidesTrainingModels: Bool { deniesDataCollection }

    // MARK: - Models that train

    /// OpenRouter slugs known to train before any catalog read has answered,
    /// so a fresh install labels them from its first launch. Contributor is
    /// Meta's discounted tier, priced for training consent; 1.3 Contributor
    /// (2026-09-28) is the same tier, on Meta's one endpoint. Every other
    /// model that trains is learnt from OpenRouter (`observedTrainingSlugs`):
    /// until 2026-09-28 this list was the whole answer, and the free
    /// Nemotrons and Inklings, whose one host trains, went unlabelled.
    static let trainingModelSlugs: Set<String> = [
        "meta/muse-spark-1.2-contributor",
        "meta/muse-spark-1.3-contributor",
    ]

    /// Whether a model, named by the slug the managed rail requests from
    /// OpenRouter, is served by a host that trains on prompts: one pinned
    /// above, or one the last catalog read said trains.
    static func trainsOnInputs(modelSlug: String) -> Bool {
        let slug = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trainingModelSlugs.contains(slug) || observedTrainingSlugs.contains(slug)
    }

    /// Device-local, like the directory's other capability tables: every
    /// device reads the same catalog.
    static let observedTrainingSlugsKey = "aiPrivacy.openRouterTrainingSlugs"
    private static let observedTrainingLock = NSLock()
    nonisolated(unsafe) private static var observedTrainingCache: Set<String>?

    /// The variants whose endpoint OpenRouter's catalog marks as training
    /// (`endpoint.data_policy.training`), as its last read found them. The
    /// public API publishes no data policy (checked 2026-09-14); the catalog
    /// behind openrouter.ai's model pages does, for the endpoint it lists
    /// first. That is exact for a variant with one host, which is every one
    /// that trains today; one whose first host trains while another does not
    /// is labelled, and hidden by the switch, all the same.
    static var observedTrainingSlugs: Set<String> {
        observedTrainingLock.withLock { loadedObservedTrainingSlugs() }
    }

    /// Stores a catalog read's answer in place of the last one. Returns
    /// whether it changed, so the pickers rebuild only when a label moved.
    @discardableResult
    static func recordObservedTrainingSlugs(_ slugs: Set<String>) -> Bool {
        let normalized = Set(slugs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let changed: Bool = observedTrainingLock.withLock {
            guard loadedObservedTrainingSlugs() != normalized else { return false }
            observedTrainingCache = normalized
            return true
        }
        guard changed else { return false }
        UserDefaults.standard.set(normalized.sorted(), forKey: observedTrainingSlugsKey)
        return true
    }

    /// Caller holds `observedTrainingLock`. Nothing stored reads as none.
    private static func loadedObservedTrainingSlugs() -> Set<String> {
        if let observedTrainingCache { return observedTrainingCache }
        let stored = Set(UserDefaults.standard.stringArray(forKey: observedTrainingSlugsKey) ?? [])
        observedTrainingCache = stored
        return stored
    }

    // MARK: - Request shaping

    /// Adds `provider.data_collection = "deny"` to an OpenRouter chat body,
    /// keeping any provider preferences already present. The proxy preserves
    /// the field and adds its own routing invariants beside it.
    static func applyDenyDataCollection(to payload: inout [String: Any]) {
        var provider = payload["provider"] as? [String: Any] ?? [:]
        provider["data_collection"] = openRouterDenyValue
        payload["provider"] = provider
    }

    /// Whether a body already carries the deny preference.
    static func payloadDeniesDataCollection(_ payload: [String: Any]) -> Bool {
        (payload["provider"] as? [String: Any])?["data_collection"] as? String == openRouterDenyValue
    }

    // MARK: - Refusals

    /// Whether a provider error is OpenRouter saying no host met the data
    /// policy. OpenRouter phrases it as a 404, "No endpoints found matching
    /// your data policy"; the match is on the words, not the status, so a
    /// reworded message that still names the policy keeps translating.
    static func isDataPolicyRefusal(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if lowered.contains("data policy") || lowered.contains("data_collection") { return true }
        return lowered.contains("no endpoints") && lowered.contains("data")
    }

    /// Whether a provider error is OpenRouter saying the model's only hosts
    /// train on prompts and the account forbids that. OpenRouter phrases it
    /// "Paid model training violation (account settings): 1 endpoint
    /// excluded", inside a sentence that also says "data policy", so callers
    /// test this first: the switch is not the way out of this one.
    static func isTrainingPolicyRefusal(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if lowered.contains("training violation") { return true }
        return lowered.contains("model training") && lowered.contains("account settings")
    }

    /// The message shown when the router's account, not the switch, excluded
    /// every host: what the model does with prompts, that the router refused
    /// it, and the provider's own words last.
    static func trainingRefusalExplanation(providerMessage: String?) -> String {
        var text = "This model is served only by hosts that train on what you send them, "
            + "and ForeverLM's router refused it. Pick another model."
        if let providerMessage, !providerMessage.isEmpty {
            text += " The provider said: \(providerMessage)"
        }
        return text
    }

    /// The message shown for a data-policy refusal: what happened, the two ways
    /// out, and the provider's own words last so nothing is hidden.
    static func refusalExplanation(providerMessage: String?) -> String {
        var text = "No provider serves this model without keeping your data, and "
            + "“\(switchTitle)” is on. Pick another model, or turn the switch off "
            + "under \(settingsLocation)."
        if let providerMessage, !providerMessage.isEmpty {
            text += " The provider said: \(providerMessage)"
        }
        return text
    }

    // MARK: - Copy shared by the Mac and phone Settings

    static let switchTitle = "Don't show models that train on my data"

    /// Where the switch lives on the Mac; the phone's Settings has one screen.
    static let settingsLocation = "Settings → Data & Privacy"

    /// Said in Get Started's "Your data" row (product owner, 2026-09-27): the
    /// choice is OpenRouter's account setting, linked beside this, and what
    /// it costs. A request cannot loosen it.
    static let openRouterAccountNote =
        "To use only models that do not train on your data, turn off the free and paid endpoints that may train on your inputs in OpenRouter's privacy settings. Most free models then stop working."

    static let switchExplanation =
        "Models whose hosts train on what you send them, such as Muse Spark 1.2 Contributor, leave the model pickers, "
        + "and models served through OpenRouter are routed only to hosts that neither keep prompts nor train on them. "
        + "A model with no such host refuses and says so. "
        + "First-party models are governed by their makers' API terms, which this switch does not change."
}

/// The routing preference every standard-speed OpenRouter chat body carries,
/// beside the data-policy switch: the model's fastest endpoint, among those
/// that cache the prompt. OpenRouter's default weighs endpoints by price, which
/// on an open-weight model with thirty hosts lands on the cheapest and slowest
/// of them (GLM 5.3 Flash, 2026-09-22: 49 s of thinking on a $0.10/M host).
/// The price is whatever the chosen endpoint charges, read back from the
/// generation record, so the ledgers stay exact.
enum OpenRouterRoutePreference {
    static let sort = "throughput"
    /// For a request the learner waits on to its first word (speaking to the
    /// canvas): the endpoint quickest to answer.
    static let interactiveSort = "latency"

    /// Adds `provider.sort`, and `provider.only` when `cachingEndpointTags`
    /// names the endpoints that cache. A Speed pick is left alone: it names
    /// its tier endpoint in `provider.order`, which outranks any sort. `only`
    /// is withheld while the data-policy switch is on — OpenRouter publishes
    /// no per-endpoint data policy, so the two filters could leave no endpoint,
    /// and OpenRouter fails that send with a 404.
    ///
    /// `regionEndpointTags` are the endpoints of a model set to run only on
    /// hosts in one region (`OpenRouterHostPreference.region`). They bound
    /// every route, a pinned host's and the data-policy switch's included:
    /// `only` is those endpoints, narrowed to the ones that cache when some
    /// do. A send the filters leave no host for fails and says so; it never
    /// leaves the region.
    static func applyFastestCachingRoute(
        to payload: inout [String: Any],
        cachingEndpointTags: [String]? = nil,
        regionEndpointTags: [String]? = nil
    ) {
        var provider = payload["provider"] as? [String: Any] ?? [:]
        let deniesDataCollection = AIDataPolicy.payloadDeniesDataCollection(payload)
        let confinedToRegion = !(regionEndpointTags ?? []).isEmpty
        if let regionEndpointTags, confinedToRegion {
            provider["only"] = OpenRouterRegionalEndpoints.narrowing(
                regionEndpointTags,
                toCaching: deniesDataCollection ? nil : cachingEndpointTags
            )
        }
        if let order = provider["order"] as? [String], !order.isEmpty {
            if confinedToRegion { payload["provider"] = provider }
            return
        }
        // A task set to its model's cheapest host has already asked for price.
        if provider["sort"] == nil { provider["sort"] = sort }
        if !confinedToRegion, let cachingEndpointTags, !cachingEndpointTags.isEmpty, !deniesDataCollection {
            provider["only"] = cachingEndpointTags
        }
        payload["provider"] = provider
    }

    /// The endpoint capabilities a body depends on, named as OpenRouter's
    /// `supported_parameters` names them, so an `only` list never keeps an
    /// endpoint that would ignore or refuse the request's tools or format.
    static func requiredParameters(of payload: [String: Any]) -> Set<String> {
        var required: Set<String> = []
        if let tools = payload["tools"] as? [Any], !tools.isEmpty { required.insert("tools") }
        if payload["tool_choice"] != nil { required.insert("tool_choice") }
        if payload["response_format"] != nil { required.insert("response_format") }
        if payload["reasoning"] != nil || payload["reasoning_effort"] != nil { required.insert("reasoning") }
        return required
    }
}

// MARK: - Host per task

/// Which of a model's OpenRouter hosts serves one task (product owner, 2026-09-26:
/// "let me choose the inference provider … per task"). An open-weight model
/// has dozens of hosts at up to six times the price of the cheapest, some at
/// fp4 and some at fp8, and OpenRouter otherwise picks for us. No stored row
/// is Automatic: the fastest host that caches the prompt
/// (`OpenRouterRoutePreference`).
///
/// A row belongs to one slot of Settings › Chat and one model, so switching a
/// task to another model and back finds its host again, and a pin never rides
/// along onto a model it was not chosen for. Slots are `ModelPickerSlot` ids:
/// `chat`, `background.text`, `background.images`, `task.<AITask rawValue>`.
///
/// A row can also keep the work in one region (`region`), whichever host
/// choice it makes: only the endpoints OpenRouter lists as running there may
/// serve it (`OpenRouterRegionalEndpoints`).
struct OpenRouterHostPreference: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// The fastest host that caches the prompt, as with no row. Stored
        /// only beside a `region`, which narrows the hosts it picks from.
        case automatic
        /// OpenRouter ranks the model's hosts by price.
        case cheapest
        /// One host, named by its endpoint tag.
        case host
    }

    /// Where the hosts that may run the work are. The product owner, 2026-09-28: the
    /// recommended chat model only "if it's actually being run on the American
    /// Inference Cloud … I don't want the data to go to China". An open-weight
    /// model is served by dozens of hosts, some of them in China (GLM 5.3
    /// Flash's include Z.AI, SiliconFlow and StreamLake), and OpenRouter
    /// otherwise picks among all of them.
    enum Region: String, Codable, Sendable, CaseIterable {
        case us

        /// "the US", for sentences.
        var name: String {
            switch self {
            case .us: "the US"
            }
        }

        /// "US", before "hosts".
        var shortName: String {
            switch self {
            case .us: "US"
            }
        }

        /// OpenRouter's in-region domain, whose directory lists only the
        /// endpoints it has onboarded as running in the region.
        var directoryHost: String {
            switch self {
            case .us: "us.openrouter.ai"
            }
        }
    }

    let mode: Mode
    /// The endpoint tag for `.host`, as OpenRouter lists it ("deepinfra/fp4").
    let tag: String?
    /// Whether OpenRouter may move a `.host` request to another of the model's
    /// hosts when the pinned one refuses. Off, the request fails instead.
    let allowsFallback: Bool
    /// The host's name as OpenRouter shows it ("DeepInfra"), for the sheet's
    /// sidebar; routing reads only `tag`.
    let hostName: String?
    /// Nil: any host OpenRouter lists for the model.
    let region: Region?

    init(mode: Mode, tag: String? = nil, hostName: String? = nil, allowsFallback: Bool = true, region: Region? = nil) {
        self.mode = mode
        self.tag = mode == .host ? tag : nil
        self.hostName = mode == .host ? hostName : nil
        self.allowsFallback = allowsFallback
        self.region = region
    }

    /// "DeepInfra", "Cheapest provider", "US providers", or "Cheapest US
    /// provider": OpenRouter's word, and the product owner's, for who runs a model.
    var label: String {
        switch (mode, region) {
        case (.automatic, let region?): "\(region.shortName) providers"
        case (.automatic, nil): "Automatic"
        case (.cheapest, let region?): "Cheapest \(region.shortName) provider"
        case (.cheapest, nil): "Cheapest provider"
        case (.host, _): hostName ?? tag ?? "One provider"
        }
    }

    /// The same host choice in another region, or in none. Nil when what is
    /// left is Automatic everywhere, which is no row.
    func inRegion(_ region: Region?) -> OpenRouterHostPreference? {
        let moved = OpenRouterHostPreference(
            mode: mode, tag: tag, hostName: hostName, allowsFallback: allowsFallback, region: region
        )
        return moved.isValid ? moved : nil
    }

    static let keyPrefix = "aiHost."

    static func key(slot: String, slug: String) -> String {
        "\(keyPrefix)\(slot)|\(slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func stored(slot: String, slug: String) -> OpenRouterHostPreference? {
        UserDefaults.standard.string(forKey: key(slot: slot, slug: slug)).flatMap(decoded)
    }

    /// A stored row's JSON text, as the Mac writes it and the phone reads it
    /// from the account's preference record. Nil when it is not a valid row.
    static func decoded(_ text: String) -> OpenRouterHostPreference? {
        guard let data = text.data(using: .utf8),
              let preference = try? JSONDecoder().decode(OpenRouterHostPreference.self, from: data),
              preference.isValid
        else { return nil }
        return preference
    }

    /// The first slot in `slots` with a row for this model.
    static func stored(slots: [String], slug: String) -> OpenRouterHostPreference? {
        for slot in slots {
            if let preference = stored(slot: slot, slug: slug) { return preference }
        }
        return nil
    }

    var isValid: Bool {
        switch mode {
        case .automatic: region != nil
        case .cheapest: true
        case .host: !(tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The slots a model is chosen in for everything that runs on it: the
    /// chat and the two Background defaults.
    static let sharedSlots = ["chat", "background.text", "background.images"]

    /// The region a request for one model keeps to, from the rows `row`
    /// reads for that model. A row in `ownSlots`, the slots of the work being
    /// served, decides. Work with none there follows any region the model is
    /// kept in where it is chosen (`sharedSlots`), so a model kept in the US
    /// does not leave it through work that has no slot of its own: a chat's
    /// title, or a task Settings does not list. A task on the chat's route
    /// (Deep Research, Source Discovery) has the chat's slot as its own
    /// (`AIService.openRouterHostSlots(forTaskLabel:)`).
    static func region(ownSlots: [String], row: (String) -> OpenRouterHostPreference?) -> Region? {
        for slot in ownSlots {
            if let preference = row(slot) { return preference.region }
        }
        for slot in sharedSlots {
            if let region = row(slot)?.region { return region }
        }
        return nil
    }

    #if os(macOS)
    /// The phone compiles this file without `PreferenceStore`. Nil is Automatic.
    static func set(_ preference: OpenRouterHostPreference?, slot: String, slug: String) {
        let key = key(slot: slot, slug: slug)
        guard let preference, preference.isValid,
              let data = try? JSONEncoder().encode(preference),
              let text = String(data: data, encoding: .utf8)
        else {
            PreferenceStore.remove(forKey: key)
            return
        }
        PreferenceStore.set(text, forKey: key)
    }
    #endif

    /// Puts the choice on an OpenRouter body. A pinned host names its tag in
    /// `provider.order`, which outranks the fastest-host sort; the proxy keeps
    /// the fallback choice for a host, and forces it off only for a lab's
    /// service tier (fast, flex, priority). The region is not applied here: it
    /// needs the model's endpoints in it, which
    /// `OpenRouterRoutePreference.applyFastestCachingRoute` takes.
    func apply(to payload: inout [String: Any]) {
        var provider = payload["provider"] as? [String: Any] ?? [:]
        switch mode {
        case .automatic:
            return
        case .cheapest:
            provider["sort"] = "price"
        case .host:
            guard let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { return }
            provider["order"] = [tag]
            provider["allow_fallbacks"] = allowsFallback
        }
        payload["provider"] = provider
    }
}

// MARK: - Hosts in one region

/// The endpoints OpenRouter itself lists as running in a region: its
/// in-region domain's directory (`us.openrouter.ai/api/v1/models/{slug}/endpoints`),
/// which holds only endpoints "whose provider infrastructure is located in
/// that region" (OpenRouter's In-Region Routing guide). Sending to that
/// domain needs an OpenRouter Business plan, so requests still go to the
/// global one, confined to these endpoints by `provider.only`. Checked
/// 2026-09-28: the global directory lists 34 hosts for GLM 5.3 Flash, among
/// them Z.AI, SiliconFlow and StreamLake; the US one lists four (Sail
/// Research us, DeepInfra fp4, BaseTen fp8, Fireworks us).
///
/// A tag can name two endpoints of one host on the global domain (BaseTen
/// lists `baseten/fp8` twice), so `only` can admit the same host's other
/// endpoint under that name; it never admits another host.
///
/// Memory only, like `OpenRouterEndpointTierCatalog`. A read that fails keeps
/// the list OpenRouter last gave for the model; with none, a request that
/// needs one is not sent (`Failure.unknown`).
actor OpenRouterRegionalEndpoints {
    static let shared = OpenRouterRegionalEndpoints()

    typealias Region = OpenRouterHostPreference.Region

    struct Endpoint: Sendable, Equatable {
        /// The endpoint tag, as `provider.only` takes it ("fireworks/us").
        let tag: String
        let providerName: String
        let supportsTools: Bool
        /// USD per 1M tokens; nil when the row did not say.
        let inputUSDPerMTokens: Double?
        let outputUSDPerMTokens: Double?
    }

    enum Failure: LocalizedError, Equatable {
        /// The region's list for the model could not be read.
        case unknown(model: String, region: Region)
        /// OpenRouter lists no endpoint for the model in the region.
        case noHost(model: String, region: Region)

        var errorDescription: String? {
            switch self {
            case .unknown(let model, let region):
                "\(model) is set to run only on providers in \(region.name), and OpenRouter's list of them could not be read, so nothing was sent. Try again in a moment."
            case .noHost(let model, let region):
                "\(model) is set to run only on providers in \(region.name), and OpenRouter lists none there now, so nothing was sent. Choose another model, or let this one use any provider in its provider settings."
            }
        }
    }

    private struct Entry {
        let endpoints: [Endpoint]
        let fetchedAt: Date
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()
    private static let freshnessInterval: TimeInterval = 30 * 60

    private var inFlight: [String: Task<[Endpoint], Error>] = [:]

    private static func key(_ slug: String, _ region: Region) -> String {
        "\(region.rawValue)|\(slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// The region's endpoints for a model, from what has been read already.
    /// Nil until a read, which is not the same as none (`[]`).
    nonisolated static func cachedEndpoints(slug: String, region: Region) -> [Endpoint]? {
        lock.withLock { entries[key(slug, region)]?.endpoints }
    }

    nonisolated static func cachedTags(slug: String, region: Region) -> [String]? {
        cachedEndpoints(slug: slug, region: region)?.map(\.tag)
    }

    /// Tests seed the cache through this.
    nonisolated static func cache(_ endpoints: [Endpoint], slug: String, region: Region, at date: Date = Date()) {
        lock.withLock { entries[key(slug, region)] = Entry(endpoints: endpoints, fetchedAt: date) }
    }

    nonisolated static func clearCacheForTesting() {
        lock.withLock { entries = [:] }
    }

    /// The region's endpoints for a model, read again once the last read is
    /// half an hour old. A read that fails falls back to the last list
    /// OpenRouter gave, never to one made up.
    func endpoints(for slug: String, region: Region) async throws -> [Endpoint] {
        let key = Self.key(slug, region)
        let cached = Self.lock.withLock { Self.entries[key] }
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.freshnessInterval {
            return cached.endpoints
        }
        if let task = inFlight[key] { return try await task.value }
        let task = Task<[Endpoint], Error> { try await Self.fetch(slug: slug, region: region) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let endpoints = try await task.value
            Self.cache(endpoints, slug: slug, region: region)
            return endpoints
        } catch {
            if let cached { return cached.endpoints }
            throw Failure.unknown(model: slug, region: region)
        }
    }

    private static func fetch(slug: String, region: Region) async throws -> [Endpoint] {
        let path = slug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "https://\(region.directoryHost)/api/v1/models/\(path)/endpoints") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The in-region directory answers 404 for a model it has no endpoint of.
        if status == 404 { return [] }
        guard (200...299).contains(status) else { throw URLError(.badServerResponse) }
        guard let endpoints = parse(data) else { throw URLError(.cannotParseResponse) }
        return endpoints
    }

    /// Nil when the body is not an endpoints listing, so a changed shape is
    /// a failed read rather than an empty region.
    static func parse(_ data: Data) -> [Endpoint]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let rows = payload["endpoints"] as? [[String: Any]]
        else { return nil }
        func usdPerMTokens(_ value: Any?) -> Double? {
            let perToken: Double?
            if let string = value as? String { perToken = Double(string) }
            else if let number = value as? NSNumber { perToken = number.doubleValue }
            else { perToken = nil }
            guard let perToken, perToken.isFinite, perToken >= 0 else { return nil }
            return (perToken * 1_000_000 * 1_000_000).rounded() / 1_000_000
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let tag = (row["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !tag.isEmpty, seen.insert(tag).inserted
            else { return nil }
            let pricing = row["pricing"] as? [String: Any]
            return Endpoint(
                tag: tag,
                providerName: row["provider_name"] as? String ?? tag,
                supportsTools: (row["supported_parameters"] as? [String])?.contains("tools") ?? false,
                inputUSDPerMTokens: usdPerMTokens(pricing?["prompt"]),
                outputUSDPerMTokens: usdPerMTokens(pricing?["completion"])
            )
        }
    }

    /// The region's endpoints that also cache the prompt, when any do; else
    /// all of them. Caching narrows the route; it never widens the region.
    static func narrowing(_ region: [String], toCaching caching: [String]?) -> [String] {
        guard let caching, !caching.isEmpty else { return region }
        let allowed = Set(region.map { $0.lowercased() })
        let both = caching.filter { allowed.contains($0.lowercased()) }
        return both.isEmpty ? region : both
    }

    /// Throws unless an OpenRouter body is confined to the region's endpoints
    /// for its model: the last check before a body for a model set to one
    /// region is sent. A body built before the list was read carries no such
    /// `only`, and is not sent.
    static func requireConfined(_ payload: [String: Any], region: Region) throws {
        guard let model = payload["model"] as? String else { return }
        guard let allowed = cachedTags(slug: model, region: region) else {
            throw Failure.unknown(model: model, region: region)
        }
        guard !allowed.isEmpty else { throw Failure.noHost(model: model, region: region) }
        let permitted = Set(allowed.map { $0.lowercased() })
        let only = ((payload["provider"] as? [String: Any])?["only"] as? [String]) ?? []
        guard !only.isEmpty, only.allSatisfy({ permitted.contains($0.lowercased()) }) else {
            throw Failure.unknown(model: model, region: region)
        }
    }
}

// MARK: - Free models

/// OpenRouter's free models: a learner may pick one for any setting, like any
/// other model, and background work starts on one (`FreeModelsSetup`). There
/// is no mode that holds every setting to them (product owner, 2026-10-11:
/// "don't do this free mode thing").
///
/// Foundation-only so both targets compile it.
enum AIFreeModels {
    /// OpenRouter names every zero-priced variant with a `:free` suffix. Its
    /// Free Models Router has no suffix but only ever routes to those models,
    /// so it is free too.
    static func isFreeModelID(_ id: String) -> Bool {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(":free") || normalized == AIModelDefaults.openRouterFreeRouter
    }

    #if os(macOS)
    /// The phone compiles this file without `AIProvider` (its routes carry
    /// their own model ids), so the provider-shaped check is the Mac's. A
    /// `:free` id the live directory now lists with a price is not free.
    static func isFreeSelection(provider: AIProvider, model: String) -> Bool {
        provider == .openRouter && isFreeModelID(model) && !AIFreeModelPrices.hasEnded(model)
    }
    #endif

    /// Where the learner allows OpenRouter's free endpoints, whose providers
    /// may train on prompts. OpenRouter refuses free models until they do.
    static let openRouterPrivacyURL = URL(string: "https://openrouter.ai/settings/privacy")!
}

/// What OpenRouter's live directory last said about its `:free` ids: whether
/// each is still priced at zero. Fed by every directory read on the Mac
/// (`AIModelPriceRefresher.ingest`) and read synchronously wherever a free
/// pick is resolved, so a model whose free period ended is not sent. Empty
/// until the first read, and on the phone.
enum AIFreeModelPrices {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var zeroPriced: [String: Bool] = [:]
    nonisolated(unsafe) private static var readWasWhole = false

    /// Replaces the table with one directory read, keyed by lowercased id.
    /// An empty read (a truncated response) keeps the previous table.
    /// `isWhole` says the read was long enough to be the whole directory, so
    /// an id it does not list has left it (`isDelisted`); a short read says
    /// nothing about absent ids.
    static func record(_ table: [String: Bool], isWhole: Bool = false) {
        guard !table.isEmpty else { return }
        let normalized = Dictionary(table.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        lock.withLock {
            zeroPriced = normalized
            readWasWhole = isWhole
        }
    }

    /// True only when the last read listed this id with a price. An id it
    /// did not list is left to OpenRouter.
    static func isListedAsPaid(_ id: String) -> Bool {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lock.withLock { zeroPriced[key] == false }
    }

    /// True when the last whole read did not list this `:free` id at all,
    /// which is how OpenRouter ends a free variant: the row goes, and a
    /// request for it is refused ("no longer free", 2026-10-29). The price
    /// watch only sees a model it recorded while it was listed, so this is
    /// what keeps a pick made after the row left from being sent.
    static func isDelisted(_ id: String) -> Bool {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.hasSuffix(":free") else { return false }
        return lock.withLock { readWasWhole && zeroPriced[key] == nil }
    }

    /// A `:free` id whose free period is over: listed with a price, or gone.
    static func hasEnded(_ id: String) -> Bool {
        isListedAsPaid(id) || isDelisted(id)
    }
}

/// Free models OpenRouter refused to run for ForeverLM because it offers them
/// only inside the apps it lists ("… is only available on agentic harnesses",
/// seen 2026-09-26 for the Inkling `:free` variants). The directory still
/// lists such a model at zero, so neither the price table nor the price watch
/// can tell; the refusal itself is the only signal. Device-local, like the
/// price table. A refusal is kept for a week and then forgotten, so a model
/// OpenRouter opens up again comes back to the pickers.
enum AIFreeModelRestrictions {
    static let recordKey = "aiFreeModelRestrictions.refusedAt.v1"
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let lock = NSLock()

    /// The `:free` id an OpenRouter refusal names as limited to its listed
    /// apps; nil for any other error.
    static func restrictedModel(inRefusal message: String) -> String? {
        let lowered = message.lowercased()
        guard lowered.contains("only available on agentic harness") else { return nil }
        let pattern = #"([A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+:free)\s+is\s+only\s+available"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message)
        else { return nil }
        return String(message[range])
    }

    /// Records a refusal. True when the model was not already recorded, so
    /// the caller moves the settings using it once, not on every failed call.
    @discardableResult
    static func record(_ id: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let key = normalized(id)
        guard !key.isEmpty else { return false }
        return lock.withLock {
            var table = current(now: now, defaults: defaults)
            let isNew = table[key] == nil
            table[key] = now.timeIntervalSince1970
            defaults.set(table, forKey: recordKey)
            return isNew
        }
    }

    static func isRestricted(_ id: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let key = normalized(id)
        return lock.withLock { current(now: now, defaults: defaults)[key] != nil }
    }

    /// The refusals younger than `retention`.
    private static func current(now: Date, defaults: UserDefaults) -> [String: Double] {
        let stored = defaults.dictionary(forKey: recordKey) as? [String: Double] ?? [:]
        let cutoff = now.timeIntervalSince1970 - retention
        return stored.filter { $0.value > cutoff }
    }

    private static func normalized(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
