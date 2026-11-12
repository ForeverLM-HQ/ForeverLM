import Combine
import Foundation
import NaturalLanguage

/// Models whose paid-generation estimate the learner has explicitly dismissed.
///
/// Suppression is keyed only by model ID. Voices are presentation choices inside
/// one billing model, so changing a voice must not bring the same price prompt
/// back. The array is sorted before persistence so two clients serialize the
/// same set identically for preference sync.
enum TextToSpeechCostConfirmationPreferences {
    static let suppressedModelIDsKey = Prefs.ReadAloud.costConfirmationSuppressedModels.name

    static var suppressedModelIDs: Set<String> {
        #if os(macOS)
        Set(Preferences.value(Prefs.ReadAloud.costConfirmationSuppressedModels) ?? [])
        #else
        Set(UserDefaults.standard.stringArray(forKey: suppressedModelIDsKey) ?? [])
        #endif
    }

    static func confirmsEstimatedCost(for modelID: String) -> Bool {
        !suppressedModelIDs.contains(modelID)
    }

    static func updatedSuppressedModelIDs(
        _ existing: Set<String>,
        confirms: Bool,
        modelID: String
    ) -> [String] {
        var models = existing
        if confirms { models.remove(modelID) }
        else if !modelID.isEmpty { models.insert(modelID) }
        return models.sorted()
    }
}

/// One voice a text-to-speech model accepts. `id` is the wire value; `name` and
/// `detail` are display only and never reach a request or a manifest.
struct ArticleSpeechVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String?
    /// ISO 3166-1 alpha-2 region for a provider-documented accent. A nil region
    /// means the voice is multilingual or the provider does not promise one.
    let regionCode: String?
    /// What this particular voice can narrate, when it is narrower than its
    /// model's. Most provider catalogs bind a voice to one language — a French
    /// voice reads English text with a French phoneme set — so the voice, not
    /// the model, is what a language check has to match. A nil value inherits
    /// the model's declaration; `.unstated` says nothing ForeverLM has read
    /// names this voice's languages.
    let languages: ArticleSpeechLanguageSupport?

    init(
        _ id: String,
        _ name: String,
        detail: String? = nil,
        regionCode: String? = nil,
        languages: ArticleSpeechLanguageSupport? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.regionCode = regionCode
        self.languages = languages
    }

    /// Nil when no country is known; a row then shows no flag at all.
    var flagEmoji: String? {
        Self.flagEmoji(forRegionCode: regionCode)
    }

    private static func flagEmoji(forRegionCode regionCode: String?) -> String? {
        let normalized = regionCode?.uppercased() ?? ""
        guard normalized.count == 2,
              normalized.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return nil
        }
        var flag = ""
        for scalar in normalized.unicodeScalars {
            guard let regionalIndicator = UnicodeScalar(127_397 + scalar.value) else { return nil }
            flag.unicodeScalars.append(regionalIndicator)
        }
        return flag
    }

    var settingsLabel: String { flagEmoji.map { "\($0) \(name)" } ?? name }
}

/// Wire formats OpenRouter's speech endpoint returns. Its API reference lists
/// `response_format: mp3 | pcm` for every speech model (checked 2026-09-27).
/// A PCM response is raw 16-bit little-endian mono samples and nothing in it
/// says how many there are to the second: Gemini and OpenAI send 24 kHz,
/// HeyGen 44.1 kHz. It is put in a playable container before it is cached or
/// synced, and a container written at another rate than the samples were made
/// at plays them at the wrong speed and pitch (HeyGen wrapped at 24 kHz ran at
/// 0.54x, nearly an octave low). So PCM is asked for only where the rate is
/// known, and the rate is part of the format; everything else is MP3, which
/// describes itself.
enum ArticleSpeechResponseFormat: Hashable, Sendable {
    case mp3
    case pcm(sampleRate: Int)

    /// What `response_format` carries in the request.
    var wireValue: String {
        switch self {
        case .mp3: return "mp3"
        case .pcm: return "pcm"
        }
    }

    var storedFileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .pcm: return "m4a"
        }
    }

    /// Samples per second of the raw PCM this format returns; nil for MP3.
    var pcmSampleRate: Int? {
        switch self {
        case .mp3: return nil
        case .pcm(let sampleRate): return sampleRate
        }
    }
}

/// One text-to-speech model ForeverLM offers for reading sources aloud, with
/// the voices that model accepts and the synthesis-unit sizes it takes.
struct ArticleSpeechModelOption: Identifiable, Hashable, Sendable {
    /// OpenRouter's slug: what every request names.
    let id: String
    let name: String
    let detail: String?
    /// Who made the model, as OpenRouter's directory names it ("Google",
    /// "Deepgram"): what Settings groups the model cards under.
    let maker: String
    /// The voices, in picker order: the ones ForeverLM curates first, then the
    /// rest of the directory's `supported_voices`. Empty when OpenRouter
    /// lists none and nothing ForeverLM has read names one; a request then
    /// leaves `voice` out, which OpenRouter's per-model reference allows for
    /// such a model (its own example request for Seed Audio sends none).
    let voices: [ArticleSpeechVoice]
    /// What this model can narrate. Required so that adding a model forces a
    /// decision about its languages rather than silently inheriting English;
    /// `.unstated` is that decision for a model nothing documents.
    let languages: ArticleSpeechLanguageSupport
    /// True when `languages` is the model's own and binds every voice — a
    /// Gemini voice is a timbre, not a language — and false when it describes
    /// only the curated voices, so a voice the directory adds beside them is
    /// `.unstated` rather than assumed to share their languages.
    let languagesCoverEveryVoice: Bool
    let responseFormat: ArticleSpeechResponseFormat
    /// Largest input one request for this model may carry. Bigger units give
    /// the voice more context for continuous prosody; too big is the request
    /// the provider rejects, so this is per model rather than global.
    let chunkLimit: Int
    /// Smaller first request, so listening starts before the whole source has
    /// been generated.
    let leadChunkLimit: Int
    /// How many of `voices`, from the front, are ForeverLM's curated voices —
    /// what the catalog-wide preview warm-up covers
    /// (`ArticleSpeechVoicePreviewRepository.previewPairs`).
    let curatedVoiceCount: Int

    init(
        id: String,
        name: String,
        detail: String?,
        maker: String,
        voices: [ArticleSpeechVoice],
        languages: ArticleSpeechLanguageSupport,
        languagesCoverEveryVoice: Bool = true,
        responseFormat: ArticleSpeechResponseFormat = .mp3,
        chunkLimit: Int,
        leadChunkLimit: Int,
        curatedVoiceCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.maker = maker
        self.voices = voices
        self.languages = languages
        self.languagesCoverEveryVoice = languagesCoverEveryVoice
        self.responseFormat = responseFormat
        self.chunkLimit = chunkLimit
        self.leadChunkLimit = leadChunkLimit
        self.curatedVoiceCount = curatedVoiceCount ?? voices.count
    }

    /// A model the overlay does not know, offered as the directory lists it
    /// and with nothing about it guessed: its languages are unstated, it is
    /// asked for MP3, and it narrates in ForeverLM's untuned units. Its price
    /// is OpenRouter's, like every model's (`OpenRouterAudioPrices`).
    ///
    /// A Fish Audio row with no voice list is the exception: a Fish request
    /// that names no reference voice is spoken by a different random speaker
    /// each time, so a paper narrated in several requests changed voice every
    /// few sentences (Drama 3 on the iPhone). It takes the Fish
    /// reference voice every other Fish model takes (`fishS21Voices`).
    init(directoryRow row: OpenRouterAudioModelRow) {
        let takesFishReference = row.supportedVoices.isEmpty
            && ArticleSpeechCatalog.isFishAudioModel(row.id)
        self.init(
            id: row.id,
            name: row.name,
            detail: nil,
            maker: row.maker,
            voices: takesFishReference
                ? ArticleSpeechCatalog.fishS21Voices
                : row.supportedVoices.map {
                    ArticleSpeechVoice($0, ArticleSpeechCatalog.listedVoiceName($0))
                },
            languages: .unstated,
            chunkLimit: ArticleSpeechCatalog.untunedChunkLimit,
            leadChunkLimit: ArticleSpeechCatalog.untunedLeadChunkLimit,
            curatedVoiceCount: takesFishReference ? nil : 0
        )
    }

    /// This option's knowledge laid over the directory's row for it: the
    /// row's maker and voice list, with the curated voices first and
    /// named as ForeverLM names them. A curated voice the row no longer lists
    /// is dropped, since OpenRouter would refuse it — unless the row lists no
    /// voices at all (Fish Audio), when the voices recorded here are the only
    /// ones anything names.
    func merged(with row: OpenRouterAudioModelRow) -> ArticleSpeechModelOption {
        let listed = row.supportedVoices
        let merged: [ArticleSpeechVoice]
        let curated: Int
        if listed.isEmpty {
            merged = voices
            curated = curatedVoiceCount
        } else {
            let listedIDs = Set(listed)
            let kept = voices.filter { listedIDs.contains($0.id) }
            let keptIDs = Set(kept.map(\.id))
            let added = listed.filter { !keptIDs.contains($0) }.map { id in
                ArticleSpeechVoice(
                    id,
                    ArticleSpeechCatalog.listedVoiceName(id),
                    languages: languagesCoverEveryVoice ? nil : .unstated
                )
            }
            merged = kept + added
            curated = kept.count
        }
        return ArticleSpeechModelOption(
            id: row.id,
            name: name,
            detail: detail,
            maker: row.maker,
            voices: merged,
            languages: languages,
            languagesCoverEveryVoice: languagesCoverEveryVoice,
            responseFormat: responseFormat,
            chunkLimit: chunkLimit,
            leadChunkLimit: leadChunkLimit,
            curatedVoiceCount: curated
        )
    }

    /// Whether this model has a voice a request can name. Every request names
    /// one: a request without a voice is spoken by whatever speaker the
    /// provider picks, which can change from one request to the next
    /// (product owner, 2026-11-11: "Make sure for every request there is a
    /// speaker actually set"). A model without one is not offered
    /// (`options(fromDirectory:)`).
    var takesVoice: Bool { !voices.isEmpty }

    /// Spoken by OpenAI through ForeverLM's proxy rather than through
    /// OpenRouter, which lists no OpenAI voice (`ArticleSpeechCatalog.openAIRealtimeModelID`).
    var speaksThroughOpenAI: Bool { id == ArticleSpeechCatalog.openAIRealtimeModelID }

    /// The model name the request carries: the OpenRouter slug, or for an
    /// OpenAI voice OpenAI's own id.
    var wireModelID: String {
        speaksThroughOpenAI ? String(id.dropFirst("openai/".count)) : id
    }

    /// Where a request for this model goes before `ManagedAI.rewrite`.
    var speechEndpoint: URL {
        speaksThroughOpenAI ? ManagedAI.openAISpeechURL : OpenRouterAPI.audioSpeech
    }

    var defaultVoiceID: String? { voices.first?.id }

    /// "30 voices · 70+ languages · long-form", for a card's help text.
    var summary: String {
        let voiceCount: String
        switch voices.count {
        case 1: voiceCount = "1 voice"
        default: voiceCount = "\(voices.count) voices"
        }
        let languages: String? = self.languages.isStated ? nil : "languages not published"
        return [voiceCount, detail, languages].compactMap { $0 }.joined(separator: " · ")
    }

    /// USD per million narrated characters, from OpenRouter's catalog, or nil
    /// when OpenRouter does not bill this model by the character (Gemini by
    /// its tokens, Seed Audio by the second of audio) or has not priced it.
    /// Nothing is converted: a per-character figure made from a token price
    /// would be a guess presented as a price.
    var ratePerMillionCharacters: Double? {
        ArticleSpeechCatalog.ratePerMillionCharacters(forModel: id)
    }

    /// The card's line, in the unit OpenRouter bills the model by: "Free",
    /// "$15 / 1M characters", "$1 / $20 per 1M tokens", "$0.15 / minute of
    /// audio" — or "Price unknown", never a guess.
    var priceLabel: String {
        ArticleSpeechCatalog.priceLabel(forModel: id)
    }

    func voice(id: String) -> ArticleSpeechVoice? {
        voices.first { $0.id == id }
    }

    /// What `voiceID` can narrate, falling back to the model's own declaration
    /// for a voice that names no language of its own — and for a nil voice, to
    /// everything the model offers across its voices.
    func languageSupport(voice voiceID: String?) -> ArticleSpeechLanguageSupport {
        guard let voiceID, let voice = voice(id: voiceID) else { return languages }
        return voice.languages ?? languages
    }

    func speaks(_ languageCode: String, voice voiceID: String?) -> Bool {
        languageSupport(voice: voiceID).speaks(languageCode)
    }

    /// Any voice of this model that narrates `languageCode`, preferring one
    /// built for that language over a multilingual generalist.
    func voice(speaking languageCode: String) -> ArticleSpeechVoice? {
        nativeVoice(speaking: languageCode)
            ?? voices.first { ($0.languages ?? languages).speaks(languageCode) }
    }

    /// A voice whose declared language list names `languageCode` — a voice the
    /// provider built for it, rather than one that merely accepts any input.
    func nativeVoice(speaking languageCode: String) -> ArticleSpeechVoice? {
        voices.first { voice in
            guard case .languages(let codes) = voice.languages ?? languages else { return false }
            return codes.contains(languageCode.lowercased())
        }
    }
}

/// Which languages a text-to-speech model or voice can actually narrate.
///
/// This is not decoration for the picker: a model handed text in a language it
/// does not speak still returns audio, and still bills for it — the words are
/// simply read with the wrong phonemes. Declaring support is what lets a
/// non-English source be routed to a voice that can read it, or the listener be
/// told before the money is spent.
enum ArticleSpeechLanguageSupport: Hashable, Sendable {
    private static let representativeRegions: [String: String] = [
        "ar": "SA", "bn": "BD", "de": "DE", "en": "GB", "es": "ES",
        "fr": "FR", "hi": "IN", "id": "ID", "it": "IT", "ja": "JP",
        "ko": "KR", "pt": "PT", "ru": "RU", "tr": "TR", "vi": "VN",
        "zh": "CN",
    ]

    /// The provider documents no language restriction and detects the input
    /// language itself.
    case multilingual
    /// Exactly these ISO 639-1 codes, lowercased.
    case languages(Set<String>)
    /// Nothing ForeverLM has read says which languages this narrates:
    /// OpenRouter's directory publishes no language list, and no curated
    /// record covers the model or voice. It is never a claim either way —
    /// not English by default (the rule is "no fallback defaults"), not a
    /// substitute for a language, and not a reason to move a listener off
    /// the voice they picked (`ArticleSpeechCatalog.LanguageFit.unverified`).
    case unstated

    /// Whether this is known to narrate `languageCode`. False for `.unstated`,
    /// which is why the language fit asks `isStated` before reading a false
    /// as "does not speak it".
    func speaks(_ languageCode: String) -> Bool {
        switch self {
        case .multilingual:
            return true
        case .languages(let codes):
            return codes.contains(languageCode.lowercased())
        case .unstated:
            return false
        }
    }

    var isStated: Bool {
        if case .unstated = self { return false }
        return true
    }

    /// A compact flag for a voice picker. A provider-documented region remains
    /// more specific and wins at the call site. A single-language voice uses a
    /// conventional flag for that language; multilingual, multi-language and
    /// unstated voices have no flag.
    var flagEmoji: String? {
        guard case .languages(let codes) = self,
              codes.count == 1,
              let code = codes.first else {
            return nil
        }
        guard let region = Self.representativeRegions[code.lowercased()] else { return nil }
        return ArticleSpeechVoice("", "", regionCode: region).flagEmoji
    }
}

// MARK: - OpenRouter's audio directories

/// One row of OpenRouter's speech or transcription directory
/// (`GET /api/v1/models?output_modalities=speech|transcription`, public, no
/// key), trimmed to what the catalogs read. Codable so the last read survives
/// a relaunch. Its `pricing` is left out on purpose: the directory prints the
/// numbers without their unit, which differs by model (seconds of audio for
/// Parakeet, hours for MAI-Transcribe), and can quote a host requests do not
/// go to; prices come from `OpenRouterAudioPrices`.
struct OpenRouterAudioModelRow: Codable, Equatable, Sendable {
    /// The slug a request names.
    let id: String
    /// The directory's name without its "Maker: " prefix.
    let name: String
    /// The prefix OpenRouter puts before the name ("Google"), or the slug's
    /// author when the name has none.
    let maker: String
    /// When OpenRouter first listed the model.
    let created: Date?
    /// `supported_voices`, in the directory's order; empty when it lists none.
    let supportedVoices: [String]
}

extension Notification.Name {
    /// Posted on the main thread when a read changed what a speech or
    /// transcription picker lists or the prices it shows; `object` is the
    /// kind's raw value, or "prices".
    static let openRouterAudioDirectoryDidChange = Notification.Name(
        "openRouterAudioDirectoryDidChange"
    )
}

/// OpenRouter's speech and transcription directories, read live and shared by
/// both platforms (product owner, 2026-09-27: "show all models at
/// https://openrouter.ai/models?output_modalities=speech and
/// https://openrouter.ai/models?output_modalities=transcription").
///
/// Event-driven, like the text directory (`OpenRouterCatalogAvailability`): a
/// read happens when something needs the list — a Settings pane opening, a
/// request about to be built, the voice-sample warm-up — never on a timer, at
/// most once per `freshness` unless a pane asks again, and only one at a time
/// per kind. Every read runs off the main actor. The last good read is kept
/// in `UserDefaults` (device-local; the list is OpenRouter's, not the
/// learner's), so a model picked from it is still known at the next launch
/// before the network answers — as `AIProviderPricing` keeps the text
/// directory's prices.
///
/// Unit tests never see either: a hosted test bundle would otherwise inherit
/// whatever list this Mac last read, and the catalogs' tests pin the models
/// this build records. The merge itself is pure and tested from fixtures
/// (`ArticleSpeechCatalog.options(fromDirectory:)`).
enum OpenRouterAudioDirectory {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case speech
        case transcription

        var url: URL {
            OpenRouterAPI.models(outputModality: rawValue)
        }
    }

    /// Where a pane stands with one directory, so it says it is reading or
    /// that the read failed instead of showing a list as if it were current.
    enum ReadState: Equatable, Sendable {
        case reading
        case read
        case failed(String)
    }

    enum Failure: LocalizedError, Equatable, Sendable {
        case unreachable(String)
        case unreadable
        case empty
        case unitTests

        var errorDescription: String? {
            switch self {
            case .unreachable(let reason):
                return "OpenRouter's model list could not be read: \(reason)"
            case .unreadable:
                return "OpenRouter's answer was not the model list ForeverLM reads."
            case .empty:
                return "OpenRouter's model list came back empty."
            case .unitTests:
                return "Unit tests do not read OpenRouter's model list."
            }
        }
    }

    /// How long a read answers for without being repeated. A pane opening
    /// after this reads again; a request being built only starts a
    /// background read (`prepare`).
    static let freshness: TimeInterval = 30 * 60

    private struct Entry {
        var rows: [OpenRouterAudioModelRow]?
        var readAt: Date?
        var loadedPersisted = false
        /// Bumped whenever `rows` changes, so derived lists are rebuilt once.
        var generation: UInt64 = 0
    }

    private static let lock = AppLock()
    nonisolated(unsafe) private static var entries: [Kind: Entry] = [:]

    fileprivate static let isRunningUnitTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private static func rowsKey(_ kind: Kind) -> DeviceKey<Data?> {
        switch kind {
        case .speech: return Prefs.ReadAloud.speechDirectoryRows
        case .transcription: return Prefs.ReadAloud.transcriptionDirectoryRows
        }
    }

    private static func readAtKey(_ kind: Kind) -> DeviceKey<Date?> {
        switch kind {
        case .speech: return Prefs.ReadAloud.speechDirectoryReadAt
        case .transcription: return Prefs.ReadAloud.transcriptionDirectoryReadAt
        }
    }

    /// The last read's rows — this launch's, or the one kept from an earlier
    /// launch — or nil when the directory has never been read on this device.
    static func rows(_ kind: Kind) -> [OpenRouterAudioModelRow]? {
        snapshot(kind).rows
    }

    /// The rows with the generation they belong to, read together.
    static func snapshot(_ kind: Kind) -> (rows: [OpenRouterAudioModelRow]?, generation: UInt64) {
        guard !isRunningUnitTests else { return (nil, 0) }
        ensurePersistedLoaded(kind)
        return lock.withLock {
            let entry = entries[kind]
            // A subsidized account sees only what its access covers (`AIModelAccess`).
            return (entry?.rows?.filter { AIModelAccess.allows(slug: $0.id) }, entry?.generation ?? 0)
        }
    }

    /// Whether the last read is recent enough to answer without another.
    static func isFresh(_ kind: Kind, now: Date = Date()) -> Bool {
        guard !isRunningUnitTests else { return false }
        ensurePersistedLoaded(kind)
        return lock.withLock {
            guard let entry = entries[kind], entry.rows != nil, let readAt = entry.readAt else { return false }
            return now.timeIntervalSince(readAt) < freshness
        }
    }

    /// Reads the directory unless the last read is fresh (`force` reads
    /// anyway), keeps what it read, and returns it. OpenRouter's prices for
    /// the models are read beside it (`OpenRouterAudioPrices`); a price read
    /// that fails leaves "Price unknown", not a failed list. Callers waiting
    /// on one read in flight share it.
    @discardableResult
    static func refresh(_ kind: Kind, force: Bool = false) async throws -> [OpenRouterAudioModelRow] {
        async let prices: Void = OpenRouterAudioPrices.refresh(force: force)
        let rows = try await OpenRouterAudioDirectoryLoader.shared.rows(kind, force: force)
        await prices
        return rows
    }

    /// For a request about to be built, or a price about to be quoted:
    /// returns at once when this launch or an earlier one has read the
    /// directory and the prices (starting a background re-read when a read
    /// is stale), and otherwise waits for one read of each. Never throws: a
    /// failed read leaves the catalog on what this build records, and a
    /// request for a model outside it is refused by its builder in words that
    /// say so; an unread price is "unknown".
    static func prepare(_ kind: Kind) async {
        async let prices: Void = OpenRouterAudioPrices.prepare()
        if rows(kind) != nil {
            if !isFresh(kind) { warm(kind) }
        } else {
            _ = try? await OpenRouterAudioDirectoryLoader.shared.rows(kind, force: false)
        }
        await prices
    }

    /// Starts a read in the background when the last one is stale. Returns
    /// immediately; safe from a view's `onAppear`.
    static func warm(_ kind: Kind) {
        guard !isRunningUnitTests else { return }
        Task.detached(priority: .utility) {
            _ = try? await refresh(kind)
        }
    }

    /// The rows of one directory response. Pure, so the parse is tested on
    /// fixtures. A row whose output is not `kind` is skipped (the query
    /// filters by it, but a directory that grows a mixed row loses that row,
    /// not the list), as are OpenRouter's "~" rolling aliases.
    static func rows(fromDirectory data: Data, kind: Kind) throws -> [OpenRouterAudioModelRow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        func usd(_ value: Any?) -> Double? {
            if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
            return (value as? NSNumber)?.doubleValue
        }
        var seen = Set<String>()
        return rows.compactMap { row -> OpenRouterAudioModelRow? in
            guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, !id.hasPrefix("~"), seen.insert(id.lowercased()).inserted else { return nil }
            if let architecture = row["architecture"] as? [String: Any],
               let outputs = architecture["output_modalities"] as? [String],
               !outputs.isEmpty, !outputs.contains(kind.rawValue) {
                return nil
            }
            let rawName = ((row["name"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = rawName.components(separatedBy: ": ")
            let author = id.split(separator: "/").first.map(String.init) ?? id
            let maker = parts.count > 1 ? parts[0] : author
            let name = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : rawName
            let created = usd(row["created"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            var voices: [String] = []
            for voice in (row["supported_voices"] as? [String]) ?? [] {
                let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !voices.contains(trimmed) { voices.append(trimmed) }
            }
            return OpenRouterAudioModelRow(
                id: id,
                name: name.isEmpty ? rawName : name,
                maker: maker.isEmpty ? author : maker,
                created: created,
                supportedVoices: voices
            )
        }
    }

    /// One network read, off the main actor.
    fileprivate static func fetch(_ kind: Kind) async throws -> [OpenRouterAudioModelRow] {
        guard !isRunningUnitTests else { throw Failure.unitTests }
        var request = URLRequest(url: kind.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.foreverLMData(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.unreachable("OpenRouter answered HTTP \(http.statusCode).")
        }
        let rows = try rows(fromDirectory: data, kind: kind)
        // An empty parse (schema drift, a truncated body) must not replace a
        // good list with nothing.
        guard !rows.isEmpty else { throw Failure.empty }
        return rows
    }

    /// Keeps a good read, in memory and for the next launch, and tells the
    /// pickers when it changed what they list.
    fileprivate static func store(_ rows: [OpenRouterAudioModelRow], kind: Kind) {
        let now = Date()
        ensurePersistedLoaded(kind)
        let changed: Bool = lock.withLock {
            var entry = entries[kind] ?? Entry()
            entry.loadedPersisted = true
            let changed = entry.rows != rows
            entry.rows = rows
            entry.readAt = now
            if changed { entry.generation &+= 1 }
            entries[kind] = entry
            return changed
        }
        if let data = try? JSONEncoder().encode(rows) {
            Preferences.set(data, for: rowsKey(kind))
        }
        Preferences.set(now, for: readAtKey(kind))
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openRouterAudioDirectoryDidChange, object: kind.rawValue)
        }
    }

    /// Adopts the read an earlier launch kept, once. Defaults are read here,
    /// outside `lock`; only the adoption happens under it.
    private static func ensurePersistedLoaded(_ kind: Kind) {
        let alreadyLoaded = lock.withLock { entries[kind]?.loadedPersisted ?? false }
        guard !alreadyLoaded else { return }
        var persisted: (rows: [OpenRouterAudioModelRow], readAt: Date?)?
        if let data = Preferences.value(rowsKey(kind)),
           let rows = try? JSONDecoder().decode([OpenRouterAudioModelRow].self, from: data),
           !rows.isEmpty {
            persisted = (rows, Preferences.value(readAtKey(kind)))
        }
        lock.withLock {
            var entry = entries[kind] ?? Entry()
            guard !entry.loadedPersisted else { return }
            entry.loadedPersisted = true
            if entry.rows == nil, let persisted {
                entry.rows = persisted.rows
                entry.readAt = persisted.readAt
                entry.generation &+= 1
            }
            entries[kind] = entry
        }
    }
}

/// Coalesces directory and price reads: one in flight per kind, and one for
/// the prices, shared by every caller.
private actor OpenRouterAudioDirectoryLoader {
    static let shared = OpenRouterAudioDirectoryLoader()

    private var inFlight: [OpenRouterAudioDirectory.Kind: Task<[OpenRouterAudioModelRow], Error>] = [:]
    private var pricesInFlight: Task<OpenRouterAudioPrices.Table, Error>?

    func prices(force: Bool) async {
        if !force, OpenRouterAudioPrices.isFresh { return }
        if let running = pricesInFlight {
            _ = try? await running.value
            return
        }
        let task = Task.detached(priority: .utility) {
            try await OpenRouterAudioPrices.fetch()
        }
        pricesInFlight = task
        defer { pricesInFlight = nil }
        // A catalog read that fails or parses to nothing keeps the last table.
        if let table = try? await task.value, !table.isEmpty {
            OpenRouterAudioPrices.store(table)
        }
    }

    func rows(_ kind: OpenRouterAudioDirectory.Kind, force: Bool) async throws -> [OpenRouterAudioModelRow] {
        if !force, OpenRouterAudioDirectory.isFresh(kind), let rows = OpenRouterAudioDirectory.rows(kind) {
            return rows
        }
        if let running = inFlight[kind] { return try await running.value }
        let task = Task.detached(priority: .utility) {
            try await OpenRouterAudioDirectory.fetch(kind)
        }
        inFlight[kind] = task
        defer { inFlight[kind] = nil }
        let rows = try await task.value
        OpenRouterAudioDirectory.store(rows, kind: kind)
        return rows
    }
}

/// What OpenRouter charges for its speech and transcription models, in the
/// unit it bills each one by. Every speech and transcription price the apps
/// show comes from here, and so does the estimate a usage row gets when its
/// response reported no cost. The product owner, 2026-09-26: "you should always just
/// pull the price from OpenRouter. It should never be wrong. It never have
/// hard-coded prices."
///
/// The source is the catalog openrouter.ai's own model pages draw from
/// (`/api/frontend/v1/catalog/models`), not the public directory, for two
/// reasons: the directory's `pricing.prompt`
/// carries no unit, and the unit differs by model — seconds of audio for
/// Parakeet, hours for MAI-Transcribe (read as seconds, $0.36 became $1,296
/// an hour); and where a model has several hosts the directory can quote one
/// requests do not go to (Kokoro at Together's $4 per million characters
/// while OpenRouter routes it to DeepInfra at $0.62).
/// Each catalog row names the endpoint OpenRouter routes to and prices it
/// with an explicit unit (`display_pricing`): per second, minute or hour of
/// audio, per character, per UTF-8 byte, or per input and output token. A
/// model billed another way has no per-character or per-hour price, and none
/// is made up for it — not even from a token rate: its label quotes its own
/// unit. The catalog is OpenRouter's own site's, not a documented API, so a
/// row whose price this does not understand is left out (unknown, never
/// zero) and a read that parses to nothing keeps the last good table.
///
/// Compiled into both apps. The Mac folds it into the text directory read it
/// already makes (`AIService.listOpenRouterModelDirectory`); both read it
/// beside the speech and transcription directories
/// (`OpenRouterAudioDirectory.refresh`, `prepare`). The table persists in
/// `UserDefaults` as a cache of the last read; unit tests never see it and pin
/// their own with `$pinnedTable`.
enum OpenRouterAudioPrices {
    struct Price: Codable, Equatable, Sendable {
        /// What one unit of `rate` buys.
        enum Unit: String, Codable, Sendable {
            /// A second of audio: heard, for a transcription model; spoken,
            /// for a speech model billed by its output.
            case audioSecond
            case character
            case utf8Byte
            /// An input token; `outputRate` prices an output token.
            case token
        }

        let kind: OpenRouterAudioDirectory.Kind
        let unit: Unit
        /// USD per unit.
        let rate: Double
        /// USD per output token, for `.token`.
        var outputRate: Double?
        /// The endpoint's promotion in basis points (5,000 for 50% off), nil
        /// for none. `rate` already includes it, as the catalog quotes it;
        /// Settings strikes the list figure through beside it.
        var discountBasisPoints: Int?

        var isFree: Bool { rate == 0 && (outputRate ?? 0) == 0 }
    }

    /// Lowercased slug (`:free` variants under their own id) → price.
    typealias Table = [String: Price]

    static let catalogURL = OpenRouterAPI.frontendCatalogModels

    /// What a price label says when OpenRouter has not priced a model in a
    /// unit ForeverLM reads: never blank, which reads as free.
    static let unknownPriceLabel = "Price unknown"

    /// A table a test runs against. Task-local, so parallel tests cannot see
    /// each other's.
    @TaskLocal static var pinnedTable: Table?

    /// The table every lookup reads: a test's pinned one, else the last read.
    static var current: Table {
        if let pinnedTable { return pinnedTable }
        if OpenRouterAudioDirectory.isRunningUnitTests { return [:] }
        ensurePersistedLoaded()
        return lock.withLock { stored }
    }

    /// Bumped when a read changes a price, so lists ordered by price are
    /// rebuilt once.
    static var generation: UInt64 {
        lock.withLock { generationValue }
    }

    // MARK: Lookups

    /// The catalog's price for a slug. A `:free` id the catalog does not list
    /// with a price is free by OpenRouter's definition of the variant, so it
    /// reads as zero even before the first read.
    static func price(
        for slug: String,
        kind: OpenRouterAudioDirectory.Kind,
        in table: Table = current
    ) -> Price? {
        let key = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let listed = table[key], listed.kind == kind { return listed }
        if key.hasSuffix(":free") { return Price(kind: kind, unit: .token, rate: 0, outputRate: 0) }
        return nil
    }

    /// USD per million characters of text for a speech model, zero for a free
    /// one; nil for one billed by tokens or by audio, or not priced. A model
    /// billed per UTF-8 byte is quoted per byte: the same number for English
    /// text, and a lower bound where a character takes more than one byte.
    static func speechUSDPerMillionCharacters(slug: String, in table: Table = current) -> Double? {
        guard let price = price(for: slug, kind: .speech, in: table) else { return nil }
        if price.isFree { return 0 }
        switch price.unit {
        case .character, .utf8Byte: return price.rate * 1_000_000
        case .audioSecond, .token: return nil
        }
    }

    /// USD per hour of audio for a transcription model billed by duration,
    /// zero for a free one; nil for one billed by tokens or not priced.
    static func transcriptionUSDPerHour(slug: String, in table: Table = current) -> Double? {
        guard let price = price(for: slug, kind: .transcription, in: table) else { return nil }
        if price.isFree { return 0 }
        guard price.unit == .audioSecond else { return nil }
        return price.rate * 3_600
    }

    /// What a picker shows under a model, in the unit OpenRouter bills it by:
    /// "Free", "$0.09 / hour of audio", "$15 / 1M characters", "$15 / 1M
    /// UTF-8 bytes", "$0.15 / minute of audio" for a speech model billed by
    /// its output, or "$1.25 / $5 per 1M tokens". Nil when OpenRouter does
    /// not price the model.
    static func label(
        slug: String,
        kind: OpenRouterAudioDirectory.Kind,
        in table: Table = current
    ) -> String? {
        guard let price = price(for: slug, kind: kind, in: table) else { return nil }
        if price.isFree { return "Free" }
        let amount = Self.amount(of: price, kind: kind)
        switch price.unit {
        case .audioSecond:
            return kind == .transcription ? "\(amount) / hour of audio" : "\(amount) / minute of audio"
        case .character:
            return "\(amount) / 1M characters"
        case .utf8Byte:
            return "\(amount) / 1M UTF-8 bytes"
        case .token:
            return "\(amount) per 1M tokens"
        }
    }

    /// The figure `label` quotes, without its unit: "$0.09", "$15", "$1.25 /
    /// $5". `scale` multiplies every rate first, which is how Settings shows
    /// the list figure a promotion cuts.
    static func amount(of price: Price, kind: OpenRouterAudioDirectory.Kind, scale: Double = 1) -> String {
        switch price.unit {
        case .audioSecond:
            return dollars(price.rate * scale * (kind == .transcription ? 3_600 : 60))
        case .character, .utf8Byte:
            return dollars(price.rate * scale * 1_000_000)
        case .token:
            let input = dollars(price.rate * scale * 1_000_000)
            let output = dollars((price.outputRate ?? 0) * scale * 1_000_000)
            return "\(input) / \(output)"
        }
    }

    /// "$0.012", "$0.126", "$15", "$2.4": three significant digits below a
    /// dollar, so a small rate never rounds to a different price.
    static func dollars(_ amount: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number
            .grouping(.never)
            .locale(Locale(identifier: "en_US"))
        let formatted = amount >= 1
            ? amount.formatted(style.precision(.fractionLength(0...2)))
            : amount.formatted(style.precision(.significantDigits(1...3)))
        return "$\(formatted)"
    }

    // MARK: Reading the catalog

    /// The speech and transcription rows of one catalog response.
    static func parseCatalog(_ data: Data) -> Table {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]]
        else { return [:] }
        return parseCatalog(rows: rows)
    }

    /// The speech and transcription rows of a catalog already parsed. A row
    /// whose price this does not understand is left out, never priced at
    /// zero.
    static func parseCatalog(rows: [[String: Any]]) -> Table {
        var table: Table = [:]
        for row in rows {
            let outputs = row["output_modalities"] as? [String] ?? []
            let kind: OpenRouterAudioDirectory.Kind
            if outputs.contains("transcription") {
                kind = .transcription
            } else if outputs.contains("speech") {
                kind = .speech
            } else {
                continue
            }
            guard let endpoint = row["endpoint"] as? [String: Any],
                  let slug = (endpoint["model_variant_slug"] as? String) ?? (row["slug"] as? String),
                  !slug.isEmpty,
                  let pricing = endpoint["pricing"] as? [String: Any],
                  let display = pricing["display_pricing"] as? [[String: Any]],
                  var price = price(kind: kind, display: display)
            else { continue }
            // `display_pricing` is the price after the cut, like the public
            // directory's (AssemblyAI's Universal 3.5 Pro at $0.225 an hour,
            // 50% off, in both).
            if let discount = number(pricing["discount"]), discount > 0, discount < 1 {
                let basisPoints = Int((discount * 10_000).rounded())
                if basisPoints > 0, basisPoints < 10_000 { price.discountBasisPoints = basisPoints }
            }
            table[slug.lowercased()] = price
        }
        return table
    }

    /// One row's `display_pricing`: its first unit price, or its input and
    /// output token prices. Each entry's `price` times its
    /// `displayMultiplier` is the price per `unitLabel` ("/hour",
    /// "/M characters").
    private static func price(kind: OpenRouterAudioDirectory.Kind, display: [[String: Any]]) -> Price? {
        let tokens = display.filter { ($0["kind"] as? String) == "token" }
        if !tokens.isEmpty {
            let input = tokens.first { ($0["sku_label"] as? String)?.lowercased().contains("input") == true }
            let output = tokens.first { ($0["sku_label"] as? String)?.lowercased().contains("output") == true }
            guard let input, let inputRate = number(input["price"]),
                  let output, let outputRate = number(output["price"])
            else { return nil }
            return Price(kind: kind, unit: .token, rate: inputRate, outputRate: outputRate)
        }
        guard let entry = display.first(where: { ($0["kind"] as? String) == "unit" }),
              let price = number(entry["price"]),
              let label = (entry["unitLabel"] as? String)?.lowercased()
        else { return nil }
        let multiplier = number(entry["displayMultiplier"]) ?? 1
        guard multiplier > 0 else { return nil }
        let perLabelUnit = price * multiplier
        var noun = label.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var scale = 1.0
        if noun.hasPrefix("m ") {
            scale = 1_000_000
            noun.removeFirst(2)
        } else if noun.hasPrefix("k ") {
            scale = 1_000
            noun.removeFirst(2)
        }
        switch noun {
        case "second", "seconds":
            return Price(kind: kind, unit: .audioSecond, rate: perLabelUnit / scale)
        case "minute", "minutes":
            return Price(kind: kind, unit: .audioSecond, rate: perLabelUnit / (60 * scale))
        case "hour", "hours":
            return Price(kind: kind, unit: .audioSecond, rate: perLabelUnit / (3_600 * scale))
        case "character", "characters":
            return Price(kind: kind, unit: .character, rate: perLabelUnit / scale)
        case "utf-8 byte", "utf-8 bytes":
            return Price(kind: kind, unit: .utf8Byte, rate: perLabelUnit / scale)
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let string as String: parsed = Double(string)
        case let number as NSNumber: parsed = number.doubleValue
        default: parsed = nil
        }
        guard let parsed, parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    /// Stores what a catalog the Mac's text directory read already fetched
    /// prices. An empty parse (a truncated response, a changed shape) keeps
    /// the last table.
    static func ingest(catalogRows rows: [[String: Any]]) {
        let table = parseCatalog(rows: rows)
        guard !table.isEmpty else { return }
        store(table)
    }

    /// Reads the catalog unless the last read is fresh. Silent: a failed read
    /// keeps the last table, and the next trigger tries again.
    static func refresh(force: Bool = false) async {
        guard !OpenRouterAudioDirectory.isRunningUnitTests else { return }
        await OpenRouterAudioDirectoryLoader.shared.prices(force: force)
    }

    /// Returns at once when a read exists (re-reading in the background when
    /// it is stale); otherwise waits for one.
    static func prepare() async {
        guard !OpenRouterAudioDirectory.isRunningUnitTests else { return }
        ensurePersistedLoaded()
        let hasTable = lock.withLock { !stored.isEmpty }
        if hasTable {
            if !isFresh {
                Task.detached(priority: .utility) { await refresh() }
            }
            return
        }
        await refresh()
    }

    // MARK: Storage

    static let freshnessInterval: TimeInterval = OpenRouterAudioDirectory.freshness
    private static let lock = AppLock()
    nonisolated(unsafe) private static var stored: Table = [:]
    nonisolated(unsafe) private static var fetchedAt: Date?
    nonisolated(unsafe) private static var didLoadPersisted = false
    nonisolated(unsafe) private static var generationValue: UInt64 = 0

    static var isFresh: Bool {
        ensurePersistedLoaded()
        return lock.withLock {
            guard !stored.isEmpty, let fetchedAt else { return false }
            return Date().timeIntervalSince(fetchedAt) < freshnessInterval
        }
    }

    /// One network read, off the main actor.
    fileprivate static func fetch() async throws -> Table {
        var request = URLRequest(url: catalogURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.foreverLMData(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OpenRouterAudioDirectory.Failure.unreachable("OpenRouter answered HTTP \(http.statusCode).")
        }
        return parseCatalog(data)
    }

    /// Adopts the read an earlier launch kept, once. Defaults are read here,
    /// outside `lock`; only the adoption happens under it.
    private static func ensurePersistedLoaded() {
        guard !lock.withLock({ didLoadPersisted }) else { return }
        let readAt = Preferences.value(Prefs.ReadAloud.audioPricesReadAt)
        var persisted: Table?
        if let data = Preferences.value(Prefs.ReadAloud.audioPricesTable),
           let table = try? JSONDecoder().decode(Table.self, from: data) {
            persisted = table
        }
        lock.withLock {
            guard !didLoadPersisted else { return }
            didLoadPersisted = true
            fetchedAt = readAt
            if let persisted {
                stored = persisted
                generationValue &+= 1
            }
        }
    }

    /// Replaces the table with a read, and tells the pickers when a price
    /// changed.
    fileprivate static func store(_ table: Table) {
        let now = Date()
        ensurePersistedLoaded()
        let changed = lock.withLock {
            let changed = stored != table
            stored = table
            fetchedAt = now
            if changed { generationValue &+= 1 }
            return changed
        }
        if let data = try? JSONEncoder().encode(table) {
            Preferences.set(data, for: Prefs.ReadAloud.audioPricesTable)
        }
        Preferences.set(now, for: Prefs.ReadAloud.audioPricesReadAt)
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openRouterAudioDirectoryDidChange, object: "prices")
        }
    }
}

// MARK: - The text-to-speech catalog

/// The text-to-speech catalog: which speech models ForeverLM offers, which voices
/// each one takes, and how much text one request may carry.
///
/// Every model OpenRouter's speech directory lists is offered (product owner,
/// 2026-09-27: "it can just be done via openrouter"; "show all models at
/// https://openrouter.ai/models?output_modalities=speech"). The list is read
/// live (`OpenRouterAudioDirectory`), so a model OpenRouter adds reaches the
/// pickers without a code change, and a model's voices are its row's
/// `supported_voices`. What ForeverLM has learned about a model — its voices'
/// display names, accents and languages, the unit size it narrates well in,
/// PCM or MP3 — is an overlay for the models it knows (`curatedModels`,
/// `learnedModels`). A model the overlay
/// does not know is still offered, with nothing about it guessed
/// (`ArticleSpeechModelOption.init(directoryRow:)`).
///
/// Every request names the OpenRouter slug and goes to OpenRouter's speech
/// endpoint: straight there on the learner's own OpenRouter key, through the
/// managed proxy otherwise (`ManagedAI.rewrite`). Grok and the default Gemini
/// model are OpenRouter models like the rest, under the same slugs.
///
/// Prices are OpenRouter's, in the unit it bills each model by
/// (`OpenRouterAudioPrices`); none is written here.
///
/// Shared because both platforms read the same catalog. macOS reaches it
/// through `MacArticleSpeechSettings` (which owns the Mac's stored selection)
/// and iOS through `ArticleSpeechSelection`. Before this device has ever read
/// the directory, the catalog is `curatedModels`. Offered models are ordered
/// cheapest first.
enum ArticleSpeechCatalog {
    static let provider = "openrouter"

    static let defaultModelID = "google/gemini-3.1-flash-tts-preview"

    /// Settings › Voice's Suggested text-to-speech models: one per maker, the
    /// best that is still affordable, as Settings › Chat suggests its own.
    /// Picked from OpenRouter's speech directory. A model
    /// OpenRouter stops serving drops off the list.
    static let suggestedModelIDs = [
        "google/gemini-3.8-flash-tts",
        "x-ai/grok-voice-tts-1.0",
        "qwen/qwen-audio-3.0-tts-plus",
        "mistralai/voxtral-mini-tts-2603",
        "microsoft/mai-voice-2",
        "minimax/speech-2.8-turbo",
        "fish-audio/s2.1-pro",
        "deepgram/aura-2",
        "bytedance-seed/seed-audio-1-0",
    ]
    static let defaultVoiceID = "Kore"
    static let grokModelID = "x-ai/grok-voice-tts-1.0"

    /// Listen on OpenAI (product owner, 2026-11-11: "DO do a direct openai
    /// route too"). OpenRouter lists no OpenAI voice, and OpenAI retires its
    /// speech models on 2027-01-06 for gpt-realtime-2.1-mini, which speaks
    /// only over the Realtime API. The proxy reads each section aloud on it
    /// (`POST /v1/openai/speech`, foreverlm-ai-proxy `realtime-narration.js`)
    /// and answers with 24 kHz PCM, paid by ForeverLM's OpenAI credits. A
    /// reading that strays from the text comes back 422, and the section is
    /// read again in halves.
    static let openAIRealtimeModelID = "openai/gpt-realtime-2.1-mini"

    /// gpt-realtime-2.1-mini's voices (developers.openai.com);
    /// OpenAI recommends marin and cedar, so they lead.
    static let openAIRealtimeVoices: [ArticleSpeechVoice] = [
        .init("marin", "Marin", detail: "Recommended"),
        .init("cedar", "Cedar", detail: "Recommended"),
        .init("alloy", "Alloy"),
        .init("ash", "Ash"),
        .init("ballad", "Ballad"),
        .init("coral", "Coral"),
        .init("echo", "Echo"),
        .init("sage", "Sage"),
        .init("shimmer", "Shimmer"),
        .init("verse", "Verse"),
    ]

    /// Gemini's prebuilt voices, with the one-word character Google gives
    /// each. IDs are wire values; the names and details are display only.
    static let geminiVoices: [ArticleSpeechVoice] = [
        .init("Zephyr", "Zephyr", detail: "Bright"),
        .init("Puck", "Puck", detail: "Upbeat"),
        .init("Charon", "Charon", detail: "Informative"),
        .init("Kore", "Kore", detail: "Firm"),
        .init("Fenrir", "Fenrir", detail: "Excitable"),
        .init("Leda", "Leda", detail: "Youthful"),
        .init("Orus", "Orus", detail: "Firm"),
        .init("Aoede", "Aoede", detail: "Breezy"),
        .init("Callirrhoe", "Callirrhoe", detail: "Easy-going"),
        .init("Autonoe", "Autonoe", detail: "Bright"),
        .init("Enceladus", "Enceladus", detail: "Breathy"),
        .init("Iapetus", "Iapetus", detail: "Clear"),
        .init("Umbriel", "Umbriel", detail: "Easy-going"),
        .init("Algieba", "Algieba", detail: "Smooth"),
        .init("Despina", "Despina", detail: "Smooth"),
        .init("Erinome", "Erinome", detail: "Clear"),
        .init("Algenib", "Algenib", detail: "Gravelly"),
        .init("Rasalgethi", "Rasalgethi", detail: "Informative"),
        .init("Laomedeia", "Laomedeia", detail: "Upbeat"),
        .init("Achernar", "Achernar", detail: "Soft"),
        .init("Alnilam", "Alnilam", detail: "Firm"),
        .init("Schedar", "Schedar", detail: "Even"),
        .init("Gacrux", "Gacrux", detail: "Mature"),
        .init("Pulcherrima", "Pulcherrima", detail: "Forward"),
        .init("Achird", "Achird", detail: "Friendly"),
        .init("Zubenelgenubi", "Zubenelgenubi", detail: "Casual"),
        .init("Vindemiatrix", "Vindemiatrix", detail: "Gentle"),
        .init("Sadachbia", "Sadachbia", detail: "Lively"),
        .init("Sadaltager", "Sadaltager", detail: "Knowledgeable"),
        .init("Sulafat", "Sulafat", detail: "Warm"),
    ]

    /// The languages Gemini TTS is documented to narrate, from Google's
    /// published table for the 3.1 Flash / 2.5 preview TTS models (checked
    /// 2026-08-19). Every Gemini voice reads all of them — the voice picks a
    /// timbre, not a language — so this is declared once on the model.
    ///
    /// Deliberately a list rather than `.multilingual`: Google documents a
    /// boundary, and a source outside it (Welsh, Irish, Zulu) still comes back
    /// as billable audio read with the wrong phonemes. Naming the boundary is
    /// what lets that source be routed elsewhere, or the listener be asked,
    /// before the money is spent. The table names those models only, so the
    /// 3.8 models (`learnedModels`) are not given it.
    ///
    /// Codes are the primary subtags `ArticleSpeechLanguage.primaryCode`
    /// produces, so Google's `cmn` is stored as `zh`, and the aliases a
    /// detector may return for one published language (`fil`/`tl`,
    /// `nb`/`nn`/`no`) are all listed.
    static let geminiLanguages: ArticleSpeechLanguageSupport = .languages([
        "af", "am", "ar", "az", "be", "bg", "bn", "ca", "ceb", "cs", "da", "de",
        "el", "en", "es", "et", "eu", "fa", "fi", "fil", "fr", "gl", "gu", "he",
        "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja", "jv", "ka", "kn",
        "ko", "kok", "la", "lb", "lo", "lt", "lv", "mai", "mg", "mk", "ml",
        "mn", "mr", "ms", "my", "nb", "ne", "nl", "nn", "no", "or", "pa", "pl",
        "ps", "pt", "ro", "ru", "sd", "si", "sk", "sl", "sq", "sr", "sv", "sw",
        "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "zh",
    ])

    static let grokVoices: [ArticleSpeechVoice] = [
        .init("eve", "Eve"),
        .init("ara", "Ara"),
        .init("rex", "Rex"),
        .init("sal", "Sal"),
        .init("leo", "Leo"),
    ]

    static let sesameVoices: [ArticleSpeechVoice] = [
        .init("read_speech_a", "Read Speech A"),
        .init("read_speech_b", "Read Speech B"),
        .init("read_speech_c", "Read Speech C"),
        .init("read_speech_d", "Read Speech D"),
        .init("conversational_a", "Conversational A"),
        .init("conversational_b", "Conversational B"),
    ]

    static let voxtralVoices: [ArticleSpeechVoice] = [
        .init("en_paul_neutral", "Paul · Neutral"),
        .init("en_paul_cheerful", "Paul · Cheerful"),
        .init("en_paul_confident", "Paul · Confident"),
        .init("en_paul_happy", "Paul · Happy"),
        .init("gb_oliver_neutral", "Oliver · Neutral", regionCode: "GB"),
        .init("gb_oliver_confident", "Oliver · Confident", regionCode: "GB"),
        .init("gb_oliver_cheerful", "Oliver · Cheerful", regionCode: "GB"),
        .init("gb_jane_neutral", "Jane · Neutral", regionCode: "GB"),
        .init("gb_jane_confident", "Jane · Confident", regionCode: "GB"),
        .init("gb_jane_curious", "Jane · Curious", regionCode: "GB"),
        .init("fr_marie_neutral", "Marie · Neutral", regionCode: "FR", languages: .languages(["fr"])),
        .init("fr_marie_happy", "Marie · Happy", regionCode: "FR", languages: .languages(["fr"])),
    ]

    static let maiVoices: [ArticleSpeechVoice] = [
        .init("en-US-Harper:MAI-Voice-2", "Harper", regionCode: "US", languages: .languages(["en"])),
        .init("es-MX-Valeria:MAI-Voice-2", "Valeria", regionCode: "MX", languages: .languages(["es"])),
        .init("fr-FR-Soleil:MAI-Voice-2", "Soleil", regionCode: "FR", languages: .languages(["fr"])),
        .init("de-DE-Klaus:MAI-Voice-2", "Klaus", regionCode: "DE", languages: .languages(["de"])),
    ]

    /// Stable English system voices published by MiniMax, listed first; the
    /// rest of the directory's list follows them.
    static let miniMaxVoices: [ArticleSpeechVoice] = [
        .init("English_expressive_narrator", "Expressive Narrator"),
        .init("English_radiant_girl", "Radiant Girl"),
        .init("English_magnetic_voiced_man", "Magnetic-voiced Man"),
        .init("English_compelling_lady1", "Compelling Lady"),
        .init("English_Trustworth_Man", "Trustworthy Man"),
        .init("English_CalmWoman", "Calm Woman"),
        .init("English_Diligent_Man", "Diligent Man"),
        .init("English_Graceful_Lady", "Graceful Lady"),
    ]

    /// OpenRouter lists no voices for Fish Audio's models: its adapter takes
    /// Fish Audio reference IDs rather than a closed voice list. Selene is the
    /// reference each Fish model page's own playable example sends (checked
    /// for S1, S2 Pro and S2.1 Pro on 2026-09-27), so it is the one voice
    /// anything names for them, and for any Fish model the directory adds
    /// (Drama 3): without a reference, each request picks its own speaker.
    static let fishS21Voices: [ArticleSpeechVoice] = [
        .init(
            "b347db033a6549378b48d00acb0d06cd",
            "Selene",
            detail: "Meditative · multilingual"
        ),
    ]

    /// Curated English voices from Flux's catalog, listed first.
    static let fluxVoices: [ArticleSpeechVoice] = [
        .init("flux-alexis-en", "Alexis"),
        .init("flux-bree-en", "Bree"),
        .init("flux-bruce-en", "Bruce"),
        .init("flux-elise-en", "Elise"),
        .init("flux-gemma-en", "Gemma"),
        .init("flux-jack-en", "Jack"),
        .init("flux-maeve-en", "Maeve"),
        .init("flux-marcus-en", "Marcus"),
        .init("flux-paige-en", "Paige"),
        .init("flux-priya-en", "Priya"),
        .init("flux-rufus-en", "Rufus"),
        .init("flux-sharon-en", "Sharon"),
    ]

    static let qwenAudioFlashVoices: [ArticleSpeechVoice] = [
        .init("loongjohn", "Loongjohn", detail: "American English", regionCode: "US", languages: .languages(["en"])),
        .init(
            "longanhuan_v3.6",
            "Longanhuan",
            detail: "Mandarin Chinese",
            regionCode: "CN",
            languages: .languages(["zh"])
        ),
    ]

    /// English voices from Kokoro's catalog, listed first. The wire prefix
    /// determines how Kokoro interprets the narration text; the picker renders
    /// that region as a flag.
    static let kokoroVoices: [ArticleSpeechVoice] = [
        .init("af_heart", "Heart", regionCode: "US"),
        .init("af_bella", "Bella", regionCode: "US"),
        .init("af_nicole", "Nicole", regionCode: "US"),
        .init("af_nova", "Nova", regionCode: "US"),
        .init("af_sarah", "Sarah", regionCode: "US"),
        .init("am_adam", "Adam", regionCode: "US"),
        .init("am_michael", "Michael", regionCode: "US"),
        .init("am_onyx", "Onyx", regionCode: "US"),
        .init("bf_emma", "Emma", regionCode: "GB"),
        .init("bf_isabella", "Isabella", regionCode: "GB"),
        .init("bm_george", "George", regionCode: "GB"),
        .init("bm_lewis", "Lewis", regionCode: "GB"),
    ]

    /// English voices from Deepgram's Aura-2 catalog, listed first.
    static let auraVoices: [ArticleSpeechVoice] = [
        .init("aura-2-thalia-en", "Thalia", regionCode: "US"),
        .init("aura-2-andromeda-en", "Andromeda", regionCode: "US"),
        .init("aura-2-apollo-en", "Apollo", regionCode: "US"),
        .init("aura-2-asteria-en", "Asteria", regionCode: "US"),
        .init("aura-2-athena-en", "Athena", regionCode: "US"),
        .init("aura-2-atlas-en", "Atlas", regionCode: "US"),
        .init("aura-2-aurora-en", "Aurora", regionCode: "US"),
        .init("aura-2-cora-en", "Cora", regionCode: "US"),
        .init("aura-2-draco-en", "Draco", regionCode: "GB"),
        .init("aura-2-harmonia-en", "Harmonia", regionCode: "US"),
        .init("aura-2-helena-en", "Helena", regionCode: "US"),
        .init("aura-2-hermes-en", "Hermes", regionCode: "US"),
        .init("aura-2-luna-en", "Luna", regionCode: "US"),
        .init("aura-2-odysseus-en", "Odysseus", regionCode: "US"),
        .init("aura-2-orion-en", "Orion", regionCode: "US"),
        .init("aura-2-orpheus-en", "Orpheus", regionCode: "US"),
        .init("aura-2-phoebe-en", "Phoebe", regionCode: "US"),
        .init("aura-2-selene-en", "Selene", regionCode: "US"),
        .init("aura-2-theia-en", "Theia", regionCode: "AU"),
        .init("aura-2-zeus-en", "Zeus", regionCode: "US"),
    ]

    /// Gemini accepts a much larger context, but speech latency grows with the
    /// requested duration. A multi-thousand-character request can outlive the
    /// managed route's 90-second timeout and repeat the same expensive wait.
    /// Keep body units bounded and generate them concurrently instead.
    static let geminiChunkLimit = 800
    static let standardChunkLimit = 4_000
    static let fishChunkLimit = 3_000

    /// Fish Audio's models, which OpenRouter lists with no voices: a request
    /// to one must name a reference voice or each request speaks with a
    /// different one.
    static func isFishAudioModel(_ modelID: String) -> Bool {
        modelID.lowercased().hasPrefix("fish-audio/")
    }
    static let realtimeChunkLimit = 2_000
    // Flux's free route babbled and truncated on ~1,950-character units (two
    // units of a 44-unit paper came back as nonsense, one came back a third
    // short). Shorter units bound how much one bad response
    // garbles; the route stays labelled best effort because it is.
    static let fluxChunkLimit = 1_000
    // Grok Voice can take roughly a minute to synthesize a 4k-character unit.
    // One-minute units keep generation ahead of the fastest playback rate and
    // bound the damage if the model returns a semantically malformed waveform.
    static let grokChunkLimit = 1_000
    /// Seed Audio returns at most 120 seconds of audio per request (its
    /// OpenRouter description); 1,000 characters is about 80
    /// seconds at 750 spoken characters a minute, leaving room for a slower
    /// reading.
    static let seedAudioChunkLimit = 1_000
    /// The unit size for a model nobody has measured. This is ForeverLM's
    /// request size, not a limit the model publishes: one-minute units
    /// (about 1,000 characters at 750 spoken characters a minute) finish
    /// inside the managed route's 90-second timeout on a model that
    /// synthesizes slower than real time, and fit a per-request audio cap
    /// like Seed Audio's two minutes. A unit the model still refuses is halved
    /// and sent again (`CloudArticleTTS.split`).
    static let untunedChunkLimit = 1_000
    static let untunedLeadChunkLimit = 1_000
    // The managed proxy must finish exact OpenRouter metering before it can
    // release a speech response. Keep Gemini's opening to roughly one title
    // plus one sentence so the first playable audio does not inherit the
    // latency of a half-minute narration segment.
    static let geminiLeadChunkLimit = 240
    static let standardLeadChunkLimit = 1_000

    /// The models this build knows well enough to curate: voices named and
    /// placed, languages declared, units tuned. No prices: those are
    /// OpenRouter's (`OpenRouterAudioPrices`). Offered as they stand before
    /// the directory has been read; laid over its rows after.
    static let curatedModels: [ArticleSpeechModelOption] = [
        .init(
            id: openAIRealtimeModelID,
            name: "GPT Realtime 2.1 Mini",
            detail: "OpenAI · multilingual",
            maker: "OpenAI",
            voices: openAIRealtimeVoices,
            languages: .multilingual,
            responseFormat: .pcm(sampleRate: 24_000),
            chunkLimit: realtimeChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "fish-audio/s2.1-pro-free:free",
            name: "Fish Audio S2.1 Pro Free",
            detail: "Best effort · multilingual",
            maker: "Fish Audio",
            voices: fishS21Voices,
            languages: .multilingual,
            chunkLimit: fishChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "deepgram/flux-tts:free",
            name: "Deepgram Flux TTS Free",
            detail: "English · best effort",
            maker: "Deepgram",
            voices: fluxVoices,
            // "Natural, expressive English speech synthesis" (the directory),
            // and every voice it lists ends in -en.
            languages: .languages(["en"]),
            chunkLimit: fluxChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "hexgrad/kokoro-82m",
            name: "Kokoro 82M",
            detail: "Economy",
            maker: "hexgrad",
            voices: kokoroVoices,
            // The curated voices are English; Kokoro's other voices read
            // Spanish, French, Hindi, Italian, Japanese, Portuguese and
            // Chinese, which nothing here maps voice by voice.
            languages: .languages(["en"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "sesame/csm-1b",
            name: "Sesame CSM 1B",
            detail: nil,
            maker: "Sesame",
            voices: sesameVoices,
            // "Produces English speech output" (the directory).
            languages: .languages(["en"]),
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "fish-audio/s2.1-pro",
            name: "Fish Audio S2.1 Pro",
            detail: "Expressive · multilingual",
            maker: "Fish Audio",
            voices: fishS21Voices,
            languages: .multilingual,
            chunkLimit: fishChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: grokModelID,
            name: "Grok Voice TTS 1.0",
            detail: nil,
            maker: "SpaceXAI",
            voices: grokVoices,
            languages: .multilingual,
            chunkLimit: grokChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "microsoft/mai-voice-2-flash",
            name: "MAI Voice 2 Flash",
            detail: "Low latency",
            maker: "Microsoft AI",
            voices: maiVoices,
            languages: .languages(["en", "es", "fr", "de"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "qwen/qwen-audio-3.0-tts-flash",
            name: "Qwen Audio 3 TTS Flash",
            detail: "Low latency",
            maker: "Qwen",
            voices: qwenAudioFlashVoices,
            languages: .languages(["en", "zh"]),
            languagesCoverEveryVoice: false,
            chunkLimit: realtimeChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "mistralai/voxtral-mini-tts-2603",
            name: "Voxtral Mini TTS",
            detail: nil,
            maker: "Mistral",
            voices: voxtralVoices,
            languages: .languages(["en", "fr"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "microsoft/mai-voice-2",
            name: "MAI Voice 2",
            detail: nil,
            maker: "Microsoft AI",
            voices: maiVoices,
            languages: .languages(["en", "es", "fr", "de"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "deepgram/aura-2",
            name: "Deepgram Aura 2",
            detail: nil,
            maker: "Deepgram",
            voices: auraVoices,
            // The curated voices are English. Aura-2's others read Spanish,
            // French, German, Italian, Dutch and Japanese.
            languages: .languages(["en"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "google/gemini-3.1-flash-tts-preview",
            name: "Gemini 3.1 Flash TTS",
            detail: "70+ languages · long-form",
            maker: "Google",
            voices: geminiVoices,
            languages: geminiLanguages,
            // OpenRouter's Gemini adapter returns Google's 24 kHz PCM, which
            // own-key narration transcodes.
            responseFormat: .pcm(sampleRate: 24_000),
            chunkLimit: geminiChunkLimit,
            leadChunkLimit: geminiLeadChunkLimit
        ),
        .init(
            id: "minimax/speech-2.8-turbo",
            name: "MiniMax Speech 2.8 Turbo",
            detail: "Long-form",
            maker: "MiniMax",
            voices: miniMaxVoices,
            languages: .languages(["en"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
        .init(
            id: "minimax/speech-2.8-hd",
            name: "MiniMax Speech 2.8 HD",
            detail: "Long-form",
            maker: "MiniMax",
            voices: miniMaxVoices,
            languages: .languages(["en"]),
            languagesCoverEveryVoice: false,
            chunkLimit: standardChunkLimit,
            leadChunkLimit: standardLeadChunkLimit
        ),
    ]

    /// What ForeverLM knows about models the directory lists but the catalog
    /// does not pin: the voice a
    /// model with no voice list takes, a per-request cap, a family's voice
    /// names and unit sizes. Laid over their rows only while the directory
    /// lists them; before its first read they are not offered.
    static let learnedModels: [ArticleSpeechModelOption] = [
        .init(
            id: "heygen/heygen-voice-1-turbo:free",
            name: "HeyGen Voice Turbo (free)",
            detail: "39 languages · best effort",
            maker: "HeyGen",
            voices: [],
            languages: .unstated,
            // HeyGen streams 44.1 kHz mono PCM (its OpenRouter model page)
            // and rejects MP3 requests. This is a distinct wire contract, not
            // a preference: its OpenRouter adapter answers
            // `response_format: mp3` with HTTP 400.
            responseFormat: .pcm(sampleRate: 44_100),
            chunkLimit: untunedChunkLimit,
            leadChunkLimit: untunedLeadChunkLimit,
            curatedVoiceCount: 0
        ),
        .init(
            id: "heygen/heygen-voice-1-turbo",
            name: "HeyGen Voice Turbo",
            detail: "39 languages",
            maker: "HeyGen",
            voices: [],
            languages: .unstated,
            responseFormat: .pcm(sampleRate: 44_100),
            chunkLimit: untunedChunkLimit,
            leadChunkLimit: untunedLeadChunkLimit,
            curatedVoiceCount: 0
        ),
        .init(
            id: "heygen/heygen-voice-1",
            name: "HeyGen Voice",
            detail: "39 languages",
            maker: "HeyGen",
            voices: [],
            languages: .unstated,
            responseFormat: .pcm(sampleRate: 44_100),
            chunkLimit: untunedChunkLimit,
            leadChunkLimit: untunedLeadChunkLimit,
            curatedVoiceCount: 0
        ),
        .init(
            id: "fish-audio/s1",
            name: "Fish Audio S1",
            detail: nil,
            maker: "Fish Audio",
            voices: fishS21Voices,
            languages: .unstated,
            chunkLimit: untunedChunkLimit,
            leadChunkLimit: untunedLeadChunkLimit
        ),
        .init(
            id: "fish-audio/s2-pro",
            name: "Fish Audio S2 Pro",
            detail: nil,
            maker: "Fish Audio",
            voices: fishS21Voices,
            languages: .unstated,
            chunkLimit: untunedChunkLimit,
            leadChunkLimit: untunedLeadChunkLimit
        ),
        .init(
            id: "bytedance-seed/seed-audio-1-0",
            name: "Seed Audio 1.0",
            detail: nil,
            maker: "ByteDance Seed",
            voices: [],
            languages: .unstated,
            chunkLimit: seedAudioChunkLimit,
            leadChunkLimit: seedAudioChunkLimit
        ),
        .init(
            id: "google/gemini-3.8-flash-tts",
            name: "Gemini 3.8 Flash TTS",
            detail: "Long-form",
            maker: "Google",
            // "The 30 prebuilt studio voices" of its predecessor (the
            // directory), which lists the same ids.
            voices: geminiVoices,
            languages: .unstated,
            // Every Gemini TTS model takes only PCM; asking for mp3 is a 400.
            responseFormat: .pcm(sampleRate: 24_000),
            chunkLimit: geminiChunkLimit,
            leadChunkLimit: geminiLeadChunkLimit
        ),
        .init(
            id: "google/gemini-3.8-flash-lite-tts",
            name: "Gemini 3.8 Flash Lite TTS",
            detail: "Fast",
            maker: "Google",
            voices: geminiVoices,
            languages: .unstated,
            // Every Gemini TTS model takes only PCM; asking for mp3 is a 400.
            responseFormat: .pcm(sampleRate: 24_000),
            chunkLimit: geminiChunkLimit,
            leadChunkLimit: geminiLeadChunkLimit
        ),
    ]

    private static let mergedLock = AppLock()
    nonisolated(unsafe) private static var mergedModels: (
        directory: UInt64,
        prices: UInt64,
        models: [ArticleSpeechModelOption]
    )?

    /// The offered models: every model the last directory read lists, with
    /// the overlay laid over the ones it knows, cheapest first by
    /// OpenRouter's price — or `curatedModels` before this device has read
    /// the directory.
    static var models: [ArticleSpeechModelOption] {
        let snapshot = OpenRouterAudioDirectory.snapshot(.speech)
        guard let rows = snapshot.rows else { return curatedModels }
        let prices = OpenRouterAudioPrices.generation
        if let cached = mergedLock.withLock({ mergedModels }),
           cached.directory == snapshot.generation, cached.prices == prices {
            return cached.models
        }
        let merged = options(fromDirectory: rows)
        // A read with nothing ForeverLM can offer is treated as no read.
        let offered = merged.isEmpty ? curatedModels : merged
        mergedLock.withLock { mergedModels = (snapshot.generation, prices, offered) }
        return offered
    }

    /// Whether `models` comes from a directory read rather than from what this
    /// build records. A stored pick missing from a list that is not
    /// directory-backed may be a model OpenRouter added since, so it is left
    /// alone rather than "repaired".
    static var isDirectoryBacked: Bool {
        OpenRouterAudioDirectory.rows(.speech) != nil
    }

    /// Every directory row ForeverLM can offer, as options: the overlay over
    /// the rows it knows, the row as listed otherwise, retired models left
    /// out, cheapest first. Pure, so the merge is tested on fixtures.
    static func options(fromDirectory rows: [OpenRouterAudioModelRow]) -> [ArticleSpeechModelOption] {
        var known: [String: ArticleSpeechModelOption] = [:]
        for option in curatedModels + learnedModels {
            known[option.id.lowercased()] = option
        }
        var seen = Set<String>()
        let options = rows.compactMap { row -> ArticleSpeechModelOption? in
            let key = row.id.lowercased()
            guard !isRetiredModel(row.id), seen.insert(key).inserted else { return nil }
            let option = known[key].map { $0.merged(with: row) }
                ?? ArticleSpeechModelOption(directoryRow: row)
            // No voice to name, no request: the provider would pick the
            // speaker, a different one per request (`takesVoice`).
            return option.takesVoice ? option : nil
        }
        // OpenAI's voices are not on OpenRouter's list; the proxy speaks them.
        let openAI = curatedModels.filter { $0.speaksThroughOpenAI && seen.insert($0.id.lowercased()).inserted }
        return (options + openAI).sorted(by: cheapestFirst)
    }

    /// Cheapest first by OpenRouter's per-character price; a model with no
    /// per-character price (unpriced, or billed by tokens or by the second)
    /// after every priced one, by name.
    static func cheapestFirst(_ lhs: ArticleSpeechModelOption, _ rhs: ArticleSpeechModelOption) -> Bool {
        switch (lhs.ratePerMillionCharacters, rhs.ratePerMillionCharacters) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
        }
    }

    static func model(id: String) -> ArticleSpeechModelOption? {
        models.first { $0.id == id }
    }

    /// Samples per second of the raw PCM `modelID` answers with, from what
    /// this build records about the model; nil for a model that answers MP3
    /// and for one this build does not know. Read from the build rather than
    /// from `models` because it judges audio already stored, which must not
    /// depend on whether this device has read OpenRouter's directory yet.
    static func pcmSampleRate(forModel modelID: String) -> Int? {
        recordedPCMSampleRates[modelID.lowercased()]
    }

    private static let recordedPCMSampleRates: [String: Int] = {
        var rates: [String: Int] = [:]
        for option in curatedModels + learnedModels {
            rates[option.id.lowercased()] = option.responseFormat.pcmSampleRate
        }
        return rates
    }()

    /// USD per million narrated characters for a slug, from OpenRouter's
    /// catalog, whether or not the model is offered today — a ledger row made
    /// with a retired model still prices while OpenRouter lists it. Nil for a
    /// model OpenRouter does not bill by the character, or has not priced.
    static func ratePerMillionCharacters(forModel modelID: String) -> Double? {
        // An OpenAI voice charges the learner nothing: ForeverLM's OpenAI
        // credits pay for it (`openAIRealtimeModelID`).
        if modelID == openAIRealtimeModelID { return 0 }
        return OpenRouterAudioPrices.speechUSDPerMillionCharacters(slug: modelID)
    }

    /// What an OpenAI voice's card says where the others carry a price.
    static let includedPriceLabel = "Included"

    /// The price line for a slug, in OpenRouter's unit, or "Price unknown".
    /// The one place a model's price is worded: the Settings card, the
    /// phone's list and `read_aloud.model` over MCP all read it.
    static func priceLabel(forModel modelID: String) -> String {
        // ForeverLM's own OpenAI credits pay for an OpenAI voice, and the
        // learner is charged nothing, as for voice mode. OpenRouter does not
        // list it, so its price there would read "Price unknown".
        if modelID == openAIRealtimeModelID { return includedPriceLabel }
        return OpenRouterAudioPrices.label(slug: modelID, kind: .speech) ?? OpenRouterAudioPrices.unknownPriceLabel
    }

    /// Models retired from the catalog, each for a recorded reason. A stored
    /// selection naming one is rejected rather than replaced, audio generated
    /// by one is regenerated, and one the directory still lists is left out.
    ///
    /// - Orpheus 3B: expressive on short samples but resets its prosody every
    ///   ~180 characters, so it cannot narrate long-form. OpenRouter still
    ///   lists it.
    /// - Zonos v0.1: no longer in OpenRouter's directory; kept so its audio is
    ///   remade.
    static func isRetiredModel(_ model: String) -> Bool {
        model.caseInsensitiveCompare("canopylabs/orpheus-3b-0.1-ft") == .orderedSame
            || model.caseInsensitiveCompare("zyphra/zonos-v0.1-transformer") == .orderedSame
            || model.caseInsensitiveCompare("zyphra/zonos-v0.1-hybrid") == .orderedSame
    }

    static func voices(forModel modelID: String) -> [ArticleSpeechVoice] {
        model(id: modelID)?.voices ?? []
    }

    /// A voice this model still offers, falling back to the model's first voice.
    /// A stored id the catalog no longer lists never travels to the wire. Nil
    /// for a model the catalog does not offer, and for one with no voice list,
    /// whose request names no voice.
    static func resolvedVoiceID(_ voiceID: String?, forModel modelID: String) -> String? {
        guard let option = model(id: modelID) else { return nil }
        let trimmed = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, option.voice(id: trimmed) != nil { return trimmed }
        return option.defaultVoiceID
    }

    /// A display name for a voice the directory lists and nothing here
    /// curates: its id, with underscores read as spaces, as a manifest from
    /// an older build has always been labelled.
    static func listedVoiceName(_ voiceID: String) -> String {
        voiceID.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Human label for a voice id, for the settings picker and the text-to-speech
    /// toolbar. Falls back to the generic shape for an id the catalog does not
    /// list, so a manifest written by an older build still reads sensibly.
    static func voiceLabel(model modelID: String, voice voiceID: String) -> String {
        let option = self.model(id: modelID)
        if let name = option?.voice(id: voiceID)?.name { return name }
        return listedVoiceName(voiceID)
    }

    /// Locale-aware label used in Settings. Wire values and persisted manifest
    /// labels remain free of presentation-only emoji.
    static func voiceSettingsLabel(model modelID: String, voice voiceID: String) -> String {
        guard let model = self.model(id: modelID), let voice = model.voice(id: voiceID) else {
            return voiceLabel(model: modelID, voice: voiceID)
        }
        let flag = voice.regionCode == nil
            ? (voice.languages ?? model.languages).flagEmoji
            : voice.flagEmoji
        return flag.map { "\($0) \(voice.name)" } ?? voice.name
    }

    /// "Kore (Gemini 3.1 Flash TTS)" — both halves of a selection, for prose
    /// that has to name what will be doing the reading.
    static func selectionLabel(model modelID: String, voice voiceID: String) -> String {
        let voice = voiceLabel(model: modelID, voice: voiceID)
        guard let name = model(id: modelID)?.name else { return voice }
        return "\(voice) (\(name))"
    }

    static func chunkLimit(forModel modelID: String) -> Int {
        model(id: modelID)?.chunkLimit ?? untunedChunkLimit
    }

    static func leadChunkLimit(forModel modelID: String) -> Int {
        model(id: modelID)?.leadChunkLimit ?? untunedLeadChunkLimit
    }

    // MARK: - Language

    /// How a text-to-speech selection lines up with the language a source is
    /// actually written in.
    enum LanguageFit: Equatable, Sendable {
        /// The selected model and voice narrate this language.
        case supported
        /// The selected model narrates it, but through a different voice.
        case otherVoice(model: String, voice: String)
        /// Another catalog model narrates it; the selected one does not.
        case otherModel(model: String, voice: String)
        /// No catalog model claims this language. Generating anyway produces
        /// audio, and a bill, in the wrong phonemes.
        case unsupported
        /// Nothing records which languages the selected voice narrates
        /// (`ArticleSpeechLanguageSupport.unstated`), so the selection stands:
        /// it is neither confirmed nor swapped for a model that is documented.
        case unverified

        /// The model and voice that can read the language, or nil when nothing
        /// in the catalog can, or when the selection stands.
        var replacement: (model: String, voice: String)? {
            switch self {
            case .supported, .unsupported, .unverified:
                return nil
            case .otherVoice(let model, let voice), .otherModel(let model, let voice):
                return (model, voice)
            }
        }
    }

    /// What it would take to narrate `languageCode` given the selected model
    /// and voice.
    ///
    /// A voice that stays inside the selected model wins over one that changes
    /// it: same price, same latency, same chunking. Beyond that the default
    /// model comes first (it is the one the rest of the app is tuned around),
    /// then a model with a voice built for the language, then any multilingual
    /// model in catalog order — which is cheapest first. Only a documented
    /// language moves a source: a selection whose languages are unstated
    /// stands, and an unstated model is never the replacement.
    static func languageFit(
        for languageCode: String,
        model modelID: String,
        voice voiceID: String?
    ) -> LanguageFit {
        languageFit(for: languageCode, model: modelID, voice: voiceID, in: models)
    }

    /// `languageFit` against a given list, so a test can hand it a directory's
    /// options without reading the directory.
    static func languageFit(
        for languageCode: String,
        model modelID: String,
        voice voiceID: String?,
        in catalog: [ArticleSpeechModelOption]
    ) -> LanguageFit {
        let code = languageCode.lowercased()
        if let option = catalog.first(where: { $0.id == modelID }) {
            let support = option.languageSupport(voice: voiceID)
            if support.speaks(code) { return .supported }
            guard support.isStated else { return .unverified }
            if let voice = option.voice(speaking: code) {
                return .otherVoice(model: modelID, voice: voice.id)
            }
        }
        guard let replacement = replacementModel(speaking: code, excluding: modelID, in: catalog) else {
            return .unsupported
        }
        return .otherModel(model: replacement.model, voice: replacement.voice)
    }

    private static func replacementModel(
        speaking languageCode: String,
        excluding modelID: String,
        in catalog: [ArticleSpeechModelOption]
    ) -> (model: String, voice: String)? {
        let candidates = catalog.filter { $0.id != modelID && !isRetiredModel($0.id) && $0.takesVoice }

        func pick(_ option: ArticleSpeechModelOption) -> (model: String, voice: String)? {
            option.voice(speaking: languageCode).map { (option.id, $0.id) }
        }

        if let fallback = candidates.first(where: { $0.id == defaultModelID }) {
            // Keep the product's default voice when it can read the language,
            // rather than dropping to whichever voice the model lists first.
            if let preferred = fallback.voice(id: defaultVoiceID),
               (preferred.languages ?? fallback.languages).speaks(languageCode) {
                return (fallback.id, preferred.id)
            }
            if let picked = pick(fallback) { return picked }
        }
        if let native = candidates.first(where: { $0.nativeVoice(speaking: languageCode) != nil }),
           let picked = pick(native) {
            return picked
        }
        return candidates.lazy.compactMap(pick).first
    }
}

/// The language a source is written in, as far as text-to-speech is concerned.
///
/// Detection is on-device and deterministic: `NLLanguageRecognizer` classifies
/// the script and word statistics of a sample. Deliberately *not* an LLM call —
/// this runs before every Listen, on text the user is waiting to hear, and it
/// answers a closed classification question rather than reading for meaning.
///
/// The bias is toward silence. Short, mixed, or ambiguous text returns nil,
/// which leaves the listener's own model and voice selection untouched. A
/// wrong-language warning on an English source would be worse than no warning
/// at all, because it would teach the listener to click past this one.
enum ArticleSpeechLanguage {
    /// Below this the recognizer's top hypothesis is close to a coin flip
    /// between related languages, and acting on it would move the listener off
    /// their chosen voice for nothing.
    static let minimumConfidence = 0.75
    /// Narration shorter than this is a title or a stub — too little for the
    /// recognizer to separate, say, Dutch from Afrikaans.
    static let minimumSampleLength = 240

    /// Windows sampled across the source rather than one prefix: a paper in
    /// another language still opens with an English title and abstract, and a
    /// book chapter can open with an epigraph.
    private static let windowLength = 1_500
    private static let windowCount = 3

    /// ISO 639-1 code (`"nl"`, `"de"`, `"zh"`) for the language `text` is
    /// written in, or nil when it is too short or too ambiguous to act on.
    ///
    /// Walks a whole source's characters — blocking work, never on the main
    /// actor.
    static func detect(in text: String) -> String? {
        guard let sample = sample(from: text) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        guard confidence >= minimumConfidence else { return nil }
        return primaryCode(dominant.rawValue)
    }

    /// `"zh-Hans"` and `"pt-BR"` are the same narration problem as `"zh"` and
    /// `"pt"`: the catalog declares support by language, not by script or
    /// region.
    static func primaryCode(_ identifier: String) -> String? {
        let primary = identifier.split(separator: "-").first.map(String.init)?.lowercased()
        guard let primary, !primary.isEmpty, primary != "und" else { return nil }
        return primary
    }

    /// "Dutch", "German" — in the reader's own language, since this ends up in
    /// a sentence they read.
    static func displayName(for languageCode: String) -> String {
        Locale.current.localizedString(forLanguageCode: languageCode)?.localizedCapitalized
            ?? languageCode.uppercased()
    }

    /// A bounded, spread-out sample of `text`, or nil when there is not enough
    /// of it to classify.
    static func sample(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = trimmed.count
        guard total >= minimumSampleLength else { return nil }
        guard total > windowLength * windowCount else { return trimmed }

        var windows: [String] = []
        for window in 0..<windowCount {
            let offset = total * window / windowCount
            guard let lower = trimmed.index(
                      trimmed.startIndex,
                      offsetBy: offset,
                      limitedBy: trimmed.endIndex
                  ),
                  let upper = trimmed.index(
                      lower,
                      offsetBy: windowLength,
                      limitedBy: trimmed.endIndex
                  ) else { continue }
            windows.append(String(trimmed[lower..<upper]))
        }
        guard !windows.isEmpty else { return nil }
        return windows.joined(separator: "\n\n")
    }
}

/// The text-to-speech selection a source's own language calls for, and what the
/// listener has to be told about it.
///
/// Both platforms resolve this the same way and before anything billable
/// happens, because both consequences are paid for in advance: a model that
/// cannot read the language still returns audio and still bills for it, and the
/// substitute model has its own price, chunk size, and cache entries.
struct ArticleSpeechLanguageResolution: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Too little text, or too ambiguous, to act on. The listener's own
        /// selection stands.
        case undetected
        /// The selected model and voice narrate this language.
        case supported
        /// A voice that narrates this language was substituted for this
        /// source, in place of the one Settings selected.
        case adjusted(voiceLabel: String, replacing: String)
        /// Nothing in the catalog narrates it.
        case unsupported
        /// Nothing records which languages the selected voice narrates, so
        /// the listener's selection stands, and nothing is said: the Settings
        /// card already tells them the model publishes no languages, and a
        /// sentence under every Listen that cannot say whether anything is
        /// wrong would teach them to click past the ones that can. Kept apart
        /// from `.supported` so nothing reads it as a confirmation.
        case unverified
    }

    /// ISO 639-1 code detected in the narration, nil when undetected.
    let languageCode: String?
    /// The model that should narrate this source.
    let model: String
    /// The voice that should narrate it, on `model`.
    let voice: String
    let outcome: Outcome

    var languageName: String? {
        languageCode.map(ArticleSpeechLanguage.displayName(for:))
    }

    /// True when the resolved selection differs from the one that went in.
    var changesSelection: Bool {
        if case .adjusted = outcome { return true }
        return false
    }

    /// Resolves `text` against a catalog selection. Walks the narration and
    /// runs the language recognizer — blocking work, never on the main actor.
    static func resolve(text: String, model: String, voice: String) -> ArticleSpeechLanguageResolution {
        func unchanged(_ code: String?, _ outcome: Outcome) -> ArticleSpeechLanguageResolution {
            ArticleSpeechLanguageResolution(languageCode: code, model: model, voice: voice, outcome: outcome)
        }

        guard let code = ArticleSpeechLanguage.detect(in: text) else {
            return unchanged(nil, .undetected)
        }
        let fit = ArticleSpeechCatalog.languageFit(for: code, model: model, voice: voice)
        switch fit {
        case .supported:
            return unchanged(code, .supported)
        case .unsupported:
            return unchanged(code, .unsupported)
        case .unverified:
            return unchanged(code, .unverified)
        case .otherVoice(let newModel, let newVoice), .otherModel(let newModel, let newVoice):
            return ArticleSpeechLanguageResolution(
                languageCode: code,
                model: newModel,
                voice: newVoice,
                outcome: .adjusted(
                    voiceLabel: ArticleSpeechCatalog.selectionLabel(model: newModel, voice: newVoice),
                    replacing: ArticleSpeechCatalog.selectionLabel(model: model, voice: voice)
                )
            )
        }
    }

    /// One sentence for the listener: what language this is, and what was done
    /// about it. Nil whenever there is nothing worth saying.
    var message: String? {
        guard let languageName else { return nil }
        switch outcome {
        case .undetected, .supported, .unverified:
            return nil
        case .adjusted(let voiceLabel, let replaced):
            return """
                This source is in \(languageName). Reading it with \(voiceLabel) \
                instead of \(replaced), which does not speak \(languageName).
                """
        case .unsupported:
            return """
                This source is in \(languageName), and no text-to-speech voice in the \
                catalog speaks \(languageName). The narration will be generated — and \
                billed — with the wrong pronunciation.
                """
        }
    }
}

/// What generating text-to-speech audio will cost before any billable request goes
/// out: the narration characters that still need generating, the provider's
/// list price for them, and roughly how long the finished audio runs.
///
/// A whole book is the reason this counts sources as well as characters.
/// Listening auto-advances from one chapter to the next, so pressing Listen on
/// chapter one commits to the entire book — pricing only the chapter in hand
/// would understate the charge by two orders of magnitude.
struct ArticleSpeechCostEstimate: Equatable, Sendable {
    /// Narration characters spoken per minute. The TTS price table already uses
    /// this figure to convert audio-token prices into per-character rates, so
    /// reusing it keeps the duration shown beside a price consistent with how
    /// that price was derived.
    static let spokenCharactersPerMinute = 750.0

    /// Characters with no cached audio yet — what the provider would bill for.
    let characters: Int
    /// Sources those characters came from: 1 for a single source, the uncached
    /// chapter count for a book.
    let sourceCount: Int
    /// USD at the model's list price, or nil when this build has no rate for
    /// the model. A missing rate reads as "price unknown"; never as free.
    let usd: Double?
    /// OpenRouter's price in its own unit, for a model it does not bill by the
    /// character ("$1 / $20 per 1M tokens" for Gemini, "$0.15 / minute of
    /// audio" for Seed Audio): what the quote states in place of a total,
    /// which would have to be converted from a unit the narration is not
    /// counted in. Nil when `usd` is known or OpenRouter prices nothing.
    let unitPriceLabel: String?

    init(characters: Int, sourceCount: Int = 1, usd: Double?, unitPriceLabel: String? = nil) {
        self.characters = max(0, characters)
        self.sourceCount = max(0, sourceCount)
        self.usd = usd
        self.unitPriceLabel = usd == nil ? unitPriceLabel : nil
    }

    init(characters: Int, sourceCount: Int = 1, provider: String, model: String) {
        let rate = AIProviderPricing.ttsDisplayRatePerMillionCharacters(
            provider: provider,
            model: model
        )
        let unitPrice = rate == nil && provider.lowercased().contains("openrouter")
            ? OpenRouterAudioPrices.label(slug: model, kind: .speech)
            : nil
        self.init(
            characters: characters,
            sourceCount: sourceCount,
            usd: rate.map { Double(max(0, characters)) / 1_000_000 * $0 },
            unitPriceLabel: unitPrice
        )
    }

    var estimatedDuration: TimeInterval {
        Double(characters) / Self.spokenCharactersPerMinute * 60
    }

    /// "free", "less than $0.01", "$12.19", or "price unknown" — a tiny estimate
    /// must not render as $0.00, and an unpriced model must not render as free.
    var costLabel: String {
        guard let usd else {
            return unitPriceLabel.map { "priced at \($0)" } ?? "price unknown"
        }
        if usd == 0 { return "free" }
        if usd < 0.005 { return "less than $0.01" }
        return String(format: "$%.2f", usd)
    }

    /// "about 40 min" / "about 18 hr" / "about 3 hr 20 min". Rounded hard on
    /// purpose: this is a listening-length signal, not a running time.
    var durationLabel: String {
        let minutes = Int((estimatedDuration / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "about \(hours) hr" : "about \(hours) hr \(remainder) min"
    }

    /// "812,430 characters · about 18 hr · $12.19"
    var summary: String {
        "\(characters.formatted()) characters · \(durationLabel) · \(costLabel)"
    }

    /// The same summary prefixed with the source count, for a book's chapters:
    /// "37 chapters · 788,310 characters · about 17 hr · $11.82".
    func summary(countingSourcesAs noun: String) -> String {
        let plural = sourceCount == 1 ? noun : "\(noun)s"
        return "\(sourceCount.formatted()) \(plural) · \(self.summary)"
    }

    /// English prose, used when nothing better is available to calibrate with.
    static let fallbackCharactersPerWord = 6.0

    /// Characters per word, calibrated from a source whose exact narration
    /// length and stored word count are both known. Sibling book chapters often
    /// have only a word count until their own narration is prepared, and the
    /// book's own prose is a far better ratio for them than a fixed constant,
    /// which is wrong for dense technical text and wrong again in another
    /// language. Clamped so a stale word count cannot quote a wild price.
    static func charactersPerWord(narrationCharacters: Int, wordCount: Int?) -> Double {
        guard let wordCount, wordCount > 0, narrationCharacters > 0 else {
            return fallbackCharactersPerWord
        }
        return min(20, max(3, Double(narrationCharacters) / Double(wordCount)))
    }

    /// Merges a second body of narration priced at the same rate.
    func adding(_ other: ArticleSpeechCostEstimate) -> ArticleSpeechCostEstimate {
        ArticleSpeechCostEstimate(
            characters: characters + other.characters,
            sourceCount: sourceCount + other.sourceCount,
            usd: usd.flatMap { total in other.usd.map { total + $0 } },
            unitPriceLabel: unitPriceLabel == other.unitPriceLabel ? unitPriceLabel : nil
        )
    }
}

/// Account-level opt-ins for preparing text-to-speech audio as sources become ready.
/// The generic keys are shared by macOS, iOS, and Web Studio through the
/// existing Preference CloudKit records.
///
/// Automation is opt-in per *kind* — just articles, articles and papers, or
/// any other combination of the reading types. A kind is a source type, with
/// one exception: an explainer is stored as an article-typed source
/// (explainer-design.md) but has its own switch, because a learner who wants
/// every explainer narrated (product owner, 2026-09-20: "always generate audio for
/// explainers") does not thereby want every article narrated.
/// `kind(forSourceType:url:)` is the one place that tells the two apart, and
/// every surface keys its switches, filters, backlogs and progress by the kind
/// it returns. Automation is deliberately limited to exact zero-price catalog
/// models because one switch can cover hundreds of sources. Paid and unpriced
/// models fail closed on every client and executor.
///
/// Podcasts, videos, and recorded meetings are absent by design: they arrive as
/// audio already, and `ArticleSpeechContent.canAttemptRead` refuses to narrate
/// their transcripts.
enum SourceAudioAutomation {
    struct FilterCandidate: Codable, Equatable, Sendable {
        let id: String
        let sourceType: String
        let title: String
        let author: String?
        let journal: String?
        let year: String?
        let collection: String?
        let url: String?
        let description: String?
        let characterCount: Int?
    }

    struct FilterPreview: Equatable, Sendable {
        let constraint: String
        let matches: [FilterCandidate]

        var characterCount: Int? {
            guard matches.allSatisfy({ $0.characterCount != nil }) else { return nil }
            return matches.reduce(0) { $0 + ($1.characterCount ?? 0) }
        }

        func speechCost(ratePerMillionCharacters rate: Double?) -> Double? {
            guard let characterCount, let rate else { return nil }
            return Double(characterCount) / 1_000_000 * rate
        }
    }

    static let articlesPreferenceKey = Prefs.ReadAloud.autoGenerateArticles.name
    static let papersPreferenceKey = Prefs.ReadAloud.autoGeneratePapers.name
    static let booksPreferenceKey = Prefs.ReadAloud.autoGenerateBooks.name
    static let coursesPreferenceKey = Prefs.ReadAloud.autoGenerateCourses.name
    static let explainersPreferenceKey = Prefs.ReadAloud.autoGenerateExplainers.name

    /// The kind an explainer's switch is keyed by. Not a `StudioSourceType`:
    /// an explainer is an article-typed row told apart by its URL.
    static let explainerKind = "explainer"

    /// The automation kind of one source: `explainer` for a source whose URL
    /// names a spoken script — an explainer, or an audio overview's carrier —
    /// otherwise its source type. Every client derives the key for a switch,
    /// a filter or a backlog through this, so a spoken script never falls
    /// under the Articles switch and an article never under the Explainers
    /// switch.
    static func kind(forSourceType sourceType: String, url: String?) -> String {
        if let url, ExplainerScript.isSpokenScriptURL(url) { return explainerKind }
        return sourceType.lowercased()
    }

    /// One device's active automatic-generation pass. The count is deliberately
    /// source-level rather than chunk-level: it answers how much of the backlog
    /// is done without letting a long article make hundreds of tiny jumps.
    struct GenerationProgress: Equatable, Sendable {
        let completedCount: Int
        let totalCount: Int
        let currentSourceType: String?
        let currentTitle: String?

        var fractionCompleted: Double {
            guard totalCount > 0 else { return 0 }
            return min(max(Double(completedCount) / Double(totalCount), 0), 1)
        }

        var countLabel: String {
            "\(completedCount) of \(totalCount)"
        }

        var currentSourceLabel: String? {
            guard let currentSourceType,
                  let title = currentTitle else { return nil }
            let type = SourceAudioAutomation.noun(
                forSourceType: currentSourceType,
                count: 1
            )
            return "\(type.prefix(1).uppercased())\(type.dropFirst()) · \(title)"
        }

        var currentSourceSystemImage: String {
            switch currentSourceType {
            case "paper": return "doc.text.magnifyingglass"
            case "book": return "book.closed"
            case "course": return "graduationcap"
            case SourceAudioAutomation.explainerKind: return "lightbulb"
            default: return "doc.richtext"
            }
        }
    }

    /// One kind automation covers, with the words every surface uses for it. A
    /// kind is automatable exactly when it appears in `automatable`, so adding
    /// one is an entry here plus its keys in `SyncedPreferenceKeys`.
    struct AutomatableType: Equatable, Sendable {
        /// The automation kind: a raw `StudioSourceType`, or `explainerKind`.
        /// Named for the four entries that are types; read it as the kind.
        let sourceType: String
        /// The kind's switch, and the standing instruction that narrows what
        /// it narrates.
        let key: AccountKey<Bool?>
        let constraintKey: AccountKey<String?>
        var preferenceKey: String { key.name }
        /// Matches the Studio tab, so the switch names what the learner sees.
        let switchTitle: String
        /// What one of them is called in a sentence — a book's sources are
        /// chapters, not books, and the counts have to say so.
        let singular: String
        let plural: String

        static func == (lhs: AutomatableType, rhs: AutomatableType) -> Bool {
            lhs.sourceType == rhs.sourceType
                && lhs.key.name == rhs.key.name
                && lhs.constraintKey.name == rhs.constraintKey.name
                && lhs.switchTitle == rhs.switchTitle
                && lhs.singular == rhs.singular
                && lhs.plural == rhs.plural
        }
    }

    /// The automatable types, in the order settings lists them.
    static let automatable: [AutomatableType] = [
        AutomatableType(
            sourceType: "article",
            key: Prefs.ReadAloud.autoGenerateArticles,
            constraintKey: Prefs.ReadAloud.autoGenerateConstraintArticle,
            switchTitle: "Articles",
            singular: "article",
            plural: "articles"
        ),
        AutomatableType(
            sourceType: "paper",
            key: Prefs.ReadAloud.autoGeneratePapers,
            constraintKey: Prefs.ReadAloud.autoGenerateConstraintPaper,
            switchTitle: "Papers",
            singular: "paper",
            plural: "papers"
        ),
        AutomatableType(
            sourceType: "book",
            key: Prefs.ReadAloud.autoGenerateBooks,
            constraintKey: Prefs.ReadAloud.autoGenerateConstraintBook,
            switchTitle: "Books",
            singular: "book chapter",
            plural: "book chapters"
        ),
        AutomatableType(
            sourceType: "course",
            key: Prefs.ReadAloud.autoGenerateCourses,
            constraintKey: Prefs.ReadAloud.autoGenerateConstraintCourse,
            switchTitle: "Courses",
            singular: "course document",
            plural: "course documents"
        ),
        // Explainers are article-typed rows with a switch of their own:
        // "always generate audio for explainers" must not mean every article.
        // A notebook's audio overview is a spoken script too, and falls under
        // this switch (`kind(forSourceType:url:)`), never under Articles.
        AutomatableType(
            sourceType: explainerKind,
            key: Prefs.ReadAloud.autoGenerateExplainers,
            constraintKey: Prefs.ReadAloud.autoGenerateConstraintExplainer,
            switchTitle: "Explainers",
            singular: "explainer",
            plural: "explainers"
        ),
    ]

    /// The automatable kinds, in the order settings lists them.
    static var automatableSourceTypes: [String] { automatable.map(\.sourceType) }

    /// Account-level consent to let automatic audio use a priced voice. Synced,
    /// so granting it on one device authorizes the others; each device still
    /// spends at whatever rate its own text-to-speech selection carries.
    static let paidVoiceConsentPreferenceKey = Prefs.ReadAloud.autoGenerateAllowPaidVoices.name

    static func allowsPaidVoices(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Prefs.ReadAloud.autoGenerateAllowPaidVoices.name)
    }

    /// Whether automatic generation may run with this selection.
    ///
    /// Free entries always qualify. A priced entry qualifies only behind
    /// explicit account consent, and an entry this build cannot price never
    /// qualifies at all: a missing or stale rate must never turn a
    /// library-wide preference into an unbounded charge, and consent to a
    /// number the learner was shown is not consent to an unknown one.
    static func allowsAutomaticGeneration(
        provider: String,
        model: String,
        allowsPaidVoices: Bool = false
    ) -> Bool {
        guard let rate = AIProviderPricing.ttsDisplayRatePerMillionCharacters(
            provider: provider,
            model: model
        ) else { return false }
        return rate == 0 || (allowsPaidVoices && rate > 0)
    }

    /// True when this selection runs only because consent was granted — what
    /// the cautionary copy and the Stop control key off.
    static func requiresPaidVoiceConsent(provider: String, model: String) -> Bool {
        guard let rate = AIProviderPricing.ttsDisplayRatePerMillionCharacters(
            provider: provider,
            model: model
        ) else { return false }
        return rate > 0
    }

    static func automatableType(for sourceType: String) -> AutomatableType? {
        let normalized = sourceType.lowercased()
        return automatable.first { $0.sourceType == normalized }
    }

    static func preferenceKey(for sourceType: String) -> String? {
        automatableType(for: sourceType)?.preferenceKey
    }

    static func constraintPreferenceKey(for sourceType: String) -> String? {
        automatableType(for: sourceType)?.constraintKey.name
    }

    static func constraint(
        for sourceType: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let key = automatableType(for: sourceType)?.constraintKey,
              let value = defaults.string(forKey: key.name)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func isEnabled(for sourceType: String, defaults: UserDefaults = .standard) -> Bool {
        guard let key = automatableType(for: sourceType)?.key else { return false }
        return defaults.bool(forKey: key.name)
    }

    /// The automatable kinds whose switch is on.
    static func enabledSourceTypes(defaults: UserDefaults = .standard) -> Set<String> {
        Set(automatableSourceTypes.filter { isEnabled(for: $0, defaults: defaults) })
    }

    // MARK: - Naming

    /// Switch title for one automatable type ("Articles").
    static func switchTitle(forSourceType sourceType: String) -> String {
        automatableType(for: sourceType)?.switchTitle ?? "Sources"
    }

    /// "article" / "articles", for sentences that count sources.
    static func noun(forSourceType sourceType: String, count: Int) -> String {
        guard let type = automatableType(for: sourceType) else {
            return count == 1 ? "source" : "sources"
        }
        return count == 1 ? type.singular : type.plural
    }

    // MARK: - What switching one on will spend

    /// The sources a type would generate the moment its switch goes on: every
    /// ready, readable source of that type that has no audio yet.
    ///
    /// `characterCount` is the surface's best measure of the narration those
    /// sources will produce. Articles and papers use the exact durable
    /// listen-ready derivative consumed by TTS. A client that cannot establish
    /// that length leaves the quote unknown instead of substituting raw source
    /// text, word counts, or historical spend.
    struct Backlog: Equatable, Sendable {
        var sourceCount: Int
        var characterCount: Int?

        init(sourceCount: Int = 0, characterCount: Int? = nil) {
            self.sourceCount = sourceCount
            self.characterCount = characterCount
        }

        /// Estimated dollars to clear this backlog, or nil when neither
        /// the selected model's current rate nor a character total is known.
        /// Historical usage is deliberately not an input: it may describe a
        /// different model, voice, or rate and cannot price the current choice.
        func estimatedCost(ratePerMillionCharacters rate: Double?) -> Double? {
            guard sourceCount > 0 else { return 0 }
            guard let rate, rate >= 0, let characterCount, characterCount > 0 else { return nil }
            return Double(characterCount) / 1_000_000 * rate
        }
    }

    /// What granting paid consent would start right now, priced per type and in
    /// total, so the dialog quotes the whole pending library rather than an
    /// abstract rate. Types with nothing waiting are omitted; a type that
    /// cannot be sized is reported so the total never reads as complete when
    /// part of the library is unmeasured.
    struct LibraryCostPreview: Equatable, Sendable {
        struct Line: Equatable, Sendable {
            let sourceType: String
            let backlog: Backlog
        }

        let lines: [Line]
        let ratePerMillionCharacters: Double?

        init(backlogs: [String: Backlog], ratePerMillionCharacters rate: Double?) {
            self.lines = automatableSourceTypes.compactMap { sourceType in
                guard let backlog = backlogs[sourceType], backlog.sourceCount > 0 else { return nil }
                return Line(sourceType: sourceType, backlog: backlog)
            }
            self.ratePerMillionCharacters = rate
        }

        var sourceCount: Int { lines.reduce(0) { $0 + $1.backlog.sourceCount } }

        var isEmpty: Bool { sourceCount == 0 }

        /// Nil when any waiting type could not be sized, so a partial sum is
        /// never presented as the whole bill.
        var characterCount: Int? {
            guard lines.allSatisfy({ $0.backlog.characterCount != nil }) else { return nil }
            return lines.reduce(0) { $0 + ($1.backlog.characterCount ?? 0) }
        }

        var total: ArticleSpeechCostEstimate? {
            guard let characterCount else { return nil }
            return ArticleSpeechCostEstimate(
                characters: characterCount,
                sourceCount: sourceCount,
                usd: ratePerMillionCharacters.map { Double(characterCount) / 1_000_000 * $0 }
            )
        }

        /// "Papers · 96 papers · 4,800,000 characters · about 107 hr · $72.00"
        func lineLabels() -> [String] {
            lines.map { line in
                let counted = "\(line.backlog.sourceCount) "
                    + noun(forSourceType: line.sourceType, count: line.backlog.sourceCount)
                guard let characters = line.backlog.characterCount else {
                    return "\(switchTitle(forSourceType: line.sourceType)) · \(counted) · size unavailable"
                }
                let estimate = ArticleSpeechCostEstimate(
                    characters: characters,
                    sourceCount: line.backlog.sourceCount,
                    usd: ratePerMillionCharacters.map { Double(characters) / 1_000_000 * $0 }
                )
                return "\(switchTitle(forSourceType: line.sourceType)) · \(counted) · \(estimate.summary)"
            }
        }

        var totalLabel: String {
            guard let total else {
                return "\(sourceCount) sources · total size unavailable"
            }
            return "\(sourceCount) sources · \(total.summary)"
        }
    }

    /// The consent body: which voice, at what rate, and what the pending
    /// library would cost at that rate before anything is generated.
    static func paidVoiceConsentMessage(
        voiceName: String,
        preview: LibraryCostPreview
    ) -> String {
        var parts: [String] = []
        if let label = rateLabel(ratePerMillionCharacters: preview.ratePerMillionCharacters) {
            parts.append("\(voiceName) costs \(label).")
        } else {
            parts.append("\(voiceName) has no published rate.")
        }
        if preview.isEmpty {
            parts.append(
                "Nothing is waiting right now, so allowing this spends nothing until the next "
                + "source arrives — and then every source of a type you switch on is charged."
            )
        } else {
            parts.append("Switching a type on would start generating now:")
            parts.append(contentsOf: preview.lineLabels())
            parts.append("Total: \(preview.totalLabel).")
            parts.append(
                "Generation starts as soon as you switch a type on and continues for every "
                + "source that arrives afterwards. You can stop a run in progress, but sources "
                + "already narrated are still billed."
            )
        }
        return parts.joined(separator: "\n")
    }

    /// "812,430 characters · about $32.50 of speech", or nil when the
    /// current backlog cannot be sized and priced.
    ///
    /// The selected model's rate prices the speech request alone, while
    /// automation may also prepare a source's narration first, so the label
    /// does not misrepresent the number as the whole bill.
    static func estimateLabel(
        for backlog: Backlog,
        ratePerMillionCharacters rate: Double?
    ) -> String? {
        guard let characters = backlog.characterCount,
              characters > 0,
              let cost = backlog.estimatedCost(ratePerMillionCharacters: rate) else {
            return nil
        }
        if cost == 0 {
            return "\(characters.formatted()) characters · free"
        }
        return "\(characters.formatted()) characters · about \(costLabel(cost)) of speech"
    }

    /// Narration characters one source is likely to produce. Content length is
    /// exact where a client holds the text; a word count is the fallback, at
    /// the same characters-per-word `ArticleSpeechCostEstimate` uses when it
    /// prices a book's unprepared chapters.
    static func estimatedCharacters(wordCount: Int?, contentCharacterCount: Int?) -> Int? {
        if let contentCharacterCount, contentCharacterCount > 0 { return contentCharacterCount }
        if let wordCount, wordCount > 0 {
            return Int(Double(wordCount) * ArticleSpeechCostEstimate.fallbackCharactersPerWord)
        }
        return nil
    }

    /// "$0.42", or "less than $0.01" so a real charge never renders as $0.00.
    /// Formatting is `ArticleSpeechCostEstimate`'s, so the price of switching
    /// automation on and the price quoted by Listen round the same way.
    static func costLabel(_ usd: Double) -> String {
        ArticleSpeechCostEstimate(characters: 0, usd: usd).costLabel
    }

    /// "$40 / 1M characters" for the selected voice, or nil when the rate card
    /// does not price this model.
    static func rateLabel(ratePerMillionCharacters rate: Double?) -> String? {
        guard let rate else { return nil }
        if rate == 0 { return "free" }
        let dollars = rate < 1 ? String(format: "$%.2f", rate) : String(format: "$%.0f", rate)
        return "\(dollars) / 1M characters"
    }

    /// The standing disclosure shown beside the switches. Free selections need
    /// no consent; priced ones run only after it; unpriced ones never run.
    static func costDisclosure(
        ratePerMillionCharacters rate: Double?,
        allowsPaidVoices: Bool = false
    ) -> String {
        guard let rate else {
            return "This voice has no published price, so automatic audio stays off. Choose a "
                + "voice with a listed rate."
        }
        if rate == 0 {
            return "Audio is generated with the selected free voice as soon as a source is ready — "
                + "including sources already in your library."
        }
        guard allowsPaidVoices else {
            let label = rateLabel(ratePerMillionCharacters: rate) ?? "its listed rate"
            return "Automatic audio is off for paid voices. Allow paid voices from chat to narrate "
                + "your library at \(label), or pick a free voice."
        }
        let label = rateLabel(ratePerMillionCharacters: rate) ?? "its listed rate"
        return "Paid voices are allowed: every source of a switched-on type is narrated at "
            + "\(label) — including your existing library — and billed to your OpenRouter key."
    }
}

extension Notification.Name {
    static let automaticSourceAudioPreferencesChanged = Notification.Name(
        "automaticSourceAudioPreferencesChanged"
    )
    static let automaticSourceAudioCandidateDidChange = Notification.Name(
        "automaticSourceAudioCandidateDidChange"
    )
}

/// The iPhone's text-to-speech model and, per model, its voice.
///
/// Storage is device-local under the `ios.` prefix, which the account
/// preference sync rail excludes: the Mac keeps its own text-to-speech selection in
/// Settings → Article Speech, and the two are deliberately independent because
/// they drive different playback stacks.
///
/// Every read is validated against the catalog, so a selection stored by an
/// older build — or one whose model has since been retired — resolves to the
/// default instead of travelling to the wire and failing there. The catalog
/// follows OpenRouter's directory, so a caller about to generate reads it
/// first (`OpenRouterAudioDirectory.prepare`): a model picked from a live
/// list is not in the list this build records.
enum ArticleSpeechSelection {
    static let modelDefaultsKey = Prefs.Mobile.readAloudModel.name

    /// The account rows the Mac's Settings already write for the same choice —
    /// `KeychainService.Key.ttsModelOpenRouter`, `MacArticleSpeechSettings`'
    /// OpenRouter voice key and the provider row. The phone reads and writes
    /// these same rows, so a model picked on either device is the one the
    /// other narrates with; its own `ios.readAloud.*` defaults are the device
    /// copy that `CloudArticleTTS` reads off the main actor.
    static let syncedModelKey = Prefs.Models.ttsModelOpenRouter.name
    static let syncedVoiceKey = Prefs.ReadAloud.openRouterVoice.name
    static let syncedProviderKey = Prefs.Models.ttsProvider.name
    /// `MacArticleSpeechMode.openRouter.rawValue`: the one provider the shared
    /// catalog is served through, and the only one the Mac's picker offers.
    static let syncedProvider = "openrouter"

    static func voiceDefaultsKey(forModel modelID: String) -> String {
        Prefs.Families.readAloudDeviceVoice.name(modelID)
    }

    /// Read off the main actor by `CloudArticleTTS` while it builds a request,
    /// so this stays plain `UserDefaults` access rather than observable state.
    static func modelID(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stored.isEmpty,
              !ArticleSpeechCatalog.isRetiredModel(stored),
              ArticleSpeechCatalog.model(id: stored) != nil else {
            return ArticleSpeechCatalog.defaultModelID
        }
        return stored
    }

    static func voiceID(forModel modelID: String, defaults: UserDefaults = .standard) -> String? {
        ArticleSpeechCatalog.resolvedVoiceID(
            Preferences.withStorage(defaults) { Preferences.value(Prefs.Families.readAloudDeviceVoice.key(modelID)) },
            forModel: modelID
        )
    }

    static func selectModel(_ modelID: String, defaults: UserDefaults = .standard) {
        guard ArticleSpeechCatalog.model(id: modelID) != nil else { return }
        defaults.set(modelID, forKey: modelDefaultsKey)
    }

    static func selectVoice(_ voiceID: String, forModel modelID: String, defaults: UserDefaults = .standard) {
        guard ArticleSpeechCatalog.model(id: modelID)?.voice(id: voiceID) != nil else { return }
        Preferences.withStorage(defaults) { Preferences.set(voiceID, for: Prefs.Families.readAloudDeviceVoice.key(modelID)) }
    }

    /// Applies the account's selection to this device. A model the catalog no
    /// longer offers is left alone rather than adopted, so a stale account row
    /// cannot break narration here; the voice resolves against the model, so a
    /// voice recorded for another model becomes this model's first voice.
    /// Returns what was applied, nil when nothing was.
    @discardableResult
    static func adoptSyncedSelection(
        model: String?,
        voice: String?,
        defaults: UserDefaults = .standard
    ) -> (model: String, voice: String?)? {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty,
              !ArticleSpeechCatalog.isRetiredModel(model),
              ArticleSpeechCatalog.model(id: model) != nil else { return nil }
        defaults.set(model, forKey: modelDefaultsKey)
        let resolvedVoice = ArticleSpeechCatalog.resolvedVoiceID(voice, forModel: model)
        if let resolvedVoice {
            Preferences.withStorage(defaults) { Preferences.set(resolvedVoice, for: Prefs.Families.readAloudDeviceVoice.key(model)) }
        }
        return (model, resolvedVoice)
    }
}

/// The observable face of `ArticleSpeechSelection`, so the model row and the
/// pushed voice list stay in step. Storage stays in the plain enum above,
/// which is what the generator reads off the main actor.
@MainActor
final class ArticleSpeechPreferences: ObservableObject {
    static let shared = ArticleSpeechPreferences()

    @Published private(set) var modelID: String
    /// Model id to voice id, for models whose voice has been chosen. Absent
    /// means the model's first catalog voice.
    @Published private(set) var voiceIDs: [String: String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modelID = ArticleSpeechSelection.modelID(defaults: defaults)
        voiceIDs = Self.storedVoiceIDs(defaults: defaults)
    }

    private static func storedVoiceIDs(defaults: UserDefaults) -> [String: String] {
        var selected: [String: String] = [:]
        for model in ArticleSpeechCatalog.models {
            guard let voice = Preferences.withStorage(defaults, {
                Preferences.value(Prefs.Families.readAloudDeviceVoice.key(model.id))
            }) else { continue }
            selected[model.id] = voice
        }
        return selected
    }

    /// Re-reads the stored pick against the catalog as it stands now. Called
    /// after a directory read: a model chosen from OpenRouter's list on an
    /// earlier launch reads as the default until the list is known again, and
    /// its voice was not in the models `init` walked.
    func reloadFromStorage() {
        let model = ArticleSpeechSelection.modelID(defaults: defaults)
        if modelID != model { modelID = model }
        let voices = Self.storedVoiceIDs(defaults: defaults)
        if voiceIDs != voices { voiceIDs = voices }
    }

    /// A voice the model still offers. Never returns a stored id the catalog
    /// has dropped.
    func voiceID(forModel modelID: String) -> String? {
        ArticleSpeechCatalog.resolvedVoiceID(voiceIDs[modelID], forModel: modelID)
    }

    func voiceName(forModel modelID: String) -> String {
        guard let voice = voiceID(forModel: modelID) else { return "Unavailable" }
        return ArticleSpeechCatalog.voiceSettingsLabel(model: modelID, voice: voice)
    }

    func selectModel(_ newModelID: String) {
        guard ArticleSpeechCatalog.model(id: newModelID) != nil, newModelID != modelID else { return }
        ArticleSpeechSelection.selectModel(newModelID, defaults: defaults)
        modelID = newModelID
    }

    func selectVoice(_ voiceID: String, forModel modelID: String) {
        guard ArticleSpeechCatalog.model(id: modelID)?.voice(id: voiceID) != nil,
              voiceIDs[modelID] != voiceID else { return }
        ArticleSpeechSelection.selectVoice(voiceID, forModel: modelID, defaults: defaults)
        voiceIDs[modelID] = voiceID
    }

    /// The account's selection, as another device left it. The published
    /// state follows so an open Settings screen shows the pick.
    func adoptSyncedSelection(model: String?, voice: String?) {
        guard let applied = ArticleSpeechSelection.adoptSyncedSelection(
            model: model,
            voice: voice,
            defaults: defaults
        ) else { return }
        if modelID != applied.model { modelID = applied.model }
        if let voice = applied.voice, voiceIDs[applied.model] != voice {
            voiceIDs[applied.model] = voice
        }
    }
}
