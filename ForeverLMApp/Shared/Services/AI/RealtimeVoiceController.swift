import Combine
import Foundation
import OSLog

/// What a platform's audio graph reports to the conversation.
enum RealtimeVoiceAudioEvent: Sendable {
    case inputLevel(Float)
    case playbackStarted
    case playbackDrained
    /// The system took the audio (a call, Siri, another app). Speech stops.
    case interruptionBegan
    /// Audio is back; the graph is running again.
    case interruptionEnded
    /// The graph could not be restored. The conversation fails with this.
    case failed(String)
}

/// A platform's full-duplex audio: the microphone as 24 kHz mono PCM16 in
/// ~40 ms chunks, and the tutor's PCM16 replies out, with echo cancellation.
/// It restores itself after route changes and interruptions and reports what
/// happened; the conversation never touches AVFoundation.
protocol RealtimeVoiceAudio: AnyObject, Sendable {
    /// Asks for the microphone if needed and starts both directions. Throws a
    /// learner-readable error when it cannot.
    func start(
        microphoneMuted: Bool,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (RealtimeVoiceAudioEvent) -> Void
    ) async throws
    func stop() async
    func setMicrophoneMuted(_ muted: Bool)
    func enqueuePlayback(_ pcm16: Data)
    /// A new reply begins: playback may start again after an interruption.
    func beginResponsePlayback()
    /// A new reply item begins: its played-time clock restarts at zero.
    func resetPlaybackClock()
    /// Stops the speaker now and says how much of the current item was heard.
    func stopPlayback() async -> Int
}

/// One voice conversation about one source, on OpenAI Realtime. Shared by the
/// Mac and the iPhone; each passes its audio graph and saves the transcript in
/// `onFinished` the way its typed chats are saved.
///
/// Robustness, in the order things go wrong:
/// - The microphone starts before the socket, and audio is kept until the
///   session is configured, so the first words are never lost.
/// - A refused transcription model is retried once with the fallback model.
/// - A socket that drops mid-conversation is replaced with backoff (OpenAI also
///   ends sessions at their hour limit). The replacement gets the conversation
///   so far, the microphone keeps buffering through the gap, and a reply owed
///   when it dropped is asked for again.
/// - Barge-in stops the speaker at once and trims the unheard tail on the server,
///   so the tutor knows exactly what the learner heard.
/// - A system interruption pauses speech; a graph that cannot come back fails
///   the conversation with Resume, which keeps the transcript.
@MainActor
final class RealtimeVoiceController: ObservableObject {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoice")
    private static let recoveryDelays: [Double] = [0.4, 1, 2, 4, 8]

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
    @Published private(set) var transcript: [RealtimeVoiceTurn] = []
    /// The words in flight: the learner's as they speak, then the tutor's.
    @Published private(set) var caption: String?
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
    }

    /// Called once per conversation that had any spoken line, after it ends.
    var onFinished: ((Finished) -> Void)?

    private let makeAudio: () -> RealtimeVoiceAudio
    private let readVoice: @Sendable () async -> String?
    /// Fixed for a whole conversation, reconnects included: OpenAI keeps a
    /// session's voice once it has spoken, and a resumed one should sound the same.
    private var voice = RealtimeVoiceDefaults.voice
    private var audio: RealtimeVoiceAudio?
    private var session = RealtimeVoiceSession()
    private var lifecycle = UUID()
    private var eventTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureContinuation: AsyncStream<Data>.Continuation?
    private var recoveryTask: Task<Void, Never>?
    private var transcriptionModel = RealtimeVoiceDefaults.transcriptionModel
    private var hasBeenLive = false
    /// The model the proxy minted the session for; usage is recorded under it.
    private var activeModel = RealtimeVoiceDefaults.model
    /// One AI Usage row per conversation: every reply's usage carries this.
    private var activityID = "voice-\(UUID().uuidString.lowercased())"

    // Per-turn state.
    private var playbackGate = RealtimePlaybackGate()
    private var responseInFlight = false
    private var speakerIsPlaying = false
    private var currentOutputItemID: String?
    private var interruptedItemIDs: Set<String> = []
    /// Learner lines whose words are still being transcribed, oldest first.
    private var pendingLearnerTurnIDs: [String] = []
    private var learnerCaptionByItem: [String: String] = [:]
    private var endsAfterReply = false

    /// `readVoice` answers the learner's voice pick (the synced
    /// `RealtimeVoiceDefaults.voicePreferenceKey`), read at each start so a
    /// change in Settings applies to the next conversation.
    init(
        makeAudio: @escaping () -> RealtimeVoiceAudio,
        readVoice: @escaping @Sendable () async -> String?
    ) {
        self.makeAudio = makeAudio
        self.readVoice = readVoice
    }

    // MARK: - Starting and ending

    /// Starts a conversation about one source. `load` reads its text (from disk
    /// or from sync) while the cover already says what is being opened; a
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
        hasBeenLive = false
        activityID = "voice-\(UUID().uuidString.lowercased())"
        transcriptionModel = RealtimeVoiceDefaults.transcriptionModel
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

    /// Resume after a failure: a fresh session that carries the transcript.
    func resume() async {
        guard phase == .failed, brief != nil else { return }
        // A failure before the text loaded has nothing to resume; starting
        // again is the screen's job.
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

    /// Ends the conversation and hands its transcript to `onFinished`.
    func end() async {
        guard phase != .idle, phase != .ending else { return }
        phase = .ending
        statusText = "Ending…"
        await tearDown()
        phase = .idle
        statusText = ""
        caption = nil
        isTutorWorking = false
        microphoneLevel.set(0)
        guard let brief, let startedAt, transcript.contains(where: { !$0.text.isEmpty }) else { return }
        let sourceIDs = await brief.toolbox.openedSourceIDs()
        onFinished?(Finished(
            title: brief.title,
            source: brief.source,
            sourceIDs: sourceIDs,
            turns: transcript.filter { !$0.text.isEmpty },
            startedAt: startedAt
        ))
    }

    func toggleMicrophoneMuted() {
        isMicrophoneMuted.toggle()
        audio?.setMicrophoneMuted(isMicrophoneMuted)
        if isMicrophoneMuted { microphoneLevel.set(0) }
        if phase == .live, !speakerIsPlaying, !responseInFlight {
            statusText = "Listening"
        }
    }

    private func begin() async {
        guard let brief else { return }
        let id = UUID()
        lifecycle = id
        errorMessage = nil
        needsSignIn = false
        phase = .connecting
        statusText = "Connecting…"
        resetTurnState()

        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        guard lifecycle == id else { return }
        guard signedIn else {
            needsSignIn = true
            phase = .idle
            statusText = ""
            return
        }

        session = RealtimeVoiceSession()
        await session.beginBufferingAudio()
        do {
            try await startAudio()
        } catch {
            guard lifecycle == id else { return }
            fail(error.localizedDescription)
            return
        }
        guard lifecycle == id else { return }

        do {
            try await connect(isResume: !transcript.isEmpty, lifecycleID: id)
        } catch {
            guard lifecycle == id else { return }
            fail(Self.message(for: error))
            return
        }
        guard lifecycle == id else { return }
        hasBeenLive = true
        phase = .live
        statusText = "Listening"
        Self.logger.info("Voice live: \(brief.source?.id ?? "assistant", privacy: .public)")
    }

    /// Mints a secret, opens and configures a socket, and starts its event loop.
    /// A fresh conversation is kicked off; a resumed one gets its transcript.
    private func connect(isResume: Bool, lifecycleID: UUID) async throws {
        guard let brief else { return }
        let secret = try await ManagedAI.mintRealtimeVoiceSecret()
        guard lifecycle == lifecycleID else { return }
        activeModel = secret.model
        let stream = await session.connect(model: secret.model, secret: secret.value)
        startEventLoop(stream, lifecycleID: lifecycleID)
        do {
            try await session.configure(
                instructions: brief.instructions,
                tools: brief.toolbox.toolDefinitions + [RealtimeVoiceTutor.endTool],
                voice: voice,
                transcriptionModel: transcriptionModel
            )
            try await session.waitUntilReady()
        } catch let error as RealtimeVoiceSessionError {
            // A transcription model OpenAI no longer takes must not stop the
            // conversation: try the fallback once on a fresh socket.
            if case .serverRejected(let message) = error,
               message.lowercased().contains("transcri"),
               transcriptionModel != RealtimeVoiceDefaults.fallbackTranscriptionModel {
                Self.logger.notice("Transcription model refused; retrying with the fallback")
                transcriptionModel = RealtimeVoiceDefaults.fallbackTranscriptionModel
                eventTask?.cancel()
                await session.closeForReplacement()
                try await connect(isResume: isResume, lifecycleID: lifecycleID)
                return
            }
            throw error
        }
        guard lifecycle == lifecycleID else { return }

        if isResume {
            for item in RealtimeVoiceTutor.resumeItems(from: transcript) {
                try await session.createMessage(role: item.role, text: item.text)
            }
            // A learner line left unanswered when the connection dropped is
            // answered now; otherwise the tutor waits for the learner.
            if transcript.last?.role == .learner {
                try await session.createResponse()
            }
        } else {
            try await session.createMessage(role: "user", text: brief.kickoff)
            try await session.createResponse()
        }
    }

    private func startAudio() async throws {
        if audio == nil { audio = makeAudio() }
        guard let audio else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1_500))
        captureContinuation = continuation
        // One ordered consumer, so chunks reach the socket in capture order.
        // Recovery replaces the socket inside this same session actor, so the
        // lane never has to be rebuilt for a reconnect.
        let session = self.session
        captureTask = Task.detached(priority: .userInitiated) {
            for await chunk in stream {
                try? await session.appendAudio(chunk)
            }
        }
        try await audio.start(
            microphoneMuted: isMicrophoneMuted,
            onCapturedAudio: { chunk in continuation.yield(chunk) },
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleAudioEvent(event) }
            }
        )
    }

    private func tearDown() async {
        lifecycle = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        eventTask?.cancel()
        eventTask = nil
        captureContinuation?.finish()
        captureContinuation = nil
        captureTask?.cancel()
        captureTask = nil
        await session.close()
        if let audio {
            await audio.stop()
        }
        audio = nil
        resetTurnState()
    }

    private func fail(_ message: String) {
        Self.logger.error("Voice failed: \(message, privacy: .public)")
        errorMessage = message
        phase = .failed
        statusText = ""
        caption = nil
        isTutorWorking = false
        microphoneLevel.set(0)
        let audio = self.audio
        let session = self.session
        recoveryTask?.cancel()
        recoveryTask = nil
        eventTask?.cancel()
        eventTask = nil
        Task {
            await session.close()
            await audio?.stop()
        }
        self.audio = nil
        captureContinuation?.finish()
        captureContinuation = nil
        captureTask?.cancel()
        captureTask = nil
    }

    private func resetTurnState() {
        playbackGate = RealtimePlaybackGate()
        responseInFlight = false
        speakerIsPlaying = false
        currentOutputItemID = nil
        interruptedItemIDs = []
        pendingLearnerTurnIDs = []
        learnerCaptionByItem = [:]
        endsAfterReply = false
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

    private func scheduleRecovery(after message: String) {
        guard hasBeenLive, phase == .live || phase == .reconnecting, recoveryTask == nil else { return }
        Self.logger.notice("Voice connection dropped: \(message, privacy: .public)")
        // A reply cut off mid-sentence stays in the transcript as heard.
        if let itemID = currentOutputItemID,
           let index = transcript.lastIndex(where: { $0.id == itemID }) {
            transcript[index].wasInterrupted = true
        }
        phase = .reconnecting
        statusText = "Reconnecting…"
        caption = nil
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
            await session.closeForReplacement()
            resetTurnState()
            if attempt > 0 { statusText = "Reconnecting (try \(attempt + 1))…" }
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard lifecycle == id, phase == .reconnecting else { return }
            do {
                try await connect(isResume: true, lifecycleID: id)
                guard lifecycle == id else { return }
                recoveryTask = nil
                phase = .live
                statusText = "Listening"
                errorMessage = nil
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
            // The stream finished: the socket is gone.
            guard let self, self.lifecycle == lifecycleID, !Task.isCancelled else { return }
            if self.phase == .live {
                self.scheduleRecovery(after: lastError ?? "socket closed")
            }
        }
    }

    private func handle(_ event: RealtimeVoiceServerEvent) async {
        switch event {
        case .sessionReady, .ignored:
            break

        case .speechStarted:
            await bargeIn()
            if !isMicrophoneMuted { statusText = "Listening" }

        case .speechStopped:
            let id = "learner-\(UUID().uuidString)"
            pendingLearnerTurnIDs.append(id)
            transcript.append(RealtimeVoiceTurn(id: id, role: .learner, text: ""))
            isTutorWorking = true
            statusText = "Thinking"

        case .inputTranscriptDelta(let itemID, let delta):
            learnerCaptionByItem[itemID, default: ""] += delta
            caption = learnerCaptionByItem[itemID]
            if let id = pendingLearnerTurnIDs.first,
               let index = transcript.firstIndex(where: { $0.id == id }) {
                transcript[index].text = learnerCaptionByItem[itemID] ?? ""
            }

        case .inputTranscriptCompleted(let itemID, let text):
            learnerCaptionByItem[itemID] = nil
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = pendingLearnerTurnIDs.first {
                pendingLearnerTurnIDs.removeFirst()
                if let index = transcript.firstIndex(where: { $0.id == id }) {
                    if words.isEmpty {
                        transcript.remove(at: index)
                    } else {
                        transcript[index].text = words
                    }
                }
            } else if !words.isEmpty {
                transcript.append(RealtimeVoiceTurn(id: "learner-\(itemID)", role: .learner, text: words))
            }

        case .responseCreated:
            responseInFlight = true
            isTutorWorking = true
            playbackGate.beginResponse()
            audio?.beginResponsePlayback()
            if !speakerIsPlaying { statusText = "Thinking" }

        case .outputItemAdded(let itemID):
            currentOutputItemID = itemID
            audio?.resetPlaybackClock()
            if !transcript.contains(where: { $0.id == itemID }) {
                transcript.append(RealtimeVoiceTurn(id: itemID, role: .tutor, text: ""))
            }

        case .audioDelta(let data):
            guard playbackGate.acceptsAudio,
                  let itemID = currentOutputItemID,
                  !interruptedItemIDs.contains(itemID) else { return }
            audio?.enqueuePlayback(data)

        case .outputTranscriptDelta(let itemID, let delta):
            guard !interruptedItemIDs.contains(itemID),
                  let index = transcript.firstIndex(where: { $0.id == itemID }) else { return }
            transcript[index].text += delta
            caption = transcript[index].text

        case .outputTranscriptDone(let itemID, let text):
            guard !interruptedItemIDs.contains(itemID),
                  let index = transcript.firstIndex(where: { $0.id == itemID }) else { return }
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
                errorMessage = "The tutor couldn't answer that. Say it again."
            }
            if !speakerIsPlaying {
                isTutorWorking = false
                statusText = "Listening"
                if endsAfterReply { await end() }
            }

        case .serverError(let message):
            // Socket-ending errors arrive here too, just before the stream
            // finishes; recovery takes those. Request-scoped ones are shown.
            guard phase == .live else { return }
            errorMessage = message
        }
    }

    /// The learner started talking over the tutor: stop the speaker now, and
    /// trim what was not heard so the tutor knows what the learner heard.
    private func bargeIn() async {
        guard let audio else { return }
        let wasSpeaking = speakerIsPlaying || responseInFlight
        guard wasSpeaking else { return }
        playbackGate.interrupt()
        let heardMilliseconds = await audio.stopPlayback()
        speakerIsPlaying = false
        caption = nil
        if let itemID = currentOutputItemID {
            interruptedItemIDs.insert(itemID)
            if let index = transcript.firstIndex(where: { $0.id == itemID }) {
                transcript[index].wasInterrupted = true
                if transcript[index].text.isEmpty { transcript.remove(at: index) }
            }
            try? await session.truncateItem(itemID: itemID, audioEndMs: heardMilliseconds)
            currentOutputItemID = nil
        }
        // Server VAD cancels the response itself; this covers the race where
        // it had already finished generating but was still being played.
        try? await session.cancelResponse()
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
        do {
            try await session.createFunctionOutput(callID: callID, output: output)
            if asksForReply { try await session.createResponse() }
        } catch {
            Self.logger.error("Tool output failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Audio events

    private func handleAudioEvent(_ event: RealtimeVoiceAudioEvent) {
        guard phase == .connecting || phase == .live || phase == .reconnecting else { return }
        switch event {
        case .inputLevel(let level):
            microphoneLevel.set(isMicrophoneMuted ? 0 : level)
        case .playbackStarted:
            speakerIsPlaying = true
            isTutorWorking = false
            if phase == .live { statusText = "Speaking" }
        case .playbackDrained:
            speakerIsPlaying = false
            guard phase == .live else { return }
            if responseInFlight {
                statusText = "Thinking"
            } else {
                isTutorWorking = false
                caption = nil
                statusText = "Listening"
                if endsAfterReply { Task { await self.end() } }
            }
        case .interruptionBegan:
            Task { await self.bargeIn() }
            statusText = "Paused"
        case .interruptionEnded:
            if phase == .live { statusText = "Listening" }
        case .failed(let message):
            fail(message)
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
