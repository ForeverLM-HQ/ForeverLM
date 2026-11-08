#if os(macOS)
import AVFoundation
import AppKit
import OSLog
import SwiftUI

/// Voice mode on the Mac: the same conversation as the iPhone's
/// (`RealtimeVoiceController`, OpenAI Realtime on ForeverLM's own credits),
/// started from the Reader's ⋯ (Talk About It, Quiz Me Out Loud) and shown in a
/// small floating panel that stays above the Reader, the way ChatGPT's Mac
/// voice window does. Closing the panel ends the conversation; what was said is
/// saved as a voice chat on the source, filed in the window's notebook, so it is
/// listed with the source's other chats on every device.
@MainActor
enum MacRealtimeVoice {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "RealtimeVoice")

    static let controller: RealtimeVoiceController = {
        // The synced row is hydrated into UserDefaults on the Mac.
        let controller = RealtimeVoiceController(
            platformAudio: MacRealtimeVoicePlatformAudio(),
            readVoice: { UserDefaults.standard.string(forKey: RealtimeVoiceDefaults.voicePreferenceKey) }
        )
        controller.onFinished = { finished in
            save(finished)
        }
        return controller
    }()

    private static var currentNotebookID: String?
    private static var currentContext: VoiceContextItem?
    /// Where the conversation under way goes back to when it is a typed chat
    /// carried on out loud (`continueChat`): it writes ForeverLM's side into
    /// that chat instead of saving a voice chat of its own.
    private static var currentChatWriter: (@MainActor (String) async -> Void)?
    /// True while one conversation is ended to make way for another, so the
    /// panel does not close in between.
    private(set) static var isReplacing = false

    static func start(article: StudioArticle, notebookID: String?, opening: RealtimeVoiceOpening) {
        let id = article.id
        let title = article.title
        let sourceType = article.sourceType.rawValue
        let byline = [article.author, article.journal]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        Task {
            // One conversation at a time: a new start replaces the one under way.
            if controller.isActive {
                isReplacing = true
                await controller.end()
                isReplacing = false
            }
            currentContext = VoiceContextItem(id: id, title: title, subtitle: byline.isEmpty ? nil : byline, sourceType: sourceType)
            currentNotebookID = notebookID
            currentChatWriter = nil
            MacRealtimeVoicePanel.shared.show()
            await controller.start(title: title, opening: opening) {
                guard let text = await StorageService().loadSourceContent(id) else {
                    throw MacRealtimeVoiceError.noText(title)
                }
                return RealtimeVoiceSource(
                    id: id,
                    title: title,
                    sourceType: sourceType,
                    byline: byline.isEmpty ? nil : byline,
                    text: text,
                    reviewGuide: nil
                )
            }
        }
    }

    /// The personal assistant (`MacRealtimeAssistant`): the learner's plans,
    /// calendar, goals and recent work, and any source opened by voice.
    static func startAssistant() {
        Task {
            if controller.isActive {
                isReplacing = true
                await controller.end()
                isReplacing = false
            }
            currentContext = nil
            currentNotebookID = nil
            currentChatWriter = nil
            MacRealtimeVoicePanel.shared.show()
            await controller.start(title: RealtimeVoiceAssistant.title, status: "Getting your day together…") {
                await MacRealtimeAssistant.brief()
            }
        }
    }

    /// A typed chat carried on out loud (the chat composer's voice button):
    /// the assistant, knowing the chat so far, opens by picking it up, and when
    /// the call ends `write` puts what ForeverLM said into that chat
    /// (`RealtimeVoiceChatContinuation.note`). No separate voice chat is saved.
    static func continueChat(
        _ chat: RealtimeVoiceChatContinuation.Chat,
        write: @escaping @MainActor (String) async -> Void
    ) {
        Task {
            if controller.isActive {
                isReplacing = true
                await controller.end()
                isReplacing = false
            }
            currentContext = nil
            currentNotebookID = nil
            currentChatWriter = write
            MacRealtimeVoicePanel.shared.show()
            let title = chat.title.isEmpty ? RealtimeVoiceAssistant.title : chat.title
            await controller.start(title: title, status: "Picking up the chat…") {
                await MacRealtimeAssistant.brief(continuing: chat)
            }
        }
    }

    static var contextItem: VoiceContextItem? { currentContext }

    /// Saved as a voice chat (`ChatKind.voice`, under a `mac-live-` id, which
    /// the classifier also reads as voice) through the same storage calls a
    /// typed chat uses, so it syncs like one. The answers the tutor graded
    /// (`record_answer`) are saved as a typed review's are: each exchange with
    /// what the learner said and its score, the session with the mean, and
    /// each source marked reviewed on the Schedule.
    private static func save(_ finished: RealtimeVoiceController.Finished) {
        if let write = currentChatWriter {
            currentChatWriter = nil
            guard let note = RealtimeVoiceChatContinuation.note(
                turns: finished.turns,
                startedAt: finished.startedAt,
                endedAt: Date()
            ) else { return }
            Task { await write(note) }
            return
        }
        let exchanges = RealtimeVoiceExchange.exchanges(from: finished.turns, answers: finished.answers)
        guard !exchanges.isEmpty else { return }
        let overallScore = RealtimeVoiceExchange.overallScore(of: exchanges)
        let gradedLine = RealtimeVoiceExchange.gradedLine(of: exchanges)
        let notebookID = finished.source == nil ? nil : currentNotebookID
        let answered = exchanges.filter { !$0.answer.isEmpty }.count
        let turns = "\(answered) turn\(answered == 1 ? "" : "s")"
        let topic = finished.source?.title
            ?? RealtimeVoiceExchange.assistantChatTitle(firstQuestion: exchanges.first { !$0.answer.isEmpty }?.answer)
        let said = finished.source.map { "Voice conversation about \($0.title) on the Mac — \(turns)." }
            ?? "Voice conversation with the ForeverLM assistant on the Mac — \(turns)."
        let summary = gradedLine.map { said + " " + $0 } ?? said
        let sourceIDs = finished.sourceIDs
        let startedAt = finished.startedAt
        Task {
            let storage = StorageService()
            let sessionID = "mac-live-\(UUID().uuidString.lowercased())"
            do {
                try await storage.createReviewSession(
                    id: sessionID,
                    topic: topic,
                    sourceIDs: sourceIDs,
                    startedAt: startedAt,
                    modelProvider: "OpenAI",
                    modelID: RealtimeVoiceDefaults.model,
                    goalID: notebookID,
                    chatKind: .voice
                )
                for exchange in exchanges {
                    if exchange.answer.isEmpty {
                        try await storage.addReviewPrompt(
                            sessionID: sessionID,
                            question: exchange.question,
                            sourceRefs: sourceIDs
                        )
                    } else {
                        _ = try await storage.addReviewExchange(
                            sessionID: sessionID,
                            question: exchange.question,
                            answer: exchange.answer,
                            evaluation: exchange.gap.map { exchange.evaluation + "\n\nGap: " + $0 } ?? exchange.evaluation,
                            score: exchange.score,
                            knowledgeNote: "Recorded from voice mode on the Mac.",
                            sourceRefs: sourceIDs,
                            answeredAt: exchange.answeredAt
                        )
                    }
                }
                let endedAt = Date()
                try await storage.completeReviewSession(
                    sessionID: sessionID,
                    overallScore: overallScore,
                    summary: summary,
                    endedAt: endedAt
                )
                // A graded voice review is a review of its sources, as a
                // typed one is (`ReviewSessionManager.completeSession`).
                if overallScore != nil {
                    for sourceID in sourceIDs {
                        try await storage.recordScheduledSourceReview(sourceID: sourceID, on: endedAt)
                    }
                }
            } catch {
                logger.error("Voice chat not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The Mac's part of a voice call: the microphone permission. WebRTC opens the
/// default input and output itself and cancels echo in software.
final class MacRealtimeVoicePlatformAudio: RealtimeVoicePlatformAudio, @unchecked Sendable {
    func prepare(onPreempted: @escaping @Sendable () -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MacRealtimeVoiceError.microphoneDenied
        }
    }

    func finish() async {}
}

enum MacRealtimeVoiceError: LocalizedError {
    case noText(String)
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noText(let title):
            return "\u{201C}\(title)\u{201D} has no text yet, so there is nothing to talk about. Try again once it has finished importing."
        case .microphoneDenied:
            return "Microphone access is off for ForeverLM. Turn it on in System Settings › Privacy & Security › Microphone."
        }
    }
}

/// The Reader ⋯'s voice commands, beside Listen.
struct RealtimeVoiceMenuItems: View {
    let article: StudioArticle
    let notebookID: String?

    var body: some View {
        Button {
            MacRealtimeVoice.start(article: article, notebookID: notebookID, opening: .talk)
        } label: {
            Label("Talk About It", systemImage: "waveform")
        }
        Button {
            MacRealtimeVoice.start(article: article, notebookID: notebookID, opening: .quiz)
        } label: {
            Label("Quiz Me Out Loud", systemImage: "questionmark.bubble")
        }
    }
}

/// The floating panel voice mode talks in. One for the app: it follows the
/// controller, so a conversation started from any window shows here.
@MainActor
final class MacRealtimeVoicePanel: NSObject, NSWindowDelegate {
    static let shared = MacRealtimeVoicePanel()

    private var panel: NSPanel?

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voice"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.minSize = NSSize(width: 320, height: 440)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MacRealtimeVoiceView(onClose: { [weak self] in self?.close() }))
        panel.setFrameAutosaveName("ForeverLMVoicePanel")
        if !panel.setFrameUsingName("ForeverLMVoicePanel") {
            panel.center()
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    /// Closing the panel ends the conversation; the transcript is saved.
    func windowWillClose(_ notification: Notification) {
        panel = nil
        Task { await MacRealtimeVoice.controller.end() }
    }
}

/// The panel's content: the shared voice screen while a conversation runs,
/// sign-in when it is needed.
struct MacRealtimeVoiceView: View {
    @ObservedObject private var voice = MacRealtimeVoice.controller
    let onClose: () -> Void

    var body: some View {
        Group {
            if voice.needsSignIn {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Sign in with Apple to talk")
                        .font(.headline)
                    Text("Voice runs on ForeverLM's account, and this Mac's sign-in has lapsed. Sign in with Apple again, then start voice once more.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") {
                        voice.cancelSignIn()
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VoiceSessionSurface(
                    state: voice.presentationState(context: MacRealtimeVoice.contextItem),
                    identifierPrefix: "macVoice",
                    recoveryActionTitle: "Resume",
                    onRecovery: { Task { await voice.resume() } },
                    onToggleMute: voice.toggleMicrophoneMuted,
                    onEnd: onClose,
                    onDismissError: { voice.errorMessage = nil }
                )
            }
        }
        .frame(minWidth: 320, minHeight: 440)
        // A conversation that ends itself (the tutor's goodbye) closes the panel.
        .onChange(of: voice.phase) { _, phase in
            if phase == .idle, !voice.needsSignIn, !MacRealtimeVoice.isReplacing { onClose() }
        }
    }
}
#endif
