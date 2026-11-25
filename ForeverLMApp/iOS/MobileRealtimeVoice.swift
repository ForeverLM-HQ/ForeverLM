import AVFoundation
import Foundation
import OSLog
import os

/// Voice mode on the iPhone: talk about a source out loud, or be quizzed on
/// it, the way ChatGPT's voice mode talks (product owner, 2026-11-07). The
/// conversation is the shared `RealtimeVoiceController` on OpenAI Realtime over
/// WebRTC; this starts it from a source or as the assistant, shows it in the
/// shell's voice cover (`MobileVoiceSessionCover`), and saves what was said as
/// a voice chat, filed in the notebook it was started from, so the Mac lists it
/// with the source's other chats. CarPlay starts the assistant on connect; the
/// card review's Review by Voice starts a card review.
@MainActor
enum MobileRealtimeVoice {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeVoice")

    static let controller: RealtimeVoiceController = {
        let controller = RealtimeVoiceController(
            platformAudio: MobileRealtimeVoicePlatformAudio(),
            readVoice: { await MobileRealtimeVoicePick.read() }
        )
        controller.onFinished = { finished in
            save(finished)
        }
        return controller
    }()

    /// The source on the voice screen, for its card (thumbnail, subtitle).
    private(set) static var currentSource: MobileCloudSource?
    private static var currentNotebookID: String?
    /// The running conversation was started from CarPlay: its chat is saved
    /// under a `carplay-live-` id, which `ReviewSessionOrigin` reads as
    /// CarPlay, and its summary says so. A conversation started on the phone
    /// and carried into the car stays the phone's.
    private static var startedInCar = false
    /// CarPlay is connected (`CarPlaySceneDelegate`). A narration voice mode
    /// started there that fails is the returning assistant's to say.
    static var isCarConnected = false

    /// True when the start was put aside for the voice sheet: the first
    /// conversation started on the phone's own screen, by someone who has
    /// not picked a voice on any device. Never in the car, where nothing may
    /// be asked on a screen.
    private static func offersVoiceChoice(then start: @escaping @MainActor () async -> Void) async -> Bool {
        guard !isCarConnected, !controller.isActive,
              !Preferences.value(Prefs.Mobile.hasOfferedVoiceModeVoiceChoice) else { return false }
        let stored = await MobileRealtimeVoicePick.read()
        guard MobileVoiceModeVoiceChoice.isFirstConversation(hasOffered: false, storedVoice: stored) else {
            Preferences.set(true, for: Prefs.Mobile.hasOfferedVoiceModeVoiceChoice)
            return false
        }
        MobileAudioReviewViewModel.shared.voiceModeVoiceChoice = MobileVoiceModeVoiceChoice(start: start)
        return true
    }

    /// The sheet's Start Talking: the voice is picked and saved, and the
    /// conversation that was asked for starts once the sheet has gone.
    static func confirmVoiceChoice(_ choice: MobileVoiceModeVoiceChoice) {
        Preferences.set(true, for: Prefs.Mobile.hasOfferedVoiceModeVoiceChoice)
        let player = MobileAudioReviewViewModel.shared
        player.voiceModeStartAfterChoice = choice.start
        player.voiceModeVoiceChoice = nil
    }

    /// Run when the voice sheet has left the screen. One swiped away starts
    /// nothing, and the next conversation offers again.
    static func continueAfterVoiceChoice() async {
        let player = MobileAudioReviewViewModel.shared
        guard let start = player.voiceModeStartAfterChoice else { return }
        player.voiceModeStartAfterChoice = nil
        await start()
    }

    static func start(
        source: MobileCloudSource,
        notebook: MobileCloudNotebook?,
        opening: RealtimeVoiceOpening,
        inCar: Bool = false
    ) async {
        if await offersVoiceChoice(then: { await start(source: source, notebook: notebook, opening: opening) }) { return }
        await prepareToTalk(inCar: inCar)
        currentSource = source
        currentNotebookID = notebook?.id
        let id = source.id
        let title = source.title
        let sourceType = source.sourceType
        let byline = source.citationSubtitle
        await controller.start(title: title, opening: opening) {
            let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: id)
            return RealtimeVoiceSource(
                id: id,
                title: title,
                sourceType: sourceType,
                byline: byline,
                text: text,
                reviewGuide: nil
            )
        }
    }

    /// The personal assistant (`MobileRealtimeAssistant`): no source, the
    /// learner's plans and recent work instead. CarPlay starts it on connect.
    ///
    /// `narration` is a narration started by voice (`listen_to_source`) that
    /// the learner comes back from: the assistant opens on it.
    static func startAssistant(
        setting: RealtimeVoiceAssistant.Setting,
        returningFrom narration: RealtimeVoiceAssistant.NarrationReturn? = nil,
        voiceChangedTo newVoice: String? = nil
    ) async {
        if setting == .phone, narration == nil, newVoice == nil,
           await offersVoiceChoice(then: { await startAssistant(setting: setting) }) { return }
        // Saved as CarPlay's only when CarPlay is on: a drive started from
        // Talk in the Car (a Tesla) is the phone's.
        await prepareToTalk(inCar: setting == .car && isCarConnected)
        currentSource = nil
        currentNotebookID = nil
        await controller.start(
            title: RealtimeVoiceAssistant.title,
            status: "Getting your day together…"
        ) {
            await MobileRealtimeAssistant.brief(
                setting: setting,
                returningFrom: narration,
                voiceChangedTo: newVoice
            )
        }
    }

    /// Review by Voice: today's cards in the card review's scope, asked and
    /// graded out loud (`MobileRealtimeCardReview`). The chat is filed in the
    /// notebook the review is narrowed to.
    static func startCardReview(scope: MemoryReviewScope, scopeTitle: String, inCar: Bool = false) async {
        if await offersVoiceChoice(then: { await startCardReview(scope: scope, scopeTitle: scopeTitle) }) { return }
        await prepareToTalk(inCar: inCar)
        currentSource = nil
        if case .notebook(let notebookID) = scope {
            currentNotebookID = notebookID
        } else {
            currentNotebookID = nil
        }
        await controller.start(
            title: RealtimeVoiceCardReview.title,
            status: "Dealing today's cards…"
        ) {
            try await MobileRealtimeCardReview.brief(scope: scope, scopeTitle: scopeTitle)
        }
    }

    /// Check Cards by Voice: the cards waiting in To Check, asked, then kept,
    /// changed or skipped on the learner's word (`MobileRealtimeCardsToCheck`).
    static func startCardsToCheck(scope: MemoryReviewScope, scopeTitle: String) async {
        if await offersVoiceChoice(then: { await startCardsToCheck(scope: scope, scopeTitle: scopeTitle) }) { return }
        await prepareToTalk()
        currentSource = nil
        if case .notebook(let notebookID) = scope {
            currentNotebookID = notebookID
        } else {
            currentNotebookID = nil
        }
        await controller.start(
            title: RealtimeVoiceCardsToCheck.title,
            status: "Dealing the cards to check…"
        ) {
            try await MobileRealtimeCardsToCheck.brief(scope: scope, scopeTitle: scopeTitle)
        }
    }

    /// Memory Check by Voice: today's cards, then today's memory review,
    /// out loud (`MobileRealtimeMemoryCheck`). The review half is saved on
    /// the day's review as it goes, so it is not filed again as a voice chat.
    static func startMemoryCheck() async {
        await prepareToTalk()
        currentSource = nil
        currentNotebookID = nil
        await controller.start(
            title: RealtimeVoiceMemoryCheck.title,
            status: "Getting today's check ready…"
        ) {
            try await MobileRealtimeMemoryCheck.brief()
        }
    }

    /// This morning's explanation (docs/morning-routine-design.md): the
    /// Feynman Technique out loud on the morning's pick, saved as a voice chat
    /// whose graded turns mark the source explained. False, and nothing
    /// started, when there is nothing to explain this morning.
    @discardableResult
    static func startMorningExplanation() async -> Bool {
        guard let source = await MobileMorningPick.source() else { return false }
        await start(source: source, notebook: nil, opening: .explain)
        return true
    }

    /// The running Memory Check's tools, which save its last turn when it ends.
    static var memoryCheck: MobileRealtimeMemoryCheck.Toolbox?

    private static func prepareToTalk(inCar: Bool = false) async {
        // A narration playing under the conversation would talk over it.
        let player = MobileAudioReviewViewModel.shared
        if player.isPlaying { player.togglePlayback() }
        // A conversation takes the audio back from a narration voice started.
        player.voiceListen = nil
        // The controller turns a start away while a conversation is running,
        // and that conversation keeps the place it was started in.
        if controller.phase == .idle || controller.phase == .failed {
            startedInCar = inCar
        }
    }

    static var contextItem: VoiceContextItem? {
        guard let source = currentSource else { return nil }
        return VoiceContextItem(
            id: source.id,
            title: source.title,
            subtitle: source.citationSubtitle,
            sourceType: source.sourceType,
            thumbnailURL: source.thumbnailURL
        )
    }

    /// Saved as a voice chat (`ChatKind.voice`; the `-live-` id is what the
    /// classifier reads as voice for records without a kind), under
    /// `carplay-live-` when CarPlay started it and `ios-live-` otherwise. The answers the
    /// tutor graded (`record_answer`) are saved as a hands-free review's are:
    /// each exchange with what the learner said and its score, the mean as
    /// the session's score, and each gap.
    private static func save(_ finished: RealtimeVoiceController.Finished) {
        if let check = memoryCheck, finished.title == RealtimeVoiceMemoryCheck.title {
            memoryCheck = nil
            // Taken now: the next conversation starts a new transcript.
            let transcript = controller.transcript
            Task { await check.finish(transcript: transcript) }
            return
        }
        let exchanges = RealtimeVoiceExchange.exchanges(from: finished.turns, answers: finished.answers)
        guard !exchanges.isEmpty else { return }
        let gradedLine = RealtimeVoiceExchange.gradedLine(of: exchanges)
        let answered = exchanges.filter { !$0.answer.isEmpty }.count
        let turns = "\(answered) turn\(answered == 1 ? "" : "s")"
        // Where it was had: the id's prefix is the chat's origin, and the
        // summary says it in words.
        let inCar = startedInCar
        let place = inCar ? "in CarPlay" : "on iOS"
        // The assistant's chat is called by what the learner first asked; a
        // card review is called a card review.
        let isAssistant = finished.source == nil && finished.title == RealtimeVoiceAssistant.title
        let isExplanation = finished.source != nil && controller.opening == .explain
        let topic = finished.source?.title
            ?? (isAssistant
                ? RealtimeVoiceExchange.assistantChatTitle(firstQuestion: exchanges.first { !$0.answer.isEmpty }?.answer)
                : finished.title)
        var result = MobileReviewResult(
            sessionID: "\(inCar ? "carplay" : "ios")-live-\(UUID().uuidString.lowercased())",
            topic: topic,
            sourceID: finished.sourceIDs.first,
            goalID: isAssistant ? nil : currentNotebookID,
            startedAt: finished.startedAt,
            endedAt: Date(),
            // The mean of the answers the tutor graded, which the Mac reads as
            // the source's latest recall score; nil for a talk with none graded.
            overallScore: RealtimeVoiceExchange.overallScore(of: exchanges),
            summary: (finished.source.map { source in
                controller.opening == .gym
                    ? "Gym mode walk-through of \(source.title) \(place) — \(answered) typed question\(answered == 1 ? "" : "s")."
                    : "Voice conversation about \(source.title) \(place) — \(turns)."
            }
                ?? (isAssistant
                    ? "Voice conversation with the ForeverLM assistant \(place) — \(turns)."
                    : "Card review by voice \(place) — \(turns).")) + (gradedLine.map { " " + $0 } ?? ""),
            // The recorder keeps no gaps of its own, so a gap rides in its
            // exchange's evaluation, as the Mac saves it.
            exchanges: exchanges.map { exchange in
                let evaluation = exchange.gap.map { exchange.evaluation + "\n\nGap: " + $0 } ?? exchange.evaluation
                return MobileReviewRecordedExchange(
                    question: exchange.question,
                    userAnswer: exchange.answer,
                    evaluation: evaluation.isEmpty ? nil : evaluation,
                    score: exchange.score,
                    answeredAt: exchange.answeredAt,
                    // A graded turn of the Feynman Technique by voice is an
                    // explanation the morning's pick reads, on both devices.
                    grading: isExplanation && exchange.score != nil
                        ? MorningPickRule.explanationGrading(sourceCount: finished.sourceIDs.count)
                        : nil
                )
            },
            gaps: [],
            knowledgeNote: "Recorded from voice mode \(place).",
            modelProvider: "OpenAI",
            modelID: RealtimeVoiceDefaults.model
        )
        result.kind = .voice
        result.additionalSourceIDs = Array(finished.sourceIDs.dropFirst())
        // A graded voice review is a review of its sources, as a hands-free
        // one is: each is logged reviewed and its Schedule placement completed.
        let reviewed = result.overallScore == nil ? [] : finished.sourceIDs
        Task {
            do {
                try await MobileReviewSessionRecorder.shared.record(result, reviewedSourceIDs: reviewed)
            } catch {
                logger.error("Voice chat not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The learner's voice for voice mode, on the iPhone. The account row is the
/// truth (the Mac and the phone both set it), but a conversation must not wait
/// on iCloud to start, least of all in CarPlay: the row is read with a short
/// wait, and when it does not answer in time the last pick this phone saw is
/// used. A late answer still lands in that copy for the next conversation.
enum MobileRealtimeVoicePick {
    private static let key = Prefs.ReadAloud.voiceModeVoice
    private static let wait: Duration = .milliseconds(1500)

    /// The pick this phone last saw, kept beside the account row.
    static var lastSeen: String? {
        UserDefaults.standard.string(forKey: key.name)
    }

    static func remember(_ voice: String?) {
        if let voice {
            UserDefaults.standard.set(voice, forKey: key.name)
        } else {
            UserDefaults.standard.removeObject(forKey: key.name)
        }
    }

    static func read() async -> String? {
        let once = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = {
            once.withLock { claimed in
                defer { claimed = true }
                return !claimed
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            Task.detached {
                do {
                    let voice = try await MobileModelPreferenceStore.shared.valueOrDefault(for: key)
                    remember(voice)
                    if claim() { continuation.resume(returning: voice) }
                } catch {
                    if claim() { continuation.resume(returning: lastSeen) }
                }
            }
            Task.detached {
                try? await Task.sleep(for: wait)
                if claim() { continuation.resume(returning: lastSeen) }
            }
        }
    }
}

/// The iPhone's part of a voice call: the microphone permission, and the audio
/// session taken from narration and other players under the arbiter's
/// `.conversation` lease, in the voice chat mode WebRTC runs in. WebRTC
/// captures, plays, follows route changes (AirPods, CarPlay) and cancels echo,
/// so a route change never needs the call reopened.
final class MobileRealtimeVoicePlatformAudio: RealtimeVoicePlatformAudio, @unchecked Sendable {
    func prepare(
        usesMicrophone: Bool,
        onPreempted: @escaping @Sendable () -> Void,
        onDevicesChanged: @escaping @Sendable () -> Void
    ) async throws {
        if usesMicrophone, !(await AVAudioApplication.requestRecordPermission()) {
            throw MobileRealtimeVoiceAudioError.microphoneDenied
        }
        let arbiter = MobileAudioSessionArbiter.shared
        await arbiter.register(.realtimeVoice) { onPreempted() }
        try await arbiter.acquire(.realtimeVoice, for: .conversation)
    }

    func finish() async {
        await MobileAudioSessionArbiter.shared.release(.realtimeVoice)
    }
}

enum MobileRealtimeVoiceAudioError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off for ForeverLM. Turn it on in Settings › Privacy & Security › Microphone."
        }
    }
}
