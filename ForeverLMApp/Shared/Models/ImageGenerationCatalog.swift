import Foundation
import os

/// What one picture costs on a model's OpenRouter endpoint, in the unit
/// OpenRouter bills it by. Read from the endpoint record's `output_image`
/// line (`GET /api/v1/images/models/{slug}/endpoints`), never estimated: a
/// token-priced model draws a different number of tokens per picture, so its
/// honest quote is the rate.
enum ImageGenerationPrice: Equatable, Sendable {
    case perImage(Double)
    case perMegapixel(Double)
    case perMillionTokens(Double)

    /// Whether OpenRouter charges nothing for the picture.
    var isFree: Bool {
        switch self {
        case .perImage(let usd), .perMegapixel(let usd), .perMillionTokens(let usd): return usd == 0
        }
    }

    /// The card's line: "$0.040 a picture", "$8 / 1M image tokens", "Free".
    var label: String {
        if isFree { return "Free" }
        switch self {
        case .perImage(let usd): return "\(Self.dollars(usd)) a picture"
        case .perMegapixel(let usd): return "\(Self.dollars(usd)) a megapixel"
        case .perMillionTokens(let usd): return "\(Self.dollars(usd)) / 1M image tokens"
        }
    }

    /// The same figure as a sentence, for a tooltip or a cost quote.
    var sentence: String {
        if isFree { return "Free on OpenRouter for now." }
        switch self {
        case .perImage(let usd):
            return "\(Self.dollars(usd)) a picture (OpenRouter's price)."
        case .perMegapixel(let usd):
            return "\(Self.dollars(usd)) a megapixel (OpenRouter's price); a 1K picture is about one megapixel."
        case .perMillionTokens(let usd):
            return "\(Self.dollars(usd)) per million image tokens (OpenRouter's price). A small icon is a few hundred of them; a chat picture at medium quality is a few thousand."
        }
    }

    /// The per-picture figure when OpenRouter publishes one.
    var usdPerImage: Double? {
        if case .perImage(let usd) = self { return usd }
        return nil
    }

    /// The figure alone, in its unit's dollars: "$0.035", "$8".
    var amountLabel: String {
        switch self {
        case .perImage(let usd), .perMegapixel(let usd), .perMillionTokens(let usd): return Self.dollars(usd)
        }
    }

    /// The same unit at a new figure: what a promotion leaves of the price
    /// (`RouterModelPromotion.effectiveRate(fromList:)`).
    func mapped(_ transform: (Double) -> Double) -> ImageGenerationPrice {
        switch self {
        case .perImage(let usd): return .perImage(transform(usd))
        case .perMegapixel(let usd): return .perMegapixel(transform(usd))
        case .perMillionTokens(let usd): return .perMillionTokens(transform(usd))
        }
    }

    /// "$0.04", "$0.0336", "$8": the precision it is published at, never
    /// rounded away, and no trailing zeros past the cents.
    static func dollars(_ usd: Double) -> String {
        guard usd >= 1 else {
            var text = String(format: "%.4f", usd)
            while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
                text.removeLast()
            }
            return "$" + text
        }
        return usd == usd.rounded() ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }
}

/// One image model OpenRouter's Image API serves, as its directory
/// (`GET /api/v1/images/models`) describes it.
///
/// Every picture ForeverLM draws goes through OpenRouter (product owner, 2026-09-27:
/// "it can just be done via openrouter"), on the learner's own key or through
/// the managed proxy. So the catalog is OpenRouter's own list, read live, and a
/// model OpenRouter adds shows up in Settings without a code change.
struct ImageGenerationModel: Identifiable, Equatable, Sendable {
    /// OpenRouter's slug ("openai/gpt-image-1-mini"): what a request names,
    /// and what the proxy prices against OpenRouter's directory.
    let id: String
    /// "GPT Image 1 Mini": the directory's name without its "Maker: " prefix.
    let name: String
    /// "OpenAI": the prefix OpenRouter puts before the name.
    let maker: String
    let detail: String
    /// When OpenRouter first listed the model; the picker lists newest first.
    let createdAt: Date?
    /// The values each optional request field takes. OpenRouter refuses a
    /// field a model does not list, so a request sends only fields named here,
    /// and an empty list means the field is left out.
    let aspectRatios: [String]
    let qualities: [String]
    let resolutions: [String]
    let outputFormats: [String]
    /// Whether the model takes `n`. Every request asks for one picture.
    let takesCount: Bool
    /// How many pictures the model takes to start from. Zero means it can
    /// draw from a prompt but cannot revise a picture.
    let maximumReferences: Int
    /// What a picture costs, once the model's endpoint record has been read.
    var price: ImageGenerationPrice? = nil

    /// Whether this model can change an existing picture rather than only
    /// drawing a new one.
    var revisesPictures: Bool { maximumReferences > 0 }

    /// The maker's slug prefix ("openai", "x-ai"): a stable grouping key,
    /// where the display name OpenRouter gives a maker can change.
    var makerSlug: String {
        id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
    }

    /// A model known only by its id, for a stored choice read before the
    /// directory has arrived. `ManagedImageGeneration` resolves it against
    /// the directory before anything is drawn, so no request is ever built
    /// from it; the name is the slug's own model half, not an invented one.
    static func unresolved(id: String) -> ImageGenerationModel {
        let tail = id.split(separator: "/").last.map(String.init) ?? id
        return ImageGenerationModel(
            id: id,
            name: tail,
            maker: "",
            detail: "",
            createdAt: nil,
            aspectRatios: [],
            qualities: [],
            resolutions: [],
            outputFormats: [],
            takesCount: false,
            maximumReferences: 0
        )
    }

    var isResolved: Bool { !maker.isEmpty }

    /// The price sentence a confirmation quotes before up to `count` pictures
    /// are drawn: a total when OpenRouter publishes a per-picture price, the
    /// rate otherwise, and never a guessed figure. `chooser` names who may
    /// draw fewer ("the writers", "the picker").
    func drawingQuote(forUpTo count: Int, chooser: String) -> String {
        switch price {
        case .perImage(let each):
            return String(format: " Its price on OpenRouter is $%.4g per image, so the maximum is $%.2f; %@ may choose fewer.", each, each * Double(count), chooser)
        case .some(let price):
            return " Its price on OpenRouter is \(price.label); OpenRouter publishes no per-image figure for it, so no total can be quoted."
        case nil:
            return " OpenRouter lists no price for it, so no total can be quoted."
        }
    }
}

/// The image models ForeverLM offers — every one OpenRouter's Image API
/// serves that can draw from a prompt — and the prompts it draws with.
enum ImageGenerationCatalog {
    /// The cheapest of the well-known models, and ample for a 42-point icon:
    /// the smallest thing the app buys, bought in batches of forty.
    static let defaultModelID = "openai/gpt-image-1-mini"

    /// Settings › Images' Suggested list: one model per maker, the best that
    /// is still affordable, as Settings › Chat suggests its own
    /// (`AIModelDefaults.suggestedChatModels`). Picked from OpenRouter's Image
    /// API directory on 2026-09-28: OpenAI's speed tier of GPT Image 2.5,
    /// Nano Banana 2, Seedream 5.0 Lite at $0.035 a picture, FLUX.2 Pro at
    /// $0.03 a megapixel. A model OpenRouter stops serving drops off the list.
    static let suggestedModelIDs = [
        "openai/gpt-image-2.5-flare",
        "google/gemini-3.1-flash-image",
        "x-ai/grok-imagine-image-2.0",
        "qwen/qwen-image-3",
        "meta/muse-image",
        "black-forest-labs/flux.2-pro",
        "bytedance-seed/seedream-5-0-lite",
        "recraft/recraft-v4.1",
        "microsoft/mai-image-2.6-flash",
        "krea/krea-2-medium",
    ]

    static let directoryURL = URL(string: "https://openrouter.ai/api/v1/images/models")!

    /// OpenRouter's general directory filtered to image output: where a
    /// model whose endpoint record lists no price (Krea's, Meta's Muse, on
    /// 2026-09-27) still has its published image-output rate per token.
    static let pricedDirectoryURL = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=image")!

    static func endpointsURL(forModel id: String) -> URL? {
        URL(string: "https://openrouter.ai/api/v1/images/models/\(id)/endpoints")
    }

    /// The ids stored before 2026-09-27, when a picture went to its maker's
    /// own API, and the OpenRouter slug each became. A stored choice keeps
    /// its model across the move.
    static let makerNativeIDs: [String: String] = [
        "gpt-image-1-mini": "openai/gpt-image-1-mini",
        "gpt-image-2.5-flare": "openai/gpt-image-2.5-flare",
        "gpt-image-2.5-sunburst": "openai/gpt-image-2.5-sunburst",
        "gpt-image-2": "openai/gpt-image-2",
        "gpt-image-1": "openai/gpt-image-1",
        "gemini-3.1-flash-lite-image": "google/gemini-3.1-flash-lite-image",
        "gemini-3.1-flash-image": "google/gemini-3.1-flash-image",
        "gemini-3-pro-image": "google/gemini-3-pro-image",
    ]

    /// The OpenRouter slug a stored id names.
    static func canonicalID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return makerNativeIDs[trimmed] ?? trimmed
    }

    /// The models of the last directory read, newest first; empty until one
    /// has arrived. For synchronous readers (Settings' MCP entries, a quote);
    /// anything that draws goes through `ImageGenerationDirectory` instead.
    static var models: [ImageGenerationModel] {
        ImageGenerationDirectory.snapshot
    }

    static func model(id: String) -> ImageGenerationModel? {
        let id = canonicalID(id)
        return models.first { $0.id == id }
    }

    /// The stored model: its directory entry when the directory has been
    /// read, the default when the directory no longer lists it, and an
    /// unresolved stand-in before the first read (see `unresolved(id:)`).
    static func resolvedModel(id: String?) -> ImageGenerationModel {
        resolvedModel(id: id, in: models)
    }

    static func resolvedModel(id: String?, in models: [ImageGenerationModel]) -> ImageGenerationModel {
        let wanted = id.map(canonicalID).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModelID
        guard !models.isEmpty else { return .unresolved(id: wanted) }
        if let match = models.first(where: { $0.id == wanted }) { return match }
        return models.first { $0.id == defaultModelID } ?? models[0]
    }

    // MARK: - Reading OpenRouter's directory

    private struct DirectoryResponse: Decodable {
        let data: [OpenRouterLossyRow<Row>]
    }

    private struct Row: Decodable {
        struct Architecture: Decodable {
            let output_modalities: [String]?
        }
        let id: String
        let name: String?
        let description: String?
        let created: Double?
        let architecture: Architecture?
        let supported_parameters: [String: Parameter]?
    }

    /// One capability descriptor: `{type: enum, values}`, `{type: range,
    /// min, max}` or `{type: boolean}`. An absent key is an unsupported field.
    struct Parameter: Decodable, Equatable, Sendable {
        let type: String
        let values: [String]?
        let min: Int?
        let max: Int?

        private enum CodingKeys: String, CodingKey { case type, values, min, max }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            values = try? container.decode([String].self, forKey: .values)
            min = try? container.decode(Int.self, forKey: .min)
            max = try? container.decode(Int.self, forKey: .max)
        }
    }

    /// The models in one directory response that ForeverLM can offer.
    ///
    /// Two kinds are left out, each because the app could not use it: a model
    /// that needs a picture to start from (`input_references` with a minimum
    /// above zero — a layer splitter, the style-reference models), since every
    /// picture the app asks for starts from a prompt; and a model that draws
    /// only SVG, since the image store, the chat and the sidebar show raster
    /// pictures.
    static func models(fromDirectory data: Data) throws -> [ImageGenerationModel] {
        let rows = try JSONDecoder().decode(DirectoryResponse.self, from: data).data.compactMap(\.value)
        return rows.compactMap(model(from:)).sorted(by: newestFirst)
    }

    private static func model(from row: Row) -> ImageGenerationModel? {
        if let outputs = row.architecture?.output_modalities, !outputs.isEmpty, !outputs.contains("image") {
            return nil
        }
        let parameters = row.supported_parameters ?? [:]
        let references = parameters["input_references"]
        if (references?.min ?? 0) > 0 { return nil }
        let formats = parameters["output_format"]?.values ?? []
        if !formats.isEmpty, formats.allSatisfy({ $0.lowercased() == "svg" }) { return nil }

        let rawName = row.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? row.id
        let parts = rawName.components(separatedBy: ": ")
        let maker = parts.count > 1 ? parts[0] : (row.id.split(separator: "/").first.map(String.init) ?? row.id)
        let name = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : rawName
        return ImageGenerationModel(
            id: row.id,
            name: name,
            maker: maker,
            detail: plainDescription(row.description),
            createdAt: row.created.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            aspectRatios: parameters["aspect_ratio"]?.values ?? [],
            qualities: parameters["quality"]?.values ?? [],
            resolutions: parameters["resolution"]?.values ?? [],
            outputFormats: formats.filter { $0.lowercased() != "svg" },
            takesCount: parameters["n"] != nil,
            maximumReferences: references?.max ?? 0
        )
    }

    private static func newestFirst(_ lhs: ImageGenerationModel, _ rhs: ImageGenerationModel) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }

    /// The directory's blurb as plain text: its Markdown links become their
    /// words ("[MAI-Image-2.6 Flash](/microsoft/…)" reads "MAI-Image-2.6 Flash").
    static func plainDescription(_ text: String?) -> String {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return text
    }

    private struct EndpointsResponse: Decodable {
        struct Endpoint: Decodable {
            struct Line: Decodable {
                let billable: String?
                let unit: String?
                let cost_usd: Double?
                let variant: String?
            }
            let pricing: [Line]?
        }
        let endpoints: [Endpoint]?
    }

    private struct PricedDirectoryResponse: Decodable {
        struct Row: Decodable {
            let id: String
            let pricing: [String: OpenRouterPriceValue]?
        }
        let data: [OpenRouterLossyRow<Row>]
    }

    /// Each model's published image-output rate in the general directory, as
    /// a per-million-token price: the second place a price is read from, for a
    /// model whose endpoint record has none.
    static func tokenPrices(fromDirectory data: Data) -> [String: ImageGenerationPrice] {
        guard let response = try? JSONDecoder().decode(PricedDirectoryResponse.self, from: data) else { return [:] }
        var table: [String: ImageGenerationPrice] = [:]
        for row in response.data.compactMap(\.value) {
            guard let text = row.pricing?["image_output"]?.text, let perToken = Double(text), perToken >= 0 else { continue }
            table[row.id] = .perMillionTokens(perToken * 1_000_000)
        }
        return table
    }

    /// The output price in one endpoints record: its first endpoint's
    /// `output_image` line, at the base tier when the price is tiered by
    /// resolution (the 1K the app draws at). Nil when the record lists none.
    static func price(fromEndpoints data: Data) -> ImageGenerationPrice? {
        guard let response = try? JSONDecoder().decode(EndpointsResponse.self, from: data),
              let lines = response.endpoints?.first?.pricing else { return nil }
        let outputs = lines.filter { $0.billable == "output_image" && ($0.cost_usd ?? -1) >= 0 }
        let line = outputs.first { $0.variant == nil }
            ?? outputs.first { $0.variant?.lowercased() == "1k" }
            ?? outputs.first
        guard let line, let usd = line.cost_usd else { return nil }
        switch line.unit?.lowercased() {
        case "image": return .perImage(usd)
        case "megapixel": return .perMegapixel(usd)
        case "token": return .perMillionTokens(usd * 1_000_000)
        default: return nil
        }
    }

    // MARK: - Drawing

    /// Where a meeting's icon comes from when more than one source could
    /// supply it.
    ///
    /// The free sources are frames of a video call — a face mid-sentence, a
    /// half-drawn slide, whatever the encoder happened to land on. They are
    /// honest and they cost nothing, and they are also the reason a sidebar can
    /// look like a contact sheet. Drawing every icon instead trades that money
    /// for a set of pictures that were composed rather than caught.
    enum Source: String, CaseIterable, Identifiable, Sendable {
        /// Use a real thumbnail wherever one exists; draw only the rest.
        case preferThumbnail
        /// Draw every icon, including for meetings a frame could have covered.
        case alwaysDraw

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .preferThumbnail: return "Prefer a Real Thumbnail"
            case .alwaysDraw: return "Always Draw"
            }
        }

        var detail: String {
            switch self {
            case .preferThumbnail:
                return "Free where a recording or Drive can supply a frame. Drawn only for the meetings they cannot."
            case .alwaysDraw:
                return "Every icon drawn, so they read as one set. Costs more: meetings a frame would have covered reach the model too."
            }
        }

        var drawsEverything: Bool { self == .alwaysDraw }
    }

    /// How generated icons should look. One account-wide choice rather than a
    /// per-icon one, because forty icons in a sidebar read as a set or as
    /// clutter, and nothing about a single icon decides which.
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case emblem
        case gradient
        case lineArt

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .emblem: return "Flat Emblem"
            case .gradient: return "Soft Gradient"
            case .lineArt: return "Line Art"
            }
        }

        var detail: String {
            switch self {
            case .emblem: return "Solid shapes on a flat colour field."
            case .gradient: return "One soft shape over a two-tone wash."
            case .lineArt: return "Thin strokes on a pale ground."
            }
        }

        fileprivate var drawingInstruction: String {
            switch self {
            case .emblem:
                return "Flat vector emblem: two or three solid shapes, one flat background colour, no shading, no outline."
            case .gradient:
                return "One simple rounded shape over a smooth two-colour gradient background, soft and calm."
            case .lineArt:
                return "Thin even line art in a single ink colour on a pale solid background, no fill."
            }
        }

        /// The same style for a picture that is drawn without a ground (a notebook's cover): the shapes
        /// alone, which the app cuts out and shows as the icon (`NotebookCoverCutout`).
        fileprivate var groundlessInstruction: String {
            switch self {
            case .emblem:
                return "Flat vector emblem: two or three solid shapes, no shading, no outline."
            case .gradient:
                return "One simple rounded shape filled with a smooth two-colour gradient, soft and calm."
            case .lineArt:
                return "Thin even line art in a single ink colour, no fill."
            }
        }
    }

    /// The prompt for one meeting's icon.
    ///
    /// Built from the session's topic and presenter — the fields the import's
    /// own descriptor call already established — rather than from the file name
    /// they came from. What the picture must never contain is text: it is drawn
    /// once and then displayed at 42 points, where lettering is illegible at
    /// best and misspelt at worst.
    static func iconPrompt(
        topic: String,
        presenter: String?,
        groupTitle: String?,
        style: Style
    ) -> String {
        var subject = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty { subject = groupTitle ?? "a research meeting" }

        var lines = [
            "A small square app icon representing the subject of a research meeting.",
            "Subject: \(subject)",
        ]
        if let presenter = presenter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !presenter.isEmpty {
            // The presenter narrows an ambiguous topic without ever being drawn:
            // a portrait of a named person is both a poor icon and a likeness
            // nobody consented to.
            lines.append("Presented by \(presenter) — use this only to disambiguate the subject; never depict a person, face, or likeness.")
        }
        if let groupTitle = groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupTitle.isEmpty, groupTitle != subject {
            lines.append("Part of the series: \(groupTitle)")
        }
        lines.append(style.drawingInstruction)
        lines.append("Centred, symmetrical, legible when shrunk to 42 pixels.")
        lines.append("Absolutely no text, letters, numbers, words, or logos anywhere in the image.")
        return lines.joined(separator: "\n")
    }

    /// The prompt for a notebook's cover (schema v2 D53, §5.9): drawn once and
    /// shown in place of the notebook's emoji, at 16 points in the rail as well
    /// as at a card's corner, on the card's soft colour. So it holds one
    /// subject, drawn large, and no lettering. It is asked for on pure white
    /// with no tile, rounded square or frame behind it (product owner, 2026-10-06:
    /// "perhaps they can just be icons with no background?"), because the app
    /// takes the ground away and shows the subject alone
    /// (`NotebookCoverCutout`); a model asked for "an app icon" draws a tile
    /// with the subject at half its size inside. The title is read
    /// without its leading emoji, which is only a hint; the Instructions and
    /// the description or topic say what the notebook is about. The web draws
    /// covers too: `library-notebook-cover.js` holds the same text.
    static func notebookCoverPrompt(
        title: String,
        instructions: String?,
        summary: String?,
        topic: String?,
        style: Style
    ) -> String {
        let named = NotebookTitle(title)
        func trimmed(_ text: String?, limit: Int) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        var subject = named.text
        if subject.isEmpty { subject = trimmed(topic, limit: 200) ?? "a research notebook" }
        var lines = [
            "A simple icon for a research notebook.",
            "Subject: \(subject)",
        ]
        if let about = trimmed(summary, limit: 400) ?? trimmed(topic, limit: 200), about != subject {
            lines.append("About: \(about)")
        }
        if let instructions = trimmed(instructions, limit: 400) {
            lines.append("What the learner is after: \(instructions)")
        }
        if let emoji = named.icon {
            lines.append("The learner marks this notebook with \(emoji); take it as a hint for the subject, never draw the emoji itself.")
        }
        lines.append("Show one concrete object or structure from the subject; never a person, face, or likeness.")
        lines.append(style.groundlessInstruction)
        lines.append("One subject, centred and drawn large so that it fills most of the frame, on a plain pure white background: no tile, rounded square, circle, border, frame, shadow, glow or floor behind it, and nothing else in the picture. Legible when shrunk to 16 pixels.")
        lines.append("Colours that stay clear on both a white and a dark window: mid-tone and dark, nothing pale or white in the subject, no transparency checkerboard.")
        lines.append("Absolutely no text, letters, numbers, words, or logos anywhere in the image.")
        return lines.joined(separator: "\n")
    }

    /// The picture for a course quiz's tile: what its questions are about,
    /// drawn in the learner's chosen style like a meeting's icon.
    static func quizIconPrompt(
        topic: String,
        courseTitle: String?,
        keyIdeas: [String],
        style: Style
    ) -> String {
        var subject = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty { subject = courseTitle ?? "a university course" }
        var lines = [
            "A small square app icon for a quiz in a university course.",
            "Topic: \(subject)",
        ]
        if let courseTitle = courseTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !courseTitle.isEmpty, courseTitle != subject {
            lines.append("Course: \(courseTitle)")
        }
        let ideas = keyIdeas.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(4)
        if !ideas.isEmpty {
            lines.append("The quiz asks about: " + ideas.joined(separator: "; "))
        }
        lines.append("Show one concrete object or structure from the topic; never a person, face, or likeness.")
        lines.append(style.drawingInstruction)
        lines.append("Centred, symmetrical, legible when shrunk to 40 pixels.")
        lines.append("Absolutely no text, letters, numbers, words, or logos anywhere in the image.")
        return lines.joined(separator: "\n")
    }
}

/// One row of an OpenRouter directory, or nil when the row does not decode:
/// a directory that grows a field of an unexpected shape loses that row, not
/// the whole list.
struct OpenRouterLossyRow<Row: Decodable>: Decodable {
    let value: Row?

    init(from decoder: Decoder) throws {
        value = try? Row(from: decoder)
    }
}

/// A price OpenRouter sends as a string ("0.10") or, now and then, a number.
struct OpenRouterPriceValue: Decodable, Sendable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let number = try? container.decode(Double.self) {
            text = String(number)
        } else {
            text = nil
        }
    }
}

/// One OpenRouter directory read, kept for a while and shared by every caller.
///
/// Event-driven, like the text directory (`OpenRouterCatalogAvailability`):
/// a read happens when something needs the list — a Settings pane opening, a
/// picture or a clip about to be made, a tool listing the models — never on a
/// timer, and only one is in flight at a time.
actor OpenRouterMediaDirectoryCache<Value: Sendable> {
    private let freshness: TimeInterval
    private let load: @Sendable () async throws -> Value
    private var value: Value?
    private var readAt: Date?
    private var inFlight: Task<Value, Error>?

    init(freshness: TimeInterval, load: @escaping @Sendable () async throws -> Value) {
        self.freshness = freshness
        self.load = load
    }

    func current(forceRefresh: Bool = false) async throws -> Value {
        if !forceRefresh, let value, let readAt, Date().timeIntervalSince(readAt) < freshness {
            return value
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await load() }
        inFlight = task
        do {
            let loaded = try await task.value
            value = loaded
            readAt = Date()
            inFlight = nil
            return loaded
        } catch {
            inFlight = nil
            throw error
        }
    }
}

/// OpenRouter's image models, read live (see `ImageGenerationModel`).
///
/// Two reads, because the directory lists what a model takes but not what it
/// costs: the directory itself, which drawing needs, and one endpoints record
/// per model for its price, which only the Settings pane and the tools that
/// quote a price wait for.
enum ImageGenerationDirectory {
    enum Failure: LocalizedError, Sendable {
        case unreachable(String)
        case notServed(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let reason):
                return "OpenRouter's list of image models could not be read: \(reason)"
            case .notServed(let id):
                return "OpenRouter no longer serves \(id) through its Image API. Pick another model in Settings › Images."
            }
        }
    }

    private static let latest = OSAllocatedUnfairLock<[ImageGenerationModel]>(initialState: [])

    /// The last directory read (with prices, once they are in), for readers
    /// that cannot wait. Empty until the first read.
    static var snapshot: [ImageGenerationModel] { latest.withLock { $0 } }

    private static let directory = OpenRouterMediaDirectoryCache<[ImageGenerationModel]>(freshness: 30 * 60) {
        var request = URLRequest(url: ImageGenerationCatalog.directoryURL)
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
        guard let models = try? ImageGenerationCatalog.models(fromDirectory: data) else {
            throw Failure.unreachable("OpenRouter's answer was not the model list ForeverLM reads.")
        }
        guard !models.isEmpty else { throw Failure.unreachable("It listed no model that draws from a prompt.") }
        return models
    }

    private static let prices = OpenRouterMediaDirectoryCache<[String: ImageGenerationPrice]>(freshness: 60 * 60) {
        let ids = try await directory.current().map(\.id)
        return await withTaskGroup(of: (String, ImageGenerationPrice?).self) { group in
            // A handful at a time: one small public GET per model, not fifty
            // at once against the same host.
            var queue = ids.makeIterator()
            for _ in 0..<8 {
                guard let id = queue.next() else { break }
                group.addTask {
                    // Bound before the tuple: see AGENTS.md on tuples around an await in a task.
                    let price = await ImageGenerationDirectory.price(forModel: id)
                    return (id, price)
                }
            }
            var table: [String: ImageGenerationPrice] = [:]
            for await (id, price) in group {
                if let price { table[id] = price }
                if let next = queue.next() {
                    group.addTask {
                        let price = await ImageGenerationDirectory.price(forModel: next)
                        return (next, price)
                    }
                }
            }
            // A model whose endpoint record lists no price keeps the rate the
            // general directory publishes for it, never an estimate.
            if ids.contains(where: { table[$0] == nil }) {
                let fallback = await ImageGenerationDirectory.directoryTokenPrices()
                for id in ids where table[id] == nil {
                    if let price = fallback[id] { table[id] = price }
                }
            }
            return table
        }
    }

    private static func directoryTokenPrices() async -> [String: ImageGenerationPrice] {
        var request = URLRequest(url: ImageGenerationCatalog.pricedDirectoryURL)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.foreverLMData(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return [:]
        }
        return ImageGenerationCatalog.tokenPrices(fromDirectory: data)
    }

    private static func price(forModel id: String) async -> ImageGenerationPrice? {
        guard let url = ImageGenerationCatalog.endpointsURL(forModel: id) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.foreverLMData(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return ImageGenerationCatalog.price(fromEndpoints: data)
    }

    /// The models, without waiting for prices (any already read are filled in).
    static func models(forceRefresh: Bool = false) async throws -> [ImageGenerationModel] {
        let models = try await directory.current(forceRefresh: forceRefresh)
        let known = (try? await pricesIfRead()) ?? [:]
        return publish(models, prices: known)
    }

    /// The models with their prices; a model whose endpoints record could not
    /// be read keeps a nil price, which the pane shows as unknown.
    static func modelsWithPrices(forceRefresh: Bool = false) async throws -> [ImageGenerationModel] {
        let models = try await directory.current(forceRefresh: forceRefresh)
        let table = try await prices.current(forceRefresh: forceRefresh)
        return publish(models, prices: table)
    }

    /// The directory entry for a model a caller holds, which may be the
    /// unresolved stand-in for a stored choice. Throws when OpenRouter does
    /// not list it, rather than drawing on some other model.
    static func resolve(_ model: ImageGenerationModel) async throws -> ImageGenerationModel {
        let id = ImageGenerationCatalog.canonicalID(model.id)
        let models = try await models()
        guard let match = models.first(where: { $0.id == id }) else { throw Failure.notServed(id) }
        return match
    }

    /// `resolve`, with the model's price read too, for a caller about to
    /// quote what drawing will cost.
    static func priced(_ model: ImageGenerationModel) async throws -> ImageGenerationModel {
        let id = ImageGenerationCatalog.canonicalID(model.id)
        let models = try await modelsWithPrices()
        guard let match = models.first(where: { $0.id == id }) else { throw Failure.notServed(id) }
        return match
    }

    /// Starts a directory read in the background when none has happened yet,
    /// so a stored choice read synchronously soon carries its real name.
    static func warm() {
        guard snapshot.isEmpty else { return }
        Task.detached(priority: .utility) { _ = try? await models() }
    }

    private static func pricesIfRead() async throws -> [String: ImageGenerationPrice]? {
        // Reads only a table already fetched: the prices cost a request per
        // model, so nothing that only needs the directory starts them.
        let current = snapshot
        guard current.contains(where: { $0.price != nil }) else { return nil }
        return Dictionary(uniqueKeysWithValues: current.compactMap { model in model.price.map { (model.id, $0) } })
    }

    private static func publish(_ models: [ImageGenerationModel], prices: [String: ImageGenerationPrice]) -> [ImageGenerationModel] {
        let priced = models.map { model -> ImageGenerationModel in
            var model = model
            model.price = prices[model.id] ?? model.price
            return model
        }
        latest.withLock { $0 = priced }
        return priced
    }
}
