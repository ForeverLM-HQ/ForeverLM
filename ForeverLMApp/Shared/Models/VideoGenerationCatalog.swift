import Foundation
import os

/// One video model OpenRouter's video API serves, as its directory
/// (`GET /api/v1/videos/models`) describes it.
///
/// Every clip ForeverLM films goes through OpenRouter (product owner, 2026-09-27:
/// "it can just be done via openrouter"), on the learner's own key or through
/// the managed proxy's job route. So the catalog is OpenRouter's own list,
/// read live, and a model OpenRouter adds shows up in Settings › Videos
/// without a code change.
struct VideoGenerationModel: Identifiable, Equatable, Sendable {
    /// OpenRouter's slug ("google/veo-3.1-fast"): what a request names.
    let id: String
    /// "Veo 3.1 Fast": the directory's name without its "Maker: " prefix.
    let name: String
    /// "Google": the prefix OpenRouter puts before the name.
    let maker: String
    let detail: String
    /// When OpenRouter first listed the model; the picker lists newest first.
    let createdAt: Date?
    /// The clip lengths the model makes, in seconds.
    let durations: [Int]
    /// The resolutions it films at that ForeverLM offers (4K never is: a
    /// minute of explainer at 4K is a gigabyte in iCloud and far dearer, for
    /// a picture watched in a pane), lowest first.
    let resolutions: [VideoGenerationCatalog.Resolution]
    let aspectRatios: [String]
    /// Whether the model makes sound: true when it takes `generate_audio`,
    /// false when OpenRouter says it is silent, nil when OpenRouter does not
    /// say. An explainer's narration is spoken inside its clips, so a silent
    /// model makes a silent film.
    let makesSound: Bool?
    /// USD per second of finished video, by resolution, read from the
    /// directory's `pricing_skus` (see `VideoGenerationCatalog.usdPerSecond`).
    let usdPerSecond: [VideoGenerationCatalog.Resolution: Double]
    /// Whether OpenRouter prices it by video tokens, so no clip price can be
    /// quoted before it is made; the charge is OpenRouter's reported cost.
    let pricedByTokens: Bool

    /// Whether the request asks for sound. OpenRouter refuses a field a model
    /// does not list, so it is sent only to models that take it.
    var takesGenerateAudio: Bool { makesSound == true }

    func usdPerSecond(at resolution: VideoGenerationCatalog.Resolution) -> Double? {
        usdPerSecond[resolution]
    }

    /// Whether every rate OpenRouter publishes for the model is zero. A model
    /// priced by video tokens, or with no published rate, is not free: its
    /// charge is known only once a clip is made.
    var isFree: Bool {
        !pricedByTokens && !usdPerSecond.isEmpty && usdPerSecond.values.allSatisfy { $0 == 0 }
    }

    /// How long one scene's clip is: the shortest length the model makes that
    /// holds an eight-second scene's narration, or its longest when none does.
    /// Every OpenRouter model but three makes eight seconds; those three make
    /// ten, so the narration always fits and only the price differs.
    var clipSeconds: Int {
        durations.filter { $0 >= VideoGenerationCatalog.clipSeconds }.min()
            ?? durations.max()
            ?? VideoGenerationCatalog.clipSeconds
    }

    /// The maker's slug prefix ("google", "kwaivgi"): a stable grouping key.
    var makerSlug: String {
        id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
    }

    /// A model known only by its id, for a stored choice read before the
    /// directory has arrived. `ManagedVideoGeneration` resolves it against the
    /// directory before anything is filmed.
    static func unresolved(id: String) -> VideoGenerationModel {
        VideoGenerationModel(
            id: id,
            name: id.split(separator: "/").last.map(String.init) ?? id,
            maker: "",
            detail: "",
            createdAt: nil,
            durations: [],
            resolutions: [],
            aspectRatios: [],
            makesSound: nil,
            usdPerSecond: [:],
            pricedByTokens: false
        )
    }

    var isResolved: Bool { !maker.isEmpty }
}

/// The video models ForeverLM offers — every one OpenRouter's video API serves
/// that films from a prompt — and how their prices are read.
enum VideoGenerationCatalog {
    /// One frame size a clip is filmed at, as OpenRouter names it ("720p",
    /// "1080p", "2K").
    struct Resolution: RawRepresentable, Hashable, Codable, Identifiable, Sendable, Comparable {
        let rawValue: String

        init?(rawValue: String) {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self.rawValue = trimmed
        }

        private init(known: String) { rawValue = known }

        static let hd = Resolution(known: "720p")
        static let fullHD = Resolution(known: "1080p")

        var id: String { rawValue.lowercased() }
        var displayName: String { rawValue }

        /// Whether this is a 4K frame, which ForeverLM never films at.
        var isUltraHD: Bool { ["4k", "2160p"].contains(id) }

        /// Frame height, for ordering: "720p" is 720, "2K" 1440, "4K" 2160.
        var height: Int {
            switch id {
            case "2k": return 1440
            case "4k": return 2160
            default: return Int(id.prefix { $0.isNumber }) ?? 0
            }
        }

        static func < (lhs: Resolution, rhs: Resolution) -> Bool {
            lhs.height == rhs.height ? lhs.id < rhs.id : lhs.height < rhs.height
        }

        static func == (lhs: Resolution, rhs: Resolution) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let value = Resolution(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Empty resolution"))
            }
            self = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// The scene length an explainer's storyboard is written for: one or two
    /// narrated sentences. A model's own clip is at least this long
    /// (`VideoGenerationModel.clipSeconds`).
    static let clipSeconds = 8

    static let aspectRatio = "16:9"

    /// Google's quick Veo tier: sound and speech included, a quarter of the
    /// flagship's price, and the model explainers were tuned on.
    static let defaultModelID = "google/veo-3.1-fast"

    /// Settings › Videos' Suggested list: one model per maker, the best that
    /// is still affordable, as Settings › Chat suggests its own. Picked from
    /// OpenRouter's video directory on 2026-09-28, at 720p: Veo 3.1 Fast
    /// $0.10 a second with sound, Wan 3.0 $0.10, Kling v3.0 Standard $0.084,
    /// MiniMax's H3 Max $0.08, Runway Gen-4.5 $0.12, Grok Imagine Video 1.5
    /// $0.14, FLUX.3 Video $0.17, Seedance 2.0 Fast by video tokens; Sora 2
    /// Pro, $0.30, is OpenAI's only one. A model OpenRouter stops serving
    /// drops off the list.
    static let suggestedModelIDs = [
        "openai/sora-2-pro",
        "google/veo-3.1-fast",
        "x-ai/grok-imagine-video-1.5",
        "alibaba/wan-3.0",
        "bytedance/seedance-2.0-fast",
        "kwaivgi/kling-v3.0-std",
        "minimax/hailuo-3-max",
        "runway/gen-4.5",
        "black-forest-labs/flux-3-video",
    ]

    static let directoryURL = URL(string: "https://openrouter.ai/api/v1/videos/models")!

    /// The ids stored before 2026-09-27, when Veo was filmed on Google's own
    /// API, and the OpenRouter slug each became.
    static let makerNativeIDs: [String: String] = [
        "veo-3.1-fast-generate-preview": "google/veo-3.1-fast",
        "veo-3.1-lite-generate-preview": "google/veo-3.1-lite",
        "veo-3.1-generate-preview": "google/veo-3.1",
    ]

    static func canonicalID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return makerNativeIDs[trimmed] ?? trimmed
    }

    /// The models of the last directory read, newest first; empty until one
    /// has arrived.
    static var models: [VideoGenerationModel] { VideoGenerationDirectory.snapshot }

    /// Any model the last read listed — for naming a clip already made.
    static func model(id: String) -> VideoGenerationModel? {
        let id = canonicalID(id)
        return models.first { $0.id == id }
    }

    /// The stored model: its directory entry once the directory has been read,
    /// the default when the directory no longer lists it, and an unresolved
    /// stand-in before the first read.
    static func resolvedModel(id: String?) -> VideoGenerationModel {
        resolvedModel(id: id, in: models)
    }

    static func resolvedModel(id: String?, in models: [VideoGenerationModel]) -> VideoGenerationModel {
        let wanted = id.map(canonicalID).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModelID
        guard !models.isEmpty else { return .unresolved(id: wanted) }
        if let match = models.first(where: { $0.id == wanted }) { return match }
        return models.first { $0.id == defaultModelID } ?? models[0]
    }

    /// The stored resolution when the model films at it; otherwise the one
    /// nearest 720p (a tie goes to the sharper), so a model without 720p films
    /// at 768p rather than 480p.
    static func resolvedResolution(_ raw: String?, for model: VideoGenerationModel) -> Resolution {
        if let raw, let resolution = Resolution(rawValue: raw), model.resolutions.contains(resolution) {
            return resolution
        }
        return model.resolutions.min { lhs, rhs in
            let (l, r) = (abs(lhs.height - Resolution.hd.height), abs(rhs.height - Resolution.hd.height))
            return l == r ? lhs.height > rhs.height : l < r
        } ?? .hd
    }

    /// The exact charge for one clip from the published rate. Nil when the
    /// model is not priced per second at that resolution — never a guess.
    static func clipCostUSD(model: VideoGenerationModel, resolution: Resolution, seconds: Int? = nil) -> Double? {
        guard let rate = model.usdPerSecond(at: resolution) else { return nil }
        return rate * Double(seconds ?? model.clipSeconds)
    }

    /// A per-second rate at the precision it is published: "$0.10", "$0.168",
    /// "$0.0988" — two decimals at least, never rounded away.
    static func rateLabel(_ usd: Double) -> String {
        var text = String(format: "%.4f", usd)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return "$" + text
    }

    /// "$0.80", "$4.00" — always two decimals, because these are dollars.
    static func costLabel(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    // MARK: - Reading OpenRouter's directory

    private struct DirectoryResponse: Decodable {
        let data: [OpenRouterLossyRow<Row>]
    }

    private struct Row: Decodable {
        let id: String
        let name: String?
        let description: String?
        let created: Double?
        let supported_resolutions: [String]?
        let supported_aspect_ratios: [String]?
        let supported_durations: [Int]?
        let generate_audio: Bool?
        let pricing_skus: [String: OpenRouterPriceValue]?
    }

    /// The models in one directory response that ForeverLM can film with.
    ///
    /// Left out: a model with no clip lengths (the editors, the upscaler and
    /// HeyGen's avatars, which change a video or animate a presenter rather
    /// than film from a prompt), and one that films only at 4K.
    static func models(fromDirectory data: Data) throws -> [VideoGenerationModel] {
        let rows = try JSONDecoder().decode(DirectoryResponse.self, from: data).data.compactMap(\.value)
        return rows.compactMap(model(from:)).sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    private static func model(from row: Row) -> VideoGenerationModel? {
        let durations = (row.supported_durations ?? []).filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return nil }
        let resolutions = Array(Set((row.supported_resolutions ?? []).compactMap(Resolution.init(rawValue:))))
            .filter { !$0.isUltraHD }
            .sorted()
        guard !resolutions.isEmpty else { return nil }

        let rawName = row.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? row.id
        let parts = rawName.components(separatedBy: ": ")
        let maker = parts.count > 1 ? parts[0] : (row.id.split(separator: "/").first.map(String.init) ?? row.id)
        let name = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : rawName
        let skus = (row.pricing_skus ?? [:]).compactMapValues(\.text)
        let withSound = row.generate_audio == true
        var rates: [Resolution: Double] = [:]
        for resolution in resolutions {
            rates[resolution] = usdPerSecond(skus: skus, resolution: resolution, withSound: withSound)
        }
        return VideoGenerationModel(
            id: row.id,
            name: name,
            maker: maker,
            detail: ImageGenerationCatalog.plainDescription(row.description),
            createdAt: row.created.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            durations: durations,
            resolutions: resolutions,
            aspectRatios: row.supported_aspect_ratios ?? [],
            makesSound: row.generate_audio,
            usdPerSecond: rates,
            pricedByTokens: skus.keys.contains { $0.lowercased().hasPrefix("video_tokens") }
        )
    }

    /// The per-second price of a clip at `resolution`, from OpenRouter's
    /// `pricing_skus`.
    ///
    /// The SKU names differ by provider — `duration_seconds_720p`,
    /// `duration_seconds_with_audio`, `text_to_video_duration_seconds_1080p`,
    /// `cents_per_second_output_720p`, `cents_per_video_output_second_480p` —
    /// so they are read in one fixed order: a price with sound (or, for a
    /// silent clip, without it) at this resolution, then at any, then the
    /// plain price at this resolution, then the plain price at any. The
    /// `cents_` SKUs are cents. A model priced only by video tokens, or by a
    /// SKU not listed here, has no per-second price, which the pane and the
    /// cost question say rather than estimate. Mirrored by the proxy's
    /// `openRouterVideoUSDPerSecond`, which prices the same clip before it
    /// admits it.
    static func usdPerSecond(skus: [String: String], resolution: Resolution, withSound: Bool) -> Double? {
        var table: [String: Double] = [:]
        for (key, value) in skus {
            if let number = Double(value.trimmingCharacters(in: .whitespaces)), number >= 0 {
                table[key.lowercased()] = number
            }
        }
        let r = resolution.id
        let dollars = withSound
            ? ["duration_seconds_with_audio_\(r)", "duration_seconds_with_audio"]
            : ["duration_seconds_without_audio_\(r)", "duration_seconds_without_audio"]
        let suffixed: [(String, Double)] = [
            ("duration_seconds_\(r)", 1),
            ("text_to_video_duration_seconds_\(r)", 1),
            ("cents_per_video_output_second_\(r)", 0.01),
            ("cents_per_second_output_\(r)", 0.01),
        ]
        let plain: [(String, Double)] = [
            ("duration_seconds", 1),
            ("cents_per_second_output", 0.01),
        ]
        for key in dollars {
            if let value = table[key] { return value }
        }
        for (key, scale) in suffixed + plain {
            if let value = table[key] { return value * scale }
        }
        return nil
    }
}

/// OpenRouter's video models, read live (see `VideoGenerationModel`). One
/// directory request carries everything, prices included.
enum VideoGenerationDirectory {
    enum Failure: LocalizedError, Sendable {
        case unreachable(String)
        case notServed(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let reason):
                return "OpenRouter's list of video models could not be read: \(reason)"
            case .notServed(let id):
                return "OpenRouter no longer serves \(id) for video. Pick another model in Settings › Videos."
            }
        }
    }

    private static let latest = OSAllocatedUnfairLock<[VideoGenerationModel]>(initialState: [])

    static var snapshot: [VideoGenerationModel] { latest.withLock { $0 } }

    private static let directory = OpenRouterMediaDirectoryCache<[VideoGenerationModel]>(freshness: 30 * 60) {
        var request = URLRequest(url: VideoGenerationCatalog.directoryURL)
        request.timeoutInterval = 30
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
        guard let models = try? VideoGenerationCatalog.models(fromDirectory: data) else {
            throw Failure.unreachable("OpenRouter's answer was not the model list ForeverLM reads.")
        }
        guard !models.isEmpty else { throw Failure.unreachable("It listed no model that films from a prompt.") }
        return models
    }

    static func models(forceRefresh: Bool = false) async throws -> [VideoGenerationModel] {
        let models = try await directory.current(forceRefresh: forceRefresh)
        latest.withLock { $0 = models }
        return models
    }

    /// The directory entry for a model a caller holds, which may be the
    /// unresolved stand-in for a stored choice. Throws when OpenRouter does
    /// not list it, rather than filming on some other model.
    static func resolve(_ model: VideoGenerationModel) async throws -> VideoGenerationModel {
        let id = VideoGenerationCatalog.canonicalID(model.id)
        guard let match = try await models().first(where: { $0.id == id }) else { throw Failure.notServed(id) }
        return match
    }

    /// Starts a directory read in the background when none has happened yet.
    static func warm() {
        guard snapshot.isEmpty else { return }
        Task.detached(priority: .utility) { _ = try? await models() }
    }
}
