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
}
