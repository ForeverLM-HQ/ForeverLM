#if os(macOS)
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
        let controller = RealtimeVoiceController(makeAudio: { MacRealtimeVoiceAudio() })
        controller.onFinished = { source, turns, startedAt in
            save(source: source, turns: turns, startedAt: startedAt)
        }
        return controller
    }()

    private static var currentNotebookID: String?
    private static var currentContext: VoiceContextItem?
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

    static var contextItem: VoiceContextItem? { currentContext }

    /// Saved as a voice chat (`ChatKind.voice`, under a `mac-live-` id, which
    /// the classifier also reads as voice) through the same storage calls a
    /// typed chat uses, so it syncs like one.
    private static func save(source: RealtimeVoiceSource, turns: [RealtimeVoiceTurn], startedAt: Date) {
        let exchanges = RealtimeVoiceExchange.exchanges(from: turns)
        guard !exchanges.isEmpty else { return }
        let notebookID = currentNotebookID
        let answered = exchanges.filter { !$0.answer.isEmpty }.count
        Task {
            let storage = StorageService()
            let sessionID = "mac-live-\(UUID().uuidString.lowercased())"
            do {
                try await storage.createReviewSession(
                    id: sessionID,
                    topic: source.title,
                    sourceIDs: [source.id],
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
                            sourceRefs: [source.id]
                        )
                    } else {
                        _ = try await storage.addReviewExchange(
                            sessionID: sessionID,
                            question: exchange.question,
                            answer: exchange.answer,
                            evaluation: exchange.evaluation,
                            knowledgeNote: "Recorded from voice mode on the Mac.",
                            sourceRefs: [source.id],
                            answeredAt: exchange.answeredAt
                        )
                    }
                }
                try await storage.completeReviewSession(
                    sessionID: sessionID,
                    summary: "Voice conversation about \(source.title) on the Mac — \(answered) turn\(answered == 1 ? "" : "s").",
                    endedAt: Date()
                )
            } catch {
                logger.error("Voice chat not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

enum MacRealtimeVoiceError: LocalizedError {
    case noText(String)

    var errorDescription: String? {
        switch self {
        case .noText(let title):
            return "\u{201C}\(title)\u{201D} has no text yet, so there is nothing to talk about. Try again once it has finished importing."
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
