import Foundation

/// Client for the Claude (Anthropic), OpenAI, Groq, Cerebras, xAI, Gemini, Meta,
/// Together AI, Fireworks, NVIDIA, and OpenRouter APIs.
actor AIService {

    let session: URLSession
    let usageTracker: AIUsageTracker?
    let responseCacheStorage: StorageService?
    /// Meaning-only metadata normalization may see the same author across many
    /// imported papers. Reuse the first model result for that exact source
    /// string instead of paying for the same comprehension task repeatedly.
    var normalizedAuthorCache: [String: String] = [:]
    /// Identical one-shot background calls can be triggered concurrently by
    /// overlapping discovery/import events. Keep exactly one network task per
    /// payload in flight; every waiter receives the same result or error.
    var oneShotRequestsInFlight: [String: OneShotRequestInFlight] = [:]

    /// One network task and the callers waiting on it. A caller is resumed on
    /// its own the moment it is cancelled, and the task is cancelled when the
    /// last of them is: awaiting the task's `value` directly would outlast the
    /// caller's cancellation, which is how Stop in a quiz's chat sat out a
    /// grading call for minutes (2026-09-27).
    struct OneShotRequestInFlight {
        let id: UUID
        let task: Task<String, Error>
        var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    }
    
    init() {
        let config = URLSessionConfiguration.default
        // Model latency is unbounded in practice, especially for long source
        // cleanup requests. Do not turn a slow but healthy provider response
        // into a failed import; cancellation remains under the caller's control.
        config.timeoutIntervalForRequest = 0
        self.session = URLSession(configuration: config)
        self.usageTracker = .shared
        self.responseCacheStorage = StorageService()
    }

    init(
        session: URLSession,
        usageTracker: AIUsageTracker? = nil,
        responseCacheStorage: StorageService? = nil
    ) {
        self.session = session
        self.usageTracker = usageTracker
        // Injected sessions are tests/diagnostics; keeping their deterministic
        // fixtures out of the user's persistent result cache avoids surprising
        // cross-test or production cache hits. A test of the cache itself hands
        // over a store of its own.
        self.responseCacheStorage = responseCacheStorage
    }

}

// MARK: - Errors

enum AIError: LocalizedError {
    case invalidResponse
    case missingAPIKey
    case apiError(String)
    /// A provider HTTP request that failed with a status code. Carrying the
    /// status (and the Retry-After hint when the provider sent one) lets retry
    /// logic classify by code instead of matching provider-worded strings.
    case httpError(status: Int, message: String, retryAfterSeconds: Double?)
    case outputTokenLimit(String)
    /// The request never reached a provider: ForeverLM's own AI service was
    /// unreachable. Distinct from `apiError` because nothing a provider did is
    /// being reported, and the retry classifier must not have to infer that
    /// from the wording of a system error string.
    case serviceUnreachable(String)
    /// The provider answered 200 with no completion in it: no choices, or a
    /// message without text (or, for a JSON-mode request, empty text).
    /// OpenRouter's errors page puts this down to a host warming up or
    /// scaling and says to retry, so it is transient, and it is never a
    /// verdict on the request or the source. Carries the model's id.
    case emptyAnswer(model: String)
    /// An OpenRouter router handed the work to a safety classifier, which can
    /// only rate text as safe or unsafe ("User Safety: safe"). That verdict is
    /// not an answer to any task, so it is refused. Transient: the router picks
    /// per request, and the next request usually lands on a model that can do
    /// the work. Carries the classifier's id.
    case safetyClassifierAnswer(model: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid AI response"
        case .missingAPIKey: return "ForeverLM AI is not available"
        case .apiError(let message): return message
        case .httpError(_, let message, _): return message
        case .outputTokenLimit(let message): return message
        case .serviceUnreachable(let message): return message
        case .emptyAnswer(let model): return "\(model) sent back an empty answer."
        case .safetyClassifierAnswer(let model):
            return "OpenRouter's router handed this to \(model), a safety classifier that cannot do this work, so its answer was refused."
        }
    }
}

/// Classifies provider/request failures that are worth an automatic retry with
/// backoff — network blips, rate limits, and overloaded/5xx provider states —
/// as opposed to permanent failures (bad key, invalid request) that retrying
/// can never fix. Provider HTTP failures reach us as `.apiError` strings with
/// the status code embedded (e.g. "Anthropic chat request failed (429)."), so
/// the classification is by message; it deliberately errs toward NOT retrying.
enum AITransientErrorClassifier {
    /// True when the work stopped because its task was cancelled rather than
    /// because anything about the work failed. Nothing was learned about the
    /// source, the provider, or the request: it simply never finished.
    ///
    /// Cancellation wears three faces. A cooperative checkpoint throws
    /// `CancellationError`; a request already on the wire comes back as
    /// `URLError.cancelled`; and once a caller has flattened either one into a
    /// stored message, only the text of those two remains. All three are
    /// written by Swift and Foundation, so this recognizes fixed strings the
    /// app itself produced rather than interpreting provider or learner prose.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        switch error {
        case AIError.apiError(let message), AIError.serviceUnreachable(let message):
            return isCancellationMessage(message)
        default:
            return false
        }
    }

    /// `isCancellation` for a failure that has already been reduced to text.
    ///
    /// Only needed to re-read messages a previous build persisted; the live
    /// paths all still hold the typed error. Foundation localizes its strings,
    /// so an English match is what the English messages this app wrote deserve.
    static func isCancellationMessage(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Swift's description, and the generic form Foundation gives a URLError
        // carrying no localized string of its own. Each names its error
        // precisely enough to be matched anywhere inside a wrapping sentence.
        if trimmed.contains(CancellationError().localizedDescription) { return true }
        if trimmed.contains("NSURLErrorDomain error \(NSURLErrorCancelled).") { return true }
        // A cancelled URLSession task describes itself with the single word.
        // Match that only where a wrapped message keeps its detail -- at the
        // end, after the app's own prefix -- so a provider sentence that merely
        // uses the word cannot be mistaken for a request that never ran.
        return trimmed == "cancelled" || trimmed.hasSuffix(": cancelled")
    }

    /// The decision every ingestion and queue-drain site actually makes: should
    /// this failure leave the work waiting for an automatic retry, or be shown
    /// to the learner as something that went wrong?
    ///
    /// Cancellation belongs with the transient failures here even though
    /// `isTransient` excludes it. The two questions differ: an in-process retry
    /// loop must honour a cancellation and stop, while durable work that was
    /// cancelled has simply not been attempted yet and must stay queued.
    static func shouldRetryAutomatically(_ error: Error) -> Bool {
        isCancellation(error) || isTransient(error)
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                 .secureConnectionFailed, .resourceUnavailable:
                return true
            default:
                return false
            }
        }

        // A connection that never reached a provider is as transient as the
        // URLError it was made from — which is what it would still be if the
        // hop to ForeverLM had not been renamed for the reader's benefit.
        if case AIError.serviceUnreachable = error { return true }
        if case AIError.emptyAnswer = error { return true }
        if case AIError.safetyClassifierAnswer = error { return true }

        // Typed HTTP failures classify by status code — the reliable signal.
        if case AIError.httpError(let status, _, _) = error {
            return isTransientHTTPStatus(status)
        }

        guard case AIError.apiError(let message) = error else { return false }
        let lowered = message.lowercased()
        let transientStatusMarkers = ["(408)", "(429)", "(500)", "(502)", "(503)", "(504)", "(529)"]
        if transientStatusMarkers.contains(where: { lowered.contains($0) }) { return true }
        let transientPhrases = [
            "rate limit", "rate_limit", "too many requests",
            "overloaded", "server error", "internal error",
            "temporarily unavailable", "service unavailable",
            "timed out", "timeout", "connection lost", "connection was lost", "connection reset",
            "please try again"
        ]
        return transientPhrases.contains(where: { lowered.contains($0) })
    }

    static func isTransientHTTPStatus(_ status: Int) -> Bool {
        switch status {
        case 408, 425, 429, 500, 502, 503, 504, 529:
            return true
        default:
            return false
        }
    }

    /// The provider's Retry-After hint, when the failure carried one. Retry
    /// loops should wait at least this long instead of their default backoff.
    static func retryAfterSeconds(_ error: Error) -> Double? {
        guard case AIError.httpError(_, _, let retryAfter) = error else { return nil }
        return retryAfter
    }

    /// True for a 429 — the request was refused for exceeding a quota, not
    /// because anything went wrong on the wire.
    ///
    /// Worth separating from the rest of `isTransient` for two reasons. It is
    /// still worth retrying, but only on the timescale the server names: the
    /// managed proxy's ceilings are one-minute windows and its Retry-After
    /// says 60, so the usual few-second exponential backoff cannot clear it
    /// and only burns the retry budget before failing anyway. And it must not be described to the user as a
    /// connection problem, which sends them looking at their network for a
    /// condition that has nothing to do with it.
    static func isRateLimited(_ error: Error) -> Bool {
        if case AIError.httpError(let status, _, _) = error { return status == 429 }
        guard case AIError.apiError(let message) = error else { return false }
        let lowered = message.lowercased()
        if lowered.contains("(429)") { return true }
        return ["rate limit", "rate_limited", "too many requests"].contains { lowered.contains($0) }
    }

    /// The longest a retry loop should sit waiting on a `Retry-After` before
    /// giving the turn back to the user instead. Past this the honest move is
    /// to surface the server's own message — which says when to come back —
    /// rather than hold a spinner for minutes with no way to cancel.
    static let maximumRetryAfterWait: Double = 30

    /// True when a request failed because the assembled prompt overflowed the
    /// model's context window — the char→token estimate undershot. This is
    /// recoverable by compacting the request and retrying, unlike other 4xx
    /// failures, so it gets its own classification.
    static func isContextOverflow(_ error: Error) -> Bool {
        let message: String
        switch error {
        case AIError.httpError(let status, let text, _):
            guard status == 400 || status == 413 || status == 422 else { return false }
            message = text
        case AIError.apiError(let text):
            message = text
        default:
            return false
        }
        let lowered = message.lowercased()
        let overflowMarkers = [
            "context length", "context_length", "maximum context", "context window",
            "prompt is too long", "input is too long", "too many tokens",
            "request too large", "exceed context limit", "exceeds the context",
            "maximum prompt length", "max_prompt_tokens", "decoder prompt"
        ]
        return overflowMarkers.contains { lowered.contains($0) }
    }
}

struct AICompletionStopValidator {
    static func throwIfStoppedAbnormally(_ json: [String: Any]?) throws {
        guard let json, let reason = abnormalStopReason(in: json) else { return }
        if isOutputTokenLimitStopReason(reason) {
            throw AIError.outputTokenLimit(errorMessage(for: reason))
        }
        throw AIError.apiError(errorMessage(for: reason))
    }

    static func abnormalStopReason(in json: [String: Any]) -> String? {
        for reason in completionReasons(in: json) {
            if isNormalStopReason(reason) { continue }
            return reason
        }
        return nil
    }

    static func isOutputTokenLimitStopReason(_ reason: String) -> Bool {
        switch reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "length", "max_tokens", "max_tokens_exceeded", "max_output_tokens":
            return true
        default:
            return false
        }
    }

    private static func completionReasons(in json: [String: Any]) -> [String] {
        var reasons: [String] = []

        appendReason(json["finish_reason"], to: &reasons)
        appendReason(json["finishReason"], to: &reasons)
        appendReason(json["stop_reason"], to: &reasons)

        if let delta = json["delta"] as? [String: Any] {
            appendReason(delta["stop_reason"], to: &reasons)
        }

        if let message = json["message"] as? [String: Any] {
            appendReason(message["stop_reason"], to: &reasons)
            appendReason(message["finish_reason"], to: &reasons)
        }

        if let response = json["response"] as? [String: Any],
           let status = response["status"] as? String,
           !["completed", "in_progress", "queued"].contains(status.lowercased()) {
            let detail = (response["incomplete_details"] as? [String: Any])?["reason"]
            if detail != nil {
                appendReason(detail, to: &reasons)
            } else {
                appendReason(status, to: &reasons)
            }
        }

        if let choices = json["choices"] as? [[String: Any]] {
            choices.forEach { choice in
                appendReason(choice["finish_reason"], to: &reasons)
            }
        }

        if let candidates = json["candidates"] as? [[String: Any]] {
            candidates.forEach { candidate in
                appendReason(candidate["finishReason"], to: &reasons)
            }
        }

        return reasons
    }

    private static func appendReason(_ value: Any?, to reasons: inout [String]) {
        guard let reason = value as? String else { return }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reasons.append(trimmed)
    }

    private static func isNormalStopReason(_ reason: String) -> Bool {
        switch reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "stop", "end_turn", "stop_sequence", "complete", "completed",
             "finish_reason_unspecified", "tool_calls", "function_call", "tool_use":
            return true
        default:
            return false
        }
    }

    private static func errorMessage(for reason: String) -> String {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "length", "max_tokens":
            return "AI provider stopped before finishing because it hit the output token limit (\(normalized))."
        case "max_tokens_exceeded":
            return "AI provider stopped before finishing because it exceeded the output token limit (\(normalized))."
        case "content_filter", "safety", "prohibited_content", "blocklist", "recitation", "spii":
            return "AI provider stopped the response before completing normally (\(normalized))."
        default:
            return "AI provider stopped the response before completing normally (\(normalized))."
        }
    }
}

struct AIStreamEventAccumulator {
    private(set) var dataLines: [String] = []
    private var isReadingDataEvent = false

    mutating func consume(_ line: String) -> [String]? {
        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix("data:") {
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if isReadingDataEvent && currentPayloadIsComplete {
                let event = flush()
                appendDataLine(data)
                return event
            }
            appendDataLine(data)
        } else if isReadingDataEvent && !Self.isControlLine(line) {
            if Self.looksLikeDataPayload(line) && currentPayloadIsComplete {
                let event = flush()
                appendDataLine(line)
                return event
            }
            dataLines.append(line)
        } else if Self.looksLikeDataPayload(line) {
            appendDataLine(line)
        }

        return nil
    }

    mutating func finish() -> [String]? {
        flush()
    }

    /// Whether what has been read so far is a whole event rather than the
    /// front half of one. At end of stream this separates a provider that sent
    /// something unreadable from a connection that simply stopped mid-event.
    var payloadIsComplete: Bool { currentPayloadIsComplete }

    private mutating func appendDataLine(_ line: String) {
        let data = line.trimmingCharacters(in: .whitespaces)
        guard !data.isEmpty else { return }
        dataLines.append(data)
        isReadingDataEvent = true
    }

    private var currentPayloadIsComplete: Bool {
        let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return false }
        if payload == "[DONE]" { return true }
        guard let data = payload.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func looksLikeDataPayload(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("{") ||
        trimmed.hasPrefix("[") ||
        trimmed.hasPrefix(#""candidates":"#) ||
        trimmed.hasPrefix(#""choices":"#) ||
        trimmed.hasPrefix(#""message":"#) ||
        trimmed.hasPrefix(#""type":"#)
    }

    private mutating func flush() -> [String]? {
        defer {
            dataLines = []
            isReadingDataEvent = false
        }
        guard !dataLines.isEmpty else { return nil }
        return dataLines
    }

    private static func isControlLine(_ line: String) -> Bool {
        line.hasPrefix(":") ||
        line.hasPrefix("event:") ||
        line.hasPrefix("id:") ||
        line.hasPrefix("retry:")
    }
}

struct AIStreamDeltaExtractor {
    static func text(from json: [String: Any]) -> String? {
        if let type = json["type"] as? String {
            return text(fromTypedEvent: json, type: type)
        }

        if let choices = json["choices"] as? [[String: Any]],
           let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let text = textContent(from: delta["content"]) {
                    return text
                }
            }

            if let text = textContent(from: choice["text"]) {
                return text
            }

            if let message = choice["message"] as? [String: Any],
               let text = textContent(from: message["content"]) {
                return text
            }

            return nil
        }

        if let candidates = json["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let text = textContent(from: content["parts"]) {
            return text
        }

        return nil
    }

    /// The reasoning a provider chose to show in one stream event — never
    /// answer text, and never folded into it. Anthropic `thinking_delta`,
    /// Responses reasoning summaries and raw reasoning, OpenRouter's
    /// `reasoning` / `reasoning_details` (and xAI's `reasoning_content`) on the
    /// chat delta, and Gemini parts marked `thought`. Nil when the event
    /// carries none, which is every event from a model that keeps it hidden.
    static func reasoning(from json: [String: Any]) -> String? {
        if let type = json["type"] as? String {
            switch type {
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any],
                      delta["type"] as? String == "thinking_delta" else { return nil }
                return nonEmptyString(delta["thinking"])
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                return nonEmptyString(json["delta"])
            case "response.reasoning_summary_part.done":
                // Summary parts arrive as separate paragraphs, each opening
                // with its own bold heading; keep them apart.
                return "\n\n"
            default:
                return nil
            }
        }

        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            // OpenRouter sends the flat `reasoning` string beside the
            // structured details carrying the same text; read one, not both.
            if let text = nonEmptyString(delta["reasoning"]) ?? nonEmptyString(delta["reasoning_content"]) {
                return text
            }
            guard let details = delta["reasoning_details"] as? [[String: Any]] else { return nil }
            let text = details.compactMap { detail -> String? in
                switch detail["type"] as? String {
                case "reasoning.summary": return detail["summary"] as? String
                case "reasoning.text": return detail["text"] as? String
                default: return nil
                }
            }.joined()
            return text.isEmpty ? nil : text
        }

        if let candidates = json["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            let text = parts
                .filter { $0["thought"] as? Bool == true }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? nil : text
        }

        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func text(fromRawDelta delta: String) -> String? {
        guard !delta.isEmpty else { return nil }
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delta }
        guard let json = jsonObject(fromRawEvent: trimmed) else {
            return delta
        }

        if let text = text(from: json) {
            return text
        }

        if isKnownNonTextEvent(json) {
            return nil
        }

        return delta
    }

    static func isNonTextRawEvent(_ delta: String) -> Bool {
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = jsonObject(fromRawEvent: trimmed) else {
            return false
        }

        return text(from: json) == nil && isKnownNonTextEvent(json)
    }

    static func jsonObject(fromRawEvent rawEvent: String) -> [String: Any]? {
        for candidate in jsonCandidates(fromRawEvent: rawEvent) {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return json
        }

        return nil
    }

    private static func jsonCandidates(fromRawEvent rawEvent: String) -> [String] {
        let trimmed = rawEvent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("{") {
            return [trimmed]
        }

        if trimmed.hasPrefix(#""candidates":"#) ||
            trimmed.hasPrefix(#""choices":"#) ||
            trimmed.hasPrefix(#""message":"#) ||
            trimmed.hasPrefix(#""type":"#) {
            let suffix = trimmed.hasSuffix("}") ? "" : "}"
            return ["{\(trimmed)\(suffix)"]
        }

        return [trimmed]
    }

    private static func text(fromTypedEvent json: [String: Any], type: String) -> String? {
        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta" else {
                return nil
            }
            return textContent(from: delta["text"])
        case "response.output_text.delta":
            return textContent(from: json["delta"])
        default:
            // Responses streams carry reasoning summaries, raw reasoning,
            // function arguments, refusals, and other protocol state in events
            // whose names also end in `.delta`. Only the documented visible-text
            // event belongs in the chat bubble. A generic suffix match leaked
            // model scratchpad such as "The user wants me to..." immediately
            // before the real answer on a Responses-compatible stream.
            return nil
        }
    }

    private static func textContent(from value: Any?) -> String? {
        if let text = value as? String {
            return text.isEmpty ? nil : text
        }

        if let part = value as? [String: Any] {
            if let text = textContent(from: part["text"]) {
                return text
            }
            if let text = textContent(from: part["content"]) {
                return text
            }
            return nil
        }

        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { part in
                textContent(from: part)
            }.joined()
            return text.isEmpty ? nil : text
        }

        return nil
    }

    private static func isKnownNonTextEvent(_ json: [String: Any]) -> Bool {
        if json["object"] as? String == "chat.completion.chunk" {
            return true
        }

        if json["type"] as? String != nil {
            return true
        }

        return false
    }
}

// MARK: - Waits Stop can end

/// A wait on work that its caller can always walk away from.
///
/// Swift's own waits cannot promise that. `Task.value` does not pass the
/// waiting task's cancellation on to the task it waits for, and a task group
/// returns only once every child has, cancelled or not. So a chat's Stop
/// cancelled the turn and the turn sat on until the slowest work inside it
/// finished of its own accord: an app tool that took no notice of the cancel
/// held Stop, and the tool watchdog with it, for as long as it ran, whichever
/// model the chat was on (2026-09-27). Here the caller's cancellation ends
/// the wait at once with `CancellationError` and cancels the work, which
/// winds down in its own time with no one waiting for it.
enum CancellableWait {
    /// Runs `operation` as a task of its own and returns what it gives,
    /// unless the caller is cancelled first. The task inherits the caller's
    /// priority and task-locals, so usage attribution still files its rows.
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task(operation: operation)
        return try await race(work, outcome: Outcome())
    }

    /// `run`, abandoning the work once `seconds` pass: it is cancelled, left
    /// to wind down, and `timedOut()` is returned in its place.
    static func run<T: Sendable>(
        timeout seconds: TimeInterval,
        timedOut: @escaping @Sendable () -> T,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task(operation: operation)
        let outcome = Outcome<T>()
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if outcome.offer(.success(timedOut())) { work.cancel() }
        }
        defer { timer.cancel() }
        return try await race(work, outcome: outcome)
    }

    /// The work's result, or `CancellationError` the moment the caller is
    /// cancelled, whichever comes first.
    private static func race<T: Sendable>(_ work: Task<T, Error>, outcome: Outcome<T>) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.attach(continuation)
                Task { outcome.offer(await work.result) }
            }
        } onCancel: {
            if outcome.offer(.failure(CancellationError())) { work.cancel() }
        }
    }

    /// The first result offered, delivered to the waiter exactly once
    /// whichever arrives first: the result or the waiter.
    private final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var continuation: CheckedContinuation<T, Error>?

        func attach(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            guard let result else {
                self.continuation = continuation
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(with: result)
        }

        /// Whether `offered` came first, and so is the result delivered.
        @discardableResult
        func offer(_ offered: Result<T, Error>) -> Bool {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return false
            }
            result = offered
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: offered)
            return true
        }
    }
}
