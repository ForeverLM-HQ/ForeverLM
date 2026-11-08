import Foundation

extension ManagedAI {
    /// A short-lived OpenAI Realtime credential, minted with the conversation's
    /// whole session on it. It only has to open the call; the call outlives it.
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
    /// `session` is OpenAI's session object without its type and model, which the
    /// proxy sets (`OpenAIRealtimeWire.sessionConfiguration`).
    static func mintRealtimeVoiceSecret(
        model: String = RealtimeVoiceDefaults.model,
        session: [String: Any]
    ) async throws -> RealtimeVoiceSecret {
        struct Body: Encodable {
            let model: String
            let session: RealtimeSessionJSON
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
            body: Body(model: model, session: try RealtimeSessionJSON(session)),
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

/// Any JSON value, so the session dictionary rides in a typed request body. It
/// is read back from `JSONSerialization`'s text, so every number and flag is
/// exactly what JSON says (a Bool is never a 0 or 1 in disguise).
enum RealtimeSessionJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([RealtimeSessionJSON])
    case object([String: RealtimeSessionJSON])

    init(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        self = try JSONDecoder().decode(RealtimeSessionJSON.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RealtimeSessionJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RealtimeSessionJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
