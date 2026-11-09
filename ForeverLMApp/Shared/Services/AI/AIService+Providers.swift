import CryptoKit
import Foundation
import os

private let aiProvidersLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "AIProviders")

extension AIService {

    // MARK: - HTTP failure plumbing

    /// Build the typed error for a non-2xx provider response: the provider's own
    /// message when it sent one (with the status appended so logs and legacy
    /// string checks keep working), the status code for classification, and the
    /// Retry-After hint for backoff.
    /// `status` overrides the response's own, for a failure reported inside a
    /// 200 (`inBodyProviderFailure`).
    func httpFailureError(label: String, http: HTTPURLResponse, data: Data, status: Int? = nil) -> AIError {
        let status = status ?? http.statusCode
        let statusSuffix = "(\(status))"
        let baseMessage = extractAPIErrorMessage(from: data) ?? "\(label) \(statusSuffix)."
        let labelled = baseMessage.contains(statusSuffix)
            ? baseMessage
            : "\(baseMessage) [\(label) \(statusSuffix)]"
        return AIError.httpError(
            status: status,
            message: labelled,
            retryAfterSeconds: Self.retryAfterSeconds(from: http)
                ?? (status == 429 ? Self.rateLimitResetSeconds(from: http, body: data) : nil)
        )
    }

    /// A provider failure OpenRouter reports inside a `200 OK`, or nil when the
    /// body reports none. Its errors page: when a provider sends headers and
    /// then fails, a non-streaming body holds only an `error` object and no
    /// `choices`; when a generation fails partway, its choice ends with
    /// `finish_reason: "error"` and carries the `error`. Either way
    /// `error.code` is the status the failure would have had, so it becomes
    /// that HTTP failure, classified, retried and worded like one. Read as a
    /// missing completion instead, it was the final "Invalid AI response"
    /// that parked a paper's cleanup on free Nemotron (2026-09-27).
    func inBodyProviderFailure(label: String, http: HTTPURLResponse?, json: [String: Any]?) -> AIError? {
        guard let http, let json else { return nil }
        let reported: [String: Any]
        if let error = json["error"] as? [String: Any] {
            reported = error
        } else if let choices = json["choices"] as? [[String: Any]],
                  let failed = choices.first(where: {
                      ($0["finish_reason"] as? String)?.lowercased() == "error" || $0["error"] is [String: Any]
                  }) {
            reported = failed["error"] as? [String: Any] ?? [:]
        } else {
            return nil
        }
        // 502 is OpenRouter's own status for a provider that failed or gave
        // an invalid answer, which is all an error without a code says.
        let status = jsonInt(reported["code"]).flatMap { (400...599).contains($0) ? $0 : nil } ?? 502
        let body = (try? JSONSerialization.data(withJSONObject: ["error": reported])) ?? Data()
        return httpFailureError(label: label, http: http, data: body, status: status)
    }

    /// The completion text of a non-streaming chat response. Throws
    /// `emptyAnswer` for a response that has none: no choices, or a message
    /// without text, which is OpenRouter's "no content generated" (a host
    /// warming up or scaling). A JSON-mode request cannot be answered with
    /// empty text either. Anything that is not a JSON object is unreadable.
    static func completionText(in json: [String: Any]?, model: String, jsonMode: Bool) throws -> String {
        guard let json else { throw AIError.invalidResponse }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.emptyAnswer(model: model)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonMode, trimmed.isEmpty { throw AIError.emptyAnswer(model: model) }
        return trimmed
    }

    /// When a rate limit without Retry-After refills, from OpenRouter's
    /// `X-RateLimit-Reset`: on the response, or inside the error body's
    /// `metadata.headers`, which is where OpenRouter reports the daily
    /// free-model quota. The value is epoch milliseconds; epoch seconds and a
    /// plain delta are accepted too. Nil when there is none or it has passed.
    static func rateLimitResetSeconds(from http: HTTPURLResponse, body: Data, now: Date = Date()) -> Double? {
        var raw = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
        if raw == nil,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let metadata = error["metadata"] as? [String: Any],
           let headers = metadata["headers"] as? [String: Any] {
            let value = headers.first { $0.key.caseInsensitiveCompare("X-RateLimit-Reset") == .orderedSame }?.value
            raw = (value as? String) ?? (value as? NSNumber)?.stringValue
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text), value > 0 else { return nil }
        let seconds: Double
        if value > 1e12 {
            seconds = value / 1000 - now.timeIntervalSince1970
        } else if value > 1e9 {
            seconds = value - now.timeIntervalSince1970
        } else {
            seconds = value
        }
        return seconds > 0 ? seconds : nil
    }

    /// Parse a Retry-After header: either delta-seconds or an HTTP-date.
    static func retryAfterSeconds(from http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
        if let seconds = Double(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    // MARK: - OpenAI model rules

    static func openAIModelRequiresDefaultTemperature(_ model: String) -> Bool {
        // Accepts a bare ID or an OpenRouter slug ("openai/gpt-5.6-sol"); the
        // generation test strips the vendor segment itself.
        AIModelDefaults.isOpenAIReasoningModel(model)
    }

    /// The `reasoning.effort` value that turns thinking as far down as a model
    /// allows. Most reasoning models accept `none`. The first GPT-5 generation
    /// (`gpt-5`, `gpt-5-mini`, `gpt-5-nano`) does not: OpenRouter answers
    /// `Reasoning is mandatory for this endpoint and cannot be disabled` with a
    /// 400, and the ad-cleanup queue sat on exactly that error. `minimal` is
    /// the floor those models accept, and it still removes the ten-thousand-plus
    /// reasoning tokens each transcript chunk was spending by default. GPT-6
    /// rejects both `none` and `minimal` (its documented range starts at
    /// `low`), so `low` is its floor.
    static func lowestReasoningEffort(model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = normalized.split(separator: "/").last.map(String.init) ?? normalized
        if MandatoryReasoningModels.contains(normalized) { return reasoningFloor(model: normalized) }
        if (AIModelDefaults.openAIGeneration(of: bare) ?? 0) >= 6 { return "low" }
        let mandatoryReasoning = bare == "gpt-5"
            || (bare.hasPrefix("gpt-5-") && !bare.hasPrefix("gpt-5-chat"))
        return mandatoryReasoning ? "minimal" : "none"
    }

    /// The least thinking a model whose thinking cannot be turned off accepts:
    /// the lowest level OpenRouter's catalog lists for it (Gemini 3.8 Flash
    /// takes `minimal`), else `low`, which every reasoning model accepts. A
    /// request the learner waits on pays for every level above the floor
    /// (2026-10-13: `low` in place of `minimal` doubled Gemini 3.8 Flash's
    /// wait for a canvas edit).
    static func reasoningFloor(model: String) -> String {
        let order = AIEffort.allCases
        let listed = AIRequestOptionSupport.supportedEfforts(provider: .openRouter, model: model)
            .filter { $0 != .noReasoning }
        return listed.min { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }?.rawValue ?? "low"
    }

    /// Whether a 400 is OpenRouter refusing a reasoning opt-out. Other makers
    /// have models whose thinking cannot be switched off (GLM 5.3 Flash, the
    /// default background model, is one), and no model list can keep up with
    /// them, so the refusal itself is the signal.
    static func isMandatoryReasoningRefusal(status: Int, body: Data) -> Bool {
        guard status == 400 else { return false }
        let text = String(decoding: body, as: UTF8.self).lowercased()
        return text.contains("reasoning is mandatory")
            || (text.contains("reasoning") && text.contains("cannot be disabled"))
    }

    /// Models OpenRouter refused a reasoning opt-out for in this run. Once one
    /// has refused, its later requests ask for `low` from the start instead of
    /// paying for a failing round trip each time.
    enum MandatoryReasoningModels {
        private static let lock = NSLock()
        private static var slugs: Set<String> = []

        static func contains(_ slug: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return slugs.contains(normalized(slug))
        }

        static func insert(_ slug: String) {
            lock.lock(); defer { lock.unlock() }
            slugs.insert(normalized(slug))
        }

        private static func normalized(_ slug: String) -> String {
            slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    func extractAPIErrorMessage(from data: Data) -> String? {
        if let serviceError = ManagedAI.serviceError(from: data) {
            ManagedAI.surfaceIfNeeded(serviceError)
            if let message = AIProviderErrorText.sanitized(serviceError.message) {
                return Self.translatingDataPolicyRefusal(message)
            }
        }

        // Filtered, because this text goes straight to the user and a failing
        // provider is as likely to hand back our own request as an explanation
        // of what went wrong.
        return AIProviderErrorText.fromResponseBody(data).map(Self.translatingDataPolicyRefusal)
    }

    /// OpenRouter's "no endpoints found matching your data policy" names a
    /// policy the learner set in Settings without saying so. Translated only
    /// while the switch is on: off, the refusal is the provider's own and is
    /// shown as such. The account-level "paid model training violation" is
    /// translated whatever the switch says, since the switch cannot lift it.
    static func translatingDataPolicyRefusal(_ message: String) -> String {
        // A free model OpenRouter runs only inside the apps it lists fails on
        // every request, and its directory row still reads free. Remember it,
        // so the pickers stop offering it, and move the settings on it once.
        if let restricted = AIFreeModelRestrictions.restrictedModel(inRefusal: message) {
            if AIFreeModelRestrictions.record(restricted) {
                AIModelPriceWatch.observeRestriction(restricted)
            }
            return "OpenRouter now offers \(restricted) only inside the apps it lists, not in ForeverLM. "
                + "ForeverLM is moving the work that used it to another free model; try again in a moment."
                + " OpenRouter said: \(message)"
        }
        if AIDataPolicy.isTrainingPolicyRefusal(message) {
            return AIDataPolicy.trainingRefusalExplanation(providerMessage: message)
        }
        guard AIDataPolicy.deniesDataCollection, AIDataPolicy.isDataPolicyRefusal(message) else {
            return message
        }
        return AIDataPolicy.refusalExplanation(providerMessage: message)
    }

    func extractAPIErrorMessage(from json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return extractAPIErrorMessage(from: data)
    }

    /// Listed for the background-work list while it streams, unless it is a
    /// chat the learner is typing in (`AIInFlightCalls`). Its callbacks
    /// cannot leave this call, so it does not run as a task of its own: Stop
    /// cancels its data task instead, once the response has begun.
    func streamSSE(
        request: URLRequest,
        usageProvider: String? = nil,
        usageModel: String? = nil,
        usageOperation: String = "stream_chat",
        firstByteLimit: Duration = AIService.streamFirstByteLimit,
        errorBodyReadLimit: Duration = AIService.errorBodyReadLimit,
        onEvent: ([String: Any]) throws -> String?,
        onDelta: (String) -> Void
    ) async throws {
        let registry = AIInFlightCalls.current
        let step = AIUsageAttribution.task
        let inFlightID = try registry.begin(
            taskLabel: step,
            sourceTitle: AIUsageAttribution.sourceTitle,
            subjectID: AIUsageAttribution.subjectID
        )
        do {
            try await streamSSEListed(
                inFlightID: inFlightID,
                registry: registry,
                request: request,
                usageProvider: usageProvider,
                usageModel: usageModel,
                usageOperation: usageOperation,
                firstByteLimit: firstByteLimit,
                errorBodyReadLimit: errorBodyReadLimit,
                onEvent: onEvent,
                onDelta: onDelta
            )
            registry.end(inFlightID)
        } catch {
            throw registry.end(inFlightID, failure: error, step: step)
        }
    }

    private func streamSSEListed(
        inFlightID: UUID?,
        registry: AIInFlightCalls,
        request: URLRequest,
        usageProvider: String?,
        usageModel: String?,
        usageOperation: String,
        firstByteLimit: Duration,
        errorBodyReadLimit: Duration,
        onEvent: ([String: Any]) throws -> String?,
        onDelta: (String) -> Void
    ) async throws {
        let (bytes, response) = try await bytesWithFirstByteDeadline(for: request, limit: firstByteLimit)
        let dataTask = bytes.task
        registry.attach(inFlightID) { dataTask.cancel() }

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let body = try await readErrorBody(
                bytes,
                dataTask: dataTask,
                limit: errorBodyReadLimit
            )
            let data = Data(body.utf8)
            throw httpFailureError(
                label: "AI provider stream request failed",
                http: http,
                data: data
            )
        }

        var eventAccumulator = AIStreamEventAccumulator()
        var usageReport = AIUsageReport.empty
        do {
            for try await line in bytes.sseLines {
                try Task.checkCancellation()

                if let dataLines = eventAccumulator.consume(line) {
                    let shouldContinue = try processSSEEvent(
                        dataLines: dataLines,
                        usageReport: &usageReport,
                        onEvent: onEvent,
                        onDelta: onDelta
                    )
                    if !shouldContinue { break }
                }
            }

            // A body that stops mid-event is a dropped connection, not a
            // provider talking nonsense. Say that, rather than describing the
            // half-event we were left holding as something unreadable.
            let trailingEventIsWhole = eventAccumulator.payloadIsComplete
            if let dataLines = eventAccumulator.finish() {
                guard trailingEventIsWhole else {
                    aiProvidersLogger.error(
                        "Truncated final AI stream event: \(dataLines.joined(separator: "\n"), privacy: .private)"
                    )
                    throw AIError.apiError(
                        "The connection to the AI provider ended before the response finished; try again."
                    )
                }
                _ = try processSSEEvent(
                    dataLines: dataLines,
                    usageReport: &usageReport,
                    onEvent: onEvent,
                    onDelta: onDelta
                )
            }
        } catch {
            // The provider bills whatever it processed before a stream dies
            // (cancellation, abnormal stop, network drop). Record any usage
            // already observed — Anthropic's message_start carries the input
            // tokens, cumulative deltas carry partial output — before failing.
            if let usageProvider, let usageModel, usageReport.hasBillableUsage {
                try await recordUsage(
                    provider: usageProvider,
                    model: usageModel,
                    operation: usageOperation,
                    fallbackReport: usageReport
                )
            }
            throw error
        }

        if let usageProvider, let usageModel {
            try await recordUsage(
                provider: usageProvider,
                model: usageModel,
                operation: usageOperation,
                fallbackReport: usageReport
            )
        }
    }

    /// How long a stream may take to send its first byte. On 2026-11-08
    /// OpenRouter answered a chat with a 408 after 29 s and then held the body
    /// open; the chat read "Thinking" for eleven minutes until Stop. URLSession
    /// hands over a response only with its first body byte (headers alone,
    /// 200 or 408, never come back from `bytes(for:)`, nor reach a task
    /// delegate), and the AI session has no idle deadline by design, so a
    /// stream that never starts is invisible without this limit. A healthy
    /// stream is expected to start within seconds (OpenRouter writes comment
    /// lines while the model works; not measured here), so two minutes of
    /// nothing is taken as a dead request. It fails as a timeout, which the
    /// chat retries.
    static let streamFirstByteLimit: Duration = .seconds(120)

    /// How long a failed stream may take to deliver its error message once it
    /// has begun. The status is the failure; the body only words it.
    static let errorBodyReadLimit: Duration = .seconds(5)

    /// `foreverLMBytes`, cancelled when not even the first byte has arrived
    /// within `limit` (`streamFirstByteLimit`). A cancellation that was not
    /// this deadline's — the learner's Stop — is rethrown as it came.
    private func bytesWithFirstByteDeadline(
        for request: URLRequest,
        limit: Duration
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let capture = StreamFirstByteDeadline()
        let deadline = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            capture.expire()
        }
        defer { deadline.cancel() }
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.foreverLMBytes(for: request, delegate: capture)
        } catch {
            guard capture.hasExpired else { throw error }
            throw Self.firstByteTimeout(limit)
        }
        // The deadline may have fired between the first byte and here; the
        // request it cancelled is then as dead as one that never started.
        guard capture.markStarted() else { throw Self.firstByteTimeout(limit) }
        return result
    }

    private static func firstByteTimeout(_ limit: Duration) -> AIError {
        let seconds = Int(limit.components.seconds)
        aiProvidersLogger.error("AI stream sent nothing in \(seconds, privacy: .public) s; cancelled as timed out")
        // "timed out" is what `isTransient` reads, so the chat retries it.
        return AIError.apiError(
            "The AI provider sent nothing back in \(seconds) seconds, so the request timed out. Try again."
        )
    }

    /// The first 4,000 characters of a failed stream's body, or whatever of it
    /// arrived within `limit`. When the limit runs out the request is cancelled
    /// and the partial body returned, so the caller still fails with the
    /// status — which is what lets a 408 or 5xx be retried. A cancellation
    /// that was not this deadline's (the learner's Stop) is rethrown.
    private func readErrorBody(
        _ bytes: URLSession.AsyncBytes,
        dataTask: URLSessionDataTask,
        limit: Duration
    ) async throws -> String {
        let deadline = Task {
            do {
                try await Task.sleep(for: limit)
            } catch {
                return false
            }
            dataTask.cancel()
            return true
        }
        var body = ""
        do {
            for try await line in bytes.sseLines {
                body += line
                if body.count > 4_000 { break }
            }
        } catch {
            deadline.cancel()
            guard await deadline.value else { throw error }
            aiProvidersLogger.notice(
                "AI stream error body unfinished after \(limit, privacy: .public); reporting the status alone"
            )
            return body
        }
        deadline.cancel()
        return body
    }

    func processSSEEvent(
        dataLines: [String],
        usageReport: inout AIUsageReport,
        onEvent: ([String: Any]) throws -> String?,
        onDelta: (String) -> Void
    ) throws -> Bool {
        let dataString = dataLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dataString.isEmpty else { return true }
        guard dataString != "[DONE]" else { return false }

        guard let data = dataString.data(using: .utf8) else {
            throw AIError.apiError("AI provider returned a stream event that was not valid UTF-8.")
        }

        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            if let json = AIStreamDeltaExtractor.jsonObject(fromRawEvent: dataString) {
                return try processSSEJSONEvent(json, usageReport: &usageReport, onEvent: onEvent, onDelta: onDelta)
            }
            if let message = extractAPIErrorMessage(from: data) {
                throw AIError.apiError(message)
            }
            aiProvidersLogger.error("Unreadable AI stream event: \(dataString, privacy: .private)")
            throw AIError.apiError(
                "AI provider returned a stream event ForeverLM could not read (\(streamEventDescription(dataString))). The stream was most likely cut short; try again."
            )
        }

        guard let json = decoded as? [String: Any] else {
            aiProvidersLogger.error("Unexpected AI stream event shape: \(dataString, privacy: .private)")
            throw AIError.apiError(
                "AI provider returned an unexpected stream event (\(streamEventDescription(dataString)))."
            )
        }

        if let message = extractAPIErrorMessage(from: json) {
            throw AIError.apiError(message)
        }

        return try processSSEJSONEvent(json, usageReport: &usageReport, onEvent: onEvent, onDelta: onDelta)
    }

    func processSSEJSONEvent(
        _ json: [String: Any],
        usageReport: inout AIUsageReport,
        onEvent: ([String: Any]) throws -> String?,
        onDelta: (String) -> Void
    ) throws -> Bool {
        usageReport.merge(AIUsageParser.report(from: json))
        if let delta = try onEvent(json), !delta.isEmpty {
            onDelta(delta)
        }
        try AICompletionStopValidator.throwIfStoppedAbnormally(json)

        return true
    }

    /// A description of an unparseable stream event that carries no part of the
    /// event itself. A half-received event is a slice of the request we sent —
    /// system prompt, sources, conversation — and this string goes onto the
    /// user's screen; the event body belongs in the log and nowhere else.
    func streamEventDescription(_ event: String) -> String {
        let bytes = event.utf8.count
        guard let type = Self.streamEventType(in: event) else { return "\(bytes) bytes" }
        return "\(bytes) bytes, type \(type)"
    }

    /// The event's `"type"`, when the fragment we received reached it. Provider
    /// vocabulary ("response.in_progress"), not content — and bounded to a
    /// short identifier so a corrupt or hostile value cannot smuggle payload
    /// text out through it.
    static func streamEventType(in event: String) -> String? {
        guard let key = event.range(of: "\"type\"") else { return nil }
        let afterKey = event[key.upperBound...].drop { $0 == " " || $0 == ":" }
        guard afterKey.first == "\"" else { return nil }
        let value = afterKey.dropFirst().prefix { $0 != "\"" }
        guard !value.isEmpty, value.count <= 60,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
        else { return nil }
        return String(value)
    }

    func jsonNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    func jsonInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let parsed = Int(string) { return parsed }
        return nil
    }

    func recordUsage(
        provider: String,
        model: String,
        operation: String,
        json: [String: Any]? = nil,
        fallbackReport: AIUsageReport? = nil
    ) async throws {
        let reported = json.flatMap { AIUsageParser.report(from: $0) }
        var report = fallbackReport ?? .empty
        report.merge(reported)
        // Record provider-side substitutions under the model that was actually
        // billed, then reject the response. A task may never silently accept an
        // answer from a model other than the one its resolved config selected;
        // a router's pick is the model it was asked for.
        let servedModel = report.servedModelIfDifferent(fromRequested: model)
        let rejectedModel = report.rejectedSubstitution(fromRequested: model)
        if let rejectedModel {
            aiProvidersLogger.error("\(provider, privacy: .public) served \(operation, privacy: .public) with \(rejectedModel, privacy: .public) instead of requested \(model, privacy: .public); recording the billed attempt and rejecting its answer.")
        }
        // A response that carries no usage is a generation that never ran:
        // OpenRouter answers a failed upstream attempt with 200 and an error
        // body or empty choices, and bills nothing for it. Recording it left
        // a row with no quantities and no cost, which the Usage pane rightly
        // counts as spend it cannot account for. The caller's own validation
        // still rejects the response; only the phantom row is skipped.
        let providerReportedUsage = reported != nil
            || (json == nil && fallbackReport?.hasBillableUsage == true)
        if !providerReportedUsage {
            let providerError = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "none"
            aiProvidersLogger.error("\(provider, privacy: .public) returned \(operation, privacy: .public) for \(model, privacy: .public) without usage; nothing billed, no ledger row. Provider error: \(providerError, privacy: .public)")
        }
        // The billable response is not complete until its usage row is durable.
        // The recorder has a schema-forward append path for a newer database;
        // if both normal and compatibility writes fail, surface that failure.
        if providerReportedUsage, let usageTracker {
            try await usageTracker.record(
                provider: provider,
                model: servedModel ?? model,
                operation: operation,
                report: report
            )
        }
        // A safety verdict answers no task. The attempt is recorded above, at
        // its price (free on the router that makes these picks).
        if let classifier = report.routedSafetyClassifier(fromRequested: model) {
            aiProvidersLogger.error("\(provider, privacy: .public) routed \(operation, privacy: .public) for \(model, privacy: .public) to safety classifier \(classifier, privacy: .public); rejecting its answer.")
            throw AIError.safetyClassifierAnswer(model: classifier)
        }
        if let rejectedModel {
            throw AIError.apiError(
                "The AI provider served \(rejectedModel) instead of the selected model \(model). The response was rejected."
            )
        }
    }

    func recordUsage(
        provider: AIProvider,
        model: String,
        operation: String,
        json: [String: Any]? = nil,
        fallbackReport: AIUsageReport? = nil
    ) async throws {
        try await recordUsage(
            provider: provider.shortName,
            model: model,
            operation: operation,
            json: json,
            fallbackReport: fallbackReport
        )
    }
    
    // MARK: - Private: Text transport

    // Text travels on OpenRouter's chat-completions endpoint and nowhere else.
    // The first-party labs are model families on OpenRouter, not transports —
    // the proxy has no route to their own hosts (its first-party media routes
    // answer 410 since 2026-10-02), and `KeychainService.routedTextConfig`
    // hands every text call the OpenRouter provider before it reaches this
    // file.

    /// Chat endpoint for providers that speak the OpenAI-compatible protocol.
    /// A first-party lab has none, so a text call that somehow skipped routing
    /// fails here instead of reaching the lab's own API.
    static func openAICompatibleChatEndpoint(for provider: AIProvider) -> String? {
        switch provider {
        case .openRouter, .groq, .cerebras, .together, .fireworks, .nvidia:
            return "https://openrouter.ai/api/v1/chat/completions"
        case .anthropic, .openai, .gemini, .xai, .meta:
            return nil
        }
    }

    /// Whether this provider's chat traffic reaches OpenRouter.
    ///
    /// Gating on the resolved endpoint rather than on `provider == .openRouter`
    /// matters because the long tail (Groq, Cerebras, …) records its own name
    /// while travelling to openrouter.ai; keying off the enum silently skipped
    /// it and cost the actual-cost reporting below.
    static func routesThroughOpenRouter(_ provider: AIProvider) -> Bool {
        openAICompatibleChatEndpoint(for: provider)?.hasPrefix("https://openrouter.ai/") == true
    }

    /// Model identifier OpenRouter expects: a vendor-qualified slug. Any other
    /// provider's id is passed through as given.
    static func openAICompatibleModelID(
        provider: AIProvider,
        model: String
    ) -> String {
        guard routesThroughOpenRouter(provider) else {
            return model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return OpenRouterModelID.slug(provider: provider, model: model)
    }

    /// Adapt the common OpenAI-compatible payload to OpenRouter.
    static func prepareOpenAICompatiblePayload(
        _ original: [String: Any],
        provider: AIProvider,
        speed: AISpeed? = nil
    ) throws -> [String: Any] {
        var payload = original
        guard routesThroughOpenRouter(provider) else { return payload }
        // GPT-5 models do not expose a temperature parameter on OpenRouter.
        // Keeping an explicit extraction temperature in the payload while the
        // proxy enforces `require_parameters` leaves OpenRouter with no
        // eligible endpoint and returns a 404 before the selected model runs.
        // Apply the model rule before adding routing metadata.
        if let model = payload["model"] as? String {
            let customModelRejectsTemperature = AIModelCatalog
                .customOpenRouterModel(id: model)?
                .supportsTemperature == false
            if openAIModelRequiresDefaultTemperature(model)
                || customModelRejectsTemperature {
                payload.removeValue(forKey: "temperature")
            }
        }
        applyOpenRouterPayloadExtras(&payload, provider: provider, speed: speed)
        return payload
    }

    /// Managed requests are rewritten to the authenticated proxy.
    /// Readies a text route ahead of a request the learner will wait on the
    /// moment they finish asking (speaking to the Canvas): opens this
    /// session's connection to the host the request will go to (the managed
    /// proxy, or OpenRouter on the learner's own key), and reads the model's
    /// region endpoints and speed tiers into their caches, so the request
    /// itself starts warm. The GET carries no credential and nothing reads its
    /// answer; HTTP/2 keeps the connection for the request that follows.
    func warmTextRoute(_ config: AITaskConfig) async {
        let config = KeychainService.routedTextConfig(config)
        guard let endpoint = Self.openAICompatibleChatEndpoint(for: config.provider),
              let url = URL(string: endpoint) else { return }
        var routed = URLRequest(url: url)
        try? Self.prepareOpenAICompatibleRequestForTransport(&routed, provider: config.provider)
        if let host = routed.url, var components = URLComponents(url: host, resolvingAgainstBaseURL: false) {
            components.path = "/health"
            components.query = nil
            if let health = components.url {
                var ping = URLRequest(url: health)
                ping.httpMethod = "GET"
                ping.timeoutInterval = 10
                let task = session.dataTask(with: ping)
                task.priority = URLSessionTask.lowPriority
                task.resume()
            }
        }
        await Self.primeOpenRouterRegion(provider: config.provider, model: config.model)
        if Self.routesThroughOpenRouter(config.provider) {
            _ = try? await OpenRouterEndpointTierCatalog.shared.tiers(for: config.model)
        }
    }

    static func prepareOpenAICompatibleRequestForTransport(
        _ request: inout URLRequest,
        provider: AIProvider
    ) throws {
        ManagedAI.rewrite(&request)
    }

    /// Fast or Flex on the OpenRouter rail names the lab's tier endpoint in
    /// `provider.order`. OpenRouter's base-slug matching never selects a
    /// service tier on its own (docs: "service tier endpoints … require
    /// explicit opt-in"), so a standard request can never land on the premium
    /// endpoint by accident, and `allow_fallbacks: false` — which the Worker
    /// enforces for any request that names an endpoint in `provider.order` —
    /// stops a tier request from quietly running at standard when the tier is
    /// down. Nothing is added when the tier is unknown: the request then goes
    /// out at standard speed and standard price, and the Worker leaves
    /// fallbacks on for it so OpenRouter can move it between the model's
    /// standard endpoints when one refuses.
    static func applyOpenRouterSpeedTier(to payload: inout [String: Any], speed: AISpeed?) {
        guard let speed, speed != .standard,
              let model = payload["model"] as? String,
              let tier = OpenRouterEndpointTierCatalog.cachedTier(slug: model, speed: speed)
        else { return }
        var provider = payload["provider"] as? [String: Any] ?? [:]
        provider["order"] = [tier.tag]
        provider["allow_fallbacks"] = false
        payload["provider"] = provider
    }

    /// The model-sheet slots whose host choice a request serving `label` (an
    /// `AITask` rawValue, or "chat") follows: the chat's, or the Background
    /// model's the task runs on. Each row is kept per model, so it applies to
    /// whichever model the task is running on, that model's backups and a
    /// meeting's paid model included. A quiz answer graded in a chat runs on
    /// the chat's model, so it runs where the chat does.
    static func openRouterHostSlots(forTaskLabel label: String?) -> [String] {
        guard let label else { return [] }
        if label == AITask.chat.rawValue || label == "deep_research_chat" || label == "chat_quiz_grading" {
            return ["chat"]
        }
        // A task that runs on the chat's model (Deep Research outside a chat,
        // Source Discovery) runs where it does.
        if let task = AITask(rawValue: label), task.followsChatRoute { return ["chat"] }
        guard let task = AITask(rawValue: label), AITask.advancedTasks.contains(task) else { return [] }
        return [AIBackupModels.backgroundSlot(multimodal: task.usesMultimodalBackgroundModelDefault)]
    }

    /// The region a request for this model keeps to, for the task being
    /// served (`OpenRouterHostPreference.region(ownSlots:row:)`).
    static func openRouterRegion(forModelSlug slug: String) -> OpenRouterHostPreference.Region? {
        OpenRouterHostPreference.region(ownSlots: openRouterHostSlots(forTaskLabel: AIUsageAttribution.task)) {
            OpenRouterHostPreference.stored(slot: $0, slug: slug)
        }
    }

    /// Reads the region's endpoints for a model kept in one, before its body
    /// is built: the builder is synchronous and takes them from the cache. A
    /// failed read is left to `requireOpenRouterRegion`, which then refuses
    /// the body and says why.
    ///
    /// On the learner's own key it also reads the endpoints of an OpenAI
    /// model before the send, so `pinLabModelToItsOwnEndpoint` knows whether
    /// OpenAI serves it; a cold first send would otherwise go out unpinned
    /// and land on Azure or Bedrock, billed to OpenRouter credits.
    static func primeOpenRouterRegion(provider: AIProvider, model: String) async {
        guard routesThroughOpenRouter(provider) else { return }
        let slug = openAICompatibleModelID(provider: provider, model: model)
        if slug.hasPrefix("openai/"),
           ManagedAI.sendsOwnKeyDirect(toHost: ManagedAI.OwnKeyRouter.openRouter.host) {
            _ = try? await CancellableWait.run {
                try await OpenRouterEndpointTierCatalog.shared.tiers(for: slug)
            }
        }
        guard let region = openRouterRegion(forModelSlug: slug) else { return }
        _ = try? await CancellableWait.run {
            try await OpenRouterRegionalEndpoints.shared.endpoints(for: slug, region: region)
        }
    }

    /// The last check on an OpenRouter body for a model kept in one region:
    /// its `only` must name that region's endpoints and nothing else. Both
    /// chat-body builders call it once the body is final.
    static func requireOpenRouterRegion(_ payload: [String: Any], provider: AIProvider) throws {
        guard routesThroughOpenRouter(provider),
              let model = payload["model"] as? String,
              let region = openRouterRegion(forModelSlug: model)
        else { return }
        try OpenRouterRegionalEndpoints.requireConfined(payload, region: region)
    }

    /// The lab whose own endpoint serves a model, when the learner's provider
    /// key for that lab (OpenRouter → Settings → Integrations) can pay for it:
    /// Anthropic for every Claude model, and OpenAI for a model OpenAI itself
    /// hosts. OpenAI's open-weight models (gpt-oss) are served by other hosts
    /// only, so an OpenAI model is named only once its endpoint list, read
    /// from the cache, shows an OpenAI endpoint. Nil for every other model.
    static func ownKeyLab(forModelSlug slug: String) -> String? {
        if slug.hasPrefix("anthropic/") { return "anthropic" }
        guard slug.hasPrefix("openai/"),
              !slug.contains(":"),
              !slug.hasPrefix("openai/gpt-oss"),
              !slug.hasPrefix("openai/whisper")
        else { return nil }
        // Endpoints already read decide; unread ones are OpenAI's own, since
        // only its open weights (named above) run elsewhere alone. Left
        // unpinned until the endpoints were read, GPT-6 Luna ran on Amazon
        // Bedrock and billed OpenRouter credits (2026-11-09).
        if let tiers = OpenRouterEndpointTierCatalog.cachedTiers(slug: slug) {
            return tiers.contains(where: { $0.tag == "openai" || $0.tag.hasPrefix("openai/") }) ? "openai" : nil
        }
        return "openai"
    }

    /// A Claude or GPT model on the learner's own OpenRouter key runs on its
    /// lab's own endpoint. The throughput sort below otherwise lands on
    /// Bedrock or Vertex (Claude) or Azure or Bedrock (GPT), where the lab's
    /// key does not apply, so the call is billed to OpenRouter credits (Opus
    /// 5.5, 2026-10-24: Bedrock, `is_byok: false`, on every call since the key
    /// was added). Fallbacks stay off: when the key cannot serve the call, it
    /// fails instead of quietly spending credits. A pinned host, a Speed tier
    /// and a region all name their own endpoints and win.
    static func pinLabModelToItsOwnEndpoint(_ payload: inout [String: Any]) {
        guard let model = payload["model"] as? String,
              let lab = ownKeyLab(forModelSlug: model),
              ManagedAI.sendsOwnKeyDirect(toHost: ManagedAI.OwnKeyRouter.openRouter.host),
              openRouterRegion(forModelSlug: model) == nil
        else { return }
        var routing = payload["provider"] as? [String: Any] ?? [:]
        guard routing["order"] == nil, routing["only"] == nil else { return }
        routing["order"] = [lab]
        routing["allow_fallbacks"] = false
        payload["provider"] = routing
    }

    /// `learnerMessageIndex` is the index in `payload["messages"]` of the
    /// learner's own message for this turn, when the caller knows it (a tool
    /// loop does); the per-turn tail is placed in front of it. Without it the
    /// tail goes in front of the newest learner-like message
    /// (`openRouterMessagesWithVolatileContext`).
    static func applyOpenRouterPayloadExtras(
        _ payload: inout [String: Any],
        provider: AIProvider,
        speed: AISpeed? = nil,
        learnerMessageIndex: Int? = nil
    ) {
        guard routesThroughOpenRouter(provider) else { return }

        // Before the volatile tail moves and the cache breakpoints land, so
        // they are placed on the request as it is sent.
        if let messages = payload["messages"] as? [[String: Any]] {
            payload["messages"] = ChatRequestTurnOrder.endingOnAnswerableTurn(messages)
        }

        // On the direct rail the Worker is not there to price the call against
        // OpenRouter's generation record, so ask OpenRouter itself for what it
        // charged: `AIUsageParser` already reads `usage.cost` into
        // `providerReportedCost`, which keeps the local ledger exact instead of
        // list-price estimated. Left off the proxied body deliberately — that
        // rail is priced by the Worker, and its request shape stays as it is.
        if ManagedAI.sendsOwnKeyDirect(toHost: ManagedAI.OwnKeyRouter.openRouter.host) {
            payload["usage"] = ["include": true]
        }

        // The learner's data-policy switch rides on every OpenRouter body as
        // the provider preference OpenRouter honours; the proxy keeps it and
        // adds its own routing invariants beside it. Read at request time so
        // a switch flipped mid-conversation applies to the next message.
        if AIDataPolicy.deniesDataCollection {
            AIDataPolicy.applyDenyDataCollection(to: &payload)
        }
        // A task pinned to one host names it instead of a speed tier; a task
        // set to the cheapest host keeps its tier, which outranks the sort.
        let hostPreference = (payload["model"] as? String).flatMap {
            OpenRouterHostPreference.stored(slots: openRouterHostSlots(forTaskLabel: AIUsageAttribution.task), slug: $0)
        }
        if hostPreference?.mode != .host {
            applyOpenRouterSpeedTier(to: &payload, speed: speed)
        }
        hostPreference?.apply(to: &payload)
        // Speaking to the canvas is waited on with the learner watching: its
        // route is the host quickest to answer, not the one that streams most
        // once it starts (a few lines of edits are all it writes).
        if AIUsageAttribution.task == AITask.canvasVoice.rawValue {
            var routing = payload["provider"] as? [String: Any] ?? [:]
            if routing["sort"] == nil {
                routing["sort"] = OpenRouterRoutePreference.interactiveSort
                payload["provider"] = routing
            }
        }
        if hostPreference?.mode != .cheapest {
            pinLabModelToItsOwnEndpoint(&payload)
        }
        if let model = payload["model"] as? String {
            let cachingTags = OpenRouterEndpointTierCatalog.cachedTiers(slug: model).flatMap {
                OpenRouterSpeedTier.promptCachingEndpointTags(
                    in: $0,
                    requiredParameters: OpenRouterRoutePreference.requiredParameters(of: payload)
                )
            }
            // A model kept to one region's hosts: `requireOpenRouterRegion`
            // refuses the body if these were not known yet.
            let regionTags = openRouterRegion(forModelSlug: model).flatMap {
                OpenRouterRegionalEndpoints.cachedTags(slug: model, region: $0)
            }
            OpenRouterRoutePreference.applyFastestCachingRoute(
                to: &payload,
                cachingEndpointTags: cachingTags,
                regionEndpointTags: regionTags
            )
        }

        guard let model = payload["model"] as? String,
              var messages = payload["messages"] as? [[String: Any]] else { return }

        // OpenRouter's automatic caches need no provider-specific flag, but
        // session_id makes sticky routing active on the first successful call
        // rather than only after OpenRouter observes a cache hit. Derive it
        // from the stable system head and opening user turn: it survives later
        // history/digest churn, but unrelated conversations do not all pin to
        // one upstream endpoint.
        if let sessionID = openRouterPromptCacheSessionID(model: model, messages: messages) {
            payload["session_id"] = sessionID
        }

        // Every model, cached explicitly or automatically, reads a prompt as a
        // byte prefix, so a per-turn tail ahead of the history ends the shared
        // prefix at the tail and the whole conversation after it is rewritten
        // every turn. The tail moves behind the history, in front of the
        // learner's newest message. The session id above is derived first, while
        // the tail is still the second system block.
        let reuseExpected = (payload["tools"] as? [Any])?.isEmpty == false
            || messages.filter { ($0["role"] as? String) != "system" }.count >= 2
        let moved = openRouterMessagesWithVolatileContext(messages, learnerMessageIndex: learnerMessageIndex)
        messages = moved.messages
        payload["messages"] = messages

        // Explicit breakpoints are required only for the families documented
        // by OpenRouter. Automatic-cache models keep their native message
        // shape; models without provider cache support still get harmless
        // sticky routing, ready for support to appear without an app update.
        // A budget-truncated system head is cut at a boundary that moves every
        // turn, so its breakpoints can only ever pay the write premium — see
        // `systemPromptIsCacheable`. Sticky routing above still applies; only the
        // explicit markers are withheld.
        if openRouterModelNeedsExplicitCacheControl(model),
           systemPromptIsCacheable(openAIStyleStableSystemHead(messages)) {
            // A GPT-5.6-and-later write bills 1.25x, so the trailing message is
            // marked only when the request has a later turn or tool round to
            // read it back; a one-shot's document would be paid for twice.
            let markTrailing = reuseExpected || !AIModelDefaults.openAIBillsCacheWrites(model)
            // A breakpoint ahead of the per-turn tail, where the provider
            // takes several (Anthropic, the one family with a ttl): the next
            // turn repeats everything up to it, so the history is read, not
            // rewritten, each time the learner sends a message.
            messages = openAIStyleMessagesMarkingCacheBreakpoints(
                messages,
                systemTTL: openRouterModelSupportsCacheTTL(model) ? "1h" : nil,
                markTrailingMessage: markTrailing,
                historyBreakpointBefore: openRouterModelSupportsCacheTTL(model) ? moved.tailIndex : nil
            )
            payload["messages"] = messages
        }
    }

    /// The stable system head of an OpenAI-format message array — the text a
    /// cache breakpoint would end on. Content pre-split into
    /// `[stable head, volatile tail]` yields the first block; single-block or
    /// plain-string content is itself the head. Returns `""` when there is no
    /// system message, which reads as cacheable: nothing was truncated.
    static func openAIStyleStableSystemHead(_ messages: [[String: Any]]) -> String {
        guard let system = messages.first(where: {
            let role = ($0["role"] as? String)?.lowercased()
            return role == "system" || role == "developer"
        }) else { return "" }
        if let blocks = system["content"] as? [[String: Any]] {
            return blocks.first?["text"] as? String ?? ""
        }
        return system["content"] as? String ?? ""
    }

    /// Moves a split system message's volatile tail out of the system message
    /// and in front of the learner's newest message.
    ///
    /// A prompt is cached as a byte prefix, and the tail (clock, history digest,
    /// notes, retry nudges) changes between turns. Left in the system message it
    /// sits ahead of the whole conversation, so every turn rewrites the history
    /// at the cache-write rate; measured on GPT-5.6 Sol chat, 90% of a prompt was
    /// written and under 5% read once the learner paused for a minute. Behind the
    /// history it stays put across the tool rounds of one turn and costs only the
    /// newest turn on the next. Gemini needs it for a second reason: its
    /// normalized `systemInstruction` is one immutable cache unit, so a changing
    /// second block invalidates the cached paper even when the first block has
    /// the explicit breakpoint (OpenRouter's documented shape is a stable cached
    /// system instruction followed by changing context in a later user message).
    ///
    /// The session id is derived before this transform, while the volatile tail
    /// is still the second system block, so it continues to key off the actual
    /// opening learner message rather than this synthetic context message.
    static func openRouterMessagesWithVolatileContextBeforeLatestTurn(
        _ messages: [[String: Any]]
    ) -> [[String: Any]] {
        openRouterMessagesWithVolatileContext(messages).messages
    }

    /// `openRouterMessagesWithVolatileContextBeforeLatestTurn`, also saying
    /// where the tail went, so the message just ahead of it can carry a cache
    /// breakpoint: that message ends the part of the conversation the next
    /// turn repeats byte for byte (nil when there was no tail to move).
    ///
    /// The tail must stay where the turn began for all of the turn's tool
    /// rounds: everything after it is cached per round, and moving it rewrites
    /// all of that (on 2026-11-07 one Opus call rewrote 147k tokens for $0.74
    /// that way). Two kinds of user-role message arrive mid-turn and are never
    /// the learner's: the follow-up that carries a tool result's pictures
    /// (right after a tool message), and the app's own nudges in a tool loop.
    /// The first is skipped here; the second only the caller can tell apart,
    /// so a tool loop passes `learnerMessageIndex`, honoured when it names a
    /// user message after the system message.
    static func openRouterMessagesWithVolatileContext(
        _ messages: [[String: Any]],
        learnerMessageIndex: Int? = nil
    ) -> (messages: [[String: Any]], tailIndex: Int?) {
        guard let systemIndex = messages.firstIndex(where: {
            let role = ($0["role"] as? String)?.lowercased()
            return role == "system" || role == "developer"
        }), let blocks = messages[systemIndex]["content"] as? [[String: Any]] else {
            return (messages, nil)
        }
        // [head], or [head, source text] where the source text is a block of
        // its own: both stay in the system message, only what follows moves.
        let stableCount = blocks.count > 1 && isSourceTextBlock(blocks[1]) ? 2 : 1
        guard blocks.count > stableCount else { return (messages, nil) }

        var prepared = messages
        prepared[systemIndex]["content"] = Array(blocks.prefix(stableCount))

        // The tail was produced by ForeverLM as text blocks. Strip any marker
        // defensively so changing per-turn context can never become a second
        // cache breakpoint through a retried/already-normalized payload.
        let volatileBlocks = blocks.dropFirst(stableCount).map { block -> [String: Any] in
            var clean = block
            clean.removeValue(forKey: "cache_control")
            return clean
        }
        let tail: [String: Any] = ["role": "user", "content": Array(volatileBlocks)]
        func role(_ index: Int) -> String? { (prepared[index]["role"] as? String)?.lowercased() }
        let anchor: Int?
        if let learnerMessageIndex, learnerMessageIndex > systemIndex,
           learnerMessageIndex < prepared.endIndex, role(learnerMessageIndex) == "user" {
            anchor = learnerMessageIndex
        } else {
            anchor = prepared.indices.last(where: {
                $0 > systemIndex && role($0) == "user" && role($0 - 1) != "tool"
            })
        }
        let tailIndex = anchor ?? prepared.endIndex
        prepared.insert(tail, at: tailIndex)
        return (prepared, tailIndex)
    }

    /// Whether a system content block is the loaded source text kept as a
    /// block of its own (`GenerationSystemPrompt.sourceTextHeader`).
    static func isSourceTextBlock(_ block: [String: Any]) -> Bool {
        (block["text"] as? String)?.hasPrefix(
            ReviewSessionManager.GenerationSystemPrompt.sourceTextHeader
        ) == true
    }

    /// Stable OpenRouter sticky-routing id for one conversation.
    ///
    /// OpenRouter caps this at 256 characters. SHA-256 keeps it compact and,
    /// unlike Swift's `Hasher`, deterministic across app launches. The worker
    /// namespaces this client value with the authenticated Apple subject before
    /// forwarding, so two users with identical prompts never share a session.
    static func openRouterPromptCacheSessionID(
        model: String,
        messages: [[String: Any]]
    ) -> String? {
        func text(from content: Any?) -> String? {
            if let string = content as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard let blocks = content as? [[String: Any]] else { return nil }
            let joined = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        guard let systemMessage = messages.first(where: {
            let role = ($0["role"] as? String)?.lowercased()
            return role == "system" || role == "developer"
        }) else { return nil }

        // A pre-split system message is [stable head, volatile tail]. Hash only
        // its first block; including the tail would defeat cache affinity on
        // exactly the turns where a digest or retry instruction changes.
        let stableSystem: String?
        if let blocks = systemMessage["content"] as? [[String: Any]], let first = blocks.first {
            stableSystem = text(from: first["text"])
        } else {
            stableSystem = text(from: systemMessage["content"])
        }
        guard let stableSystem else { return nil }

        let opening = messages.first(where: {
            guard let role = ($0["role"] as? String)?.lowercased() else { return false }
            return role != "system" && role != "developer"
        }).flatMap { text(from: $0["content"]) } ?? ""

        let material = model.lowercased() + "\u{1f}" + stableSystem + "\u{1f}" + opening
        let digest = SHA256.hash(data: Data(material.utf8))
        return "flm-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Serialize a request body deterministically.
    ///
    /// Prompt caching matches on a byte prefix, and Swift dictionaries iterate
    /// in an order seeded per process — so the same logical payload encodes to
    /// different bytes on different launches, and every cache lookup misses.
    /// `.sortedKeys` pins the order. JSON object key order carries no meaning,
    /// so this changes nothing a provider parses.
    static func stableJSONBody(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func openAICompatibleRequest(
        provider: AIProvider,
        apiKey: String,
        payload: [String: Any],
        speed: AISpeed? = nil
    ) throws -> URLRequest {
        guard let endpoint = Self.openAICompatibleChatEndpoint(for: provider),
              let url = URL(string: endpoint) else {
            throw AIError.apiError("\(provider.shortName) has no chat-completions endpoint configured.")
        }
        let payload = try Self.prepareOpenAICompatiblePayload(payload, provider: provider, speed: speed)
        try Self.requireOpenRouterRegion(payload, provider: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.stableJSONBody(payload)
        try Self.prepareOpenAICompatibleRequestForTransport(&request, provider: provider)
        return request
    }

    func callOpenAICompatible(
        provider: AIProvider,
        apiKey: String,
        system: String,
        userMessage: String,
        maxTokens: Int,
        temperature: Double? = nil,
        jsonMode: Bool = false,
        effort: AIEffort? = nil,
        disablesReasoning: Bool = false,
        imageJPEGData: Data? = nil,
        webSearch: Bool = false,
        model: String
    ) async throws -> String {
        await Self.primeOpenRouterRegion(provider: provider, model: model)
        let slug = Self.openAICompatibleModelID(provider: provider, model: model)
        // OpenRouter normalizes OpenAI-style image_url parts for every
        // vision-capable model it fronts, so one part format covers all hosts.
        // A model without vision rejects the request; that error surfaces to
        // the caller rather than being downgraded to text-only.
        let userContent: Any
        if let imageJPEGData {
            userContent = [
                ["type": "text", "text": userMessage],
                [
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(imageJPEGData.base64EncodedString())"],
                ],
            ] as [[String: Any]]
        } else {
            userContent = userMessage
        }
        var payload: [String: Any] = [
            "model": slug,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ] as [[String: Any]],
            "max_tokens": maxTokens,
        ]
        if let temperature {
            payload["temperature"] = temperature
        }
        if jsonMode {
            payload["response_format"] = ["type": "json_object"]
        }
        if webSearch {
            payload["plugins"] = [Self.openRouterWebPlugin]
        }
        if disablesReasoning {
            // OpenRouter's unified reasoning control. Classification/extraction
            // tasks can opt out so hidden thinking cannot consume their entire
            // completion budget before the required JSON is emitted. Models
            // whose reasoning cannot be switched off get the lowest level they
            // accept instead of a 400.
            payload["reasoning"] = ["effort": Self.lowestReasoningEffort(model: slug)]
        }

        let request = try openAICompatibleRequest(provider: provider, apiKey: apiKey, payload: payload)
        var (data, response) = try await session.foreverLMData(for: request)
        if disablesReasoning,
           let http = response as? HTTPURLResponse,
           Self.isMandatoryReasoningRefusal(status: http.statusCode, body: data) {
            // The model's thinking cannot be turned off. `low` is the floor
            // every reasoning model accepts, and it keeps the thinking from
            // eating the completion budget the caller asked for.
            MandatoryReasoningModels.insert(slug)
            payload["reasoning"] = ["effort": Self.reasoningFloor(model: slug)]
            let retry = try openAICompatibleRequest(provider: provider, apiKey: apiKey, payload: payload)
            (data, response) = try await session.foreverLMData(for: retry)
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw httpFailureError(label: "\(provider.shortName) request failed", http: http, data: data)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // An attached image is tokenized into the prompt, so its cost is already
        // inside `input_tokens` — but no provider's usage payload says an image
        // was there, which left every vision call indistinguishable from a text
        // one in the ledger. Slide-citation extraction is one call per slide (up
        // to `SlideCitationService.maxSlidesPerScan` per video), so image spend is
        // worth being able to pick out.
        try await recordUsage(
            provider: provider,
            model: model,
            operation: "text_completion",
            json: json,
            fallbackReport: imageJPEGData == nil ? nil : AIUsageReport(imageCount: 1)
        )
        if let failure = inBodyProviderFailure(
            label: "\(provider.shortName) request failed",
            http: response as? HTTPURLResponse,
            json: json
        ) {
            throw failure
        }
        try AICompletionStopValidator.throwIfStoppedAbnormally(json)
        return try Self.completionText(in: json, model: slug, jsonMode: jsonMode)
    }

    func callOpenAICompatibleChat(
        provider: AIProvider,
        apiKey: String,
        system: String,
        messages: [(role: String, content: String)],
        maxTokens: Int,
        model: String,
        effort: AIEffort? = nil
    ) async throws -> String {
        await Self.primeOpenRouterRegion(provider: provider, model: model)
        var msgArray: [[String: Any]] = [["role": "system", "content": system]]
        msgArray.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        let payload: [String: Any] = [
            "model": Self.openAICompatibleModelID(provider: provider, model: model),
            "messages": msgArray,
            "max_tokens": maxTokens,
        ]

        let request = try openAICompatibleRequest(provider: provider, apiKey: apiKey, payload: payload)
        let (data, response) = try await session.foreverLMData(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw httpFailureError(label: "\(provider.shortName) chat request failed", http: http, data: data)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try await recordUsage(provider: provider, model: model, operation: "chat_completion", json: json)
        if let failure = inBodyProviderFailure(
            label: "\(provider.shortName) chat request failed",
            http: response as? HTTPURLResponse,
            json: json
        ) {
            throw failure
        }
        try AICompletionStopValidator.throwIfStoppedAbnormally(json)
        return try Self.completionText(in: json, model: model, jsonMode: false)
    }

    func streamOpenAICompatibleChat(
        provider: AIProvider,
        apiKey: String,
        system: String,
        volatileSystem: String = "",
        messages: [(role: String, content: String)],
        maxTokens: Int,
        model: String,
        effort: AIEffort? = nil,
        speed: AISpeed? = nil,
        webSearch: Bool = false,
        disablesReasoning: Bool = false,
        onDelta: @escaping (String) -> Void
    ) async throws {
        await Self.primeOpenRouterRegion(provider: provider, model: model)
        let slug = Self.openAICompatibleModelID(provider: provider, model: model)
        let combinedSystem = volatileSystem.isEmpty ? system : system + volatileSystem
        var msgArray: [[String: Any]] = [["role": "system", "content": combinedSystem]]
        msgArray.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })
        // Preserve the stable/volatile boundary for the centralized cache
        // policy in applyOpenRouterPayloadExtras. All request paths pass that
        // function, so one-shot, non-streaming, streaming, and native-tool chat
        // cannot silently diverge again.
        if !volatileSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msgArray[0]["content"] = [
                ["type": "text", "text": system] as [String: Any],
                ["type": "text", "text": volatileSystem] as [String: Any],
            ]
        }

        var payload: [String: Any] = [
            "model": slug,
            "messages": msgArray,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        // The caller gates rounds itself here: on the text tool protocol the
        // trailing message is always the learner's, so the payload layer cannot
        // tell a fresh message from a tool continuation the way the native
        // path's turns can.
        if webSearch {
            payload["plugins"] = [Self.openRouterWebPlugin]
        }
        // Reasoning effort travels as the OpenAI-compatible `reasoning_effort`,
        // matching the native-tool path. Guarded by the app's own support table
        // so a model that never accepted an effort does not start receiving one
        // just because every provider now shares this adapter.
        if disablesReasoning {
            // The same opt-out the one-shot path makes (`callOpenAICompatible`):
            // work the learner is watching for, whose answer needs no hidden
            // thinking, asks for none, or the lowest a model accepts.
            payload["reasoning"] = ["effort": Self.lowestReasoningEffort(model: slug)]
        } else if let effort,
           AIRequestOptionSupport.supportedEfforts(provider: provider, model: model).contains(effort) {
            payload["reasoning_effort"] = effort.rawValue
        }
        let request = try openAICompatibleRequest(
            provider: provider, apiKey: apiKey, payload: payload, speed: speed)
        do {
            try await streamSSE(
                request: request,
                usageProvider: provider.shortName,
                usageModel: model,
                onEvent: { json in
                    AIStreamDeltaExtractor.text(from: json)
                },
                onDelta: onDelta
            )
        } catch AIError.httpError(let status, let message, _)
            where disablesReasoning && Self.isMandatoryReasoningRefusal(status: status, body: Data(message.utf8)) {
            // The model's thinking cannot be turned off: ask for the least it
            // takes, now and from then on. The refusal came before any token,
            // so nothing was streamed twice.
            MandatoryReasoningModels.insert(slug)
            payload["reasoning"] = ["effort": Self.reasoningFloor(model: slug)]
            let retry = try openAICompatibleRequest(
                provider: provider, apiKey: apiKey, payload: payload, speed: speed)
            try await streamSSE(
                request: retry,
                usageProvider: provider.shortName,
                usageModel: model,
                onEvent: { json in
                    AIStreamDeltaExtractor.text(from: json)
                },
                onDelta: onDelta
            )
        }
    }

}

/// Holds a stream's request from its creation so a deadline can cancel it
/// before `bytes(for:)` returns — the only point at which the caller would
/// otherwise get a handle on it. Once the first byte is in, it no longer cancels.
private final class StreamFirstByteDeadline: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var expired = false
    private var started = false

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let cancelNow = lock.withLock {
            self.task = task
            return expired
        }
        if cancelNow { task.cancel() }
    }

    /// Cancels the request unless its first byte has already arrived.
    func expire() {
        let toCancel: URLSessionTask? = lock.withLock {
            guard !started else { return nil }
            expired = true
            return task
        }
        toCancel?.cancel()
    }

    var hasExpired: Bool { lock.withLock { expired } }

    /// Records that the first byte arrived; false when the deadline won.
    func markStarted() -> Bool {
        lock.withLock {
            guard !expired else { return false }
            started = true
            return true
        }
    }
}
