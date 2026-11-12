import AVFoundation
import Foundation

/// The one managed speech-to-text transport used by macOS and iOS review
/// dictation and imported media. Every model is an OpenRouter model, and every
/// request goes to OpenRouter's transcription endpoint under its slug (product owner,
/// 2026-09-27: "it can just be done via openrouter"): straight there on the
/// learner's own OpenRouter key, through the managed proxy otherwise, which
/// keeps the long-lived key server-side. Dictation always transcribes
/// after the recording stops.
enum ManagedTranscriptionClient {
    struct Result: Sendable {
        let text: String
        let report: AIUsageReport
        let providerName: String
        let model: String
        /// Reading and base64-encoding the recording, in milliseconds.
        let encodeMilliseconds: Int
        /// Request sent to response received, in milliseconds. Also carried
        /// on `report.latencyMilliseconds`, so the ledger keeps it.
        let roundTripMilliseconds: Int
        /// OpenRouter's id for this generation, from the `X-Generation-Id`
        /// header or the body's `id`: what `AIUsageTracker.record` reads the
        /// charge by when no price table prices the call.
        var generationID: String? = nil
    }

    enum TranscriptionError: LocalizedError {
        case missingSession
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingSession:
                return "Sign in with Apple to use review dictation."
            case .badResponse(let message):
                return message
            }
        }
    }

    struct Route: Equatable, Sendable {
        let providerName: String
        let endpoint: URL
        let model: String
    }

    /// What the audio is, which decides which stored model answers for it.
    ///
    /// Dictation is seconds of one close-mic voice and is waited on live, so it
    /// wants the fastest model. Batch media is an hour of several people with
    /// crosstalk and domain vocabulary, transcribed in the background where
    /// accuracy matters more than latency. They are separate settings because
    /// the right answer genuinely differs.
    enum Purpose: Sendable {
        case dictation
        case media

        var storedModel: String {
            switch self {
            case .dictation: return KeychainService.openAITranscriptionModel
            case .media: return KeychainService.mediaTranscriptionModel
            }
        }

        var settingsLabel: String {
            switch self {
            case .dictation: return "Dictation"
            case .media: return "Recordings & Podcasts"
            }
        }
    }

    /// Every model the rail can transcribe with: the ids of
    /// `TranscriptionModelCatalog.models`, which is OpenRouter's transcription
    /// directory once this device has read it.
    static var catalog: [String] {
        TranscriptionModelCatalog.models.map(\.id)
    }

    /// Model ids stored under a provider's own spelling,
    /// mapped to the slugs OpenRouter's transcription endpoint answers to.
    ///
    /// A stored pick can be a bare `whisper-1`, `gpt-4o-transcribe`,
    /// `gpt-4o-mini-transcribe` or `whisper-large-v3`. OpenRouter's
    /// directory has no such ids, so the proxy could not price the request and
    /// refused it, and dictation would fail with a 403 on every attempt until the
    /// learner reopened Settings and picked again.
    /// Renaming a stored pick keeps it working: each of these is the same
    /// model under the id its route knows it by.
    private static let retiredModelIDs = [
        "whisper-1": "openai/whisper-1",
        "gpt-4o-transcribe": "openai/gpt-4o-transcribe",
        "gpt-4o-mini-transcribe": "openai/gpt-4o-mini-transcribe",
        "whisper-large-v3": "openai/whisper-large-v3",
        "whisper-large-v3-turbo": "openai/whisper-large-v3-turbo",
    ]

    /// The id the managed rail can actually reach for a stored selection.
    /// Settings seeds its fields through this as well, so a repaired pick
    /// shows as the selected capsule instead of sitting unmatched in the text
    /// field, and the price label quotes the rail the request will take.
    static func canonicalModel(_ selectedModel: String) -> String {
        let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return retiredModelIDs[trimmed.lowercased()] ?? trimmed
    }

    static let openRouterEndpoint = OpenRouterAPI.audioTranscriptions

    /// One route for every model: OpenRouter's transcription endpoint under
    /// the model's slug. `ManagedAI.rewrite` sends it to OpenRouter on the
    /// learner's own key, or through the managed proxy, which prices it from
    /// OpenRouter's directory and bills the response's own `usage.cost`.
    static func route(for selectedModel: String) -> Route {
        Route(
            providerName: "OpenRouter",
            endpoint: openRouterEndpoint,
            model: canonicalModel(selectedModel)
        )
    }

    /// Opens the connection to the proxy while the learner is still speaking,
    /// so the upload after the mic closes starts on a warm connection instead
    /// of paying the TLS handshake — and a cold Worker isolate — inside the
    /// wait it is measured by. `/health` is the one unauthenticated,
    /// unmetered route; nothing reads the answer.
    static func warmConnection(session: URLSession) {
        var request = URLRequest(url: ManagedAI.baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let task = session.dataTask(with: request)
        task.priority = URLSessionTask.lowPriority
        task.resume()
    }

    static func transcribe(
        fileURL: URL,
        session: URLSession,
        purpose: Purpose = .dictation
    ) async throws -> Result {
        guard ManagedAI.isSignedIn else {
            throw TranscriptionError.missingSession
        }
        let route = route(for: purpose.storedModel)
        guard !route.model.isEmpty else {
            throw TranscriptionError.badResponse(
                "Choose a \(purpose.settingsLabel) model under Settings → Speech-to-Text."
            )
        }

        // Reading and base64-encoding a long recording are blocking work. The
        // result is immutable request data, so prepare it away from whichever
        // UI actor initiated dictation.
        let encodeStartedAt = Date()
        let body = try await Task.detached(priority: .userInitiated) {
            let audio = try Data(contentsOf: fileURL)
            let extensionName = fileURL.pathExtension.lowercased()
            let format = ["m4a", "mp3", "wav"].contains(extensionName)
                ? extensionName
                : "m4a"
            let payload: [String: Any] = [
                "model": route.model,
                "response_format": "json",
                "input_audio": [
                    "data": audio.base64EncodedString(),
                    "format": format,
                ],
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }.value
        let encodeMilliseconds = Self.milliseconds(since: encodeStartedAt)

        // The duration is only a fallback for a provider that reports no usage
        // of its own, so it has no business delaying the request. Loading the
        // asset ahead of the upload put an AVFoundation demux — and, on first
        // use, the whole media-services warm-up — in front of a round trip the
        // learner is watching a spinner for. It runs alongside the upload
        // instead, and is read once the response needs it.
        let durationProbe = Task.detached(priority: .utility) { () -> Double? in
            guard let duration = try? await AVURLAsset(url: fileURL).load(.duration) else {
                return nil
            }
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        defer { durationProbe.cancel() }

        var request = URLRequest(url: route.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ManagedAI.rewrite(&request)

        let uploadStartedAt = Date()
        let (data, response) = try await session.upload(for: request, from: body)
        let roundTripMilliseconds = Self.milliseconds(since: uploadStartedAt)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.badResponse(
                "\(route.providerName) transcription did not return an HTTP response."
            )
        }
        guard (200...299).contains(http.statusCode) else {
            // The body is only quoted when it reads as an explanation. A failing
            // provider is as likely to hand back the request we uploaded.
            let detail = AIProviderErrorText.fromResponseBody(data).map { ": \($0)" } ?? "."
            throw TranscriptionError.badResponse(
                "\(route.providerName) transcription failed (\(http.statusCode))\(detail)"
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionError.badResponse(
                "\(route.providerName) transcription response did not include text."
            )
        }

        var report = AIUsageParser.report(fromTranscriptionResponse: json)
        if report.durationSeconds == nil {
            report.durationSeconds = await durationProbe.value
        }
        report.latencyMilliseconds = roundTripMilliseconds
        return Result(
            text: text,
            report: report,
            providerName: route.providerName,
            model: route.model,
            encodeMilliseconds: encodeMilliseconds,
            roundTripMilliseconds: roundTripMilliseconds,
            generationID: openRouterGenerationID(response: http, body: json)
        )
    }

    /// OpenRouter's generation id for a response: its `X-Generation-Id`
    /// header, else a `gen-` id in the body.
    static func openRouterGenerationID(response: HTTPURLResponse, body: [String: Any]) -> String? {
        let header = response.value(forHTTPHeaderField: "X-Generation-Id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let header, !header.isEmpty { return header }
        guard let id = (body["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              id.hasPrefix("gen-") else { return nil }
        return id
    }

    private static func milliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }
}

// MARK: - The transcription catalog

/// One transcription model OpenRouter serves.
struct TranscriptionModelOption: Identifiable, Hashable, Sendable {
    /// OpenRouter's slug: what the request names.
    let id: String
    /// The directory's name without its "Maker: " prefix.
    let name: String
    /// The prefix OpenRouter puts before the name; what Settings groups by.
    let maker: String

    /// USD per hour of audio, from OpenRouter's catalog, or nil when
    /// OpenRouter bills the model by its tokens or has not priced it
    /// (`OpenRouterAudioPrices`). Nothing is converted.
    var ratePerHour: Double? {
        OpenRouterAudioPrices.transcriptionUSDPerHour(slug: id)
    }

    /// The card's line in OpenRouter's unit: "$0.09 / hour of audio",
    /// "$1.25 / $5 per 1M tokens", "Free", or "Price unknown".
    var priceLabel: String {
        OpenRouterAudioPrices.label(slug: id, kind: .transcription) ?? OpenRouterAudioPrices.unknownPriceLabel
    }

    init(id: String, name: String, maker: String) {
        self.id = id
        self.name = name
        self.maker = maker
    }

    init(directoryRow row: OpenRouterAudioModelRow) {
        self.init(id: row.id, name: row.name, maker: row.maker)
    }
}

/// The batch transcription models ForeverLM offers: every one OpenRouter's
/// transcription directory lists (product owner, 2026-09-27: "show all models at
/// https://openrouter.ai/models?output_modalities=transcription"), read live
/// by `OpenRouterAudioDirectory`, so a model OpenRouter adds reaches Settings
/// without a code change. Prices are OpenRouter's (`OpenRouterAudioPrices`).
enum TranscriptionModelCatalog {
    /// Settings › Voice's Suggested dictation models: one per maker, the
    /// best that is still affordable, as Settings › Chat suggests its own.
    /// Picked from OpenRouter's transcription directory. A
    /// model OpenRouter stops serving drops off the list.
    static let suggestedModelIDs = [
        "openai/gpt-transcribe",
        "google/gemini-3.5-transcribe",
        "x-ai/grok-stt-1.0",
        "qwen/qwen3-asr-flash-2026-02-10",
        "mistralai/voxtral-mini-transcribe",
        "meta/muse-voice-transcribe-1.0",
        "nvidia/parakeet-tdt-0.6b-v3",
        "deepgram/nova-3",
        "assemblyai/universal-3-5-pro",
        "microsoft/mai-transcribe-2",
    ]

    /// What Settings offered before this device has read the directory: the
    /// eleven models the picker lists, cheapest-capable
    /// first, named as the directory names them.
    static let offeredBeforeDirectory: [TranscriptionModelOption] = [
        .init(id: "openai/gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", maker: "OpenAI"),
        .init(id: "nvidia/parakeet-tdt-0.6b-v3", name: "Parakeet TDT 0.6B v3", maker: "NVIDIA"),
        .init(id: "openai/whisper-large-v3", name: "Whisper Large V3", maker: "OpenAI"),
        .init(id: "qwen/qwen3-asr-flash-2026-02-10", name: "Qwen3 ASR Flash", maker: "Qwen"),
        .init(id: "mistralai/voxtral-mini-transcribe", name: "Voxtral Mini Transcribe", maker: "Mistral"),
        .init(id: "deepgram/nova-3", name: "Nova-3", maker: "Deepgram"),
        .init(id: "openai/whisper-1", name: "Whisper 1", maker: "OpenAI"),
        .init(id: "openai/gpt-4o-transcribe", name: "GPT-4o Transcribe", maker: "OpenAI"),
        .init(id: "google/chirp-3", name: "Chirp 3", maker: "Google"),
        .init(id: "openai/whisper-large-v3-turbo", name: "Whisper Large V3 Turbo", maker: "OpenAI"),
        .init(id: "microsoft/mai-transcribe-1.5", name: "MAI-Transcribe 1.5", maker: "Microsoft AI"),
    ]

    /// The offered models: every model the last directory read lists,
    /// cheapest first by OpenRouter's hourly price, or `offeredBeforeDirectory`
    /// before a read.
    static var models: [TranscriptionModelOption] {
        guard let rows = OpenRouterAudioDirectory.rows(.transcription) else {
            return offeredBeforeDirectory
        }
        let offered = options(fromDirectory: rows)
        return offered.isEmpty ? offeredBeforeDirectory : offered
    }

    static var isDirectoryBacked: Bool {
        OpenRouterAudioDirectory.rows(.transcription) != nil
    }

    /// Every directory row as an option, cheapest first by OpenRouter's
    /// hourly price; a model with no hourly price (unpriced, or billed by
    /// tokens) after every priced one, by name. Pure but for the price table,
    /// which a test pins (`OpenRouterAudioPrices.$pinnedTable`).
    static func options(fromDirectory rows: [OpenRouterAudioModelRow]) -> [TranscriptionModelOption] {
        var seen = Set<String>()
        return rows.compactMap { row -> TranscriptionModelOption? in
            guard seen.insert(row.id.lowercased()).inserted else { return nil }
            return TranscriptionModelOption(directoryRow: row)
        }
        .sorted { lhs, rhs in
            switch (lhs.ratePerHour, rhs.ratePerHour) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
        }
    }

    static func model(id: String) -> TranscriptionModelOption? {
        let canonical = ManagedTranscriptionClient.canonicalModel(id)
        return models.first { $0.id.caseInsensitiveCompare(canonical) == .orderedSame }
    }
}
