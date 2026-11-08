import Foundation
import OSLog

/// Voice mode on the iPhone: talk about a source out loud, or be quizzed on
/// it, the way ChatGPT's voice mode talks (product owner, 2026-11-07). The
/// conversation is the shared `RealtimeVoiceController` on OpenAI Realtime; this
/// starts it from a source, shows it in the shell's voice cover
/// (`MobileVoiceSessionCover`), and saves what was said as a voice chat on the
/// source, filed in the notebook it was started from, so the Mac lists it with
/// the source's other chats.
///
/// CarPlay and spoken memory review keep the turn-by-turn conversation
/// (`MobileVoiceConversationController`); the two never run at once.
@MainActor
enum MobileRealtimeVoice {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeVoice")

    static let controller: RealtimeVoiceController = {
        let controller = RealtimeVoiceController(makeAudio: { MobileRealtimeVoiceAudio() })
        controller.onFinished = { finished in
            save(finished)
            if pendingMemoryReview {
                pendingMemoryReview = false
                Task { await MobileVoiceConversationController.shared.startMemoryReview() }
            }
        }
        return controller
    }()

    /// Set by the assistant's `start_memory_review`: when its goodbye has been
    /// spoken, today's memory review starts on the turn-by-turn conversation,
    /// which owns cards and grading (and CarPlay follows it).
    static var pendingMemoryReview = false

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
        pendingMemoryReview = false
        await controller.start(
            title: RealtimeVoiceAssistant.title,
            status: "Getting your day together…"
        ) {
            await MobileRealtimeAssistant.brief(setting: setting)
        }
    }

    private static func prepareToTalk() async {
        let turnByTurn = MobileVoiceConversationController.shared
        if turnByTurn.isActive { await turnByTurn.end() }
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

    /// The conversation as the shell's transcript sheet shows it once it ends.
    static func completedTranscript() -> MobileVoiceChatTranscript? {
        let messages = controller.transcript.compactMap { turn -> MobileChatMessage? in
            let content = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return MobileChatMessage(
                id: UUID(),
                role: turn.role == .learner ? .user : .assistant,
                content: content,
                isStreaming: false
            )
        }
        guard !messages.isEmpty else { return nil }
        var transcript = MobileVoiceChatTranscript(messages: messages)
        transcript.title = controller.title
        return transcript
    }

    /// Saved as a voice chat (`ChatKind.voice`; the `-live-` id is what the
    /// classifier reads as voice for records without a kind).
    private static func save(_ finished: RealtimeVoiceController.Finished) {
        let exchanges = RealtimeVoiceExchange.exchanges(from: finished.turns)
        guard !exchanges.isEmpty else { return }
        let answered = exchanges.filter { !$0.answer.isEmpty }.count
        let turns = "\(answered) turn\(answered == 1 ? "" : "s")"
        // The assistant's chat is called by what the learner first asked.
        let topic = finished.source?.title
            ?? RealtimeVoiceExchange.assistantChatTitle(firstQuestion: exchanges.first { !$0.answer.isEmpty }?.answer)
        var result = MobileReviewResult(
            sessionID: "ios-live-\(UUID().uuidString.lowercased())",
            topic: topic,
            sourceID: finished.sourceIDs.first,
            goalID: finished.source == nil ? nil : currentNotebookID,
            startedAt: finished.startedAt,
            endedAt: Date(),
            // A voice conversation grades nothing on its own; a score here would
            // be read by the Mac as the source's latest recall score.
            overallScore: nil,
            summary: finished.source.map { "Voice conversation about \($0.title) on iOS — \(turns)." }
                ?? "Voice conversation with the ForeverLM assistant on iOS — \(turns).",
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
