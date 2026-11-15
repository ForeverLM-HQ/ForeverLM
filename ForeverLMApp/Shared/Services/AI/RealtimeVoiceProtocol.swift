import Foundation

// Voice mode's wire protocol: OpenAI Realtime, speech to speech, over WebRTC.
// It came back on 2026-11-07 (product owner, 2026-11-07: "now we actually have
// free API credits from OpenAI as part of our plan ... we should 100% implement
// the real-time voice mode again"). The proxy mints a short-lived client secret
// on the company's OpenAI account (`ManagedAI.mintRealtimeVoiceSecret`), so no
// company key reaches a device and the learner pays nothing. A learner who
// stores their own OpenAI key (`ManagedAI.ownOpenAIVoiceKey`) has
// the app mint the same secret straight with OpenAI on it, and pays OpenAI. This is the one
// model route that does not go through OpenRouter, which serves no
// speech-to-speech model.
//
// Everything runs on the realtime API alone, as OpenAI's guide lays it out
// (product owner, 2026-11-07: "Should all just call the real-time voice API, not
// do any sneaky text-to-speech or speech-to-text ... simplify the code and just
// follow OpenAI's documentation closely"): the learner's audio goes up a WebRTC
// track and the model's comes down one; the server detects turns, handles
// interruptions and trims unheard audio. The learner's words are transcribed by
// OpenAI on the same call, for the saved chat only (product owner, 2026-11-15:
// "it always just says spoken"; he had declined this on 2026-11-11). What the model says comes with its audio
// (`response.output_audio_transcript.*`) and is kept for the saved chat only;
// nothing is shown as text while the conversation runs.
//
// The Mac and the iPhone share this file, `RealtimeVoiceSession` (the call) and
// `RealtimeVoiceController` (the conversation); each platform brings its audio
// permission and session (`RealtimeVoicePlatformAudio`) and its screens.

/// What voice mode runs on: one model, the learner's pick of voice, nothing on
/// the learner's bill.
enum RealtimeVoiceDefaults {
    static let model = AIModelDefaults.realtimeVoiceModel
    /// OpenAI's recommended voice for the realtime models, and the one a
    /// conversation speaks in until the learner picks another.
    static let voice = "marin"
    /// The voices the realtime models speak in (OpenAI's list; the speech
    /// models' fable, nova and onyx are not among them), recommended first.
    static let voices = [
        "marin", "cedar", "alloy", "ash", "ballad",
        "coral", "echo", "sage", "shimmer", "verse",
    ]

    /// The voice a conversation speaks in: the stored pick when the realtime
    /// models still offer it, else the default.
    static func resolvedVoice(_ stored: String?) -> String {
        guard let stored, voices.contains(stored) else { return voice }
        return stored
    }

    /// "Marin", as the pickers list it.
    static func voiceLabel(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// A usage-ledger model id that voice mode ran on ("gpt-realtime-2.1",
    /// "openai/gpt-realtime-2.1-mini"). AI Usage reads these as paid by
    /// ForeverLM's credits rather than the learner's key.
    static func isVoiceModeModel(_ model: String) -> Bool {
        let id = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return id.hasPrefix("gpt-realtime")
    }
}

/// The events the controller consumes, decoded from OpenAI's server events.
enum RealtimeVoiceServerEvent: Equatable {
    case sessionReady
    /// The server heard the learner start talking. Over WebRTC it stops and
    /// trims the reply itself.
    case speechStarted
    /// The learner's turn ended; the server answers it on its own.
    case speechStopped(itemID: String)
    /// OpenAI's own transcript of one spoken learner turn, from the same call.
    /// It arrives after the turn ended, often once the reply has begun.
    case inputTranscriptDone(itemID: String, transcript: String)
    case responseCreated(responseID: String)
    case outputItemAdded(itemID: String)
    /// The model's audio began playing on the learner's device.
    case outputAudioStarted
    /// The model's audio finished playing: every buffered word was heard.
    case outputAudioStopped
    /// The model's audio was cut off by the learner and the rest thrown away.
    case outputAudioCleared
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

/// Server `error` events nobody should be shown: protocol races the
/// conversation recovers from by itself. The wire gives them no distinguishing
/// code, only the message.
enum RealtimeVoiceServerErrorDisposition {
    private static let benignFragments = [
        "already has an active response",
        "cancellation failed: no active response found",
    ]

    static func isBenign(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return benignFragments.contains { normalized.contains($0) }
    }
}

/// OpenAI Realtime's payloads and server-event decoding.
enum OpenAIRealtimeWire {
    /// The session the proxy mints the client secret with (its type and model
    /// are the proxy's). Turn detection is OpenAI's semantic VAD at low
    /// eagerness, which "will let the user take their time to speak": it ends
    /// the learner's turn when what they said sounds finished, waiting up to
    /// eight seconds through a pause, instead of after half a second of
    /// silence. A learner recalling a card's answer pauses to think, and server
    /// VAD at 500 ms answered the first half of their answer and was then cut
    /// off by the second (a car review, 2026-11-11: 13 of 33 spoken turns got
    /// no reply, most replies stopped mid-sentence). The learner can still
    /// interrupt; over WebRTC the server stops and trims the reply when they
    /// do. OpenAI's far-field noise reduction cleans the microphone before turn
    /// detection and the model hear it, so road and room noise is not taken
    /// for speech: phones on a dashboard, car microphones and laptop
    /// microphones are all far from the mouth. The learner's words are
    /// transcribed by OpenAI on the same call (`gpt-4o-mini-transcribe`) only so
    /// the saved chat holds what they said (2026-11-15: "it always just says
    /// spoken"). The transcript is never shown while talking and the realtime
    /// model still hears the audio itself, not this text.
    static func sessionConfiguration(
        instructions: String,
        tools: [[String: Any]],
        voice: String,
        typedOnly: Bool = false
    ) -> [String: Any] {
        // Foundation can bridge a Swift `Double` through its binary expansion
        // when serializing an untyped dictionary, and OpenAI constrains decimal
        // precision on these fields, so they are exact decimal numbers.
        let retentionRatio = NSDecimalNumber(mantissa: 8, exponent: -1, isNegative: false)
        let turnDetection: Any = typedOnly
            ? NSNull()
            : [
                "type": "semantic_vad",
                "eagerness": "low",
                "create_response": true,
                "interrupt_response": true,
            ] as [String: Any]
        let noiseReduction: Any = typedOnly ? NSNull() : ["type": "far_field"]
        return [
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
                    // Gym mode sends text and asks for each response itself.
                    // Explicit null matters: omitting this field restores the
                    // server-VAD default and lets noise split spoken replies.
                    "turn_detection": turnDetection,
                    "noise_reduction": noiseReduction,
                    "transcription": ["model": "gpt-4o-mini-transcribe"] as [String: Any],
                ] as [String: Any],
                "output": ["voice": voice],
            ] as [String: Any],
            "tools": tools,
            "tool_choice": "auto",
        ]
    }

    static func decodeServerEvent(_ json: [String: Any]) -> RealtimeVoiceServerEvent? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "session.created", "session.updated":
            return .sessionReady
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped(itemID: (json["item_id"] as? String) ?? "")
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = json["item_id"] as? String else { return nil }
            return .inputTranscriptDone(itemID: itemID, transcript: (json["transcript"] as? String) ?? "")
        case "response.created":
            let response = json["response"] as? [String: Any]
            return .responseCreated(responseID: (response?["id"] as? String) ?? "")
        case "response.output_item.added":
            let item = json["item"] as? [String: Any]
            // Function calls are output items too, but never speak.
            guard (item?["type"] as? String) == "message",
                  let itemID = item?["id"] as? String else { return nil }
            return .outputItemAdded(itemID: itemID)
        case "output_audio_buffer.started":
            return .outputAudioStarted
        case "output_audio_buffer.stopped":
            return .outputAudioStopped
        case "output_audio_buffer.cleared":
            return .outputAudioCleared
        case "response.output_audio_transcript.delta":
            guard let delta = json["delta"] as? String else { return nil }
            return .outputTranscriptDelta(itemID: (json["item_id"] as? String) ?? "", delta: delta)
        case "response.output_audio_transcript.done":
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
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The voice call is not connected."
        case .encodingFailed:
            return "Could not encode a voice event."
        case .connectionTimedOut:
            return "The voice service did not finish connecting."
        case .serverRejected(let message):
            return message
        }
    }
}
