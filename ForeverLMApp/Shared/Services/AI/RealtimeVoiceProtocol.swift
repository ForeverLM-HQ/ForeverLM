import Foundation

// Voice mode's wire protocol: OpenAI Realtime, speech to speech, over one
// WebSocket. It came back on 2026-11-07 (product owner, 2026-11-07: "now we
// actually have free API credits from OpenAI as part of our plan ... we should
// 100% implement the real-time voice mode again"). The proxy mints a short-lived
// client secret on the company's OpenAI account (`ManagedAI.mintRealtimeVoiceSecret`),
// so no OpenAI key reaches a device and the learner pays nothing. This is the one
// model route that does not go through OpenRouter, which serves no
// speech-to-speech model.
//
// The Mac and the iPhone share this file, `RealtimeVoiceSession` (the socket) and
// `RealtimeVoiceController` (the conversation); each platform brings only its
// audio graph (`RealtimeVoiceAudio`) and its screens. The protocol details here
// were proven in the first realtime voice (removed 2026-10-01) and ported from it.

/// What voice mode runs on. One model, one voice: nothing for the learner to
/// pick, and nothing on the learner's bill.
enum RealtimeVoiceDefaults {
    static let model = "gpt-realtime-2.1"
    /// OpenAI's recommended voice for the realtime models.
    static let voice = "marin"
    /// Streams the learner's words while they speak, for the caption and the
    /// saved transcript. `fallbackTranscriptionModel` is tried once if OpenAI
    /// refuses this one, so a renamed model never stops a conversation.
    static let transcriptionModel = "gpt-realtime-whisper"
    static let fallbackTranscriptionModel = "gpt-4o-mini-transcribe"
    /// Both directions are 24 kHz mono PCM16 on the wire.
    static let sampleRate = 24_000.0

    /// A usage-ledger model id that voice mode ran on ("gpt-realtime-2.1",
    /// "openai/gpt-realtime-2.1-mini"). AI Usage reads these as paid by
    /// ForeverLM's credits rather than the learner's key.
    static func isVoiceModeModel(_ model: String) -> Bool {
        let id = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return id.hasPrefix("gpt-realtime")
    }
}

/// The events the controller consumes, decoded from OpenAI's server events.
enum RealtimeVoiceServerEvent {
    case sessionReady
    case speechStarted
    case speechStopped
    case inputTranscriptDelta(itemID: String, delta: String)
    case inputTranscriptCompleted(itemID: String, transcript: String)
    case responseCreated(responseID: String)
    case outputItemAdded(itemID: String)
    /// 24 kHz mono PCM16 to play.
    case audioDelta(Data)
    case outputTranscriptDelta(itemID: String, delta: String)
    case outputTranscriptDone(itemID: String, transcript: String)
    case functionCallDone(callID: String, name: String, argumentsJSON: String)
    case responseDone(responseID: String, status: String, usage: RealtimeVoiceUsage?)
    case serverError(message: String)
    case ignored(type: String)
}

/// One reply's tokens, split the way OpenAI prices them. Reported to the proxy
/// (`ManagedAI.reportRealtimeVoiceUsage`), which records it in the usage ledger
/// as spent on ForeverLM's own OpenAI credits: shown in AI Usage, never charged.
struct RealtimeVoiceUsage: Equatable, Sendable {
    let responseID: String
    var textInputTokens = 0
    var audioInputTokens = 0
    var cachedTextInputTokens = 0
    var cachedAudioInputTokens = 0
    var textOutputTokens = 0
    var audioOutputTokens = 0

    var totalTokens: Int {
        textInputTokens + audioInputTokens + cachedTextInputTokens + cachedAudioInputTokens
            + textOutputTokens + audioOutputTokens
    }

    /// From `response.done`'s `usage`. Cached tokens are counted inside the
    /// input totals there, so they are taken out of the uncached buckets.
    init?(responseID: String, usage: [String: Any]) {
        guard !responseID.isEmpty else { return nil }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let input = usage["input_token_details"] as? [String: Any] ?? [:]
        let cached = input["cached_tokens_details"] as? [String: Any] ?? [:]
        let output = usage["output_token_details"] as? [String: Any] ?? [:]
        self.responseID = responseID
        cachedTextInputTokens = int(cached["text_tokens"])
        cachedAudioInputTokens = int(cached["audio_tokens"])
        textInputTokens = max(0, int(input["text_tokens"]) - cachedTextInputTokens)
        audioInputTokens = max(0, int(input["audio_tokens"]) - cachedAudioInputTokens)
        textOutputTokens = int(output["text_tokens"])
        audioOutputTokens = int(output["audio_tokens"])
        guard totalTokens > 0 else { return nil }
    }
}

/// How a server `error` event is treated.
enum RealtimeVoiceServerErrorDisposition: Equatable {
    case ignore
    case failReadiness
    case surfaceInline

    /// Protocol races nobody should be shown. Barge-in is the one that reaches
    /// people: trimming the unheard tail of a reply is a request about an item
    /// the server may already have finished, so healthy interruptions come back
    /// rejected. The wire gives them no distinguishing code, only the message.
    private static let benignFragments = [
        "only model output audio messages can be truncated",
        "already has an active response",
        "cancellation failed: no active response found",
        "audio content of",
    ]

    static func resolve(isReady: Bool, message: String) -> Self {
        // Before the session is up, the same text is the reason it never came
        // up, and the learner needs it.
        guard isReady else { return .failReadiness }
        if isBenign(message) { return .ignore }
        // OpenAI uses top-level errors for request-scoped races too; its socket
        // stays usable, so the conversation goes on with a line on screen.
        return .surfaceInline
    }

    static func isBenign(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return benignFragments.contains { normalized.contains($0) }
    }
}

/// Keeps reply audio that was already in flight when the learner barged in
/// from restarting the speaker. A few deltas can arrive after the interruption;
/// playback stays closed until the next response begins.
struct RealtimePlaybackGate: Sendable {
    private(set) var isSuppressed = false

    var acceptsAudio: Bool { !isSuppressed }

    mutating func interrupt() { isSuppressed = true }
    mutating func beginResponse() { isSuppressed = false }
}

/// OpenAI Realtime's payloads and server-event decoding.
enum OpenAIRealtimeWire {
    static func socketRequest(model: String, secret: String) -> URLRequest {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The whole session configuration. Foundation can bridge a Swift `Double`
    /// through its binary expansion when serializing an untyped dictionary and
    /// OpenAI constrains decimal precision on these fields, so they are exact
    /// decimal numbers.
    static func configurationPayload(
        instructions: String,
        tools: [[String: Any]],
        voice: String,
        transcriptionModel: String
    ) -> [String: Any] {
        let retentionRatio = NSDecimalNumber(mantissa: 8, exponent: -1, isNegative: false)
        let vadThreshold = NSDecimalNumber(mantissa: 5, exponent: -1, isNegative: false)
        return [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": instructions,
                // A long conversation drops its oldest turns, never the
                // instructions, which carry the source.
                "truncation": [
                    "type": "retention_ratio",
                    "retention_ratio": retentionRatio,
                ] as [String: Any],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000] as [String: Any],
                        "transcription": ["model": transcriptionModel],
                        // Echo cancellation and the platform's own noise
                        // suppression run before this; the server's adds the
                        // near-field filter a phone held close needs.
                        "noise_reduction": ["type": "near_field"],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": vadThreshold,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 600,
                            "create_response": true,
                            "interrupt_response": true,
                        ] as [String: Any],
                    ] as [String: Any],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000] as [String: Any],
                        "voice": voice,
                    ] as [String: Any],
                ] as [String: Any],
                "tools": tools,
                "tool_choice": "auto",
            ] as [String: Any],
        ]
    }

    static func decodeServerEvent(_ json: [String: Any]) -> RealtimeVoiceServerEvent? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "session.created":
            // The bare session is not ready: only the acknowledgement of our
            // configuration may release buffered microphone audio.
            return .ignored(type: type)
        case "session.updated":
            return .sessionReady
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String else { return nil }
            return .inputTranscriptDelta(itemID: (json["item_id"] as? String) ?? "", delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscriptCompleted(
                itemID: (json["item_id"] as? String) ?? "",
                transcript: (json["transcript"] as? String) ?? ""
            )
        case "response.created":
            let response = json["response"] as? [String: Any]
            return .responseCreated(responseID: (response?["id"] as? String) ?? "")
        case "response.output_item.added":
            let item = json["item"] as? [String: Any]
            // Function calls are output items too, but never own speaker audio.
            guard (item?["type"] as? String) == "message",
                  let itemID = item?["id"] as? String else { return nil }
            return .outputItemAdded(itemID: itemID)
        case "response.output_audio.delta", "response.audio.delta":
            guard let base64 = json["delta"] as? String,
                  let data = Data(base64Encoded: base64) else { return nil }
            return .audioDelta(data)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = json["delta"] as? String else { return nil }
            return .outputTranscriptDelta(itemID: (json["item_id"] as? String) ?? "", delta: delta)
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return .outputTranscriptDone(
                itemID: (json["item_id"] as? String) ?? "",
                transcript: (json["transcript"] as? String) ?? ""
            )
        case "response.function_call_arguments.done":
            guard let callID = json["call_id"] as? String,
                  let name = json["name"] as? String else { return nil }
            return .functionCallDone(
                callID: callID,
                name: name,
                argumentsJSON: (json["arguments"] as? String) ?? "{}"
            )
        case "response.done":
            let response = json["response"] as? [String: Any]
            let responseID = (response?["id"] as? String) ?? ""
            return .responseDone(
                responseID: responseID,
                status: (response?["status"] as? String) ?? "unknown",
                usage: (response?["usage"] as? [String: Any]).flatMap {
                    RealtimeVoiceUsage(responseID: responseID, usage: $0)
                }
            )
        case "error":
            let error = json["error"] as? [String: Any]
            return .serverError(
                message: (error?["message"] as? String) ?? "The voice service reported an error."
            )
        default:
            return .ignored(type: type)
        }
    }

    static func appendAudioPayload(_ pcm16: Data) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()]
    }

    static func messagePayload(role: String, text: String) -> [String: Any] {
        // The API takes earlier assistant turns as text items, so a resumed
        // conversation can carry what the tutor already said.
        let contentType = role == "assistant" ? "output_text" : "input_text"
        return [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": role,
                "content": [["type": contentType, "text": text]],
            ] as [String: Any],
        ]
    }

    static func functionOutputPayload(callID: String, output: String) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output,
            ],
        ]
    }

    static func responseCreatePayload(eventID: String) -> [String: Any] {
        ["type": "response.create", "event_id": eventID]
    }

    static let responseCancelPayload: [String: Any] = ["type": "response.cancel"]

    static func truncatePayload(itemID: String, audioEndMs: Int) -> [String: Any] {
        [
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": 0,
            "audio_end_ms": max(0, audioEndMs),
        ]
    }

    static func responseCreateErrorEventID(in json: [String: Any]) -> String? {
        guard (json["type"] as? String) == "error",
              let error = json["error"] as? [String: Any] else { return nil }
        return error["event_id"] as? String
    }

    static func encodedText(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeVoiceSessionError.encodingFailed
        }
        return text
    }
}

/// Serializes response control the way OpenAI's Agents SDK transport does:
/// repeated create/cancel requests are coalesced until the server acknowledges
/// the active response, so benign protocol errors never look like a dead session.
struct OpenAIRealtimeResponseSequencer: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case createRequested(eventID: String)
        case active
        case cancelRequested
    }

    enum Action: Equatable, Sendable {
        case create(eventID: String)
        case cancel
    }

    private(set) var phase: Phase = .idle
    private var hasPendingCreate = false

    mutating func requestCreate() -> Action? {
        hasPendingCreate = true
        return dispatchPendingCreateIfPossible()
    }

    mutating func requestCancel() -> Action? {
        guard phase == .active else { return nil }
        phase = .cancelRequested
        return .cancel
    }

    mutating func responseCreated() {
        phase = .active
    }

    mutating func responseDone() -> Action? {
        phase = .idle
        return dispatchPendingCreateIfPossible()
    }

    mutating func responseCreateFailed(eventID: String?) -> Action? {
        guard case .createRequested(let pendingEventID) = phase,
              eventID == nil || eventID == pendingEventID else { return nil }
        phase = .idle
        return dispatchPendingCreateIfPossible()
    }

    mutating func reset() {
        phase = .idle
        hasPendingCreate = false
    }

    private mutating func dispatchPendingCreateIfPossible() -> Action? {
        guard phase == .idle, hasPendingCreate else { return nil }
        hasPendingCreate = false
        let eventID = "foreverlm_response_create_\(UUID().uuidString.lowercased())"
        phase = .createRequested(eventID: eventID)
        return .create(eventID: eventID)
    }
}

enum RealtimeVoiceSessionError: LocalizedError, Equatable {
    case notConnected
    case encodingFailed
    case connectionTimedOut
    case startupAudioBufferExceeded
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The voice session is not connected."
        case .encodingFailed:
            return "Could not encode a voice event."
        case .connectionTimedOut:
            return "The voice service did not finish connecting."
        case .startupAudioBufferExceeded:
            return "The voice service took too long to connect while listening."
        case .serverRejected(let message):
            return message
        }
    }
}
