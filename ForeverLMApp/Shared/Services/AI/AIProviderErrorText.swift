import Foundation

/// Filters provider-authored text before it can become a user-visible error.
///
/// A failed provider call hands back a body, and a body is not safe to show. A
/// stream that dies mid-event, a gateway that answers with an HTML page, a
/// proxy that echoes the request back — each hands us a slice of what we
/// *sent*: the system prompt, the learner's sources, the conversation. That
/// used to reach the chat's red error row verbatim, pasting the whole
/// instruction block onto the screen. Every provider-authored string now passes
/// through here first, so the worst case is a vague error instead of a leaked
/// prompt.
enum AIProviderErrorText {
    /// The longest provider message worth showing. Real ones ("You exceeded
    /// your current quota") sit far below this; past it we are reading a
    /// payload rather than a sentence.
    static let maximumLength = 400

    /// The longest error text the chat error row should render, whatever the
    /// source. Errors arrive there from storage, sync, and MCP as well as from
    /// providers, and only provider text passes through `sanitized`.
    static let maximumDisplayLength = 600

    /// The message to show for provider text, or nil when none of it can be
    /// shown safely and the caller should fall back to its own labelled
    /// message.
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikePayload(trimmed) else { return nil }
        return clamped(trimmed, limit: maximumLength)
    }

    /// True when the text is request or response data rather than a
    /// human-readable explanation — structured by shape, or carrying a key only
    /// a payload has. Deliberately eager: misreading a real provider message
    /// costs a vaguer error, misreading a payload leaks the prompt.
    static func looksLikePayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first == "{" || first == "[" || first == "<" { return true }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("data:") || lowered.hasPrefix("event:") { return true }
        let payloadKeys = [
            "\"instructions\"", "\"messages\"", "\"input\"", "\"system\"",
            "\"response\"", "\"delta\"", "\"content\"", "\"tools\"", "\"prompt\"",
        ]
        return payloadKeys.contains { lowered.contains($0) }
    }

    /// The provider's explanation for a failed request, read from the shapes
    /// providers actually use and filtered on the way out. Nil when the body
    /// carries nothing showable, and the caller should fall back to its own
    /// labelled message.
    static func fromResponseBody(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                if let message = (error["message"] as? String).flatMap(sanitized) {
                    return namingProvider(message, metadata: error["metadata"] as? [String: Any])
                }
                if let type = (error["type"] as? String).flatMap(sanitized) { return type }
            }
            return (object["message"] as? String).flatMap(sanitized)
        }
        // Not JSON: as often a truncated payload or an HTML gateway page as a
        // sentence, so it is shown only when it reads like one.
        return String(data: data, encoding: .utf8).flatMap(sanitized)
    }

    /// OpenRouter's wording when the lab behind a model refuses a request.
    /// It says nothing about which lab or why; both sit in `error.metadata`.
    static let openRouterGenericProviderError = "Provider returned error"

    /// OpenRouter answers a lab-side failure with the one sentence "Provider
    /// returned error" and puts the lab's name and its own error body in
    /// `error.metadata` (`provider_name`, `raw`). Shown as-is, a 429 from
    /// Google read as a ForeverLM fault with no reason. This names the lab and
    /// appends its reason when the reason reads like a sentence — the raw body
    /// is provider-authored and passes the same payload filter as the message.
    static func namingProvider(_ message: String, metadata: [String: Any]?) -> String {
        guard let metadata else { return message }
        let providerName = (metadata["provider_name"] as? String)
            .flatMap(sanitized)
            .flatMap { $0.count <= 60 && !$0.contains("\n") ? $0 : nil }
        let reason = rawProviderReason(metadata["raw"])
        var base = message
        if let providerName {
            base = message == openRouterGenericProviderError
                ? "\(providerName) returned an error"
                : "\(providerName): \(message)"
        }
        guard let reason, reason != message else { return clamped(base, limit: maximumLength) }
        let separator = base.hasSuffix(".") || base.hasSuffix(":") ? " " : ": "
        return clamped(base + separator + reason, limit: maximumLength)
    }

    /// The lab's own explanation inside OpenRouter's `metadata.raw`: a JSON
    /// error body (Google: `{"error":{"message":…,"status":…}}`), a JSON
    /// object already parsed, or a bare sentence. Nil when it carries nothing
    /// showable, including when it echoes the request.
    private static func rawProviderReason(_ raw: Any?) -> String? {
        if let object = raw as? [String: Any] {
            return (try? JSONSerialization.data(withJSONObject: object)).flatMap(nestedMessage)
        }
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "{" { return nestedMessage(Data(trimmed.utf8)) }
        return sanitized(trimmed)
    }

    /// `error.message` or `message` of a nested error body, filtered. The
    /// nested body's own metadata is not followed: one level of naming is
    /// enough, and a loop here would be a provider echoing us back.
    private static func nestedMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            if let message = (error["message"] as? String).flatMap(sanitized) { return message }
            if let status = (error["status"] as? String).flatMap(sanitized) { return status }
            return nil
        }
        return (object["message"] as? String).flatMap(sanitized)
    }

    /// Trims an error to a length a person will actually read. Used at the
    /// display boundary as well as on provider text, because a wall of text in
    /// the chat is worth capping wherever it came from.
    static func clamped(_ message: String, limit: Int = AIProviderErrorText.maximumDisplayLength) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "\(trimmed.prefix(limit))…"
    }
}
