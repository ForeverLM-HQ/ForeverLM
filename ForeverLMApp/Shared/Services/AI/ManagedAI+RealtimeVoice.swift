import Foundation

extension ManagedAI {
    /// A short-lived OpenAI Realtime credential. It only has to open the socket;
    /// the session it opens outlives it.
    struct RealtimeVoiceSecret: Sendable {
        let value: String
        let expiresAt: Date
        let model: String
        /// Voice sessions left in this account's rolling day, nil when unlimited.
        let sessionsLeftToday: Int?
    }

    /// Asks the proxy for a Realtime client secret minted on ForeverLM's own
    /// OpenAI account (voice mode is free for the learner; see
    /// `RealtimeVoiceProtocol.swift`). Needs Sign in with Apple, not a key: the
    /// learner's OpenRouter key plays no part.
    static func mintRealtimeVoiceSecret(model: String = RealtimeVoiceDefaults.model) async throws -> RealtimeVoiceSecret {
        struct Body: Encodable {
            let model: String
        }
        struct Response: Decodable {
            let value: String?
            let expiresAt: TimeInterval?
            let model: String?
            let sessionsLeftToday: Int?

            enum CodingKeys: String, CodingKey {
                case value
                case expiresAt = "expires_at"
                case model
                case sessionsLeftToday = "sessions_left_today"
            }
        }
        let response: Response = try await post(
            "/v1/realtime/client_secrets",
            body: Body(model: model),
            authenticated: true
        )
        guard let value = response.value, !value.isEmpty else {
            throw ServiceError(code: "bad_response", message: "The voice service sent no session key. Try again.")
        }
        return RealtimeVoiceSecret(
            value: value,
            expiresAt: Date(timeIntervalSince1970: response.expiresAt ?? 0),
            model: response.model ?? model,
            sessionsLeftToday: response.sessionsLeftToday
        )
    }

    /// Records one reply's tokens in the proxy's usage ledger, as spent on
    /// ForeverLM's own OpenAI credits: AI Usage on the Mac and the iPhone show
    /// it with that capsule, and nothing is charged. Idempotent on the reply id,
    /// so a retry never counts twice. Fire and forget: a conversation never
    /// waits on its bookkeeping.
    static func reportRealtimeVoiceUsage(
        _ usage: RealtimeVoiceUsage,
        model: String,
        sourceTitle: String?,
        activityID: String
    ) {
        struct Body: Encodable {
            let model: String
            let responseID: String
            let textInputTokens: Int
            let audioInputTokens: Int
            let cachedTextInputTokens: Int
            let cachedAudioInputTokens: Int
            let textOutputTokens: Int
            let audioOutputTokens: Int
            let sourceTitle: String?

            enum CodingKeys: String, CodingKey {
                case model
                case responseID = "response_id"
                case textInputTokens = "text_input_tokens"
                case audioInputTokens = "audio_input_tokens"
                case cachedTextInputTokens = "cached_text_input_tokens"
                case cachedAudioInputTokens = "cached_audio_input_tokens"
                case textOutputTokens = "text_output_tokens"
                case audioOutputTokens = "audio_output_tokens"
                case sourceTitle = "source_title"
            }
        }
        struct Response: Decodable {
            let recorded: Bool?
        }
        let body = Body(
            model: model,
            responseID: usage.responseID,
            textInputTokens: usage.textInputTokens,
            audioInputTokens: usage.audioInputTokens,
            cachedTextInputTokens: usage.cachedTextInputTokens,
            cachedAudioInputTokens: usage.cachedAudioInputTokens,
            textOutputTokens: usage.textOutputTokens,
            audioOutputTokens: usage.audioOutputTokens,
            sourceTitle: sourceTitle.map { String($0.prefix(200)) }
        )
        Task.detached(priority: .utility) {
            for attempt in 0..<3 {
                do {
                    let _: Response = try await post(
                        "/v1/realtime/usage",
                        body: body,
                        authenticated: true,
                        usageActivityID: activityID
                    )
                    return
                } catch {
                    if let service = error as? ServiceError, service.isInvalidSession || service.code == "bad_request" {
                        return
                    }
                    try? await Task.sleep(for: .seconds(Double(2 << attempt)))
                }
            }
        }
    }
}
