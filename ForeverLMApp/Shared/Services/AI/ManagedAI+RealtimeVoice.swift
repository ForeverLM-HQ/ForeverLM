import Foundation
import os

private let realtimeVoiceUsageLogger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoiceUsage")

extension ManagedAI {
    /// A short-lived OpenAI Realtime credential, minted with the conversation's
    /// whole session on it. It only has to open the call; the call outlives it.
    struct RealtimeVoiceSecret: Sendable {
        let value: String
        let expiresAt: Date
        let model: String
        /// Voice sessions left in this account's rolling day, nil when unlimited
        /// or when the learner's own key opened the session.
        let sessionsLeftToday: Int?
        /// Opened on the learner's own OpenAI key (`ownOpenAIVoiceKey`), so
        /// OpenAI bills them and ForeverLM's ledger is not asked.
        var paidByOwnKey = false
    }

    // MARK: - The learner's own OpenAI key for voice mode

    /// The learner may run voice mode on their own OpenAI API key (product
    /// owner, 2026-11-08: "let people put their own openai key for the voice
    /// mode"). With one stored, every voice session is opened straight with
    /// OpenAI on it: the key never reaches ForeverLM's server, OpenAI bills the
    /// learner. Without one, voice mode is off (product owner, 2026-11-15:
    /// realtime voice requires the learner's own OpenAI key). The key sits in iCloud Keychain, so the Mac and the iPhone share
    /// it, like the OpenRouter key.
    static let ownOpenAIVoiceKeysURL = URL(string: "https://platform.openai.com/api-keys")!

    /// OpenAI's help page on the monthly API credits an eligible ChatGPT
    /// subscription (Pro, Business) brings, claimed in OpenAI's billing
    /// settings (product owner, 2026-11-14: "a link to how people get a
    /// certain number of api credits for free ... when they have a
    /// subscription already").
    static let openAISubscriberCreditsURL = URL(string: "https://help.openai.com/en/articles/20001626-api-credits-benefit-for-eligible-chatgpt-subscriptions")!

    private static let ownOpenAIVoiceKeyLock = AppLock()
    /// `nil` until read this launch; then the answer, which every write keeps.
    nonisolated(unsafe) private static var ownOpenAIVoiceKeyCache: String??

    #if DEBUG
    /// Pins the voice key for a unit test; `.some(nil)` pins "no key".
    nonisolated(unsafe) static var ownOpenAIVoiceKeyOverrideForTesting: String??
    #endif

    /// The learner's own OpenAI key for voice mode, or nil.
    static var ownOpenAIVoiceKey: String? {
        #if DEBUG
        if let override = ownOpenAIVoiceKeyOverrideForTesting { return override }
        #endif
        return ownOpenAIVoiceKeyLock.withLock {
            if let cached = ownOpenAIVoiceKeyCache { return cached }
            let loaded = KeychainService.load(.ownOpenAIVoiceKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (loaded?.isEmpty ?? true) ? nil : loaded
            ownOpenAIVoiceKeyCache = .some(key)
            return key
        }
    }

    /// The key's last four characters, for a row that names it.
    static var ownOpenAIVoiceKeySuffix: String? {
        ownOpenAIVoiceKey.map { String($0.suffix(4)) }
    }

    /// Stores, replaces, or (nil or empty) removes the voice key.
    static func setOwnOpenAIVoiceKey(_ rawKey: String?) {
        let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ownOpenAIVoiceKeyLock.withLock {
            if key.isEmpty {
                KeychainService.delete(.ownOpenAIVoiceKey)
                ownOpenAIVoiceKeyCache = .some(nil)
            } else {
                KeychainService.save(key, for: .ownOpenAIVoiceKey)
                ownOpenAIVoiceKeyCache = .some(key)
            }
        }
        NotificationCenter.default.post(name: .managedAIOwnKeyDidChange, object: nil)
    }

    /// Drops the in-memory copy, for a key synced in from another device.
    static func reloadOwnOpenAIVoiceKey() {
        ownOpenAIVoiceKeyLock.withLock { ownOpenAIVoiceKeyCache = nil }
    }

    /// Asks OpenAI whether it accepts `key` before it is stored: listing the
    /// models spends nothing and answers 401 for a key OpenAI does not know.
    /// Throws when OpenAI cannot be asked at all.
    static func checkOwnOpenAIVoiceKey(_ key: String, session: URLSession = .shared) async throws -> OwnKeyCheck {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let result = ownOpenAIVoiceKeyCheckResult(statusCode: status) else {
            throw OwnKeyCheckError(message: "OpenAI answered \(status) when asked about the key. Try again in a moment.")
        }
        return result
    }

    /// The status-code half of `checkOwnOpenAIVoiceKey`. Nil for an answer
    /// that says nothing about the key (a 5xx, a 429).
    static func ownOpenAIVoiceKeyCheckResult(statusCode: Int) -> OwnKeyCheck? {
        switch statusCode {
        case 200..<300: return .accepted
        case 401, 403: return .rejected("OpenAI didn't accept this key. Check that you copied all of it.")
        default: return nil
        }
    }

    /// What `POST /v1/realtime/client_secrets` takes when the app mints on
    /// the learner's key: the proxy's own body (`mintOpenAIRealtimeSecret` in
    /// workers/ai-proxy): the session as the app built it under type and
    /// model, and a two-minute secret.
    static func ownKeyRealtimeMintBody(model: String, session: [String: Any]) -> [String: Any] {
        var configured = session
        configured["type"] = "realtime"
        configured["model"] = model
        return [
            "expires_after": ["anchor": "created_at", "seconds": 120],
            "session": configured,
        ]
    }

    /// Mints the session's secret straight with OpenAI on the learner's key.
    private static func mintRealtimeVoiceSecretOnOwnKey(
        _ key: String,
        model: String,
        session: [String: Any]
    ) async throws -> RealtimeVoiceSecret {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ownKeyRealtimeMintBody(model: model, session: session))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                throw ServiceError(
                    code: "own_openai_key_rejected",
                    message: "OpenAI didn't accept your OpenAI key for voice mode. Replace or remove it in Settings, under API keys."
                )
            }
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String)
                .map { " \($0)" } ?? ""
            throw ServiceError(
                code: "upstream_error",
                message: "OpenAI couldn't start a voice session on your key (HTTP \(status)).\(detail)"
            )
        }
        guard let value = json?["value"] as? String, !value.isEmpty else {
            throw ServiceError(code: "bad_response", message: "OpenAI sent no session key. Try again.")
        }
        let expiresAt = (json?["expires_at"] as? NSNumber)?.doubleValue ?? Date().addingTimeInterval(120).timeIntervalSince1970
        return RealtimeVoiceSecret(
            value: value,
            expiresAt: Date(timeIntervalSince1970: expiresAt),
            model: model,
            sessionsLeftToday: nil,
            paidByOwnKey: true
        )
    }

    /// A Realtime client secret for the session, minted straight with OpenAI on
    /// the learner's own OpenAI key. Voice mode runs on that key alone
    /// (product owner, 2026-11-15: realtime voice requires the learner's own
    /// OpenAI key); ForeverLM's server mints nothing and sees nothing.
    /// `session` is OpenAI's session object without its type and model
    /// (`OpenAIRealtimeWire.sessionConfiguration`).
    static func mintRealtimeVoiceSecret(
        model: String = RealtimeVoiceDefaults.model,
        session: [String: Any]
    ) async throws -> RealtimeVoiceSecret {
        guard let ownKey = ownOpenAIVoiceKey else {
            throw ServiceError(
                code: "no_openai_key",
                message: "Voice mode runs on your own OpenAI key. Add it in Settings, then try again."
            )
        }
        return try await mintRealtimeVoiceSecretOnOwnKey(ownKey, model: model, session: session)
    }

    /// Keeps one reply's tokens in the Mac's own usage ledger as an own-key
    /// call at OpenAI's list price. The iPhone keeps no local ledger, and
    /// OpenAI's usage page has the rest. Fire and forget: a conversation never
    /// waits on its bookkeeping.
    static func reportRealtimeVoiceUsage(
        _ usage: RealtimeVoiceUsage,
        model: String,
        sourceTitle: String?,
        activityID: String,
        paidByOwnKey: Bool = true
    ) {
        #if os(macOS)
        recordOwnKeyRealtimeVoiceUsage(usage, model: model, sourceTitle: sourceTitle, activityID: activityID)
        #endif
    }
}

extension RealtimeVoiceUsage {
    /// OpenAI's list price per 1M tokens for the voice models, the proxy's
    /// `REALTIME_VOICE_RATES` (workers/ai-proxy, checked 2026-11-07). Nil for a
    /// model not listed.
    static let listRatesPerMillion: [String: (textIn: Double, cachedTextIn: Double, textOut: Double, audioIn: Double, cachedAudioIn: Double, audioOut: Double)] = [
        "gpt-realtime-2.1": (4, 0.4, 24, 32, 0.4, 64),
        "gpt-realtime-2.1-mini": (0.6, 0.06, 2.4, 10, 0.3, 20),
    ]

    /// What this reply costs at OpenAI's list price, in dollars.
    func listCostUSD(model: String) -> Double? {
        guard let rates = Self.listRatesPerMillion[model] else { return nil }
        let micro = Double(textInputTokens) * rates.textIn
            + Double(cachedTextInputTokens) * rates.cachedTextIn
            + Double(audioInputTokens) * rates.audioIn
            + Double(cachedAudioInputTokens) * rates.cachedAudioIn
            + Double(textOutputTokens) * rates.textOut
            + Double(audioOutputTokens) * rates.audioOut
        return micro / 1_000_000
    }
}

#if os(macOS)
extension ManagedAI {
    /// One reply on the learner's own OpenAI key, kept in this Mac's usage
    /// ledger as an own-key call, priced at OpenAI's list price.
    fileprivate static func recordOwnKeyRealtimeVoiceUsage(
        _ usage: RealtimeVoiceUsage,
        model: String,
        sourceTitle: String?,
        activityID: String
    ) {
        var report = AIUsageReport(
            inputTokens: usage.textInputTokens + usage.audioInputTokens + usage.cachedTextInputTokens + usage.cachedAudioInputTokens,
            outputTokens: usage.textOutputTokens + usage.audioOutputTokens
        )
        report.cachedInputTokens = usage.cachedTextInputTokens + usage.cachedAudioInputTokens
        report.audioInputTokens = usage.audioInputTokens + usage.cachedAudioInputTokens
        report.audioOutputTokens = usage.audioOutputTokens
        if let cost = usage.listCostUSD(model: model) {
            report.providerReportedCost = cost
            report.currency = "USD"
        }
        Task.detached(priority: .utility) {
            do {
                try await AIUsageTracker.shared.record(
                    provider: "OpenAI",
                    model: model,
                    operation: "realtime_voice",
                    report: report,
                    eventID: "rt-own:\(usage.responseID)",
                    task: "realtime_voice",
                    activityID: activityID,
                    subjectTitle: sourceTitle,
                    ownKey: true
                )
            } catch {
                realtimeVoiceUsageLogger.error("Recording the realtime voice usage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif

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
