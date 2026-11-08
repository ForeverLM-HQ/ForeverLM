import AVFoundation
import Combine
import Foundation
import OSLog
import Speech

/// The phone's voice conversation, turn by turn. Apple's speech recognition
/// hears the learner (`MobileVoiceCommandService`), the learner's own chat
/// model answers through the ordinary chat or review the conversation drives,
/// and the answer is spoken with Apple's speech synthesis
/// (`MobileReviewSpeechService`). Listening and speaking take turns under one
/// audio lease, so a reply is never heard by the microphone.
///
/// What it holds is today's memory review, spoken: the Memory screen's Review
/// by Voice, and the realtime assistant's hand-over when the learner asks for
/// their review (in CarPlay above all; `MobileRealtimeVoice.pendingMemoryReview`).
/// The review chat (`MobileMemoryReviewViewModel`) owns the cards and grading.
/// Talking about a source, and CarPlay's conversation, are voice mode on OpenAI
/// Realtime since 2026-11-07 (`MobileRealtimeVoice`); the two never run at once.
@MainActor
final class MobileVoiceConversationController: ObservableObject {
    static let shared = MobileVoiceConversationController()

    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "VoiceConversation")

    enum Phase: Equatable {
        case idle
        /// Reading what the conversation needs before its first turn.
        case connecting
        case live
        case ending
        /// The conversation could not start, or lost the microphone. The
        /// cover stays up with Resume until the learner acts.
        case failed
    }

    /// One line of the conversation, as the cover's transcript shows it once
    /// the conversation ends.
    struct VoiceTurn: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case assistant
        }

        let id: String
        let kind: Kind
        var text: String
    }

    @Published private(set) var phase: Phase = .idle
    /// "Listening", "Thinking", "Speaking", or what is being read while the
    /// conversation starts. CarPlay's voice template follows the first three.
    @Published private(set) var statusText = ""
    @Published private(set) var activeMemoryTarget: String?
    /// The conversation so far, oldest first. Kept after it ends, for the
    /// cover's transcript, until the next one starts.
    @Published private(set) var transcript: [VoiceTurn] = []
    /// The words in flight: what the microphone is hearing, then the reply
    /// being spoken.
    @Published private(set) var caption: String?
    /// A learner turn has been sent and its answer has not been spoken yet.
    @Published private(set) var isTutorWorking = false
    @Published private(set) var isMicrophoneMuted = false
    @Published var errorMessage: String?
    /// Being signed out is the one start failure the learner can fix from the
    /// cover, so it asks there with the real Sign in with Apple button.
    @Published var needsSignIn = false
    /// The orb's input level. Apple's recognizer reports no level, so it rests.
    let microphoneLevel = VoiceMicrophoneLevel()

    var isActive: Bool { phase != .idle }

    /// Today's review, and whether ending the conversation finishes it (it
    /// does when no screen shows it).
    private struct Conversation {
        let review: MobileMemoryReviewViewModel
        let finishesWhenDone: Bool
    }

    /// What a start read, assigned only once the start is still current.
    private struct Prepared {
        let conversation: Conversation
        let transcript: [VoiceTurn]
        /// Spoken first, then the conversation listens.
        let question: String
    }

    private enum Outcome {
        case reply(String)
        case failed(String)
    }

    private struct ReviewUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What the conversation says when today's review has no question yet.
    static let noReviewReply = "Today's review has nothing to ask yet."
    /// Spoken after a turn that failed, so the learner knows to say it again.
    static let failedTurnReply = "Sorry, that didn't go through. Try saying it again."

    private var conversation: Conversation?
    /// The last start's review (nil: today's), replayed by Resume and after
    /// sign-in. Set while a start or a failed conversation stands.
    private var request: MobileMemoryReviewViewModel??
    /// A newer start or an end makes every older await stand down.
    private var lifecycle = UUID()
    private var turnTask: Task<Void, Never>?
    private var isSpeaking = false
    private var didRegisterPreemption = false
    private var listenerObservers: Set<AnyCancellable> = []
    private let speech = MobileReviewSpeechService.shared
    // Constructed on the first conversation, never while Home draws: an
    // audio engine can rendezvous with Core Audio as it is built.
    private lazy var listener: MobileVoiceCommandService = {
        let service = MobileVoiceCommandService(holder: .voiceConversation)
        service.onTranscript = { [weak self] words in
            Task { @MainActor in self?.heard(words) }
        }
        service.$transcript
            .sink { [weak self] partial in
                Task { @MainActor in self?.showHeard(partial) }
            }
            .store(in: &listenerObservers)
        return service
    }()

    private init() {}

    // MARK: - Starting

    /// Today's memory review, spoken. The Memory screen passes the review it
    /// shows, so its cards follow the conversation; nil opens today's review
    /// here (a notebook's Cards row).
    func startMemoryReview(_ review: MobileMemoryReviewViewModel? = nil) async {
        await begin(review)
    }

    private func begin(_ request: MobileMemoryReviewViewModel?) async {
        guard phase == .idle else { return }
        // Voice mode on a source and this conversation never run at once.
        let realtime = MobileRealtimeVoice.controller
        if realtime.isActive { await realtime.end() }
        let id = UUID()
        lifecycle = id
        self.request = request
        needsSignIn = false
        errorMessage = nil
        transcript = []
        caption = nil
        activeMemoryTarget = nil
        isMicrophoneMuted = false
        isTutorWorking = false
        isSpeaking = false
        conversation = nil
        phase = .connecting
        statusText = "Getting ready…"

        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        guard lifecycle == id, phase == .connecting else { return }
        guard signedIn else {
            needsSignIn = true
            phase = .idle
            statusText = ""
            return
        }

        // The assistant can hand over from CarPlay with the phone locked;
        // asking here makes a denial an answer instead of a session that hears
        // nothing. iOS asks once, on the phone.
        if let problem = await Self.permissionProblem() {
            guard lifecycle == id else { return }
            fail(problem)
            return
        }
        guard lifecycle == id, phase == .connecting else { return }

        await registerPreemptionIfNeeded()
        guard lifecycle == id, phase == .connecting else { return }
        do {
            // Taking the lease stops whatever else had the audio: playback
            // pauses, the Siri loop stops listening, a reading chat goes quiet.
            try await MobileAudioSessionArbiter.shared.acquire(.voiceConversation, for: .record)
        } catch {
            guard lifecycle == id else { return }
            fail("The microphone could not start: \(error.localizedDescription)")
            return
        }
        guard lifecycle == id, phase == .connecting else { return }

        let prepared: Prepared
        do {
            prepared = try await prepare(request)
        } catch {
            guard lifecycle == id, phase == .connecting else { return }
            fail(error.localizedDescription)
            return
        }
        guard lifecycle == id, phase == .connecting else {
            release(prepared.conversation)
            return
        }

        conversation = prepared.conversation
        activeMemoryTarget = prepared.conversation.review.title
        transcript = prepared.transcript
        phase = .live
        Self.logger.notice("Voice conversation started")
        say(prepared.question)
    }

    private func prepare(_ given: MobileMemoryReviewViewModel?) async throws -> Prepared {
        let review = given ?? MobileMemoryReviewViewModel()
        statusText = "Opening today's review…"
        await review.open()
        guard let question = Self.openQuestion(of: review) else {
            if given == nil { review.finish() }
            throw ReviewUnavailable(message: review.errorMessage ?? Self.noReviewReply)
        }
        return Prepared(
            conversation: Conversation(review: review, finishesWhenDone: given == nil),
            transcript: Self.turns(of: review),
            question: question
        )
    }

    private static func permissionProblem() async -> String? {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            return "Speech recognition is off for ForeverLM. Turn it on in Settings › Privacy & Security › Speech Recognition."
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            return "Microphone access is off for ForeverLM. Turn it on in Settings › Privacy & Security › Microphone."
        }
        return nil
    }

    // MARK: - Turns

    private func showHeard(_ partial: String) {
        guard phase == .live, !isSpeaking, !isTutorWorking, !isMicrophoneMuted else { return }
        let words = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        caption = words.isEmpty ? nil : words
    }

    private func heard(_ utterance: String) {
        let words = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .live, !isTutorWorking, !isSpeaking, !isMicrophoneMuted, !words.isEmpty else { return }
        runTurn(words, showsAsLearnerTurn: true)
    }

    private func runTurn(_ words: String, showsAsLearnerTurn: Bool) {
        isTutorWorking = true
        statusText = "Thinking"
        caption = nil
        errorMessage = nil
        if showsAsLearnerTurn {
            transcript.append(VoiceTurn(id: UUID().uuidString, kind: .user, text: words))
        }
        let id = lifecycle
        turnTask = Task { [weak self] in
            guard let self else { return }
            await self.listener.stop()
            guard self.lifecycle == id, self.phase == .live else { return }
            let outcome = await self.answer(words)
            guard self.lifecycle == id, self.phase == .live else { return }
            self.isTutorWorking = false
            switch outcome {
            case .reply(let text):
                self.transcript.append(VoiceTurn(id: UUID().uuidString, kind: .assistant, text: text))
                self.say(text)
            case .failed(let message):
                Self.logger.error("Voice turn failed: \(message, privacy: .public)")
                self.errorMessage = message
                self.say(Self.failedTurnReply)
            }
        }
    }

    private func answer(_ words: String) async -> Outcome {
        guard let review = conversation?.review else {
            return .failed("The conversation has nothing open to answer from.")
        }
        let askedBefore = review.messages.count
        review.draft = words
        await review.send()
        if let error = review.errorMessage { return .failed(error) }
        guard review.messages.count > askedBefore,
              let reply = review.messages.last, reply.role == .tutor, !reply.isStreaming,
              !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("The tutor's reply did not arrive.")
        }
        return .reply(reply.content)
    }

    /// The tutor's question the review is waiting on, once it has arrived.
    private static func openQuestion(of review: MobileMemoryReviewViewModel) -> String? {
        guard let question = review.messages
            .last(where: { $0.role == .tutor && !$0.isStreaming })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return nil }
        return question
    }

    // MARK: - Speaking and listening

    private func say(_ text: String) {
        let id = lifecycle
        isSpeaking = true
        statusText = "Speaking"
        let spoken = MobileReviewSpeechService.spokenText(from: text)
        caption = spoken.isEmpty ? nil : spoken
        speech.speak(text, owner: .voiceConversation) { [weak self] in
            Task { @MainActor in self?.finishedSpeaking(id) }
        }
    }

    private func finishedSpeaking(_ id: UUID) {
        guard lifecycle == id, phase == .live else { return }
        isSpeaking = false
        caption = nil
        listen()
    }

    private func listen() {
        guard phase == .live else { return }
        statusText = "Listening"
        guard !isMicrophoneMuted, !isSpeaking, !isTutorWorking else { return }
        let id = lifecycle
        Task { [weak self] in
            guard let self, self.lifecycle == id, self.phase == .live else { return }
            // The arbiter, not this object's flags, says who may hold a
            // microphone: another surface may have taken the audio between
            // turns.
            guard await MobileAudioSessionArbiter.shared.holds(.voiceConversation) else { return }
            self.listener.errorMessage = nil
            await self.listener.start()
            guard self.lifecycle == id, self.phase == .live else {
                await self.listener.stop()
                return
            }
            if !self.listener.isListening, let problem = self.listener.errorMessage {
                self.fail(problem)
            }
        }
    }

    func toggleMicrophoneMuted() {
        guard phase == .live else { return }
        isMicrophoneMuted.toggle()
        if isMicrophoneMuted {
            if !isSpeaking { caption = nil }
            Task { await listener.stop() }
        } else {
            listen()
        }
    }

    // MARK: - Ending and recovering

    /// Ends the conversation where it stands. Everything it said is already
    /// saved by the review it drove; the transcript stays for the cover until
    /// the next conversation starts.
    func end() async {
        guard phase != .idle else { return }
        lifecycle = UUID()
        phase = .ending
        statusText = "Ending…"
        turnTask?.cancel()
        turnTask = nil
        speech.stop(owner: .voiceConversation)
        isSpeaking = false
        await listener.stop()
        if let conversation { release(conversation) }
        conversation = nil
        request = nil
        Task { await MobileAudioSessionArbiter.shared.release(.voiceConversation) }
        isTutorWorking = false
        isMicrophoneMuted = false
        caption = nil
        statusText = ""
        phase = .idle
        Self.logger.notice("Voice conversation ended")
    }

    /// Hands the review back to its screen, finishing it when no screen
    /// shows it.
    private func release(_ conversation: Conversation) {
        if conversation.finishesWhenDone { conversation.review.finish() }
    }

    /// Resume after a failure: listening again in the conversation it left
    /// off, or the same start again when it never got going.
    func resume() async {
        guard phase == .failed else { return }
        errorMessage = nil
        if conversation != nil {
            lifecycle = UUID()
            phase = .live
            do {
                try await MobileAudioSessionArbiter.shared.acquire(.voiceConversation, for: .record)
            } catch {
                fail("The microphone could not start: \(error.localizedDescription)")
                return
            }
            listen()
        } else if let request {
            phase = .idle
            await begin(request ?? nil)
        } else {
            phase = .idle
        }
    }

    func resumeAfterSignIn() async {
        guard needsSignIn, let request else {
            needsSignIn = false
            return
        }
        needsSignIn = false
        await begin(request ?? nil)
    }

    func cancelSignIn() {
        needsSignIn = false
        request = nil
    }

    private func fail(_ message: String) {
        speech.stop(owner: .voiceConversation)
        isSpeaking = false
        isTutorWorking = false
        caption = nil
        Task { await listener.stop() }
        errorMessage = message
        statusText = ""
        phase = .failed
    }

    private func registerPreemptionIfNeeded() async {
        guard !didRegisterPreemption else { return }
        didRegisterPreemption = true
        await MobileAudioSessionArbiter.shared.register(.voiceConversation) { [weak self] in
            await self?.yieldAudio()
        }
    }

    /// Another surface took the audio (text-to-speech, the Siri loop, a reading
    /// chat's reply, voice mode): the conversation stops where it stands, saved as it is,
    /// and says why; Resume picks the same conversation up. The arbiter awaits
    /// this, so nothing here may go back to the arbiter.
    private func yieldAudio() async {
        guard phase == .live || phase == .connecting else { return }
        lifecycle = UUID()
        turnTask?.cancel()
        turnTask = nil
        speech.stop(owner: .voiceConversation)
        isSpeaking = false
        await listener.stop()
        isTutorWorking = false
        caption = nil
        errorMessage = "Something else started playing, so voice stopped."
        statusText = ""
        phase = .failed
    }

    // MARK: - Transcript

    private static func turns(of review: MobileMemoryReviewViewModel) -> [VoiceTurn] {
        review.messages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isStreaming, !text.isEmpty else { return nil }
            return VoiceTurn(
                id: message.id,
                kind: message.role == .learner ? .user : .assistant,
                text: text
            )
        }
    }
}
