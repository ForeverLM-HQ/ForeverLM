import Foundation

// Streaming counterpart to MobileSourceChatService, for the reading chat where
// the user watches an answer arrive token by token rather than hearing it
// spoken. The single-shot service stays as-is for the hands-free/driving path.
//
// The request is built by MobileOpenRouterChat.request so the OpenRouter
// request shape and ManagedAI.rewrite stay identical to every other mobile AI
// call.

struct MobileStreamingChatResult: Sendable {
    let text: String
    let report: AIUsageReport?
    let servedModel: String?
    let route: ResolvedAITextRoute
}

enum MobileStreamingChatError: LocalizedError {
    case notSignedIn
    /// `status` is 0 when the failure happened before an HTTP status existed.
    case http(status: Int, body: String)
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with Apple to ask questions about a source."
        case .http(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return status > 0
                ? "AI chat failed (\(status))\(suffix)"
                : "AI chat failed\(suffix)"
        case .emptyCompletion:
            return "The AI provider returned an empty response."
        }
    }
}

enum MobileStreamingChat {
    static let responseTokenBudget = 1_200
    static let maxSourceCharacters = 240_000

    /// Long enough for a full streamed answer; the timeout applies to the gap
    /// between bytes, not the whole response.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    private static let maximumErrorBodyCharacters = 4_000

    /// Streams one assistant turn. `onDelta` receives each new fragment only —
    /// the caller accumulates. Nothing here touches the main actor.
    ///
    /// The returned report is *not* recorded: only the caller knows which
    /// operation slug the usage belongs to.
    ///
    /// `modelOverride` is the chat's own model, picked from its model chip;
    /// nil runs on the account's default chat model.
    static func stream(
        system: String,
        messages: [(role: String, content: String)],
        modelOverride: AIModelRoutePreference? = nil,
        onDelta: @Sendable @escaping (String) async -> Void
    ) async throws -> MobileStreamingChatResult {
        guard ManagedAI.isSignedIn else { throw MobileStreamingChatError.notSignedIn }

        let route = try await MobileModelPreferenceStore.shared.resolve(.chat, overriding: modelOverride)
        let request = try streamingRequest(route: route, system: system, messages: messages)
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MobileStreamingChatError.http(status: 0, body: "The AI provider did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = try await errorBody(from: bytes)
            // Free mode's two failures read as nothing on their own: the
            // learner's OpenRouter account refusing free endpoints, and a busy
            // free host. See `AIFreeMode`.
            if let explanation = AIFreeMode.refusalExplanation(
                forProviderBody: body,
                providerMessage: AIProviderErrorText.fromResponseBody(Data(body.utf8))
            ) {
                throw MobileStreamingChatError.http(status: http.statusCode, body: explanation)
            }
            throw MobileStreamingChatError.http(
                status: http.statusCode,
                body: AIFreeMode.annotatingBusy(body, status: http.statusCode)
            )
        }

        var text = ""
        var report: AIUsageReport?
        var servedModel: String?
        var hasVerifiedModel = false
        var pendingDeltas: [String] = []
        var rejectedModel = false

        for try await line in bytes.sseLines {
            try Task.checkCancellation()

            // Only "data:" frames carry payload. This also drops the blank
            // event separators and OpenRouter's ": OPENROUTER PROCESSING"
            // keepalive comments, which are not JSON.
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let served = AIUsageParser.servedModel(from: chunk) {
                servedModel = served
                var identityReport = AIUsageReport.empty
                identityReport.servedModel = served
                do {
                    try MobileOpenRouterChat.requireSelectedModel(report: identityReport, route: route)
                    if !hasVerifiedModel {
                        hasVerifiedModel = true
                        for delta in pendingDeltas { await onDelta(delta) }
                        pendingDeltas.removeAll(keepingCapacity: false)
                    }
                } catch {
                    rejectedModel = true
                    pendingDeltas.removeAll(keepingCapacity: false)
                }
            }

            if let fragment = textDelta(from: chunk), !fragment.isEmpty {
                text += fragment
                if hasVerifiedModel, !rejectedModel {
                    await onDelta(fragment)
                } else if !rejectedModel {
                    pendingDeltas.append(fragment)
                }
            }

            // Only the terminal chunk carries usage, because the request sets
            // usage.include. Keep the last one seen rather than merging.
            if let usage = chunk["usage"] as? [String: Any] {
                report = AIUsageParser.report(fromUsageObject: usage)
            } else if let usage = (chunk["response"] as? [String: Any])?["usage"] as? [String: Any] {
                report = AIUsageParser.report(fromUsageObject: usage)
            }
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileStreamingChatError.emptyCompletion
        }

        // Some compatible endpoints report no model identity until the end (or
        // omit it). In that case the selected request is still authoritative,
        // but no unverified token was rendered while the stream was live.
        if !hasVerifiedModel, !rejectedModel {
            for delta in pendingDeltas { await onDelta(delta) }
        }

        if let servedModel {
            if report == nil { report = .empty }
            if report?.servedModel == nil { report?.servedModel = servedModel }
        }
        return MobileStreamingChatResult(text: text, report: report, servedModel: servedModel, route: route)
    }

    private static func textDelta(from chunk: [String: Any]) -> String? {
        guard let choices = chunk["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    private static func streamingRequest(
        route: ResolvedAITextRoute,
        system: String,
        messages: [(role: String, content: String)]
    ) throws -> URLRequest {
        var request = try MobileOpenRouterChat.request(
            route: route,
            system: system,
            messages: messages,
            maxTokens: responseTokenBudget,
            stream: true
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    /// Drains a failed response so the real upstream message reaches the user
    /// instead of a bare status code.
    private static func errorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        for try await line in bytes.sseLines {
            body += line
            if body.count > maximumErrorBodyCharacters { break }
        }
        return body.isEmpty ? "No response body." : body
    }
}
