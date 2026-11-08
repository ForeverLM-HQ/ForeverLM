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
        controller.onFinished = { source, turns, startedAt in
            save(source: source, turns: turns, startedAt: startedAt)
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
        let turnByTurn = MobileVoiceConversationController.shared
        if turnByTurn.isActive { await turnByTurn.end() }
        // A narration playing under the conversation would talk over it.
        let player = MobileAudioReviewViewModel.shared
        if player.isPlaying { player.togglePlayback() }
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
    private static func save(source: RealtimeVoiceSource, turns: [RealtimeVoiceTurn], startedAt: Date) {
        let exchanges = RealtimeVoiceExchange.exchanges(from: turns)
        guard !exchanges.isEmpty else { return }
        let answered = exchanges.filter { !$0.answer.isEmpty }.count
        var result = MobileReviewResult(
            sessionID: "ios-live-\(UUID().uuidString.lowercased())",
            topic: source.title,
            sourceID: source.id,
            goalID: currentNotebookID,
            startedAt: startedAt,
            endedAt: Date(),
            // A voice conversation grades nothing on its own; a score here would
            // be read by the Mac as the source's latest recall score.
            overallScore: nil,
            summary: "Voice conversation about \(source.title) on iOS — \(answered) turn\(answered == 1 ? "" : "s").",
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
        Task {
            do {
                try await MobileReviewSessionRecorder.shared.record(result)
            } catch {
                logger.error("Voice chat not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
