import Combine
import Foundation
import OSLog

/// What a platform does around a voice call that WebRTC does not: ask for the
/// microphone, on the iPhone take the audio session from narration and other
/// players, and on the Mac say when the default speaker or microphone changes.
/// WebRTC captures, plays and cancels echo itself.
protocol RealtimeVoicePlatformAudio: AnyObject, Sendable {
    /// Throws a learner-readable error when the microphone cannot be used.
    /// `onPreempted` is called if something else takes the audio for good.
    /// `onDevicesChanged` is called when the call should move to other audio
    /// devices that WebRTC will not move it to itself.
    func prepare(
        onPreempted: @escaping @Sendable () -> Void,
        onDevicesChanged: @escaping @Sendable () -> Void
    ) async throws
    func finish() async
}

/// One voice conversation on OpenAI Realtime, over WebRTC
/// (`RealtimeVoiceSession`). Shared by the Mac and the iPhone; each passes its
/// platform audio and saves the conversation in `onFinished` the way its typed
/// chats are saved.
///
/// The server runs the conversation, as OpenAI's guide intends: it detects when
/// the learner starts and stops talking, answers on its own, and when the
/// learner talks over a reply it stops the reply and trims what was not heard.
/// The controller only starts the call, answers tool calls, follows the
/// server's events for the status line, and keeps what ForeverLM said for the
/// saved chat. If the call drops (the network, OpenAI's hour limit), another is
/// opened with what ForeverLM had said so far; if that fails, Resume does it.
@MainActor
final class RealtimeVoiceController: ObservableObject {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoice")
    private static let recoveryDelays: [Double] = [0.5, 2, 5]

    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
        case ending
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = ""
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isTutorWorking = false
    /// What the conversation runs on, once loaded.
    @Published private(set) var brief: RealtimeVoiceBrief?
    /// The title from the moment the conversation is asked for.
    @Published private(set) var title: String?
    /// The one source a source conversation is about; nil for the assistant.
    var source: RealtimeVoiceSource? { brief?.source }
    @Published private(set) var opening: RealtimeVoiceOpening = .talk
    @Published var errorMessage: String?
    /// Signed out is the one start failure the learner fixes in place.
    @Published var needsSignIn = false
    let microphoneLevel = VoiceMicrophoneLevel()

    /// What was said, for the saved chat: ForeverLM's words as the realtime
    /// model gave them with its audio, and a mark for each time the learner
    /// spoke (their words are never transcribed). Never shown while talking.
    private(set) var transcript: [RealtimeVoiceTurn] = []

    var isActive: Bool { phase != .idle }
    var startedAt: Date?

    /// A conversation that ended with something said in it.
    struct Finished {
        let title: String
        /// The source of a source conversation; nil for the assistant.
        let source: RealtimeVoiceSource?
        /// Every source the conversation read, the source conversation's first.
        let sourceIDs: [String]
        let turns: [RealtimeVoiceTurn]
        let startedAt: Date
        /// The answers the tutor graded (`record_answer`); empty for a talk.
        var answers: [RealtimeVoiceAnswerRecord] = []
    }

    /// Called once per conversation in which ForeverLM said anything, after it ends.
    var onFinished: ((Finished) -> Void)?

    private let platformAudio: RealtimeVoicePlatformAudio
    private let readVoice: @Sendable () async -> String?
    /// Fixed for a whole conversation, reconnects included.
    private var voice = RealtimeVoiceDefaults.voice
    private var session: RealtimeVoiceSession?
    private var lifecycle = UUID()
    private var eventTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var hasAudio = false
    /// The model the proxy minted the call for; usage is recorded under it.
    private var activeModel = RealtimeVoiceDefaults.model
    /// One AI Usage row per conversation: every reply's usage carries this.
    private var activityID = "voice-\(UUID().uuidString.lowercased())"

    // Per-call state.
    private var isSpeaking = false
    private var responseInFlight = false
    private var currentOutputItemID: String?
    private var endsAfterReply = false
    private var endFallbackTask: Task<Void, Never>?
    /// The audio devices changed while a call was opening; it reopens once live.
    private var devicesChangedWhileConnecting = false

    /// `readVoice` answers the learner's voice pick (the synced
    /// `RealtimeVoiceDefaults.voicePreferenceKey`), read at each start so a
    /// change in Settings applies to the next conversation.
    init(
        platformAudio: RealtimeVoicePlatformAudio,
        readVoice: @escaping @Sendable () async -> String?
    ) {
        self.platformAudio = platformAudio
        self.readVoice = readVoice
    }

    // MARK: - Starting and ending

    /// Starts a conversation about one source. `load` reads its text (from disk
    /// or from sync) while the screen already says what is being opened; a
    /// failure to load is shown there like any other.
    func start(
        title: String,
        opening: RealtimeVoiceOpening,
        load: @escaping @Sendable () async throws -> RealtimeVoiceSource
    ) async {
        await start(title: title, opening: opening, status: "Opening \u{201C}\(title)\u{201D}…") {
            let loaded = try await load()
            guard !loaded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RealtimeVoiceStartError.noText(title)
            }
            return await Task.detached(priority: .userInitiated) {
                RealtimeVoiceBrief.source(loaded, opening: opening)
            }.value
        }
    }

    /// Starts any conversation: `load` builds its brief (a source's text, or the
    /// assistant's picture of the learner's day) while the screen says `status`.
    func start(
        title: String,
        opening: RealtimeVoiceOpening = .talk,
        status: String,
        load: @escaping @Sendable () async throws -> RealtimeVoiceBrief
    ) async {
        guard phase == .idle || phase == .failed else { return }
        if phase == .failed { await tearDown() }
        let id = UUID()
        lifecycle = id
        self.title = title
        self.opening = opening
        brief = nil
        transcript = []
        errorMessage = nil
        needsSignIn = false
        startedAt = Date()
        activityID = "voice-\(UUID().uuidString.lowercased())"
        phase = .connecting
        statusText = status
        let loaded: RealtimeVoiceBrief
        do {
            loaded = try await load()
        } catch {
            guard lifecycle == id else { return }
            fail(error.localizedDescription)
            return
        }
        let chosenVoice = RealtimeVoiceDefaults.resolvedVoice(await readVoice())
        guard lifecycle == id else { return }
        voice = chosenVoice
        brief = loaded
        await begin()
    }

    /// Resume after a failure: a fresh call that carries what ForeverLM said.
    func resume() async {
        guard phase == .failed, brief != nil else { return }
        await tearDown()
        await begin()
    }

    func resumeAfterSignIn() async {
        needsSignIn = false
        guard brief != nil else { return }
        await begin()
    }

    func cancelSignIn() {
        needsSignIn = false
        brief = nil
        title = nil
    }

    /// Ends the conversation and hands what was said to `onFinished`.
    func end() async {
        guard phase != .idle, phase != .ending else { return }
        phase = .ending
        statusText = "Ending…"
        await tearDown()
        phase = .idle
        statusText = ""
        isTutorWorking = false
        microphoneLevel.set(0)
        guard let brief, let startedAt,
              transcript.contains(where: { $0.role == .tutor && !$0.text.isEmpty }) else { return }
        let sourceIDs = await brief.toolbox.openedSourceIDs()
        let answers = await brief.toolbox.recordedAnswers()
        onFinished?(Finished(
            title: brief.title,
            source: brief.source,
            sourceIDs: sourceIDs,
            turns: transcript.filter { !$0.text.isEmpty },
            startedAt: startedAt,
            answers: answers
        ))
    }

    func toggleMicrophoneMuted() {
        isMicrophoneMuted.toggle()
        session?.setMicrophoneMuted(isMicrophoneMuted)
        if isMicrophoneMuted { microphoneLevel.set(0) }
        if phase == .live, !isSpeaking, !responseInFlight {
            statusText = isMicrophoneMuted ? "Muted" : "Listening"
        }
    }

    private func begin() async {
        guard brief != nil else { return }
        let id = UUID()
        lifecycle = id
        errorMessage = nil
        needsSignIn = false
        phase = .connecting
        statusText = "Connecting…"
        resetCallState()

        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        guard lifecycle == id else { return }
        guard signedIn else {
            needsSignIn = true
            phase = .idle
            statusText = ""
            return
        }

        do {
            if !hasAudio {
                try await platformAudio.prepare(
                    onPreempted: { [weak self] in
                        Task { @MainActor in await self?.end() }
                    },
                    onDevicesChanged: { [weak self] in
                        Task { @MainActor in self?.audioDevicesChanged() }
                    }
                )
                hasAudio = true
            }
            guard lifecycle == id else { return }
            devicesChangedWhileConnecting = false
            try await connect(isResume: !transcript.isEmpty, lifecycleID: id)
        } catch {
            guard lifecycle == id else { return }
            fail(Self.message(for: error))
            return
        }
        guard lifecycle == id else { return }
        phase = .live
        if statusText == "Connecting…" { statusText = "Listening" }
        Self.logger.info("Voice live: \(self.brief?.source?.id ?? "assistant", privacy: .public)")
        reopenIfDevicesChangedWhileConnecting()
    }

    /// Mints a secret with the whole session on it, opens the call, and starts
    /// the conversation: a fresh one with its kickoff, a resumed one with what
    /// ForeverLM had said.
    private func connect(isResume: Bool, lifecycleID: UUID) async throws {
        guard let brief else { return }
        let configuration = OpenAIRealtimeWire.sessionConfiguration(
            instructions: brief.instructions,
            tools: brief.toolbox.toolDefinitions + [RealtimeVoiceTutor.endTool],
            voice: voice
        )
        let secret = try await ManagedAI.mintRealtimeVoiceSecret(session: configuration)
        guard lifecycle == lifecycleID else { return }
        activeModel = secret.model
        let level = microphoneLevel
        let session = RealtimeVoiceSession(onMicrophoneLevel: { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                level.set(self.isMicrophoneMuted ? 0 : value)
            }
        })
        let stream = try await session.connect(secret: secret.value, microphoneMuted: isMicrophoneMuted)
        guard lifecycle == lifecycleID else {
            session.close()
            return
        }
        self.session = session
        startEventLoop(stream, lifecycleID: lifecycleID)

        if isResume {
            for item in RealtimeVoiceTutor.resumeItems(from: transcript) {
                try session.createMessage(role: item.role, text: item.text)
            }
            try session.createMessage(role: "user", text: RealtimeVoiceTutor.resumeNote)
        } else {
            try session.createMessage(role: "user", text: brief.kickoff)
        }
        try session.createResponse()
    }

    private func tearDown() async {
        lifecycle = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        eventTask?.cancel()
        eventTask = nil
        endFallbackTask?.cancel()
        endFallbackTask = nil
        session?.close()
        session = nil
        if hasAudio {
            hasAudio = false
            await platformAudio.finish()
        }
        resetCallState()
    }

    private func fail(_ message: String) {
        Self.logger.error("Voice failed: \(message, privacy: .public)")
        errorMessage = message
        phase = .failed
        statusText = ""
        isTutorWorking = false
        microphoneLevel.set(0)
        recoveryTask?.cancel()
        recoveryTask = nil
        eventTask?.cancel()
        eventTask = nil
        session?.close()
        session = nil
        if hasAudio {
            hasAudio = false
            let platformAudio = self.platformAudio
            Task { await platformAudio.finish() }
        }
    }

    private func resetCallState() {
        isSpeaking = false
        responseInFlight = false
        currentOutputItemID = nil
        endsAfterReply = false
        endFallbackTask?.cancel()
        endFallbackTask = nil
        isTutorWorking = false
    }

    static func message(for error: Error) -> String {
        if let service = error as? ManagedAI.ServiceError {
            return service.message
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Voice needs an internet connection."
            case .timedOut:
                return "The voice service took too long to answer. Try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Recovery

    private func scheduleRecovery(after message: String, status: String = "Reconnecting…") {
        guard phase == .live, recoveryTask == nil else { return }
        Self.logger.notice("Voice call reopening: \(message, privacy: .public)")
        if let itemID = currentOutputItemID, let index = transcript.lastIndex(where: { $0.id == itemID }) {
            transcript[index].wasInterrupted = true
        }
        phase = .reconnecting
        statusText = status
        recoveryTask = Task { @MainActor [weak self] in
            await self?.recover()
        }
    }

    private func recover() async {
        let id = UUID()
        lifecycle = id
        for (attempt, delay) in Self.recoveryDelays.enumerated() {
            eventTask?.cancel()
            eventTask = nil
            session?.close()
            session = nil
            resetCallState()
            if attempt > 0 { statusText = "Reconnecting (try \(attempt + 1))…" }
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard lifecycle == id, phase == .reconnecting else { return }
            do {
                devicesChangedWhileConnecting = false
                try await connect(isResume: true, lifecycleID: id)
                guard lifecycle == id else { return }
                recoveryTask = nil
                phase = .live
                statusText = "Listening"
                errorMessage = nil
                reopenIfDevicesChangedWhileConnecting()
                return
            } catch {
                guard lifecycle == id else { return }
                if let service = error as? ManagedAI.ServiceError,
                   service.isInvalidSession || service.code == "realtime_daily_limit"
                    || service.code == "company_spend_cap_reached" || service.isAccountDisabled {
                    recoveryTask = nil
                    fail(service.message)
                    return
                }
                Self.logger.error("Voice reconnect attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        recoveryTask = nil
        fail("The voice connection dropped and could not come back. Resume to keep going.")
    }

    /// The Mac's default speaker or microphone changed: AirPods put in, taken
    /// out, or switched over from the iPhone. WebRTC on the Mac plays and
    /// records on the devices that were the default when the call opened and
    /// never follows a change (its iPhone audio follows the route itself), so
    /// the call is reopened on the new ones, carrying what ForeverLM said, the
    /// way a dropped call is.
    private func audioDevicesChanged() {
        switch phase {
        case .live:
            scheduleRecovery(after: "the default audio devices changed", status: "Switching audio…")
        case .connecting, .reconnecting:
            devicesChangedWhileConnecting = true
        case .idle, .ending, .failed:
            break
        }
    }

    private func reopenIfDevicesChangedWhileConnecting() {
        guard devicesChangedWhileConnecting else { return }
        devicesChangedWhileConnecting = false
        audioDevicesChanged()
    }

    // MARK: - Server events

    private func startEventLoop(_ stream: AsyncStream<RealtimeVoiceServerEvent>, lifecycleID: UUID) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            var lastError: String?
            for await event in stream {
                guard let self, self.lifecycle == lifecycleID else { return }
                if case .serverError(let message) = event { lastError = message }
                await self.handle(event)
            }
            // The stream finished: the call is gone.
            guard let self, self.lifecycle == lifecycleID, !Task.isCancelled else { return }
            self.scheduleRecovery(after: lastError ?? "call ended")
        }
    }

    private func handle(_ event: RealtimeVoiceServerEvent) async {
        switch event {
        case .sessionReady, .ignored:
            break

        case .speechStarted:
            // Over WebRTC the server stops a reply the learner talks over and
            // trims what was not heard; the controller only follows along.
            if let itemID = currentOutputItemID, isSpeaking,
               let index = transcript.lastIndex(where: { $0.id == itemID }) {
                transcript[index].wasInterrupted = true
            }
            statusText = "Listening"

        case .speechStopped:
            transcript.append(RealtimeVoiceTurn(
                id: "learner-\(UUID().uuidString)",
                role: .learner,
                text: RealtimeVoiceTurn.spokenMark
            ))
            isTutorWorking = true
            statusText = "Thinking"

        case .responseCreated:
            responseInFlight = true
            isTutorWorking = true
            if !isSpeaking { statusText = "Thinking" }

        case .outputItemAdded(let itemID):
            currentOutputItemID = itemID
            if !transcript.contains(where: { $0.id == itemID }) {
                transcript.append(RealtimeVoiceTurn(id: itemID, role: .tutor, text: ""))
            }

        case .outputAudioStarted:
            isSpeaking = true
            isTutorWorking = false
            statusText = "Speaking"

        case .outputAudioStopped, .outputAudioCleared:
            isSpeaking = false
            if responseInFlight {
                statusText = "Thinking"
            } else {
                isTutorWorking = false
                statusText = isMicrophoneMuted ? "Muted" : "Listening"
                if endsAfterReply { await end() }
            }

        case .outputTranscriptDelta(let itemID, let delta):
            guard let index = transcript.lastIndex(where: { $0.id == itemID }) else { return }
            transcript[index].text += delta

        case .outputTranscriptDone(let itemID, let text):
            guard let index = transcript.lastIndex(where: { $0.id == itemID }) else { return }
            let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty { transcript[index].text = final }

        case .functionCallDone(let callID, let name, let argumentsJSON):
            await runTool(callID: callID, name: name, argumentsJSON: argumentsJSON)

        case .responseDone(_, let status, let usage):
            responseInFlight = false
            if let usage {
                ManagedAI.reportRealtimeVoiceUsage(
                    usage,
                    model: activeModel,
                    sourceTitle: brief?.source?.title ?? title,
                    activityID: activityID
                )
            }
            if status == "failed" {
                errorMessage = "ForeverLM couldn't answer that. Say it again."
            }
            if !isSpeaking {
                isTutorWorking = false
                statusText = isMicrophoneMuted ? "Muted" : "Listening"
            }
            if endsAfterReply { scheduleEndFallback(after: isSpeaking ? 10 : 2.5) }

        case .serverError(let message):
            // A call-ending error arrives here too, just before the stream
            // finishes, and recovery takes it. Request-scoped ones are shown.
            guard phase == .live else { return }
            errorMessage = message
        }
    }

    /// The goodbye ends the conversation when its audio has played
    /// (`output_audio_buffer.stopped`). If that never comes, or came before
    /// the goodbye's response finished, the conversation still ends after `seconds`.
    private func scheduleEndFallback(after seconds: Double) {
        endFallbackTask?.cancel()
        endFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
            guard !Task.isCancelled, let self, self.endsAfterReply, !self.isSpeaking else { return }
            await self.end()
        }
    }

    private func runTool(callID: String, name: String, argumentsJSON: String) async {
        let output: String
        var asksForReply = true
        if name == RealtimeVoiceTutor.endToolName {
            output = #"{"ok":true}"#
            asksForReply = false
            endsAfterReply = true
        } else if let toolbox = brief?.toolbox {
            isTutorWorking = true
            output = await toolbox.run(name: name, argumentsJSON: argumentsJSON)
        } else {
            output = #"{"error":"Unknown tool."}"#
        }
        guard let session else { return }
        do {
            try session.createFunctionOutput(callID: callID, output: output)
            if asksForReply { try session.createResponse() }
        } catch {
            Self.logger.error("Tool output failed: \(error.localizedDescription, privacy: .public)")
            // An answer too large to send is answered with a short refusal, so
            // the model is never left waiting on its tool.
            try? session.createFunctionOutput(callID: callID, output: #"{"error":"That was too long to read out. Ask for something narrower."}"#)
            if asksForReply { try? session.createResponse() }
        }
    }
}

enum RealtimeVoiceStartError: LocalizedError {
    case noText(String)

    var errorDescription: String? {
        switch self {
        case .noText(let title):
            return "\u{201C}\(title)\u{201D} has no text on this device yet, so there is nothing to talk about."
        }
    }
}
