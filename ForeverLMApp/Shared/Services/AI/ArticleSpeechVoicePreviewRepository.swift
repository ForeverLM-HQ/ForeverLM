import Foundation

/// One durable cache for the short voice-picker samples used by both native apps.
///
/// Opening Text-to-Speech settings starts a bounded warm-up: every voice of the
/// selected model, and across the rest of the catalog the voices ForeverLM
/// curates (a model it does not curate gets its first voice). The catalog is
/// OpenRouter's whole speech directory — some 400 voices, against
/// the 150 or so curated — and every sample is a billed request, so warming all
/// of them unasked would spend more on samples than most listeners spend on
/// narration. Any other voice's sample is made when it is tapped. Missing
/// samples are generated through the ordinary managed speech rail, while taps
/// share the same in-flight task and therefore never pay for a duplicate
/// request. File I/O and synthesis stay inside this actor/off the main actor;
/// the UI only receives the finished bytes.
actor ArticleSpeechVoicePreviewRepository {
    static let shared = ArticleSpeechVoicePreviewRepository()

    static let sampleText = "Mitochondria are much more than just the powerhouse of the cell"

    private var requests: [String: Task<Data, Error>] = [:]
    private var warmupTask: Task<Void, Never>?
    /// A visible picker must not wait behind the catalog-wide queue. One task
    /// per selected model warms its rows at higher concurrency; `audio` still
    /// deduplicates any pair the background pass already started.
    private var prioritizedWarmupTasks: [String: Task<Void, Never>] = [:]

    func audio(modelID: String, voiceID: String) async throws -> Data {
        let key = Self.cacheKey(modelID: modelID, voiceID: voiceID)
        if let request = requests[key] {
            return try await request.value
        }

        let request = Task.detached(priority: .utility) {
            if let cached = Self.cachedData(modelID: modelID, voiceID: voiceID) {
                return cached
            }
            // A sample already made is on the CDN: fetching it is free, so only a voice
            // nobody has heard yet makes a billed request.
            if let hosted = await Self.hostedData(modelID: modelID, voiceID: voiceID) {
                try? Self.save(hosted, modelID: modelID, voiceID: voiceID)
                return hosted
            }
            let response = try await CloudArticleTTS.synthesizePreview(
                Self.sampleText,
                modelID: modelID,
                voiceID: voiceID
            )
            try Self.save(response.data, modelID: modelID, voiceID: voiceID)
            return response.data
        }
        requests[key] = request
        defer { requests.removeValue(forKey: key) }
        return try await request.value
    }

    /// Returns immediately. The selected model gets its own prompt warm-up so
    /// all visible rows start promptly instead of arriving in groups of three
    /// behind the catalog-wide pass. The rest of the catalog stays deliberately
    /// conservative to avoid turning background preparation into a traffic spike.
    func startPrewarming(prioritizedModelID: String) {
        startPrioritizedPrewarming(modelID: prioritizedModelID)
        guard warmupTask == nil else { return }
        warmupTask = Task(priority: .utility) { [weak self] in
            // The pairs are read from OpenRouter's speech list, which this
            // device may not have read yet.
            await OpenRouterAudioDirectory.prepare(.speech)
            let pairs = Self.previewPairs(prioritizedModelID: prioritizedModelID)
            guard let self else { return }
            await self.warm(pairs, concurrency: 3)
            await self.finishPrewarming()
        }
    }

    private func startPrioritizedPrewarming(modelID: String) {
        guard prioritizedWarmupTasks[modelID] == nil else { return }
        prioritizedWarmupTasks[modelID] = Task(priority: .userInitiated) { [weak self] in
            await OpenRouterAudioDirectory.prepare(.speech)
            let pairs = Self.previewPairs(forModelID: modelID)
            guard let self else { return }
            // Eight lets an ordinary picker become ready in one or two waves,
            // while still bounding provider and managed-proxy concurrency.
            await self.warm(pairs, concurrency: 8)
            await self.finishPrioritizedPrewarming(modelID: modelID)
        }
    }

    private func warm(
        _ pairs: [(modelID: String, voiceID: String)],
        concurrency: Int
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = pairs.makeIterator()
            for _ in 0..<max(concurrency, 1) {
                guard let pair = iterator.next() else { break }
                group.addTask { await self.warm(pair) }
            }
            while await group.next() != nil {
                guard let pair = iterator.next() else { continue }
                group.addTask { await self.warm(pair) }
            }
        }
    }

    private func warm(_ pair: (modelID: String, voiceID: String)) async {
        guard Self.cachedData(modelID: pair.modelID, voiceID: pair.voiceID) == nil else { return }
        _ = try? await audio(modelID: pair.modelID, voiceID: pair.voiceID)
    }

    private func finishPrewarming() {
        warmupTask = nil
    }

    private func finishPrioritizedPrewarming(modelID: String) {
        prioritizedWarmupTasks[modelID] = nil
    }

    nonisolated static func cacheKey(modelID: String, voiceID: String) -> String {
        let raw = "v2|\(modelID)|\(voiceID)|\(sampleText)"
        return raw.sha256Hex
    }

    /// The device's cache. A sample an earlier build wrapped at another sample
    /// rate than its model sends plays slow and deep (HeyGen's did), so it is
    /// not a sample: the caller makes it again and `save` replaces the file.
    nonisolated static func cachedData(modelID: String, voiceID: String) -> Data? {
        guard let data = try? Data(contentsOf: fileURL(modelID: modelID, voiceID: voiceID)),
              ArticleSpeechAudioValidation.isWrappedAtModelSampleRate(data, modelID: modelID) else {
            return nil
        }
        return data
    }

    /// Where the samples already made live, named by the same key
    /// (`scripts/publish_voice_previews.sh` puts them there). They are not in the
    /// app: the update download is the app (product owner, 2026-10-09). The
    /// releases bucket, served by the foreverlm-releases Worker.
    nonisolated static let hostedBaseURL = URL(string: "https://foreverlm.com/releases/voice-previews/")!

    /// The sample from the CDN, or nil when it has none (or the network does not
    /// answer in a few seconds): the caller then generates it.
    nonisolated static func hostedData(modelID: String, voiceID: String) async -> Data? {
        let key = cacheKey(modelID: modelID, voiceID: voiceID)
        let stored = ArticleSpeechCatalog.model(id: modelID)?.responseFormat.storedFileExtension ?? "mp3"
        for fileExtension in [stored, stored == "mp3" ? "m4a" : "mp3"] {
            var request = URLRequest(url: hostedBaseURL.appendingPathComponent("\(key).\(fileExtension)"))
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 1_000,
                  ArticleSpeechAudioValidation.isWrappedAtModelSampleRate(data, modelID: modelID) else { continue }
            return data
        }
        return nil
    }

    /// Shared between the production and Dev profiles. The key is a hash of the
    /// model, the voice and the fixed sample text, so a preview is the same file
    /// whichever app generated it — and the warm-up walks the whole catalog, so
    /// splitting the folder meant paying for every voice twice.
    nonisolated static func fileURL(modelID: String, voiceID: String) -> URL {
        let fileExtension = ArticleSpeechCatalog.model(id: modelID)?
            .responseFormat.storedFileExtension ?? "mp3"
        return ForeverLMRuntimeIdentity.sharedVoicePreviewCacheURL
            .appendingPathComponent(cacheKey(modelID: modelID, voiceID: voiceID))
            .appendingPathExtension(fileExtension)
    }

    /// The catalog-wide warm-up: the prioritized model's every voice, then
    /// each other model's curated voices — or its first voice when ForeverLM
    /// curates none of them. A model with no voice list has no sample to warm.
    nonisolated static func previewPairs(
        prioritizedModelID: String
    ) -> [(modelID: String, voiceID: String)] {
        let models = ArticleSpeechCatalog.models
        let prioritized = models.filter { $0.id == prioritizedModelID }
        let remaining = models.filter { $0.id != prioritizedModelID }
        return prioritized.flatMap { model in model.voices.map { (model.id, $0.id) } }
            + remaining.flatMap { model in
                model.voices.prefix(max(model.curatedVoiceCount, 1)).map { (model.id, $0.id) }
            }
    }

    nonisolated static func previewPairs(
        forModelID modelID: String
    ) -> [(modelID: String, voiceID: String)] {
        ArticleSpeechCatalog.model(id: modelID)?.voices.map { (modelID, $0.id) } ?? []
    }

    nonisolated private static func save(
        _ data: Data,
        modelID: String,
        voiceID: String
    ) throws {
        guard !data.isEmpty else { return }
        let url = fileURL(modelID: modelID, voiceID: voiceID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var directory = url.deletingLastPathComponent()
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
        try data.write(to: url, options: .atomic)
    }
}

enum ArticleSpeechVoiceRating: String, Sendable {
    case up
    case down

    static let preferencePrefix = Prefs.Families.voiceRating.prefix
    static func preferenceKey(modelID: String, voiceID: String) -> String {
        "\(preferencePrefix)\(modelID)|\(voiceID)"
    }
}
