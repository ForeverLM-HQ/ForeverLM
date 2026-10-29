import Foundation
import OSLog

/// The bytes one managed image request came back with.
struct GeneratedImage: Sendable {
    let data: Data
    /// `image/png` unless OpenRouter's `media_type` says otherwise.
    let mediaType: String
}

extension ImageGenerationCatalog {
    /// The frame a drawn picture is asked for. Named by what the learner means
    /// rather than in pixels: OpenRouter normalizes an aspect ratio onto each
    /// provider, and each model lists the ratios it takes.
    enum Shape: String, CaseIterable, Sendable {
        case square
        case landscape
        case portrait

        var aspectRatio: String {
            switch self {
            case .square: return "1:1"
            case .landscape: return "3:2"
            case .portrait: return "2:3"
            }
        }

        /// The ratio closest to this shape among those a model lists, or nil
        /// when it lists none (the field is then left out, and the model
        /// draws its own default). "auto" is never picked: it hands the
        /// choice to the provider.
        func aspectRatio(among offered: [String]) -> String? {
            if offered.contains(aspectRatio) { return aspectRatio }
            let target = log(Self.ratio(aspectRatio) ?? 1)
            return offered
                .compactMap { value in Self.ratio(value).map { (value, abs(log($0) - target)) } }
                .min { $0.1 < $1.1 }?
                .0
        }

        /// "3:2" as 1.5; nil for "auto" or anything that is not two numbers.
        static func ratio(_ value: String) -> Double? {
            let parts = value.split(separator: ":")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else {
                return nil
            }
            return width / height
        }
    }

    /// How much the model may spend drawing. Sent only to a model that lists
    /// the value; the rest draw at their own single quality.
    enum Quality: String, CaseIterable, Sendable {
        case low
        case medium
        case high
    }
}

/// One text-to-image request through OpenRouter's Image API, and the local
/// ledger row for what it cost.
///
/// Every caller — a meeting's sidebar icon, a quiz picture, a picture the chat
/// draws on request — wants the same thing: a prompt in, bytes out. Every
/// request goes to OpenRouter (product owner, 2026-09-27: "it can just be done via
/// openrouter"): straight there on the learner's own OpenRouter key, or
/// through the managed proxy, which prices it from OpenRouter's reported cost,
/// on a balance or a comp. `ManagedAI.rewrite` picks the rail. Nothing here
/// decides *which* model: the caller passes the account's Settings choice.
enum ManagedImageGeneration {
    enum Failure: LocalizedError, Sendable {
        case notSignedIn
        case emptyPrompt
        case providerRejected(String)
        case noImageReturned
        case cannotRevise(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in with Apple to use ForeverLM AI."
            case .emptyPrompt:
                return "The image request had no prompt."
            case .providerRejected(let reason):
                return reason
            case .noImageReturned:
                return "The model returned no image."
            case .cannotRevise(let name):
                return "\(name) draws only from a prompt and cannot change an existing picture. Ask for a new picture, or pick a model in Settings › Images that edits pictures."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.foreverlm", category: "ImageGeneration")

    static let imagesURL = URL(string: "https://openrouter.ai/api/v1/images")!

    /// Draws one picture.
    ///
    /// - Parameters:
    ///   - model: the Settings choice. A stand-in read before OpenRouter's
    ///     directory arrived is resolved against it first, so the request
    ///     carries exactly the fields that model takes.
    ///   - usageTask: the feature label the ledger files the charge under
    ///     (`meeting_icon`, `chat_image`), so Settings → AI activity can say
    ///     what the money bought.
    ///   - source: the library record the picture is for, when there is one.
    ///   - reference: the picture being revised. The model changes it rather
    ///     than drawing afresh from the prompt, passed in `input_references`.
    static func generate(
        prompt: String,
        model: ImageGenerationModel,
        shape: ImageGenerationCatalog.Shape,
        quality: ImageGenerationCatalog.Quality,
        usageTask: String,
        source: AIUsageSource? = nil,
        reference: GeneratedImage? = nil
    ) async throws -> GeneratedImage {
        guard ManagedAI.isSignedIn else { throw Failure.notSignedIn }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyPrompt }
        let resolved = try await ImageGenerationDirectory.resolve(model)
        if reference != nil, !resolved.revisesPictures { throw Failure.cannotRevise(resolved.name) }

        return try await AIUsageAttribution.$task.withValue(usageTask) {
            try await withOptionalSource(source) {
                // Listed for the background-work list, where Stop cancels it:
                // a notebook's cover or a meeting's icon drawn on its own.
                try await AIInFlightCalls.current.track(step: usageTask) { _ in
                    // Built inside the closure: the body is not Sendable.
                    let payload = try requestBody(prompt: trimmed, model: resolved, shape: shape, quality: quality, reference: reference)
                    return try await post(payload, model: resolved)
                }
            }
        }
    }

    private static func withOptionalSource<T: Sendable>(
        _ source: AIUsageSource?,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        guard let source else { return try await body() }
        return try await AIUsageAttribution.withSource(source, operation: body)
    }

    // MARK: - The request

    /// One Image API body, carrying only the fields `model` lists: OpenRouter
    /// refuses a field a model does not take. The resolution asked for is the
    /// 1K a Gemini picture was drawn at (or the smallest a model offers), so a
    /// sidebar icon is not bought at 4K.
    static func requestBody(
        prompt: String,
        model: ImageGenerationModel,
        shape: ImageGenerationCatalog.Shape,
        quality: ImageGenerationCatalog.Quality,
        reference: GeneratedImage?
    ) throws -> [String: Any] {
        var payload: [String: Any] = ["model": model.id, "prompt": prompt]
        if model.takesCount { payload["n"] = 1 }
        if let ratio = shape.aspectRatio(among: model.aspectRatios) { payload["aspect_ratio"] = ratio }
        if model.qualities.contains(quality.rawValue) { payload["quality"] = quality.rawValue }
        if let resolution = preferredResolution(among: model.resolutions) { payload["resolution"] = resolution }
        if let format = ["png", "jpeg", "webp"].first(where: model.outputFormats.contains) {
            payload["output_format"] = format
        }
        if let reference {
            payload["input_references"] = [
                ["type": "image_url", "image_url": ["url": try referenceDataURL(reference)]]
            ]
        }
        return payload
    }

    /// 1K when offered, else the smallest tier the model lists.
    static func preferredResolution(among offered: [String]) -> String? {
        let order = ["512", "1K", "2K", "4K"]
        if offered.contains("1K") { return "1K" }
        return offered.min { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }
    }

    /// The formats a picture can be revised from; the store only writes PNG
    /// and JPEG, and older pictures may be WebP.
    static let referenceMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/webp"]

    /// The picture as the data: URL `input_references` takes. Throws for a
    /// format no model reads, rather than sending it to be refused.
    static func referenceDataURL(_ image: GeneratedImage) throws -> String {
        guard referenceMediaTypes.contains(image.mediaType), !image.data.isEmpty else {
            throw Failure.providerRejected("The picture being revised is a \(image.mediaType) file, which the image model cannot take as input.")
        }
        return "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"
    }

    // MARK: - Transport

    /// One request and the local ledger row for what it cost. `rewrite` sends
    /// it straight to OpenRouter on the learner's key, or to the managed proxy.
    private static func post(_ payload: [String: Any], model: ImageGenerationModel) async throws -> GeneratedImage {
        var request = URLRequest(url: imagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 180
        ManagedAI.rewrite(&request)

        let (data, response) = try await URLSession.shared.foreverLMData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.providerRejected("OpenRouter returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = ManagedAI.serviceError(from: data) {
                ManagedAI.surfaceIfNeeded(error)
                throw Failure.providerRejected("\(model.name) could not draw the picture: \(error.message)")
            }
            let reason = AIProviderErrorText.fromResponseBody(data) ?? "HTTP \(http.statusCode)"
            throw Failure.providerRejected("\(model.name) could not draw the picture: \(reason)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.noImageReturned
        }
        // Recorded before the picture is checked: a response that billed and
        // carried no picture still cost what it says.
        await recordUsage(from: json, model: model)
        guard let first = (json["data"] as? [[String: Any]])?.first,
              let encoded = first["b64_json"] as? String,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty else {
            throw Failure.noImageReturned
        }
        let mediaType = (first["media_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return GeneratedImage(
            data: bytes,
            mediaType: (mediaType?.hasPrefix("image/") == true ? mediaType : nil) ?? "image/png"
        )
    }

    /// OpenRouter reports the picture's tokens and the exact charge. On the
    /// own-key rail no proxy debit stands behind the picture, so that figure
    /// is the only exact record of it; on the managed rail it matches the
    /// debit the proxy took from the same field.
    private static func recordUsage(from json: [String: Any], model: ImageGenerationModel) async {
        guard let usage = json["usage"] as? [String: Any] else {
            logger.warning("OpenRouter image response carried no usage block; nothing recorded locally.")
            return
        }
        let output = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int)
        let input = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int)
        var report = AIUsageReport(
            inputTokens: input,
            outputTokens: output,
            imageOutputTokens: output,
            imageCount: 1
        )
        if let cost = usage["cost"] as? NSNumber, cost.doubleValue >= 0 {
            report.providerReportedCost = cost.doubleValue
            report.currency = "USD"
        }
        // A response that billed nothing it can name is priced from the
        // model's OpenRouter price, read now so the ledger row has it.
        if (report.providerReportedCost ?? 0) <= 0 {
            _ = try? await ImageGenerationDirectory.priced(model)
        }
        try? await AIUsageTracker.shared.record(
            provider: "OpenRouter",
            model: model.id,
            operation: "image_generation",
            report: report,
            task: AIUsageAttribution.task ?? "image_generation"
        )
    }
}

extension ManagedImageGeneration {
    /// Draws a picture and keeps it in `GeneratedImageStore` with its prompt:
    /// a new image, or with `revising` the next version of that image, drawn
    /// by editing the version being revised. The revised image is looked up
    /// before anything is spent, so an id that names nothing costs no image. Shared by the chat's `generate_image`
    /// and the MCP tool of the same name.
    static func drawAndStore(
        prompt: String,
        title: String?,
        model: ImageGenerationModel,
        shape: ImageGenerationCatalog.Shape,
        quality: ImageGenerationCatalog.Quality,
        revising: String?,
        usageTask: String,
        notebookID: String? = nil
    ) async throws -> GeneratedImageStore.Listing {
        // A revision edits the version it names — the image's latest when it
        // names the image — so the model changes that picture rather than
        // drawing a new one from the prompt (product owner, 2026-09-22).
        var reference: GeneratedImage? = nil
        if let revising {
            reference = await Task.detached(priority: .userInitiated) {
                GeneratedImageStore.revisionBase(for: revising)
            }.value
            guard reference != nil else { throw GeneratedImageStore.RevisionFailure.unknownImage(revising) }
        }
        // Resolved here too, so the stored picture names the model by
        // OpenRouter's name even when the choice was read before the
        // directory arrived. `generate` finds it in the same cached read.
        let resolved = try await ImageGenerationDirectory.resolve(model)
        let image = try await generate(
            prompt: prompt,
            model: resolved,
            shape: shape,
            quality: quality,
            usageTask: usageTask,
            reference: reference
        )
        let modelName = resolved.name
        let modelID = resolved.id
        return try await Task.detached(priority: .userInitiated) {
            try GeneratedImageStore.store(
                image, origin: .drawn, text: prompt, title: title, model: modelName, modelID: modelID, revising: revising,
                notebookID: notebookID
            )
        }.value
    }
}

