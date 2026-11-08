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
/// It replaced the realtime speech-to-speech session on 2026-10-01, when every
/// model moved to OpenRouter (product owner, 2026-09-27), which serves no
/// speech-to-speech model. Talking about a source, a notebook or a chat under
/// way left the app on 2026-10-25 for the ChatGPT share (`MobileSourceShare`);
/// what is left is what CarPlay and the spoken memory review need:
/// - nothing (CarPlay): it offers a source, then talks about the one the
///   learner takes or names in a reading chat, or holds today's memory
///   review when that is asked for (`MobileVoiceConversationRules`);
/// - today's memory review: its review chat (`MobileMemoryReviewViewModel`).
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
    @Published private(set) var activeSourceTitle: String?
    @Published private(set) var activeMemoryTarget: String?
    @Published private(set) var activeNotebook: MobileCloudNotebook?
    /// The sources the conversation reads. CarPlay lists them under Sources.
    @Published private(set) var loadedSources: [MobileCloudSource] = []
    /// The paper figure the newest reply placed, shown under the mark.
    @Published private(set) var presentedFigure: SyncedPaperFigure?
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

    private enum Conversation {
        case chat(MobileChatViewModel, finishesWhenDone: Bool)
        case memoryReview(MobileMemoryReviewViewModel, finishesWhenDone: Bool)
        case choosingSource(offer: MobileVoiceConversationRules.SuggestedSource?)
    }

    private enum Request {
        case memoryReview(MobileMemoryReviewViewModel?)
        case unscoped
    }

    /// What a start read, assigned only once the start is still current.
    private struct Prepared {
        let conversation: Conversation
        let sourceTitle: String?
        let notebook: MobileCloudNotebook?
        let memoryTarget: String?
        let sources: [MobileCloudSource]
        let transcript: [VoiceTurn]
        /// Spoken first, then the conversation listens.
        let greeting: String?
    }

    private enum Outcome {
        case reply(String, figure: SyncedPaperFigure?)
        case say(String)
        case failed(String)
    }

    private enum StartError: LocalizedError {
        case sourceHasNoText(String)
        case reviewUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .sourceHasNoText(let title):
                return "\u{201C}\(title)\u{201D} has no text on this iPhone yet. Open it on your Mac so its text syncs."
            case .reviewUnavailable(let message):
                return message
            }
        }
    }

    private var conversation: Conversation?
    /// The last start, replayed by Resume and after sign-in.
    private var request: Request?
    /// A newer start or an end makes every older await stand down.
    private var lifecycle = UUID()
    private var turnTask: Task<Void, Never>?
    private var isSpeaking = false
    private var didRegisterPreemption = false
    private var listenerObservers: Set<AnyCancellable> = []
    private let speech = MobileReviewSpeechService.shared
    private lazy var voiceAgent = MobileVoiceAgentService()
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

    /// CarPlay's conversation: it offers a source first, then talks about the one the learner takes or names.
    func startFromCarPlay() async {
        await begin(.unscoped)
    }

    /// Today's memory review, spoken. The Memory screen passes the review it
    /// shows, so its cards follow the conversation; nil opens today's review
    /// here (a notebook's Cards row).
    func startMemoryReview(_ review: MobileMemoryReviewViewModel? = nil) async {
        await begin(.memoryReview(review))
    }

    private func begin(_ request: Request) async {
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
        presentedFigure = nil
        activeSourceTitle = nil
        activeMemoryTarget = nil
        activeNotebook = nil
        loadedSources = []
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

        // A CarPlay scene can be the first thing that starts voice; asking
        // here makes a denial an answer instead of a session that hears
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
        activeSourceTitle = prepared.sourceTitle
        activeNotebook = prepared.notebook
        activeMemoryTarget = prepared.memoryTarget
        loadedSources = prepared.sources
        transcript = prepared.transcript
        phase = .live
        Self.logger.notice("Voice conversation started")

        if let greeting = prepared.greeting {
            say(greeting)
        } else {
            listen()
        }
    }

    private func prepare(_ request: Request) async throws -> Prepared {
        switch request {
        case .unscoped:
            let suggestion = await suggestedSource()
            return Prepared(
                conversation: .choosingSource(offer: suggestion),
                sourceTitle: nil,
                notebook: nil,
                memoryTarget: nil,
                sources: [],
                transcript: [],
                greeting: MobileVoiceConversationRules.openingOffer(suggestion)
            )

        case .memoryReview(let given):
            let review = given ?? MobileMemoryReviewViewModel()
            statusText = "Opening today's review…"
            await review.open()
            guard let question = Self.openQuestion(of: review) else {
                if given == nil { review.finish() }
                throw StartError.reviewUnavailable(
                    review.errorMessage ?? MobileVoiceConversationRules.noReviewReply
                )
            }
            return Prepared(
                conversation: .memoryReview(review, finishesWhenDone: given == nil),
                sourceTitle: nil,
                notebook: nil,
                memoryTarget: review.title,
                sources: [],
                transcript: Self.turns(of: review),
                greeting: question
            )
        }
    }

    /// A reading chat on `source`, filed in `notebook`, voice-driven from here.
    private func readingChat(on source: MobileCloudSource, notebook: MobileCloudNotebook?) async throws -> MobileChatViewModel {
        let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StartError.sourceHasNoText(source.title)
        }
        let chat = MobileChatViewModel(
            source: source,
            sourceText: text,
            selection: nil,
            notebook: notebook,
            onSessionSaveFailure: { [weak self] message in self?.errorMessage = message }
        )
        chat.isVoiceDriven = true
        return chat
    }

    private func library() async -> [MobileCloudSource] {
        let shown = MobileAudioReviewViewModel.shared.allSources
        if !shown.isEmpty { return shown }
        return await MobileCloudSourceCatalog.shared.currentSources()
    }

    private func suggestedSource() async -> MobileVoiceConversationRules.SuggestedSource? {
        let catalog = MobileCloudSourceCatalog.shared
        let nowPlayingSourceID = MobileAudioReviewViewModel.shared.currentItem?.id
        let sources = await catalog.currentSources()
        let schedule = await catalog.currentScheduleItems()
        let recent = await catalog.currentRecentSourceAttention()
        return MobileVoiceConversationRules.suggestedSource(
            nowPlayingSourceID: nowPlayingSourceID,
            schedule: schedule,
            recentAttention: recent,
            sources: sources,
            now: Date(),
            calendar: .autoupdatingCurrent
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
            let outcome = await self.answer(words, lifecycle: id)
            guard self.lifecycle == id, self.phase == .live else { return }
            self.isTutorWorking = false
            switch outcome {
            case .reply(let text, let figure):
                self.transcript.append(VoiceTurn(id: UUID().uuidString, kind: .assistant, text: text))
                if let figure { self.presentedFigure = figure }
                self.say(text)
            case .say(let text):
                self.say(text)
            case .failed(let message):
                Self.logger.error("Voice turn failed: \(message, privacy: .public)")
                self.errorMessage = message
                self.say(MobileVoiceConversationRules.failedTurnReply)
            }
        }
    }

    private func answer(_ words: String, lifecycle id: UUID) async -> Outcome {
        switch conversation {
        case .chat(let chat, _):
            return await reply(from: chat, to: words)

        case .memoryReview(let review, _):
            let askedBefore = review.messages.count
            review.draft = words
            await review.send()
            if let error = review.errorMessage { return .failed(error) }
            guard review.messages.count > askedBefore,
                  let reply = review.messages.last, reply.role == .tutor, !reply.isStreaming,
                  !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed("The tutor's reply did not arrive.")
            }
            return .reply(reply.content, figure: nil)

        case .choosingSource(let offer):
            return await chooseSource(from: words, offer: offer, lifecycle: id)

        case nil:
            return .failed("The conversation has nothing open to answer from.")
        }
    }

    private func reply(from chat: MobileChatViewModel, to words: String) async -> Outcome {
        if let reply = await chat.sendSpoken(words) {
            return .reply(reply.text, figure: reply.figures.first)
        }
        return .failed(chat.errorMessage ?? "The reply did not arrive.")
    }

    /// The opening offer taken, or a source named: the conversation becomes
    /// a reading chat on that source, and the learner's words are its first
    /// message. Asked for instead, today's memory review takes its place.
    private func chooseSource(
        from words: String,
        offer: MobileVoiceConversationRules.SuggestedSource?,
        lifecycle id: UUID
    ) async -> Outcome {
        let chosen: MobileCloudSource?
        let firstMessage: String
        if let offer, MobileVoiceConversationRules.isAcceptance(words) {
            chosen = offer.source
            firstMessage = MobileVoiceConversationRules.acceptedOfferRequest
        } else {
            let sources = await library()
            if let match = MobileVoiceConversationRules.titleMatch(utterance: words, sources: sources) {
                chosen = match
            } else if MobileVoiceConversationRules.asksForMemoryReview(words) {
                return await openMemoryReview(lifecycle: id)
            } else {
                do {
                    chosen = try await agentPick(words, sources: sources)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            firstMessage = words
        }
        guard let source = chosen else {
            return .say(MobileVoiceConversationRules.unmatchedSourceReply)
        }
        let chat: MobileChatViewModel
        do {
            chat = try await readingChat(on: source, notebook: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard lifecycle == id, phase == .live else {
            release(.chat(chat, finishesWhenDone: true))
            return .failed("Voice ended.")
        }
        conversation = .chat(chat, finishesWhenDone: true)
        activeSourceTitle = source.title
        loadedSources = [source]
        return await reply(from: chat, to: firstMessage)
    }

    /// Today's memory review, asked for from the opening offer (in a car,
    /// the one way to it): the conversation becomes that review and speaks
    /// its open question. With nothing to ask, the offer stands.
    private func openMemoryReview(lifecycle id: UUID) async -> Outcome {
        let review = MobileMemoryReviewViewModel()
        await review.open()
        guard lifecycle == id, phase == .live else {
            review.finish()
            return .failed("Voice ended.")
        }
        guard let question = Self.openQuestion(of: review) else {
            let message = review.errorMessage ?? MobileVoiceConversationRules.noReviewReply
            review.finish()
            return .say(message)
        }
        conversation = .memoryReview(review, finishesWhenDone: true)
        activeMemoryTarget = review.title
        return .reply(question, figure: nil)
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

    /// Asks the voice agent model which library source the learner named
    /// (`MobileVoiceAgentService`, the Siri path's own router).
    private func agentPick(_ words: String, sources: [MobileCloudSource]) async throws -> MobileCloudSource? {
        let state = MobileVoiceAgentState(
            isPlaying: false,
            isSourceReviewActive: false,
            currentSourceID: nil,
            currentSourceTitle: nil,
            activeReviewTitle: nil,
            playbackSpeed: 1,
            availableSources: sources.enumerated().map { index, source in
                MobileVoiceAgentSource(
                    id: source.id,
                    position: index + 1,
                    title: source.title,
                    subtitle: [source.sourceType, source.citationSubtitle]
                        .compactMap { $0 }
                        .joined(separator: " • ")
                )
            }
        )
        let decision = try await voiceAgent.decide(utterance: words, state: state)
        guard let sourceID = decision.sourceID else { return nil }
        return sources.first { $0.id == sourceID }
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
    /// saved by the chat or review it drove; the transcript stays for the
    /// cover until the next conversation starts.
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

    /// Hands a conversation's chat or review back to its screen, finishing
    /// one that has no screen left.
    private func release(_ conversation: Conversation) {
        switch conversation {
        case .chat(let chat, let finishesWhenDone):
            chat.isVoiceDriven = false
            if finishesWhenDone { chat.finish() }
        case .memoryReview(let review, let finishesWhenDone):
            if finishesWhenDone { review.finish() }
        case .choosingSource:
            break
        }
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
            await begin(request)
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
        await begin(request)
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
    /// chat's reply): the conversation stops where it stands, saved as it is,
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
