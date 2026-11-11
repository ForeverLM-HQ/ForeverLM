#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation
import OSLog

enum MacArticleTTSClient {
    private static let maxAudioRequestAttempts = 4
    /// Shared with the managed rail so both text-to-speech paths wait for
    /// connectivity rather than failing the instant a link drops. A laptop on a
    /// hotspot loses its connection the same way a phone does, and a request
    /// that dies before reaching a provider has spent a retry on nothing.
    private static let session = CloudArticleTTS.session

    /// `task` names the feature the audio serves ("read_aloud", "voice_preview",
    /// …). The managed rail refuses any request that names no task, so it is a
    /// required argument — a new call site cannot forget it — and it is bound
    /// here rather than at the call sites because every caller generates audio
    /// from a `Task.detached` closure, which does not inherit task locals.
    ///
    /// `model` names the model this request must use. It is normally the
    /// stored selection, and passing nil reads that; text-to-speech passes it
    /// explicitly because a source in a language the selected model cannot
    /// pronounce is routed to one that can, and every chunk, retry, and
    /// continuation of that source has to keep naming the same model.
    static func speech(
        provider: MacArticleSpeechMode,
        text: String,
        speed: Double,
        model: String? = nil,
        voice: String,
        task: String,
        source: AIUsageSource? = nil
    ) async throws -> Data {
        guard let text = MacArticleSpeechText.speakableInput(from: text) else {
            throw MacArticleTTSError.badResponse("Text-to-speech input must include at least one letter or digit.")
        }
        // The selection is checked against OpenRouter's speech list, which
        // this Mac may not have read yet; once read, this returns at once.
        var model = model
        var voice = voice
        if provider == .openRouter {
            await OpenRouterAudioDirectory.prepare(.speech)
            // A stored pick OpenRouter stopped offering is repaired here too,
            // for a caller that read it before the list did; a listening
            // session has already repaired it and told the listener.
            if let repair = MacArticleSpeechSettings.repairStoredSelection() {
                ArticleSpeechDiagnostics.append(
                    "SELECTION_REPAIRED task=\(task) old=\(repair.oldModel) model=\(repair.newModel) voice=\(repair.newVoice)"
                )
                if model == nil || model == repair.oldModel {
                    model = repair.newModel
                    voice = repair.newVoice
                }
            }
        }
        if let configurationError = MacArticleSpeechSettings.configurationError {
            throw MacArticleTTSError.badResponse(configurationError)
        }

        let operation = { [model, voice] in
            switch provider {
            case .openRouter:
                do {
                    return try await openRouter(text: text, voice: voice, model: model)
                } catch let error as MacArticleTTSError {
                    // No other model is tried (one model, one route): the
                    // refusal surfaces as it is, and a test run of the pair
                    // decides whether the next repair skips it.
                    if AIModelQualification.speechFailureVerdict(for: error) != nil {
                        AIModelQualification.recheckSpeechAfterRefusal(
                            model: model ?? MacArticleSpeechSettings.openRouterModel,
                            voice: voice
                        )
                    }
                    throw error
                }
            case .groq, .openAI, .togetherAI, .elevenLabs, .xai, .gemini, .localQwen3:
                // Every model is reached through OpenRouter (product owner,
                // 2026-09-27: "no need for any other routes to models"). A
                // stored older provider only names its failure.
                throw MacArticleTTSError.badResponse(
                    "The selected text-to-speech provider is no longer available. Choose a text-to-speech model in Settings › Voice."
                )
            case .apple:
                throw MacArticleTTSError.badResponse("On-device macOS speech cannot be generated as an audio file by the cloud TTS client.")
            }
        }
        return try await AIUsageAttribution.$task.withValue(task) {
            if let source {
                return try await AIUsageAttribution.withSource(source, operation: operation)
            }
            return try await operation()
        }
    }

    /// The label the ledger records for the audio being generated. Reads the
    /// value `speech` bound so the local ledger row and the proxy's
    /// `X-ForeverLM-Task` header always name the same task.
    private static var billingTask: String {
        AIUsageAttribution.task ?? "read_aloud"
    }

    /// The shared speech catalog, every model of which is an OpenRouter model:
    /// one request shape to OpenRouter's speech endpoint under the model's
    /// slug (product owner, 2026-09-27: "it can just be done via openrouter").
    /// `rewrite` takes it straight to OpenRouter on the learner's own key, or
    /// through the managed proxy. Grok and Gemini went to xAI's and Google's
    /// own APIs until then.
    static func openRouter(text: String, voice: String, model requested: String? = nil) async throws -> Data {
        guard ManagedAI.isSignedIn else {
            throw MacArticleTTSError.missingAPIKey("ForeverLM AI")
        }
        let apiKey = ""

        let model = requested ?? MacArticleSpeechSettings.openRouterModel
        guard let modelOption = ArticleSpeechCatalog.model(id: model),
              !ArticleSpeechCatalog.isRetiredModel(model) else {
            throw MacArticleTTSError.badResponse(MacArticleSpeechSettings.unavailableModelMessage(model))
        }
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every request names its speaker. Without one the provider picks,
        // and can pick a different speaker for each request of one source.
        guard let resolvedVoice = ArticleSpeechCatalog.resolvedVoiceID(trimmedVoice, forModel: model),
              !resolvedVoice.isEmpty else {
            throw MacArticleTTSError.badResponse(
                "\(modelOption.name) lists no voice ForeverLM can send. Choose another text-to-speech model in Settings › Voice."
            )
        }

        let payload: [String: Any] = [
            "model": modelOption.wireModelID,
            "input": text,
            "response_format": modelOption.responseFormat.rawValue,
            "voice": resolvedVoice,
        ]
        return try await postJSONAudio(
            providerName: modelOption.speaksThroughOpenAI ? "OpenAI" : "OpenRouter",
            model: model,
            cacheParts: ["macos", "openrouter", model, resolvedVoice, modelOption.responseFormat.rawValue, text],
            url: modelOption.speechEndpoint,
            headers: ["Authorization": "Bearer \(apiKey)"],
            payload: payload,
            transcodePCM: modelOption.responseFormat == .pcm
        )
    }

    /// Mirrors the `cacheParts` each provider request builds in the functions
    /// above, so cache deletion can recompute the per-request cache key for a
    /// chunk from manifest metadata. Keep in sync with the provider functions —
    /// a drifted key only means a leftover cache file, which
    /// `ArticleSpeechAudioCache.pruneStaleEntries` eventually collects.
    static func requestCacheParts(
        provider: MacArticleSpeechMode,
        model: String,
        voice: String,
        speed: Double,
        text: String
    ) -> [String]? {
        switch provider {
        case .openRouter:
            // The same parts `openRouter(text:voice:model:)` caches under, so a
            // source's request cache is found again from its manifest.
            let availableVoices = MacArticleSpeechSettings.voices(for: .openRouter, model: model)
            let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedVoice = availableVoices.isEmpty
                ? ""
                : (availableVoices.contains(trimmedVoice) ? trimmedVoice : availableVoices[0])
            let responseFormat = ArticleSpeechCatalog.model(id: model)?.responseFormat.rawValue ?? "mp3"
            return ["macos", "openrouter", model, resolvedVoice, responseFormat, text]
        case .groq:
            let availableVoices = MacArticleSpeechSettings.voices(for: .groq, model: model)
            let resolvedVoice = availableVoices.contains(voice)
                ? voice
                : (availableVoices.first ?? MacArticleSpeechSettings.defaultGroqVoice)
            let speedValue = min(max(MacArticleSpeechSpeed.clamped(speed), 0.5), 5.0)
            let responseFormat = model.hasPrefix("canopylabs/orpheus") ? "wav" : "mp3"
            return ["macos", "groq", model, resolvedVoice, responseFormat, String(format: "%.3f", speedValue), text]
        case .openAI:
            let availableVoices = MacArticleSpeechSettings.openAIVoices(for: model)
            let resolvedVoice = availableVoices.contains(voice) ? voice : MacArticleSpeechSettings.defaultOpenAIVoice
            let instructions = UserDefaults.standard.string(forKey: MacArticleSpeechSettings.openAIInstructionsDefaultsKey)
                ?? "Read in a calm, natural audiobook style with gentle pacing, clear pronunciation, and low intensity suitable for bedtime listening."
            let speedValue = MacArticleSpeechSpeed.clamped(speed)
            return [
                "macos",
                "openai",
                model,
                resolvedVoice,
                String(format: "%.3f", speedValue),
                model.contains("gpt-4o-mini-tts") ? instructions : "",
                text
            ]
        case .togetherAI:
            let availableVoices = MacArticleSpeechSettings.voices(for: .togetherAI, model: model)
            let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedVoice = availableVoices.contains(trimmedVoice)
                ? trimmedVoice
                : (availableVoices.first ?? MacArticleSpeechSettings.defaultTogetherAIVoice)
            return ["macos", "together", model, resolvedVoice, "mp3", text]
        case .elevenLabs:
            let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            let voiceID = trimmedVoice.isEmpty ? MacArticleSpeechSettings.defaultElevenLabsVoice : trimmedVoice
            return ["macos", "elevenlabs", model, voiceID, text]
        case .xai:
            let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let builtInVoices = MacArticleSpeechSettings.voices(for: .xai, model: model)
            let resolvedVoice = builtInVoices.contains(trimmedVoice)
                ? trimmedVoice
                : (trimmedVoice.isEmpty ? MacArticleSpeechSettings.defaultXAIVoice : trimmedVoice)
            let speedValue = min(max(MacArticleSpeechSpeed.clamped(speed), 0.7), 1.5)
            return ["macos", "xai", model, resolvedVoice, String(format: "%.3f", speedValue), text]
        case .gemini:
            let resolvedVoice = MacArticleSpeechSettings.geminiVoices.contains(voice)
                ? voice
                : MacArticleSpeechSettings.defaultGeminiVoice
            return ["macos", "gemini", model, resolvedVoice, text]
        case .localQwen3:
            let baseURL = MacArticleSpeechSettings.localQwen3ServerURL
            let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedVoice = trimmedVoice.isEmpty ? MacArticleSpeechSettings.defaultLocalQwen3Voice : trimmedVoice
            let speedValue = min(max(MacArticleSpeechSpeed.clamped(speed), 0.25), 4.0)
            let instructions = UserDefaults.standard.string(forKey: MacArticleSpeechSettings.localQwen3InstructionsDefaultsKey)
                ?? "Read in a calm, natural audiobook style with gentle pacing, clear pronunciation, and low intensity suitable for bedtime listening."
            let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "macos",
                "local_qwen3",
                baseURL,
                model,
                resolvedVoice,
                String(format: "%.3f", speedValue),
                trimmedInstructions,
                text
            ]
        case .apple:
            return nil
        }
    }

    private static func postJSONAudio(
        providerName: String,
        model: String,
        cacheParts: [String],
        url: URL,
        headers: [String: String],
        payload: [String: Any],
        timeoutInterval: TimeInterval = 240,
        transcodePCM: Bool = false
    ) async throws -> Data {
        let cacheKey = ArticleSpeechAudioCache.key(parts: cacheParts)
        if let cached = ArticleSpeechAudioCache.data(for: cacheKey) {
            let spokenText = (payload["input"] ?? payload["text"]) as? String ?? ""
            if audioValidationFailure(data: cached, text: spokenText) == nil {
                return cached
            }
            // Never let a malformed provider response become permanent merely
            // because an older build cached it before duration validation.
            ArticleSpeechAudioCache.removeData(for: cacheKey)
        }

        let request = try audioRequest(
            url: url,
            headers: headers,
            payload: payload,
            timeoutInterval: timeoutInterval
        )

        try await requireNetworkPath(for: url)

        // A provider that answered and one that was never reached are
        // different failures with different budgets.
        var attempt = 1
        var networkAttempt = 0
        let startedAt = Date()

        while true {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.foreverLMData(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw MacArticleTTSError.badResponse("\(providerName) did not return an HTTP response.")
                }
                guard (200..<300).contains(http.statusCode) else {
                    let reason = providerErrorReason(from: data)
                    if isProviderRejection(statusCode: http.statusCode, reason: reason) {
                        throw MacArticleTTSError.providerRejected(
                            provider: providerName,
                            statusCode: http.statusCode,
                            reason: reason
                        )
                    }
                    if attempt < maxAudioRequestAttempts, isRetryableStatusCode(http.statusCode) {
                        try await sleepBeforeRetry(attempt: attempt, response: http)
                        attempt += 1
                        continue
                    }
                    if isModelRefusal(statusCode: http.statusCode) {
                        throw MacArticleTTSError.modelRefused(
                            model: model,
                            statusCode: http.statusCode,
                            reason: reason
                        )
                    }
                    throw MacArticleTTSError.badResponse(
                        "\(providerName) TTS failed (\(http.statusCode)): \(reason)"
                    )
                }

                // TTS responses are raw audio with no usage payload; the billable
                // quantity is the input character count from the request body.
                // Record every successful upstream response, including one we
                // reject below: the provider still billed that attempt.
                let spokenText = (payload["input"] ?? payload["text"]) as? String ?? ""
                if http.url?.host?.lowercased() == ManagedAI.OwnKeyRouter.openRouter.host {
                    // Bought on the learner's own key, straight from OpenRouter:
                    // the row carries the charge from OpenRouter's own record
                    // rather than a character-count estimate.
                    CloudArticleTTS.recordOwnKeySpeech(response: http, model: model, characters: spokenText.count)
                } else {
                    try await AIUsageTracker.shared.record(
                        provider: providerName,
                        model: model,
                        operation: "text_to_speech",
                        report: AIUsageReport(characterCount: spokenText.count),
                        task: billingTask
                    )
                }

                let playableData = transcodePCM
                    ? try ArticleSpeechPCMTranscode.m4aData(fromPCM: data)
                    : data
                if let failure = audioValidationFailure(data: playableData, text: spokenText) {
                    ArticleSpeechDiagnostics.append(
                        "MALFORMED_AUDIO provider=\(providerName) model=\(model) attempt=\(attempt) \(failure)"
                    )
                    if attempt < maxAudioRequestAttempts {
                        try await sleepBeforeRetry(attempt: attempt, response: http)
                        attempt += 1
                        continue
                    }
                    throw MacArticleTTSError.unplayableAudio(
                        model: model,
                        message: "\(providerName) returned incomplete or corrupted speech after \(attempt) attempts. \(failure)"
                    )
                }

                // Persist only after semantic-length validation. A stopped
                // preview or text-to-speech request still keeps valid generated
                // audio because cancellation is checked after this write.
                ArticleSpeechAudioCache.save(playableData, for: cacheKey)
                try Task.checkCancellation()
                return playableData
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isRetryableNetworkError(error) else { throw error }
                networkAttempt += 1
                try await retryAfterTransportFailure(
                    error,
                    url: url,
                    attempt: networkAttempt,
                    startedAt: startedAt
                )
            }
        }
    }

    private static func audioValidationFailure(data: Data, text: String) -> String? {
        do {
            let player = try AVAudioPlayer(data: data)
            return ArticleSpeechAudioValidation.failureReason(text: text, duration: player.duration)
        } catch {
            return "The returned audio could not be decoded."
        }
    }

    private static func audioRequest(
        url: URL,
        headers: [String: String],
        payload: [String: Any],
        timeoutInterval: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        ManagedAI.rewrite(&request)
        return request
    }

    /// Refuses to dispatch when the system says this device has nowhere to
    /// send the request. Text-to-speech spends money one request at a time, and a
    /// listener with the Wi-Fi off should learn that in seconds rather than
    /// after a chunk's worth of timeouts.
    private static func requireNetworkPath(for url: URL) async throws {
        guard needsNetworkPath(url) else { return }
        let hasPath = await NetworkPathAvailability.shared.waitForPath(
            timeout: CloudArticleTTS.dispatchNetworkWait
        )
        guard hasPath else { throw MacArticleTTSError.networkUnavailable }
    }

    /// Waits out a transport failure, or ends the request when the network has
    /// been gone long enough that "offline" is the honest answer. Shares its
    /// policy with the managed rail so both text-to-speech paths are equally
    /// patient with the same conditions.
    private static func retryAfterTransportFailure(
        _ error: Error,
        url: URL,
        attempt: Int,
        startedAt: Date
    ) async throws {
        let needsNetwork = needsNetworkPath(url)
        guard CloudArticleTTS.shouldRetryTransport(
            attempt: attempt,
            elapsed: Date().timeIntervalSince(startedAt)
        ) else {
            throw needsNetwork && CloudArticleTTS.isOfflineError(error)
                ? MacArticleTTSError.networkUnavailable
                : error
        }
        try await sleepBeforeRetry(attempt: attempt, response: nil)
        guard needsNetwork else { return }
        // Retrying into an outage only spends the budget faster; waiting for
        // the link to come back is what makes the next attempt the one that
        // succeeds.
        let recovered = await NetworkPathAvailability.shared.waitForPath(
            timeout: CloudArticleTTS.recoveryNetworkWait
        )
        guard recovered else { throw MacArticleTTSError.networkUnavailable }
    }

    /// A voice server on this machine needs no network path: with every
    /// interface down, loopback still answers while `NWPathMonitor` still
    /// reports `.unsatisfied`. Gating a local server on the internet would
    /// break the one provider that does not need it.
    static func needsNetworkPath(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return !(host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
            || host.hasSuffix(".local"))
    }

    /// A status that refuses what the request names rather than the moment
    /// or the account: the model (404 or 410 once OpenRouter stops serving
    /// it), or its voice or response format (400, 422). Every chunk of a
    /// generation names the same three, so none of them can succeed. The
    /// iPhone's client reads the same list.
    static func isModelRefusal(statusCode: Int) -> Bool {
        AIModelQualification.isSpeechModelRefusal(statusCode: statusCode)
    }

    private static func isRetryableStatusCode(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 409
            || statusCode == 425
            || statusCode == 429
            || (500..<600).contains(statusCode)
    }

    /// True when the provider's refusal cannot be fixed by retrying: bad or
    /// revoked API key (401/403), billing problems (402), a 429 that is a
    /// quota/credit exhaustion rather than a transient rate limit (OpenAI
    /// `insufficient_quota`, ElevenLabs `quota_exceeded`, Groq/Together
    /// credit-balance errors, …), or the managed proxy refusing to serve audio
    /// it could not price.
    private static func isProviderRejection(statusCode: Int, reason: String) -> Bool {
        switch statusCode {
        case 401, 402, 403:
            return true
        case 502:
            // The proxy withholds speech it cannot meter. Retrying regenerates
            // the audio upstream — which we pay for — and cannot change the
            // outcome, since the metering gap is server-side. Matched on the
            // message rather than the error code, because providerErrorReason
            // only ever surfaces `error.message`.
            let lowered = reason.lowercased()
            return lowered.contains("could not price") || lowered.contains("could not record")
        case 429:
            let lowered = reason.lowercased()
            return lowered.contains("insufficient_quota")
                || lowered.contains("insufficient quota")
                || lowered.contains("quota_exceeded")
                || lowered.contains("exceeded your current quota")
                || lowered.contains("credit")
                || lowered.contains("billing")
                || lowered.contains("balance")
                || lowered.contains("payment")
        default:
            return false
        }
    }

    /// Extracts the human-readable message from a provider error body.
    /// Handles the common shapes — `{"error": {"message": …}}` (OpenAI, Groq,
    /// Together, xAI), `{"detail": {"message": …}}` (ElevenLabs), plain
    /// `{"message"/"detail"/"error": "…"}` (local servers) — and
    /// falls back to the raw body, truncated so a huge HTML page cannot flood
    /// an alert.
    private static func providerErrorReason(from data: Data) -> String {
        func truncated(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 400 else { return trimmed }
            return trimmed.prefix(400) + "…"
        }

        guard !data.isEmpty else { return "No response body." }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "detail"] {
                if let nested = object[key] as? [String: Any],
                   let message = nested["message"] as? String, !message.isEmpty {
                    return truncated(message)
                }
                if let message = object[key] as? String, !message.isEmpty {
                    return truncated(message)
                }
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return truncated(message)
            }
        }
        return truncated(String(data: data, encoding: .utf8) ?? "No response body.")
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func sleepBeforeRetry(attempt: Int, response: HTTPURLResponse?) async throws {
        let retryAfterSeconds = response
            .flatMap { $0.value(forHTTPHeaderField: "Retry-After") }
            .flatMap(retryAfterDelay)
        let exponentialDelay = min(pow(2.0, Double(attempt - 1)), 8.0)
        let jitter = Double.random(in: 0.15...0.6)
        let delay = retryAfterSeconds ?? (exponentialDelay + jitter)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private static func retryAfterDelay(from value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed) {
            return min(max(seconds, 0.25), 30)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return min(max(date.timeIntervalSinceNow, 0.25), 30)
    }
}

enum ArticleSpeechAudioCache {
    static let statusDidChangeNotification = Notification.Name("ArticleSpeechAudioCacheStatusDidChange")

    static func key(parts: [String]) -> String {
        let rawKey = parts.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func data(for key: String) -> Data? {
        let url = cacheDirectory().appendingPathComponent("\(key).mp3")
        return try? Data(contentsOf: url)
    }

    static func hasData(for key: String) -> Bool {
        let url = cacheDirectory().appendingPathComponent("\(key).mp3")
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func save(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        let directory = cacheDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(key).mp3"), options: .atomic)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ArticleSpeechAudioCache")
                .error("Could not save cached TTS audio: \(error.localizedDescription)")
        }
    }

    static func removeData(for key: String) {
        let url = cacheDirectory().appendingPathComponent("\(key).mp3")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func hasCachedAudio(sourceID: String) -> Bool {
        if hasCachedMarker(sourceID: sourceID) {
            return true
        }
        return SyncedArticleAudioStore.loadCompleteManifest(sourceID: sourceID) != nil
    }

    /// Marker-only check: one file stat, no manifest decode or per-chunk probing. Under generation 2 the
    /// working folder's manifest is the marker: it is there when this Mac made the narration and when it laid
    /// down one another device made (`MacNarrationLibrary`), so a stale marker from the iCloud Drive days
    /// claims nothing.
    static func hasCachedMarker(sourceID: String) -> Bool {
        FileManager.default.fileExists(atPath: markerPath(for: sourceID))
    }

    /// When the source's narration was marked made, or nil when it has no
    /// marker. One file stat, like `hasCachedMarker`: a notebook's Studio asks
    /// it of every source it holds, off the main actor.
    static func cachedMarkerDate(sourceID: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: markerPath(for: sourceID))
        return attributes?[.modificationDate] as? Date
    }

    private static func markerPath(for sourceID: String) -> String {
        if SyncedArticleAudioStore.workingFolder != nil { return SyncedArticleAudioStore.manifestURL(sourceID: sourceID).path }
        return markerURL(for: sourceID).path
    }

    /// Tells the surfaces that read a source's cached-audio state to read it again.
    static func announceStatusChange(sourceID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: statusDidChangeNotification, object: sourceID)
        }
    }

    static func hasCachedAudio(for article: StudioArticle) -> Bool {
        hasCachedAudio(sourceID: article.id)
    }

    /// Removes the iCloud-synced text-to-speech export, the local cache marker, and —
    /// when the manifest recorded chunk texts — the matching per-request TTS
    /// cache entries, so deleting cached audio actually removes it from disk
    /// instead of leaving replayable copies keyed by text hash.
    ///
    /// `forgettingReplicaNarration` is the learner's own removal: under generation 2 the narration is the
    /// account's, so its pointer goes with the folder. A generation cancelled half way passes false: it only
    /// clears what it made here, and the pointer of an earlier narration stays, so the next pass lays that
    /// one down again instead of the learner losing it.
    static func deleteCachedAudio(sourceID: String, forgettingReplicaNarration: Bool = true) {
        deleteRequestCacheEntries(sourceID: sourceID)
        let fileManager = FileManager.default
        // Set apart before the folder goes (`removed` marks the source), so no pass lays it down again.
        if forgettingReplicaNarration { SyncedArticleAudioStore.workingFolder?.removed?(sourceID) }
        let syncedDirectory = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
        if fileManager.fileExists(atPath: syncedDirectory.path) {
            try? fileManager.removeItem(at: syncedDirectory)
        }
        let marker = markerURL(for: sourceID)
        if fileManager.fileExists(atPath: marker.path) {
            try? fileManager.removeItem(at: marker)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: statusDidChangeNotification, object: sourceID)
        }
    }

    private static func deleteRequestCacheEntries(sourceID: String) {
        guard let manifest = SyncedArticleAudioStore.loadManifestIgnoringChunks(sourceID: sourceID),
              let provider = MacArticleSpeechMode(rawValue: manifest.provider) else { return }
        let fileManager = FileManager.default
        for chunk in manifest.chunks {
            guard let text = chunk.text,
                  let parts = MacArticleTTSClient.requestCacheParts(
                      provider: provider,
                      model: manifest.model,
                      voice: manifest.voice,
                      speed: MacArticleSpeechSpeed.defaultSpeed,
                      text: text
                  ) else { continue }
            let url = cacheDirectory().appendingPathComponent("\(key(parts: parts)).mp3")
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Deletes per-request cache files untouched for 60 days. The synced audio
    /// store is the durable cache — these files exist only to avoid re-billing a
    /// TTS request — so old entries are safe to drop, and without eviction the
    /// directory grows forever. Blocking file I/O — never call on the main actor.
    static func pruneStaleEntries(olderThan interval: TimeInterval = 60 * MemoryTutorScheduler.secondsPerDay) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectory(),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for url in entries where url.pathExtension == "mp3" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    static func markCached(articleID: String) {
        let marker = markerURL(for: articleID)
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data().write(to: marker, options: .atomic)
            }
            // Callers run off the main actor; observers (ArticleRow) update SwiftUI
            // state, so deliver the notification on the main queue.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: statusDidChangeNotification, object: articleID)
            }
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ArticleSpeechAudioCache")
                .error("Could not write article cache marker: \(error.localizedDescription)")
        }
    }

    /// Shared between the production and Dev profiles. Entries are named by a
    /// hash of the request that produced them, so the same narration is the same
    /// file whichever app generated it, and generating it twice is pure waste.
    /// Nothing here is authoritative: every entry can be re-billed and rewritten,
    /// which is what makes it safe for two running apps to share.
    private static func cacheDirectory() -> URL {
        return ForeverLMRuntimeIdentity.sharedTTSAudioCacheURL
    }

    /// Per-profile, and it has to stay that way. A marker asserts that *this*
    /// library's article has a finished export in `SyncedArticleAudioStore`, and
    /// the two profiles have separate iCloud document roots by design. Sharing
    /// markers would make Dev report cached audio for an export only production
    /// holds — a false `hasCachedAudio` that suppresses generation and leaves
    /// playback with nothing to play.
    static func markerDirectory() -> URL {
        SharedDerivedCacheAdoption.profileTTSAudioCacheURL
            .appendingPathComponent("ArticleMarkers", isDirectory: true)
    }

    private static func markerURL(for articleID: String) -> URL {
        let digest = SHA256.hash(data: Data(articleID.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return markerDirectory()
            .appendingPathComponent(fileName)
            .appendingPathExtension("cached")
    }
}

enum MacArticleTTSError: LocalizedError {
    case missingAPIKey(String)
    case badResponse(String)
    /// The provider refused the request for a reason retrying cannot fix:
    /// invalid API key, exhausted credits/quota, or a billing problem.
    case providerRejected(provider: String, statusCode: Int, reason: String)
    /// OpenRouter refused the model, its voice or its response format
    /// (`MacArticleTTSClient.isModelRefusal`): a failure of the selection,
    /// which retrying cannot fix and another model can.
    case modelRefused(model: String, statusCode: Int, reason: String)
    /// The model answered, every attempt, with audio that does not play.
    case unplayableAudio(model: String, message: String)
    /// Retries never got the request out. Distinct from every other case
    /// because nothing about the request, the provider, or the settings is
    /// wrong — the device has no network.
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Sign in with Apple to use \(provider) text-to-speech."
        case .badResponse(let message):
            return message
        case .providerRejected(let provider, let statusCode, let reason):
            return "\(provider) rejected the text-to-speech request (HTTP \(statusCode)): \(reason) "
                + "Check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
        case .modelRefused(let model, let statusCode, let reason):
            let name = ArticleSpeechCatalog.model(id: model)?.name ?? model
            return "OpenRouter refused \(name) (HTTP \(statusCode)): \(reason)"
        case .unplayableAudio(_, let message):
            return message
        case .networkUnavailable:
            return "Text to speech needs a network connection. Try again once you're back online."
        }
    }

    /// True when the whole text-to-speech generation should stop instead of
    /// retrying the remaining chunks — every further request would fail the
    /// same way (missing key, exhausted credits, a refused model, no network).
    var abortsGeneration: Bool {
        switch self {
        case .missingAPIKey, .providerRejected, .modelRefused, .networkUnavailable:
            return true
        case .badResponse, .unplayableAudio:
            return false
        }
    }

    /// True when picking a different voice provider is a plausible fix.
    /// Deliberately narrower than `abortsGeneration`: an outage stops
    /// generation just as firmly, but no provider is reachable without a
    /// network, so offering the switch sends the listener to change a setting
    /// that was never the problem.
    var suggestsProviderSwitch: Bool {
        switch self {
        case .missingAPIKey, .providerRejected, .modelRefused:
            return true
        case .badResponse, .unplayableAudio, .networkUnavailable:
            return false
        }
    }
}

#endif
