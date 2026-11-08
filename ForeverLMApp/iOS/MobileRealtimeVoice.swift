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

    static func start(
        source: MobileCloudSource,
        notebook: MobileCloudNotebook?,
        opening: RealtimeVoiceOpening
    ) async {
        await prepareToTalk()
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
    static func startAssistant(setting: RealtimeVoiceAssistant.Setting) async {
        await prepareToTalk()
        currentSource = nil
        currentNotebookID = nil
        await controller.start(
            title: RealtimeVoiceAssistant.title,
            status: "Getting your day together…"
        ) {
            await MobileRealtimeAssistant.brief(setting: setting)
        }
    }

    /// Review by Voice: today's cards in the card review's scope, asked and
    /// graded out loud (`MobileRealtimeCardReview`). The chat is filed in the
    /// notebook the review is narrowed to.
    static func startCardReview(scope: MemoryReviewScope, scopeTitle: String) async {
        await prepareToTalk()
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

    private static func prepareToTalk() async {
        // A narration playing under the conversation would talk over it.
        let player = MobileAudioReviewViewModel.shared
        if player.isPlaying { player.togglePlayback() }
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
    /// classifier reads as voice for records without a kind).
    private static func save(_ finished: RealtimeVoiceController.Finished) {
        let exchanges = RealtimeVoiceExchange.exchanges(from: finished.turns)
        guard !exchanges.isEmpty else { return }
        let answered = exchanges.filter { !$0.answer.isEmpty }.count
        let turns = "\(answered) turn\(answered == 1 ? "" : "s")"
        // The assistant's chat is called by what the learner first asked; a
        // card review is called a card review.
        let isAssistant = finished.source == nil && finished.title == RealtimeVoiceAssistant.title
        let topic = finished.source?.title
            ?? (isAssistant
                ? RealtimeVoiceExchange.assistantChatTitle(firstQuestion: exchanges.first { !$0.answer.isEmpty }?.answer)
                : finished.title)
        var result = MobileReviewResult(
            sessionID: "ios-live-\(UUID().uuidString.lowercased())",
            topic: topic,
            sourceID: finished.sourceIDs.first,
            goalID: isAssistant ? nil : currentNotebookID,
            startedAt: finished.startedAt,
            endedAt: Date(),
            // A voice conversation grades nothing on its own; a score here would
            // be read by the Mac as the source's latest recall score.
            overallScore: nil,
            summary: finished.source.map { "Voice conversation about \($0.title) on iOS — \(turns)." }
                ?? (isAssistant
                    ? "Voice conversation with the ForeverLM assistant on iOS — \(turns)."
                    : "Card review by voice on iOS — \(turns)."),
            exchanges: exchanges.map {
                MobileReviewRecordedExchange(
                    question: $0.question,
                    userAnswer: $0.answer,
                    evaluation: $0.evaluation.isEmpty ? nil : $0.evaluation,
                    score: nil,
                    answeredAt: $0.answeredAt
                )
            },
            gaps: [],
            knowledgeNote: "Recorded from voice mode on iOS.",
            modelProvider: "OpenAI",
            modelID: RealtimeVoiceDefaults.model
        )
        result.kind = .voice
        result.additionalSourceIDs = Array(finished.sourceIDs.dropFirst())
        Task {
            do {
                try await MobileReviewSessionRecorder.shared.record(result)
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
    private static let key = RealtimeVoiceDefaults.voicePreferenceKey
    private static let wait: Duration = .milliseconds(1500)

    /// The pick this phone last saw, kept beside the account row.
    static var lastSeen: String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func remember(_ voice: String?) {
        if let voice {
            UserDefaults.standard.set(voice, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
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
                    let voice = try await MobileModelPreferenceStore.shared.string(forKey: key)
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
/// captures, plays, follows route changes (AirPods, CarPlay) and cancels echo.
final class MobileRealtimeVoicePlatformAudio: RealtimeVoicePlatformAudio, @unchecked Sendable {
    func prepare(onPreempted: @escaping @Sendable () -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
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
