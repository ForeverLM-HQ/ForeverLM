import AVFoundation
import Foundation
import Network
import OSLog

/// Cross-platform managed text-to-speech generator for article text-to-speech.
///
/// Produces the same on-disk layout (audio chunks + `manifest.json`) that
/// `SyncedArticleAudioStore` reads, so generated audio plays through the
/// existing playback pipeline on both platforms and syncs via iCloud. This is
/// what lets iOS read articles aloud with cloud audio instead of the on-device
/// `AVSpeechSynthesizer`.
///
/// Every model is an OpenRouter model and every request goes to OpenRouter's
/// speech endpoint (product owner, 2026-09-27: "it can just be done via
/// openrouter"): straight there on the learner's own OpenRouter key, through
/// the managed proxy otherwise, which keeps the long-lived key. Grok and
/// Gemini used their makers' own APIs until then.
enum CloudArticleTTS {
    struct SpeechResponse: Sendable {
        let data: Data
        /// The proxy's metering receipt. Nil for audio the learner's own
        /// OpenRouter key bought straight from OpenRouter, which ForeverLM
        /// never metered and so has no receipt for.
        let requestID: String?
        let contentType: String
        let fileExtension: String
        /// Exact narration represented by this file. Rejected requests may be
        /// split into several responses, so the text belongs to each response.
        let text: String?
    }

    /// One model and the voice it speaks with. They travel together because
    /// Provider speech voices are model-specific: a voice from another
    /// model's list is a request the provider rejects.
    struct Selection: Sendable, Equatable {
        let model: String
        /// Optional at the type boundary for decoding older selections. Every
        /// request validates that it carries a catalog voice (`speechRequest`).
        let voice: String?

        var voiceLabel: String {
            guard let voice else { return "Unavailable" }
            return ArticleSpeechCatalog.voiceLabel(model: model, voice: voice)
        }
    }

    enum GenerationError: LocalizedError {
        case missingAPIKey
        case emptyText
        case badResponse(String)
        case failedAfterRetries(String)
        case invalidSelection(String)
        /// Retries never got the request out to the rail at all. Kept apart
        /// from `failedAfterRetries` because being offline is not a fault in
        /// the request, the model, or the settings, and must not read like one
        /// — this message is also spoken aloud.
        case networkUnavailable
        /// The rail answered, and refused this text on this model — a status no
        /// retry can change. Carries the model so the message names what has to
        /// be changed to get audio.
        case rejected(model: String, statusCode: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Sign in with Apple to read sources aloud."
            case .emptyText:
                return "This source has no readable text to narrate."
            case .badResponse(let message):
                return message
            case .failedAfterRetries(let message):
                return "Could not generate audio: \(message)"
            case .invalidSelection(let message):
                return "Text-to-speech settings are invalid. \(message) No audio request was sent."
            case .networkUnavailable:
                return "Text to speech needs a network connection. Try again once you're back online."
            case .rejected(let model, let statusCode, let reason):
                // Named as the picker names it: this message is also spoken
                // aloud, and a raw model id is not a sentence.
                let name = ArticleSpeechCatalog.model(id: model)?.name ?? model
                return """
                \(name) could not narrate this source (\(statusCode)): \(reason) \
                Pick a different text-to-speech voice in Settings.
                """
            }
        }

        var isRejection: Bool {
            if case .rejected = self { return true }
            return false
        }

        /// Only failures that smaller text can plausibly repair should create
        /// more billable requests. A proxy 5xx such as an unavailable Grok
        /// metering record must hand off to the fallback immediately.
        var isSplittableRejection: Bool {
            guard case .rejected(_, let statusCode, _) = self else { return false }
            return statusCode == 200 || statusCode == 400 || statusCode == 413 || statusCode == 422
        }
    }

    static let provider = ArticleSpeechCatalog.provider

    private static let maxConcurrentRequests = 6
    /// Body requests started the moment a source's generation begins, beside
    /// the opening. The rest join one per completion until the ceiling above
    /// is reached. Smaller than the ceiling on purpose: the second and third
    /// units are the ones that must land before the opening runs out, and on
    /// 2026-09-09 six Gemini requests in flight together each took 25–31 s
    /// while the lone opening took 10 s — parallel requests slow each other,
    /// so the head of the queue is better off with fewer neighbours.
    private static let openingBodyLaunchWave = 3
    private static let requestScheduler = ArticleSpeechRequestScheduler(
        maxConcurrentRequests: maxConcurrentRequests
    )
    /// Retries for a rail that answered and refused — an overloaded provider,
    /// a 429, a 5xx. Bounded tightly: the answer arrived, so the request is
    /// reaching the provider and more of them rarely change the verdict.
    private static let maxProviderAttempts = 4
    /// Retries for a request that never got an answer at all. A phone loses
    /// its connection as a matter of course — a lift, a tunnel, a cell
    /// handover, a Wi-Fi hop — and none of that is the provider refusing
    /// anything, so it gets its own, more patient budget. Sharing one budget
    /// with provider refusals is what turned twenty seconds underground into
    /// "Could not generate audio: The network connection was lost."
    private static let maxTransportAttempts = 6
    /// How long transport failures keep being retried before the listener is
    /// told the network is gone. Short drops — the ordinary case — fit several
    /// attempts inside it; one attempt that spends the whole window waiting for
    /// a network that never arrives ends it, because past five minutes the
    /// honest answer is that the device is offline, not that the rail is slow.
    private static let transportRetryWindow: TimeInterval = 300
    /// How long a request waits for a network before it is dispatched at all.
    /// Long enough to absorb a handover, short enough that a listener in
    /// airplane mode is told so rather than watching an empty progress bar.
    static let dispatchNetworkWait: TimeInterval = 10
    /// How long a failed request waits for the radio to come back before the
    /// next attempt. This is the tunnel: nothing else can succeed while the
    /// path is gone, so waiting for it beats spending attempts against it.
    static let recoveryNetworkWait: TimeInterval = 60
    /// How many times a rejected request may be halved before the model is
    /// declared unable to speak the text. Four pieces of an 8k section is
    /// already a 2k request; below that the input length is not the problem.
    private static let maxSplitDepth = 2
    /// Text shorter than this is not split again: a rejection here is about the
    /// model or the content, not the size.
    private static let minimumSplitLength = 400
    /// Speech endpoints may queue even a short free-model request, and larger
    /// narration units legitimately take well over a minute. Ninety seconds
    /// cut off healthy synthesis, then the transport loop sent the same
    /// potentially billable request again. Give one attempt most of the
    /// resource budget instead; an actual timeout is terminal below.
    private static let requestTimeout: TimeInterval = 240
    /// Ceiling for one attempt end to end, covering both the wait for a usable
    /// network and the transfer. Roomy because a chunk of narration is several
    /// megabytes and a slow link that is still making progress deserves to
    /// finish; `NetworkPathAvailability` is what keeps a device with no network
    /// at all from ever spending this.
    static let resourceTimeout: TimeInterval = 300
    static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/audio/speech")!

    /// The session every speech request travels on.
    ///
    /// `waitsForConnectivity` is the reason this is not `URLSession.shared`:
    /// without it, a request made while the radio is between cells fails
    /// instantly, and a whole retry budget can burn in a few seconds without
    /// one request ever reaching the rail. With it, the attempt waits for a
    /// network to appear (bounded by `timeoutIntervalForResource`) and then
    /// runs. It also keeps requests from leaving while offline only to die
    /// mid-flight — the shape of failure that pays for audio nobody receives.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = CloudArticleTTS.requestTimeout
        configuration.timeoutIntervalForResource = CloudArticleTTS.resourceTimeout
        return URLSession(configuration: configuration)
    }()

    /// Collects out-of-order request results and releases only the newly
    /// contiguous prefix. Speech requests finish in provider order, not source
    /// order; playback may consume 0, 1, 2 as soon as they exist, but must never
    /// jump from 0 to 2 while 1 is still missing.
    struct ContiguousResultBuffer<Value> {
        private var values: [Value?]
        private var nextReleaseIndex = 0

        init(count: Int) {
            values = [Value?](repeating: nil, count: count)
        }

        mutating func insert(_ value: Value, at index: Int) -> [Value] {
            guard values.indices.contains(index), values[index] == nil else { return [] }
            values[index] = value

            var released: [Value] = []
            while nextReleaseIndex < values.count,
                  let value = values[nextReleaseIndex] {
                released.append(value)
                nextReleaseIndex += 1
            }
            return released
        }

        var orderedValues: [Value]? {
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return values.compactMap { $0 }
        }
    }

    /// Serializes file names and the resume journal for progressively
    /// completed audio. One provider request may be split into several
    /// responses, so the next durable chunk index belongs to the complete
    /// contiguous prefix rather than the request index that happened to finish
    /// first. The opening is installed by whichever caller sees it done first;
    /// body chunks are numbered after it. Journal writes happen inside the
    /// actor so a slow opening can never overwrite a newer body journal.
    private actor ProgressiveChunkStore {
        struct Adoption: Sendable {
            let installed: Bool
            let completedRequestCount: Int
        }

        let sourceID: String
        private var opening: [SyncedArticleAudioManifest.Chunk]?
        private var body: [SyncedArticleAudioManifest.Chunk] = []
        /// Requests the installed opening stands for: one for a fresh opening,
        /// the whole resumed prefix when continuing an interrupted attempt.
        private var openingRequestCount: Int
        /// Every finished request, in whatever order it landed — the number
        /// the progress ring shows, not the resume point.
        private(set) var completedRequestCount: Int

        init(
            sourceID: String,
            opening: [SyncedArticleAudioManifest.Chunk]? = nil,
            completedRequestCount: Int = 0
        ) {
            self.sourceID = sourceID
            self.opening = opening
            self.openingRequestCount = opening == nil ? 0 : completedRequestCount
            self.completedRequestCount = completedRequestCount
        }

        /// The first call installs the opening and counts its request; later
        /// calls are no-ops that report the count as it stands.
        func adoptOpening(
            _ chunks: [SyncedArticleAudioManifest.Chunk],
            journal: @Sendable (_ chunks: [SyncedArticleAudioManifest.Chunk], _ completedRequestCount: Int) -> Void
        ) -> Adoption {
            guard opening == nil else {
                return Adoption(installed: false, completedRequestCount: completedRequestCount)
            }
            opening = chunks
            openingRequestCount = 1
            completedRequestCount += 1
            journal(allChunks(), openingRequestCount)
            return Adoption(installed: true, completedRequestCount: completedRequestCount)
        }

        /// Counts one finished body request, whatever its position; the
        /// contiguous prefix is what `append` tracks.
        func noteBodyRequestCompleted() -> Int {
            completedRequestCount += 1
            return completedRequestCount
        }

        /// `contiguousRequestCount` is how many body requests the gap-free
        /// prefix now covers; with the opening's own request(s) it is the
        /// resume point the journal records.
        func append(
            _ responses: [SpeechResponse],
            contiguousRequestCount: Int,
            journal: @Sendable (_ chunks: [SyncedArticleAudioManifest.Chunk], _ completedRequestCount: Int) -> Void
        ) throws -> [SyncedArticleAudioManifest.Chunk] {
            guard let opening else {
                throw GenerationError.badResponse("Audio arrived before the opening was saved.")
            }
            for response in responses {
                var chunk = try SyncedArticleAudioStore.saveChunk(
                    response.data,
                    sourceID: sourceID,
                    index: opening.count + body.count,
                    fileExtension: response.fileExtension
                )
                chunk.text = response.text
                body.append(chunk)
            }
            let chunks = allChunks()
            journal(chunks, openingRequestCount + contiguousRequestCount)
            return chunks
        }

        func allChunks() -> [SyncedArticleAudioManifest.Chunk] {
            (opening ?? []) + body
        }
    }

    /// The iPhone's chosen model and its voice, validated against the catalog.
    /// The catalog follows OpenRouter's directory, so an async caller reads it
    /// first (`OpenRouterAudioDirectory.prepare`); `generate` does. A pick
    /// OpenRouter stopped offering is repaired here, silently, as the Mac's
    /// request path repairs its own; Listen repairs it first and says so
    /// (`ArticleSpeechSelection.repairSelectionForUse`). What is left to
    /// refuse is a model this device cannot check: OpenRouter's list has not
    /// been read and this build does not record it.
    static func currentSelection(defaults: UserDefaults = .standard) throws -> Selection {
        ArticleSpeechSelection.repairStoredPick(defaults: defaults)
        if let stored = defaults.string(forKey: ArticleSpeechSelection.modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty,
           ArticleSpeechCatalog.model(id: stored) == nil {
            throw GenerationError.badResponse(unavailableModelMessage(stored))
        }
        let modelID = ArticleSpeechSelection.modelID(defaults: defaults)
        return Selection(
            model: modelID,
            voice: ArticleSpeechSelection.voiceID(forModel: modelID, defaults: defaults)
        )
    }

    /// Why a model cannot be sent, in the Mac's words
    /// (`MacArticleSpeechSettings.unavailableModelMessage`): OpenRouter's
    /// speech list no longer has it, or this device could not read the list
    /// to check. A stored pick never reaches the first once the list is
    /// read (`repairStoredPick`); a model named explicitly (a language's
    /// own) can.
    static func unavailableModelMessage(_ model: String) -> String {
        ArticleSpeechCatalog.isDirectoryBacked
            ? "\(model) is no longer offered by OpenRouter. Choose a text-to-speech model in Settings."
            : "OpenRouter's list of speech models could not be read to check \(model). Try again once OpenRouter can be reached."
    }

    /// Exactly the chosen model. A failed paid synthesis must never silently
    /// start another paid request on a different provider.
    static func candidateSelections(startingWith selection: Selection) -> [Selection] {
        [selection]
    }

    /// Returns a playable manifest for `text`, reusing cached audio when the
    /// content is unchanged so replays (and re-asks) are instant.
    ///
    /// `onOpeningReady` is called as soon as the opening section's audio is on
    /// disk, with a manifest describing only that section, so Listen can start
    /// playing while the rest of a long source is still being generated. That
    /// partial manifest is **never written to disk**: a truncated manifest in
    /// the synced folder would read as a complete source on the listener's
    /// other devices. Only the final, whole manifest is saved.
    ///
    /// Generation is resumable. Every gap-free prefix of finished requests is
    /// journaled to `generation-progress.json` beside the audio, so an attempt
    /// interrupted part-way — the phone suspending the app in the background,
    /// a connection dropped mid-source — restarts at the first missing chunk
    /// instead of paying for the whole source again.
    static func generate(
        sourceID: String,
        title: String,
        subtitle: String?,
        sourceType: String,
        sourceURL: String,
        text: String,
        sourceContentSignature: String? = nil,
        narrationPreparationSignature: String? = nil,
        createdAt: Date,
        selection: Selection? = nil,
        generatedOnPlatform: String = "ios",
        onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)? = nil,
        onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)? = nil,
        onProgress: (@Sendable (_ completedChunks: Int, _ totalChunks: Int) async -> Void)? = nil
    ) async throws -> SyncedArticleAudioManifest {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw GenerationError.emptyText }
        if sourceType == "paper",
           sourceContentSignature == nil || narrationPreparationSignature == nil {
            throw GenerationError.badResponse(
                "Paper narration must be prepared before text-to-speech generation."
            )
        }

        guard ManagedAI.isSignedIn else { throw GenerationError.missingAPIKey }
        // The selection is checked against OpenRouter's speech list, which a
        // device that has never read it does not have yet.
        await OpenRouterAudioDirectory.prepare(.speech)

        let signature = SyncedArticleAudioStore.contentSignature(for: trimmedText)

        if let cached = await Task.detached(priority: .userInitiated, operation: {
            let cached = cachedManifest(sourceID: sourceID, signature: signature)
            if cached != nil {
                // A finished manifest outranks any journal left behind by an
                // earlier attempt at the same audio.
                SyncedArticleAudioStore.clearGenerationProgress(sourceID: sourceID)
            }
            return cached
        }).value {
            return cached
        }

        // Resolve the shared destination before spending money on TTS. A
        // successful generation must never be stranded only on the phone.
        try await Task.detached(priority: .userInitiated) {
            try SyncedArticleAudioStore.ensureSyncedAudioStorageAvailable()
        }.value

        let initialSelection = try selection ?? currentSelection()
        let plannedChunks = chunk(
            trimmedText,
            limit: ArticleSpeechCatalog.chunkLimit(forModel: initialSelection.model),
            leadLimit: ArticleSpeechCatalog.leadChunkLimit(forModel: initialSelection.model)
        )
        guard let lead = plannedChunks.first else { throw GenerationError.emptyText }
        let totalChunks = plannedChunks.count

        // What an interrupted earlier attempt already generated and paid for.
        // Nothing here is trusted blind: the journal is only usable when it
        // describes this exact text, on this exact model and voice, with the
        // same chunk plan, and with every file it names still on disk.
        let resumable = await Task.detached(priority: .userInitiated) {
            resumableProgress(
                sourceID: sourceID,
                signature: signature,
                selection: initialSelection,
                plannedRequestCount: totalChunks
            )
        }.value

        // Publish a real starting progress state before the first network
        // request. The opening request is often the longest silent stretch
        // because no playable bytes exist yet; without this callback the UI can
        // only show an indeterminate ellipsis until that whole request finishes.
        await onProgress?(resumable?.completedRequestCount ?? 0, totalChunks)

        @Sendable func manifest(
            selection: Selection,
            chunks: [SyncedArticleAudioManifest.Chunk]
        ) -> SyncedArticleAudioManifest {
            SyncedArticleAudioManifest(
                schemaVersion: SyncedArticleAudioManifest.schemaVersion,
                sourceID: sourceID,
                title: title,
                subtitle: subtitle,
                sourceType: sourceType,
                sourceURL: sourceURL,
                provider: provider,
                model: selection.model,
                voice: selection.voice ?? "",
                voiceLabel: selection.voiceLabel,
                contentSignature: signature,
                totalCharacters: trimmedText.count,
                createdAt: createdAt,
                chunks: chunks,
                sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
                narrationVersion: sourceType == "paper" ? PaperNarrationFilter.version : nil,
                sourceContentSignature: sourceContentSignature,
                narrationPreparationSignature: narrationPreparationSignature,
                generatedOnPlatform: generatedOnPlatform
            )
        }

        @Sendable func save(_ responses: [SpeechResponse], from index: Int) throws -> [SyncedArticleAudioManifest.Chunk] {
            try responses.enumerated().map { offset, response in
                var chunk = try SyncedArticleAudioStore.saveChunk(
                    response.data,
                    sourceID: sourceID,
                    index: index + offset,
                    fileExtension: response.fileExtension
                )
                chunk.text = response.text
                return chunk
            }
        }

        @Sendable func journalProgress(
            chunks: [SyncedArticleAudioManifest.Chunk],
            completedRequestCount: Int
        ) {
            // Best effort by design: losing the resume point costs money on the
            // next attempt, but failing the generation over it costs the whole
            // source. The final manifest is the write that must not fail.
            try? SyncedArticleAudioStore.saveGenerationProgress(
                ArticleSpeechGenerationProgress(
                    sourceID: sourceID,
                    contentSignature: signature,
                    model: initialSelection.model,
                    voice: initialSelection.voice ?? "",
                    plannedRequestCount: totalChunks,
                    completedRequestCount: completedRequestCount,
                    chunks: chunks,
                    updatedAt: createdAt
                )
            )
        }

        return try await AIUsageAttribution.$task.withValue("read_aloud") {
            try? SyncedArticleAudioStore.saveSourceText(trimmedText, sourceID: sourceID)

            // The opening either survives from an interrupted attempt or is
            // requested now — and the body requests below go out at the same
            // moment, not after it. Waiting for the opening first used to cost
            // the whole opening latency twice: once before sound started, and
            // again as silence when the opening ran out before the second
            // request could possibly have landed (measured on 2026-09-09: a
            // 240-character Gemini opening took 10 s and played for 11 s, and
            // the first body request, started only after it, took 25 s).
            let store: ProgressiveChunkStore
            let remainingChunks: [String]
            let openingTask: Task<[SyncedArticleAudioManifest.Chunk], Error>?
            if let resumable {
                store = ProgressiveChunkStore(
                    sourceID: sourceID,
                    opening: resumable.chunks,
                    completedRequestCount: resumable.completedRequestCount
                )
                remainingChunks = Array(plannedChunks.dropFirst(resumable.completedRequestCount))
                openingTask = nil
            } else {
                store = ProgressiveChunkStore(sourceID: sourceID)
                remainingChunks = Array(plannedChunks.dropFirst())
                // Unstructured on purpose so the body's task group does not
                // have to wait for it, but still inside this attribution scope
                // (`Task` inherits task-locals; `Task.detached` would not).
                openingTask = Task(priority: .userInitiated) {
                    let responses = try await synthesizeSegment(
                        lead,
                        selection: initialSelection,
                        priority: .opening
                    )
                    return try save(responses, from: 0)
                }
            }

            /// The opening's chunks, on disk and installed as the prefix every
            /// body chunk is numbered after. Safe to await from several places:
            /// the first caller journals and reports it, later callers see it.
            @Sendable func openingChunks() async throws -> [SyncedArticleAudioManifest.Chunk] {
                guard let openingTask else { return await store.allChunks() }
                let chunks = try await openingTask.value
                let adoption = await store.adoptOpening(chunks) { chunks, completed in
                    journalProgress(chunks: chunks, completedRequestCount: completed)
                }
                if adoption.installed {
                    await onProgress?(adoption.completedRequestCount, totalChunks)
                }
                return chunks
            }

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let chunks = try await openingChunks()
                        if let onOpeningReady {
                            await onOpeningReady(manifest(selection: initialSelection, chunks: chunks))
                        }
                    }
                    group.addTask {
                        _ = try await synthesizeConcurrently(
                            remainingChunks,
                            selection: initialSelection,
                            initialConcurrency: openingBodyLaunchWave,
                            onContiguousResponses: { responses, contiguousRequestCount in
                                // Body chunks are numbered after the opening, so
                                // the opening has to be on disk first — normally
                                // long since, as the smallest and highest-priority
                                // request.
                                _ = try await openingChunks()
                                let chunks = try await store.append(
                                    responses,
                                    contiguousRequestCount: contiguousRequestCount
                                ) { chunks, completed in
                                    journalProgress(chunks: chunks, completedRequestCount: completed)
                                }
                                // The ordinary final handoff follows immediately after the
                                // last request. Intermediate prefixes are the ones that keep
                                // playback fed while a slower tail is still generating.
                                if contiguousRequestCount < remainingChunks.count {
                                    await onMoreAudioReady?(
                                        manifest(selection: initialSelection, chunks: chunks)
                                    )
                                }
                            },
                            onChunkCompleted: { _ in
                                let completed = await store.noteBodyRequestCompleted()
                                await onProgress?(completed, totalChunks)
                            }
                        )
                    }
                    try await group.waitForAll()
                }
            } catch {
                // The opening is unstructured, so a body failure or an outer
                // cancellation has to reach it by hand.
                openingTask?.cancel()
                #if os(iOS)
                // A refusal of the model or its audio has the pair tested
                // again, so the verdict, not one chunk's failure, decides
                // whether a repair passes it over. Nothing switches models.
                if qualificationVerdict(for: error) != nil {
                    recheckAfterRefusal(model: initialSelection.model, voice: initialSelection.voice ?? "")
                }
                #endif
                throw error
            }

            let manifestChunks = await store.allChunks()
            let whole = manifest(selection: initialSelection, chunks: manifestChunks)
            try SyncedArticleAudioStore.saveManifest(whole)
            // The manifest is now the record of this audio; the resume point has
            // nothing left to describe.
            SyncedArticleAudioStore.clearGenerationProgress(sourceID: sourceID)
            return whole
        }
    }

    /// The journaled prefix that this generation may safely continue from.
    ///
    /// A resume must produce exactly the audio a fresh run would have, so it is
    /// refused unless the narration text, the model, the voice, and the chunk
    /// plan all still match what the stored prefix was generated against. A
    /// journal that fails any of those describes audio this call is not making,
    /// and is deleted rather than left to confuse a later attempt.
    static func resumableProgress(
        sourceID: String,
        signature: String,
        selection: Selection,
        plannedRequestCount: Int
    ) -> ArticleSpeechGenerationProgress? {
        guard let progress = SyncedArticleAudioStore.loadGenerationProgress(sourceID: sourceID) else {
            return nil
        }
        guard progress.contentSignature == signature,
              progress.model == selection.model,
              progress.voice == (selection.voice ?? ""),
              progress.plannedRequestCount == plannedRequestCount else {
            SyncedArticleAudioStore.clearGenerationProgress(sourceID: sourceID)
            return nil
        }
        return progress
    }

    // MARK: - Cache reuse

    /// Existing audio for unchanged text is reused whatever model produced it,
    /// unless that model was retired for a reason (`isRetiredModel`) —
    /// matching the Mac's rule (`ArticleSpeechService`). Deliberately not keyed
    /// to the current selection: a listener who changes their text-to-speech voice
    /// wants it for sources they have not generated yet, not a silent
    /// re-billing of every source they already own. Nor to what OpenRouter
    /// lists today: audio already paid for plays whether or not OpenRouter
    /// still serves the model that made it.
    static func cachedManifest(sourceID: String, signature: String) -> SyncedArticleAudioManifest? {
        let url = SyncedArticleAudioStore.manifestURL(sourceID: sourceID)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SyncedArticleAudioManifest.self, from: data),
              manifest.schemaVersion == SyncedArticleAudioManifest.schemaVersion,
              manifest.usesCurrentNarration,
              manifest.speaksInOneVoice,
              !ArticleSpeechCatalog.isRetiredModel(manifest.model),
              manifest.contentSignature == signature,
              (try? SyncedArticleAudioStore.chunkURLs(for: manifest)) != nil else {
            return nil
        }
        return manifest
    }

    // MARK: - Network

    /// Narrates `text`, and keeps narrating when a model refuses it.
    ///
    /// A refusal is answered twice over. First the request is halved and each
    /// half sent again, which is what recovers a section the model considered
    /// too long — the halves become their own ordered manifest chunks, so
    /// nothing is stitched together and playback order is unchanged.
    ///
    /// A model is never switched mid-source: chunk sizes belong to the model,
    /// so a source is narrated by exactly one of them and the manifest records
    /// which.
    static func synthesize(text: String) async throws -> (Selection, [SpeechResponse]) {
        let opening = try await synthesizeOpening(text: text)
        let rest = try await synthesizeConcurrently(
            opening.remainingChunks,
            selection: opening.selection
        )
        return (opening.selection, opening.responses + rest)
    }

    /// The opening section, narrated and ready to play, plus what is left to
    /// generate for it. Split out so a listener hears the first section while
    /// the rest of a long source is still being made.
    struct Opening: Sendable {
        let selection: Selection
        let responses: [SpeechResponse]
        let remainingChunks: [String]
    }

    static func synthesizeOpening(
        text: String,
        selection: Selection? = nil
    ) async throws -> Opening {
        await OpenRouterAudioDirectory.prepare(.speech)
        let candidates = candidateSelections(startingWith: try selection ?? currentSelection())
        var lastRejection: Error?

        for (index, selection) in candidates.enumerated() {
            let chunks = chunk(
                text,
                limit: ArticleSpeechCatalog.chunkLimit(forModel: selection.model),
                leadLimit: ArticleSpeechCatalog.leadChunkLimit(forModel: selection.model)
            )
            guard let lead = chunks.first else { throw GenerationError.emptyText }

            do {
                return Opening(
                    selection: selection,
                    responses: try await synthesizeSegment(
                        lead,
                        selection: selection,
                        priority: .opening
                    ),
                    remainingChunks: Array(chunks.dropFirst())
                )
            } catch let error as GenerationError where error.isRejection && index < candidates.count - 1 {
                lastRejection = error
                continue
            }
        }

        throw lastRejection ?? GenerationError.emptyText
    }

    /// Generates every remaining chunk concurrently (bounded), in chunk order.
    /// A chunk that had to be split contributes several responses, which stay
    /// in position because the group's results are collected by chunk index.
    ///
    /// `initialConcurrency` is how many requests go out at once at the start;
    /// each completion then admits one more than it replaces until
    /// `maxConcurrentRequests` are in flight.
    private static func synthesizeConcurrently(
        _ chunks: [String],
        selection: Selection,
        initialConcurrency: Int = maxConcurrentRequests,
        onContiguousResponses: (@Sendable (
            _ responses: [SpeechResponse],
            _ contiguousRequestCount: Int
        ) async throws -> Void)? = nil,
        onChunkCompleted: (@Sendable (_ completedChunks: Int) async -> Void)? = nil
    ) async throws -> [SpeechResponse] {
        guard !chunks.isEmpty else { return [] }
        var results = ContiguousResultBuffer<[SpeechResponse]>(count: chunks.count)
        var completedCount = 0
        var contiguousRequestCount = 0
        let firstWave = max(1, min(initialConcurrency, maxConcurrentRequests))

        try await withThrowingTaskGroup(of: (Int, [SpeechResponse]).self) { group in
            var nextIndex = 0
            var inFlight = 0
            while inFlight < firstWave, nextIndex < chunks.count {
                let index = nextIndex
                group.addTask {
                    let responses = try await synthesizeSegment(
                        chunks[index],
                        selection: selection,
                        priority: .continuation(index: index)
                    )
                    return (index, responses)
                }
                nextIndex += 1
                inFlight += 1
            }

            while let (index, responses) = try await group.next() {
                let newlyContiguous = results.insert(responses, at: index)
                completedCount += 1
                inFlight -= 1
                let allowedInFlight = min(maxConcurrentRequests, firstWave + completedCount)
                while inFlight < allowedInFlight, nextIndex < chunks.count {
                    let index = nextIndex
                    group.addTask {
                        let responses = try await synthesizeSegment(
                            chunks[index],
                            selection: selection,
                            priority: .continuation(index: index)
                        )
                        return (index, responses)
                    }
                    nextIndex += 1
                    inFlight += 1
                }
                if !newlyContiguous.isEmpty {
                    contiguousRequestCount += newlyContiguous.count
                    try await onContiguousResponses?(
                        newlyContiguous.flatMap { $0 },
                        contiguousRequestCount
                    )
                }
                await onChunkCompleted?(completedCount)
            }
        }

        guard let ordered = results.orderedValues else {
            throw GenerationError.badResponse(
                "The model provider did not return every requested audio chunk."
            )
        }
        return ordered.flatMap { $0 }
    }

    /// One chunk's audio, as one response or — when the model refuses the whole
    /// chunk — as the ordered responses of its halves.
    private static func synthesizeSegment(
        _ text: String,
        selection: Selection,
        priority: ArticleSpeechRequestScheduler.Priority,
        depth: Int = 0
    ) async throws -> [SpeechResponse] {
        do {
            return [try await synthesizeRequest(text, selection: selection, priority: priority)]
        } catch let error as GenerationError {
            guard error.isSplittableRejection,
                  depth < maxSplitDepth,
                  let halves = split(text) else { throw error }
            var responses: [SpeechResponse] = []
            for half in halves {
                responses += try await synthesizeSegment(
                    half,
                    selection: selection,
                    priority: priority,
                    depth: depth + 1
                )
            }
            return responses
        }
    }

    /// Splits at the sentence boundary nearest the middle so neither half
    /// starts mid-sentence. Returns nil when the text is already short enough
    /// that its length cannot be what the model objected to.
    static func split(_ text: String) -> [String]? {
        guard text.count >= minimumSplitLength else { return nil }
        let parts = sentences(in: text)
        guard parts.count > 1 else { return nil }

        let midpoint = text.count / 2
        var bestIndex = 1
        var bestDistance = Int.max
        var consumed = 0
        for (index, sentence) in parts.enumerated() where index < parts.count - 1 {
            consumed += sentence.count + 1
            let distance = abs(consumed - midpoint)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index + 1
            }
        }

        let first = parts[..<bestIndex].joined(separator: " ")
        let second = parts[bestIndex...].joined(separator: " ")
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return [first, second]
    }

    static func speechRequest(text: String, selection: Selection) throws -> URLRequest {
        guard let model = ArticleSpeechCatalog.model(id: selection.model) else {
            throw GenerationError.badResponse(unavailableModelMessage(selection.model))
        }
        // Every request names its speaker. Without one the provider picks,
        // and can pick a different speaker for each request of one source.
        let voice = selection.voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !voice.isEmpty, model.voice(id: voice) != nil else {
            throw GenerationError.invalidSelection("Choose the voice again in Settings.")
        }
        // One route for every model, Grok and Gemini included: OpenRouter's
        // speech endpoint under the model's OpenRouter slug. `rewrite` sends
        // it straight to OpenRouter on the learner's own key, or through the
        // managed proxy, which prices it from OpenRouter's directory.
        var payload: [String: Any] = [
            "model": selection.model,
            "input": text,
            "response_format": model.responseFormat.rawValue,
            "voice": voice,
        ]
        var request = URLRequest(url: openRouterEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        ManagedAI.rewrite(&request)
        return request
    }

    #if DEBUG
    /// Makes one real, non-persisted request for the authenticated Simulator
    /// probe. The caller validates that AVFoundation can decode the returned
    /// bytes; keeping it out of the source store avoids fake library records.
    static func synthesizeProbe(_ text: String) async throws -> [SpeechResponse] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw GenerationError.emptyText }
        guard ManagedAI.isSignedIn else { throw GenerationError.missingAPIKey }
        return try await AIUsageAttribution.$task.withValue("read_aloud_probe") {
            try await synthesize(text: input).1
        }
    }
    #endif

    /// Generates one short, non-persisted sample for a specific picker row.
    /// The caller owns local preview caching; the first request still travels
    /// through the managed speech rail and is attributed separately from
    /// source narration.
    static func synthesizePreview(
        _ text: String,
        modelID: String,
        voiceID: String
    ) async throws -> SpeechResponse {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw GenerationError.emptyText }
        guard ManagedAI.isSignedIn else { throw GenerationError.missingAPIKey }
        await OpenRouterAudioDirectory.prepare(.speech)
        guard let model = ArticleSpeechCatalog.model(id: modelID),
              model.voice(id: voiceID) != nil else {
            throw GenerationError.invalidSelection("Choose the voice again in Settings.")
        }

        return try await AIUsageAttribution.$task.withValue("voice_preview") {
            try await listed(step: "voice_preview") {
                try await synthesizeRequest(
                    input,
                    selection: Selection(model: modelID, voice: voiceID),
                    priority: .opening
                )
            }
        }
    }

    /// On the Mac, a request made outside a narration is listed for the
    /// background-work list, where Stop cancels it: the voice samples warmed
    /// at launch, the test of a pick. A narration's own requests are its row.
    private static func listed(
        step: String,
        _ body: @escaping @Sendable () async throws -> SpeechResponse
    ) async throws -> SpeechResponse {
        #if os(macOS)
        return try await AIInFlightCalls.current.track(step: step) { _ in try await body() }
        #else
        return try await body()
        #endif
    }

    /// One short synthesis for the test of a pick
    /// (`CloudArticleTTS+Qualification.swift`): exactly the request playback
    /// sends for this model and voice, in the model's catalogued format, on
    /// the learner's own key or the managed rail, never saved. A model with
    /// no voice list is sent with none.
    static func synthesizeQualificationProbe(
        _ text: String,
        modelID: String,
        voiceID: String
    ) async throws {
        guard ManagedAI.isSignedIn else { throw GenerationError.missingAPIKey }
        await OpenRouterAudioDirectory.prepare(.speech)
        let voice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await AIUsageAttribution.$task.withValue(AIModelQualification.taskLabel) {
            try await listed(step: AIModelQualification.taskLabel) {
                try await synthesizeRequest(
                    text,
                    selection: Selection(model: modelID, voice: voice.isEmpty ? nil : voice),
                    priority: .opening
                )
            }
        }
    }

    private static func synthesizeRequest(
        _ text: String,
        selection: Selection,
        priority: ArticleSpeechRequestScheduler.Priority
    ) async throws -> SpeechResponse {
        let request = try speechRequest(text: text, selection: selection)

        // Speech is paid for one request at a time, and a device with no
        // network path cannot spend it. Answering that here — before the first
        // attempt — is what keeps an airplane-mode listener from watching a
        // progress bar that was never going to move. The short wait first
        // keeps a handover between cells from being reported as offline.
        guard await NetworkPathAvailability.shared.waitForPath(timeout: dispatchNetworkWait) else {
            throw GenerationError.networkUnavailable
        }

        // Two budgets, because they answer two different questions. A provider
        // that refused the request has been reached; a request that never got
        // out has not, and the listener's radio deserves more patience than an
        // overloaded model does.
        var providerAttempt = 0
        var transportAttempt = 0
        let startedAt = Date()

        while true {
            do {
                let (data, response) = try await scheduledData(
                    for: request,
                    priority: priority
                )
                guard let http = response as? HTTPURLResponse else {
                    throw GenerationError.badResponse("The model provider did not return an HTTP response.")
                }

                if (200..<300).contains(http.statusCode) {
                    // OpenRouter billed this attempt even if the audio is
                    // rejected below, so the row goes in first.
                    if http.url?.host?.lowercased() == openRouterEndpoint.host {
                        recordOwnKeySpeech(response: http, model: selection.model, characters: text.count)
                    }
                    return try validatedSpeechResponse(
                        data: data,
                        response: http,
                        model: selection.model,
                        inputText: text
                    )
                }

                // An account-level refusal — no credit, no session, a disabled
                // account — is about the account, not this model. Surfacing the
                // server's own message beats retrying it against three more
                // models that will refuse it identically.
                if let service = ManagedAI.serviceError(from: data) {
                    if isAccountFailure(service) || service.code == "metering_failed" {
                        ManagedAI.surfaceIfNeeded(service)
                        throw service
                    }
                    // A metering response can fail after the provider finishes.
                    // Regenerating cannot repair that server-side gap, so fail
                    // without splitting it into more paid requests.
                    if service.code == "unmetered_response" {
                        throw GenerationError.rejected(
                            model: selection.model,
                            statusCode: http.statusCode,
                            reason: service.message
                        )
                    }
                }

                let reason = providerErrorMessage(data: data)
                providerAttempt += 1
                if providerAttempt < maxProviderAttempts, isRetryable(http.statusCode) {
                    try await Task.sleep(nanoseconds: backoffNanoseconds(attempt: providerAttempt))
                    continue
                }
                throw GenerationError.rejected(
                    model: selection.model,
                    statusCode: http.statusCode,
                    reason: reason
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GenerationError {
                throw error
            } catch let error as ManagedAI.ServiceError {
                throw error
            } catch {
                transportAttempt += 1
                guard shouldRetryTransport(
                    error,
                    attempt: transportAttempt,
                    elapsed: Date().timeIntervalSince(startedAt)
                ) else {
                    throw transportFailure(error)
                }
                try await Task.sleep(nanoseconds: backoffNanoseconds(attempt: transportAttempt))
                // Retrying into an outage only spends the budget faster. Wait
                // for the radio instead: a lift or a tunnel ends, and the
                // attempt that follows is the one that actually succeeds.
                guard await NetworkPathAvailability.shared.waitForPath(
                    timeout: recoveryNetworkWait
                ) else {
                    throw GenerationError.networkUnavailable
                }
            }
        }
    }

    /// Whether a request that never reached the rail gets another attempt.
    /// Pure so the policy can be proven without a network: the budget is spent
    /// by attempts *and* by elapsed time, so a listener underground is not
    /// held past the point where "offline" stops being temporary.
    static func shouldRetryTransport(attempt: Int, elapsed: TimeInterval) -> Bool {
        attempt < maxTransportAttempts && elapsed < transportRetryWindow
    }

    /// A timed-out synthesis may still finish upstream and be charged. Sending
    /// the identical text again can buy duplicate audio, so timeouts get the
    /// longer single-attempt budget above and never enter the retry loop.
    static func shouldRetryTransport(
        _ error: Error,
        attempt: Int,
        elapsed: TimeInterval
    ) -> Bool {
        if (error as? URLError)?.code == .timedOut { return false }
        return shouldRetryTransport(attempt: attempt, elapsed: elapsed)
    }

    /// The failure a listener sees once retries have stopped. Being offline
    /// gets its own sentence: "Could not generate audio: The network
    /// connection was lost." sends someone looking at their text-to-speech
    /// settings for a condition that has nothing to do with them.
    static func transportFailure(_ error: Error) -> GenerationError {
        isOfflineError(error)
            ? .networkUnavailable
            : .failedAfterRetries(error.localizedDescription)
    }

    /// URL errors that mean "this device has no usable network right now",
    /// as opposed to a request or a server that misbehaved. A timeout is
    /// deliberately absent: a slow provider is not an absent network.
    static func isOfflineError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .callIsActive,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    private static func scheduledData(
        for request: URLRequest,
        priority: ArticleSpeechRequestScheduler.Priority
    ) async throws -> (Data, URLResponse) {
        try await requestScheduler.acquire(priority: priority)
        do {
            let response = try await session.foreverLMData(for: request)
            await requestScheduler.release()
            return response
        } catch {
            await requestScheduler.release()
            throw error
        }
    }

    /// Codes the proxy returns about the account rather than the request, which
    /// no other model or chunk size can satisfy.
    static func isAccountFailure(_ error: ManagedAI.ServiceError) -> Bool {
        [
            "credits_empty",
            "invalid_session",
            "account_disabled",
            "spend_cap_reached",
            "managed_disabled",
            "upstream_unconfigured",
        ].contains(error.code)
    }

    /// `model` names the model that answered, which turns a malformed answer
    /// into a rejection this model can be replaced over. Omitting it (tests,
    /// and any caller with no model in hand) keeps the plain failure.
    static func validatedSpeechResponse(
        data: Data,
        response: HTTPURLResponse,
        model: String? = nil,
        inputText: String? = nil
    ) throws -> SpeechResponse {
        func malformed(_ message: String) -> GenerationError {
            guard let model else { return .badResponse(message) }
            return .rejected(model: model, statusCode: response.statusCode, reason: message)
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard contentType.hasPrefix("audio/")
                || contentType.hasPrefix("application/octet-stream")
                || contentType.hasPrefix("binary/octet-stream") else {
            throw malformed(
                "The model provider returned \(contentType.isEmpty ? "an unknown content type" : contentType) instead of audio."
            )
        }
        // Audio the proxy released carries the receipt of the debit it made; a
        // proxy response without one is unmetered and refused. Audio from
        // openrouter.ai itself was bought with the learner's own key, which
        // `ManagedAI.rewrite` sends there directly, and ForeverLM has no
        // receipt to give for a request it never saw.
        let requestID = response.value(forHTTPHeaderField: "x-foreverlm-request-id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boughtOnOwnKey = response.url?.host?.lowercased() == ManagedAI.OwnKeyRouter.openRouter.host
        if !boughtOnOwnKey, requestID?.isEmpty ?? true {
            throw GenerationError.badResponse(
                "ForeverLM AI returned audio without a metering receipt."
            )
        }

        let responseFormat = model
            .flatMap { ArticleSpeechCatalog.model(id: $0)?.responseFormat }
            ?? .mp3
        let playableData: Data
        switch responseFormat {
        case .mp3:
            guard looksLikeMP3(data) else {
                throw malformed("The model provider returned audio that was not a valid MP3 stream.")
            }
            playableData = data
        case .pcm:
            do {
                playableData = try ArticleSpeechPCMTranscode.m4aData(fromPCM: data)
            } catch {
                throw malformed(error.localizedDescription)
            }
        }

        if let inputText {
            let duration: TimeInterval
            do {
                duration = try AVAudioPlayer(data: playableData).duration
            } catch {
                throw malformed("The model provider returned audio that could not be decoded.")
            }
            if let failure = ArticleSpeechAudioValidation.failureReason(
                text: inputText,
                duration: duration
            ) {
                throw malformed(failure)
            }
        }
        return SpeechResponse(
            data: playableData,
            requestID: requestID?.isEmpty == false ? requestID : nil,
            contentType: responseFormat == .pcm ? "audio/mp4" : contentType,
            fileExtension: responseFormat.storedFileExtension,
            text: inputText
        )
    }

    private static func looksLikeMP3(_ data: Data) -> Bool {
        guard data.count >= 128 else { return false }
        let bytes = [UInt8](data.prefix(4_096))
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return true
        }
        guard bytes.count >= 2 else { return false }
        return (0..<(bytes.count - 1)).contains { index in
            bytes[index] == 0xFF && (bytes[index + 1] & 0xE0) == 0xE0
        }
    }

    /// The provider's own words for a failure, when it wrote any. Filtered:
    /// a failing provider often answers with the request instead of an
    /// explanation, and this string is shown to the reader.
    private static func providerErrorMessage(data: Data) -> String {
        AIProviderErrorText.fromResponseBody(data) ?? "The provider returned no readable error details."
    }

    private static func isRetryable(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 409
            || statusCode == 425
            || statusCode == 429
            || (500..<600).contains(statusCode)
    }

    private static func backoffNanoseconds(attempt: Int) -> UInt64 {
        let exponential = min(pow(2.0, Double(attempt - 1)), 8.0)
        let jitter = Double.random(in: 0.15...0.6)
        return UInt64((exponential + jitter) * 1_000_000_000)
    }

    // MARK: - Chunking (mirrors macOS ArticleSpeechService)

    /// Splits narration into request-sized units for one model. The limits are
    /// the model's — a section sized for Gemini's 32k context is a rejected
    /// request on a model that takes a quarter of it — so chunking is redone
    /// whenever the model changes.
    ///
    /// The units ramp up: the lead is the short opening that gets sound out in
    /// seconds, the unit after it is lead-sized too, and each unit after that
    /// may be twice as long as the one before, until the model's full limit.
    /// Synthesis time grows with the text, so a full-size second unit takes
    /// longer to make than a short opening takes to play, and playback fell
    /// silent between them. The second unit is requested together with the
    /// opening (`generate`), and a unit the size of the opening lands about
    /// when the opening does — while it is still playing. The ramp then
    /// reaches the full limit within a few requests.
    static func chunk(_ text: String, limit: Int, leadLimit: Int) -> [String] {
        let chunkLimit = max(limit, 1)
        let reflowed = reflowedForSpeech(text)

        var chunks: [String] = []
        var current = ""
        let lead = min(leadLimit, chunkLimit)
        var currentLimit = lead

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = ""
            currentLimit = chunks.count == 1 ? lead : min(currentLimit * 2, chunkLimit)
        }

        let paragraphs = reflowed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs {
            let fillingLeadChunk = chunks.isEmpty && currentLimit < chunkLimit
            let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            if candidate.count <= currentLimit {
                current = candidate
                continue
            }

            // Keep a heading in the fast lead and use its remaining room for
            // complete opening sentences. Later requests pack whole paragraphs
            // until their larger synthesis context is full.
            if !fillingLeadChunk {
                flushCurrent()
                if paragraph.count <= currentLimit {
                    current = paragraph
                    continue
                }
            }

            var joiner = "\n\n"
            for sentence in sentences(in: paragraph) {
                let sentenceCandidate = current.isEmpty ? sentence : "\(current)\(joiner)\(sentence)"
                joiner = " "
                if sentenceCandidate.count <= currentLimit {
                    current = sentenceCandidate
                } else {
                    flushCurrent()
                    if sentence.count <= currentLimit {
                        current = sentence
                    } else {
                        chunks.append(
                            contentsOf: wordChunks(sentence, firstLimit: currentLimit, limit: chunkLimit)
                        )
                        current = ""
                        currentLimit = chunkLimit
                    }
                }
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks.filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    /// Rejoin soft-wrapped lines (a hard `\n` at every visual line end, as PDF and
    /// some HTML extractors emit) into flowing paragraphs so the narration doesn't
    /// stop mid-sentence. De-hyphenates words broken across a line and preserves real
    /// paragraph breaks marked by a blank line. Mirrors macOS `MacArticleSpeechText`.
    private static func reflowedForSpeech(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"),
                      let previous = current.dropLast().last, previous.isLetter,
                      let first = line.first, first.isLowercase {
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    private static let sentenceAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "al", "fig", "figs",
        "eq", "eqs", "no", "vol", "pp", "ca", "approx", "cf", "ref", "refs",
        "dept", "inc", "ltd", "jr", "sr", "gen", "col", "sec", "min", "max", "est"
    ]

    private static func sentences(in paragraph: String) -> [String] {
        let characters = Array(paragraph)
        let terminators: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»"]

        var result: [String] = []
        var start = 0
        var index = 0

        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }

            var end = index + 1
            while end < characters.count, closers.contains(characters[end]) {
                end += 1
            }

            let atParagraphEnd = end >= characters.count
            let followedByWhitespace = !atParagraphEnd && characters[end].isWhitespace
            guard atParagraphEnd || followedByWhitespace else {
                index += 1
                continue
            }

            if characters[index] == ".", isNonTerminatingPeriod(characters, at: index) {
                index += 1
                continue
            }

            let sentence = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            start = end
            index = end
        }

        let tail = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [paragraph] : result
    }

    private static func isNonTerminatingPeriod(_ characters: [Character], at index: Int) -> Bool {
        if index > 0, characters[index - 1].isNumber { return true }

        var cursor = index - 1
        var token = ""
        while cursor >= 0, characters[cursor].isLetter {
            token.insert(characters[cursor], at: token.startIndex)
            cursor -= 1
        }
        if token.count == 1 { return true }
        return sentenceAbbreviations.contains(token.lowercased())
    }

    private static func wordChunks(_ text: String, firstLimit: Int, limit chunkLimit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var limit = min(firstLimit, chunkLimit)

        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count <= limit {
                current = candidate
            } else {
                if !current.isEmpty {
                    result.append(current)
                    limit = chunkLimit
                }
                current = String(word)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}

/// One device-wide admission queue for managed TTS requests. Every source may
/// build its own bounded task group, but only this actor decides which requests
/// reach the provider. Opening chunks outrank continuation chunks; within the
/// continuation tier, earlier source chunks go first and equal priorities keep
/// their arrival order.
actor ArticleSpeechRequestScheduler {
    struct Priority: Sendable, Equatable, Comparable {
        private let tier: Int
        private let chunkIndex: Int

        static let opening = Priority(tier: 0, chunkIndex: 0)

        static func continuation(index: Int) -> Priority {
            Priority(tier: 1, chunkIndex: max(index, 0))
        }

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.chunkIndex < rhs.chunkIndex
        }
    }

    struct Snapshot: Sendable, Equatable {
        let activeCount: Int
        let waitingCount: Int
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrentRequests: Int
    private var activeCount = 0
    private var nextSequence: UInt64 = 0
    private var waiters: [Waiter] = []

    init(maxConcurrentRequests: Int) {
        self.maxConcurrentRequests = max(maxConcurrentRequests, 1)
    }

    func acquire(priority: Priority) async throws {
        try Task.checkCancellation()
        if activeCount < maxConcurrentRequests, waiters.isEmpty {
            activeCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(
                    id: id,
                    priority: priority,
                    sequence: nextSequence,
                    continuation: continuation
                )
                nextSequence &+= 1
                waiters.append(waiter)
            }
        } onCancel: {
            Task { await self.cancelWaitingRequest(id: id) }
        }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        guard activeCount > 0 else { return }
        guard let nextIndex = waiters.indices.min(by: { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority != right.priority {
                return left.priority < right.priority
            }
            return left.sequence < right.sequence
        }) else {
            activeCount -= 1
            return
        }

        let waiter = waiters.remove(at: nextIndex)
        // The released slot transfers directly to this waiter, so activeCount
        // remains unchanged.
        waiter.continuation.resume()
    }

    func snapshot() -> Snapshot {
        Snapshot(activeCount: activeCount, waitingCount: waiters.count)
    }

    private func cancelWaitingRequest(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Answers one question for the speech client: does this device have a network
/// path right now, and if not, does one come back in time to be worth waiting
/// for?
///
/// Text-to-speech runs on a phone, where losing the connection is ordinary — a
/// lift, a tunnel, a cell handover. Retrying blindly through an outage spends
/// a paid request budget on nothing and ends in "The network connection was
/// lost"; giving up at the first drop ends a generation over a few seconds of
/// radio. The path itself is what tells those two apart.
///
/// The state is event-driven: `NWPathMonitor` pushes every change. `waitForPath`
/// samples that state rather than parking on a continuation, which keeps the
/// registration race — a path that returns between the check and the wait —
/// from turning into a wait for an update that already happened. The sampling
/// only runs while the system says there is no path at all.
///
/// Deliberately permissive. Until the monitor has reported a path, and for
/// every status other than `.unsatisfied`, the answer is "available": a monitor
/// that is wrong — a captive portal, a VPN mid-handover — must never be the
/// reason a listener cannot generate audio. It can only delay a request the
/// system itself says has nowhere to go.
actor NetworkPathAvailability {
    static let shared = NetworkPathAvailability()

    private static let pollInterval: UInt64 = 250_000_000
    /// The monitor has no verdict the instant it starts. Letting the first
    /// update land costs a fraction of a second, once per launch, and is what
    /// lets a listener with the radio off be told so immediately rather than
    /// after a request timeout.
    private static let settleInterval: UInt64 = 150_000_000

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.foreverlm.speech.network-path")
    private var isStarted = false
    private var hasNoPath = false

    /// Whether a network path exists, waiting up to `timeout` for one to appear
    /// when it does not. The answer is as of the moment it stops waiting, so a
    /// caller can read `false` as "this device is offline".
    func waitForPath(timeout: TimeInterval) async -> Bool {
        if startIfNeeded() {
            try? await Task.sleep(nanoseconds: Self.settleInterval)
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while hasNoPath {
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(nanoseconds: Self.pollInterval)
            } catch {
                // Cancelled: the caller is going away, and its own cancellation
                // handling owns what happens next.
                return !hasNoPath
            }
        }
        return true
    }

    /// Starts the monitor once per process. Returns whether this call is what
    /// started it, so the first caller can let the opening update land.
    private func startIfNeeded() -> Bool {
        guard !isStarted else { return false }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            // Only the verdict crosses the boundary, never the path itself.
            let hasNoPath = path.status == .unsatisfied
            Task { await self?.update(hasNoPath: hasNoPath) }
        }
        monitor.start(queue: queue)
        hasNoPath = monitor.currentPath.status == .unsatisfied
        return true
    }

    private func update(hasNoPath: Bool) {
        self.hasNoPath = hasNoPath
    }
}

// MARK: - Speech bought on the learner's own OpenRouter key

extension CloudArticleTTS {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "CloudArticleTTS")

    /// When OpenRouter's generation record is re-read, in milliseconds from the
    /// first try — the proxy's schedule (`OPENROUTER_GENERATION_LOOKUP_DELAYS_MILLISECONDS`)
    /// less its last two steps, since nothing here waits on the answer.
    static let generationLookupDelaysMilliseconds: [UInt64] = [0, 250, 1_000, 2_500, 5_000, 10_000, 15_000]

    /// The ledger row for speech the learner's own key bought straight from
    /// OpenRouter. The proxy never saw that request, so no server row is coming
    /// and this is the only record of it. The response is raw audio with no
    /// usage block; its `X-Generation-Id` names OpenRouter's own record, which
    /// carries the exact charge, and that record is read on the same key.
    ///
    /// The row is written at once, carrying the generation id, and the charge
    /// is stamped on it when the record becomes readable. A record that never
    /// does inside this call (OpenRouter rate-limits a long book's worth of
    /// lookups, the app quits mid-wait) leaves a row that
    /// `AIUsageTracker.resolveGenerationCosts` finishes on a later pass, so a
    /// call OpenRouter charged for is never left without its cost. Written
    /// only after the lookup, the row was lost with the app and, on a failed
    /// lookup, stored with nothing to find the charge by.
    ///
    /// Runs as an unstructured task so the audio is not held back, and so it
    /// inherits the caller's attribution task-locals (task, source, activity)
    /// the way an inline `record` would. The Mac's alone: the phone writes no
    /// usage to CloudKit, and the Mac's ledger is its own (§14.1).
    static func recordOwnKeySpeech(response: HTTPURLResponse, model: String, characters: Int) {
        #if os(macOS)
        let generationID = response.value(forHTTPHeaderField: "X-Generation-Id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        Task {
            var report = AIUsageReport(characterCount: characters)
            report.rawUsageJSON = generationID.flatMap(generationMarker)
            let eventID = UUID().uuidString
            do {
                try await AIUsageTracker.shared.record(
                    provider: "OpenRouter",
                    model: model,
                    operation: "text_to_speech",
                    report: report,
                    eventID: eventID,
                    task: AIUsageAttribution.task ?? "read_aloud",
                    ownKey: true
                )
            } catch {
                logger.error("Own-key speech usage was not recorded: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let generationID {
                await AIUsageTracker.resolveGenerationCost(eventID: eventID, generationID: generationID)
            }
        }
        #endif
    }

    /// What a row stores in `raw_usage_json` until its charge is known: the
    /// generation id the charge is read by.
    static func generationMarker(_ id: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["generation_id": id]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The generation id `generationMarker` stored in a row's usage JSON.
    static func generationID(inRawUsageJSON raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = (object["generation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    /// What OpenRouter charged for one generation, from its generation record,
    /// or nil when the record never became readable. The record is eventually
    /// consistent, so it is re-read on `delays` (the proxy's schedule unless a
    /// sweep passes just `[0]`). A BYOK generation is charged twice —
    /// OpenRouter's fee and the provider's own invoice — and both are counted,
    /// as the proxy does. Lookups share `GenerationLookupGate`, so a book's
    /// hundred chunks do not read the record at once and get rate-limited.
    static func openRouterGenerationCostUSD(
        id: String,
        delays: [UInt64] = generationLookupDelaysMilliseconds
    ) async -> Double? {
        guard var components = URLComponents(string: "https://openrouter.ai/api/v1/generation") else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { return nil }
        var previous: UInt64 = 0
        for delay in delays {
            if delay > previous {
                try? await Task.sleep(nanoseconds: (delay - previous) * 1_000_000)
            }
            previous = delay
            await GenerationLookupGate.shared.acquire()
            let record = await generationRecord(url: url)
            await GenerationLookupGate.shared.release()
            if let record, let cost = generationCostUSD(record) { return cost }
        }
        return nil
    }

    /// One read of a generation record, or nil when it is not readable yet.
    private static func generationRecord(url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Bound for openrouter.ai, so `rewrite` sends it there on the own key.
        ManagedAI.rewrite(&request)
        guard request.url?.host?.lowercased() == openRouterEndpoint.host,
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["data"] as? [String: Any]
    }

    /// The charge in one generation record, or nil when it is incomplete.
    static func generationCostUSD(_ record: [String: Any]) -> Double? {
        guard let total = (record["total_cost"] as? NSNumber)?.doubleValue,
              total.isFinite, total >= 0 else { return nil }
        guard (record["is_byok"] as? Bool) == true else { return total }
        guard let upstream = (record["upstream_inference_cost"] as? NSNumber)?.doubleValue,
              upstream.isFinite, upstream >= 0 else { return nil }
        return total + upstream
    }
}

/// Lets a few generation lookups run at once. A long book's speech arrives as
/// hundreds of chunks, each with a record to read, and OpenRouter answers a
/// flood of reads with 429 — the lookups that lost that race stayed unpriced.
actor GenerationLookupGate {
    static let shared = GenerationLookupGate(limit: 3)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// Hands the slot straight to the next waiter, so the count stays at the limit.
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
