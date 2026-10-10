import AppKit
import Observation
import SwiftUI

// MARK: - The quick assistant
//
// A bar that floats over whatever app the learner is in, summoned by the
// shortcut (`QuickAssistantShortcut`), listening at once. Pressing the
// shortcut again sends what was said to an ordinary ForeverLM chat — the same
// command-the-app chat as the rail's New chat, with every app tool — and the
// answer grows above the bar. It is a way into Chat, not an assistant of its
// own (chat-design.md, "One chat implementation"): the chat is saved like any
// other, and Open in ForeverLM continues it in a Studio window.
// docs/quick-assistant-design.md.

/// A borderless panel that takes the keyboard without bringing ForeverLM
/// forward, the way Spotlight does: the app the learner was in stays the
/// active app, so dismissing the bar leaves them exactly where they were.
final class QuickAssistantPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: QuickAssistantController.panelWidth, height: 80),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        // Over a full-screen app too, and on whichever Space is in front.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        // The SwiftUI content draws its own rounded shapes and their shadows.
        hasShadow = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel: shows it on the shortcut, sizes it to its content from
/// the bottom up, and takes it away again.
@MainActor
final class QuickAssistantController {
    static let shared = QuickAssistantController()

    static let panelWidth: CGFloat = 640
    /// Above the Dock, like the dictation bar it borrows from.
    private static let bottomMargin: CGFloat = 28

    let model = QuickAssistantModel()
    private var panel: QuickAssistantPanel?
    private var contentHeight: CGFloat = 80
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    private init() {
        model.close = { [weak self] in self?.hide() }
    }

    /// Registers the shortcut. Called once, at launch.
    func start() {
        QuickAssistantHotKey.shared.onPress = { [weak self] in self?.shortcutPressed() }
        QuickAssistantHotKey.shared.apply(QuickAssistantShortcut.stored())
    }

    var isShown: Bool { panel?.isVisible == true }

    func shortcutPressed() {
        guard isShown, let panel else {
            show()
            model.summoned()
            return
        }
        panel.makeKeyAndOrderFront(nil)
        model.shortcutPressedWhileShown()
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel, height: contentHeight)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickAssistantPanel {
        let panel = QuickAssistantPanel()
        let root = QuickAssistantView(
            model: model,
            dictation: model.dictation,
            onHeightChange: { [weak self] height in self?.contentHeightChanged(height) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        // Escape, Return and a first typed letter, whichever view has the
        // keyboard: a monitor sees the key before the text field or the
        // hosting view can swallow it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            return self.model.handleKeyDown(event) ? nil : event
        }
        // Clicking into another app leaves an idle bar behind; one with a
        // recording, a question or an answer on it stays until dismissed.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isIdle else { return }
                self.model.dismiss()
            }
        }
        return panel
    }

    private func contentHeightChanged(_ height: CGFloat) {
        let height = ceil(max(height, 40))
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard let panel, panel.isVisible else { return }
        // Grow upward: the bar stays where the learner's eyes are.
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Bottom centre of the screen the pointer is on.
    private func place(_ panel: NSPanel, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(Self.panelWidth, visible.width - 32)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + Self.bottomMargin,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: Leaving the panel

    /// Continues the chat in a Studio window. The link takes the route every
    /// `foreverlm://chat/…` link takes (`ContentView.handleOpenURL`), which
    /// opens a window first when none is open.
    func openChat(_ sessionID: String) {
        guard let url = URL(string: "\(ForeverLMRuntimeIdentity.urlScheme)://chat/\(StudioEntityLink.encode(sessionID))") else { return }
        deliverToThisApp(url)
    }

    /// A link in an answer. A library link opens in ForeverLM, as it does in
    /// a chat; a web page opens in the learner's browser, since the learner
    /// is working outside ForeverLM.
    func open(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == StudioEntityLink.productScheme || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased() {
            // Chat links are written with the production scheme; this build
            // answers only to its own (`foreverlm-dev` in Dev).
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = ForeverLMRuntimeIdentity.urlScheme
            if let own = components?.url { deliverToThisApp(own) }
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Hands a link to this running copy of ForeverLM, never to another
    /// install that answers the same scheme.
    private func deliverToThisApp(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Bundle.main.bundleURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

/// What the bar is doing, and the chat behind it.
@Observable
@MainActor
final class QuickAssistantModel {
    enum Input: Equatable {
        case voice
        case keyboard
    }

    private(set) var input: Input = .voice
    var draft = ""
    /// Why the bar cannot do what was asked: the microphone, a transcript
    /// that failed, ForeverLM not signed in. The chat's own errors are the
    /// manager's and are shown with its answer.
    private(set) var notice: String?
    /// The chat this bar is in, from its first send until it is dismissed.
    private(set) var manager: ReviewSessionManager?

    @ObservationIgnored let dictation = ReviewDictationService()
    @ObservationIgnored var close: (() -> Void)?
    /// Chats dismissed while a reply was still on its way. They finish and
    /// save; dropping them would not stop the turn, only lose its end.
    @ObservationIgnored private var finishing: [ReviewSessionManager] = []
    /// Bumped by every dismissal, so a microphone that opens or a transcript
    /// that arrives after the bar was put away is dropped, not sent.
    @ObservationIgnored private var epoch = 0

    /// Nothing on the bar worth keeping on screen.
    var isIdle: Bool {
        !dictation.isRecording && !dictation.isTranscribing && manager == nil
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sessionID: String? { manager?.currentSessionID }

    // MARK: The shortcut

    func summoned() {
        notice = nil
        // The account model is the app's cached answer; nil only before the
        // first window has appeared, when the chat itself will say so.
        if AppModelBridge.account?.hasAccountAccess == false {
            input = .keyboard
            notice = "Sign in to ForeverLM to use the quick assistant."
            return
        }
        Task { await startListening() }
    }

    /// Stops and sends while listening; sends a typed message; otherwise
    /// listens for a follow-up in the same chat.
    func shortcutPressedWhileShown() {
        if dictation.isRecording {
            Task { await finishListening(sending: true) }
        } else if dictation.isTranscribing {
            return
        } else if input == .keyboard, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submitDraft()
        } else {
            Task { await startListening() }
        }
    }

    // MARK: Voice

    func startListening() async {
        guard !dictation.isRecording, !dictation.isTranscribing else { return }
        notice = nil
        input = .voice
        let started = epoch
        await dictation.startRecording()
        guard started == epoch else {
            dictation.cancelRecording()
            return
        }
        if let failure = dictation.errorMessage {
            notice = failure
            input = .keyboard
        }
    }

    /// Stops the microphone and transcribes; the words are sent, or put in
    /// the field to be edited first.
    func finishListening(sending: Bool) async {
        guard dictation.isRecording else { return }
        let started = epoch
        let text = await dictation.stopAndTranscribe()
        guard started == epoch else { return }
        guard let text, !text.isEmpty else {
            notice = dictation.errorMessage ?? "Nothing was heard."
            input = .keyboard
            return
        }
        if sending {
            send(text)
        } else {
            draft = text
            input = .keyboard
        }
    }

    func cancelListening() {
        dictation.cancelRecording()
    }

    func switchToKeyboard() {
        if dictation.isRecording { dictation.cancelRecording() }
        input = .keyboard
    }

    // MARK: Sending

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    private func send(_ text: String) {
        notice = nil
        input = .keyboard
        let manager = self.manager ?? StudioAssistantSession.makeManager()
        self.manager = manager
        Task {
            await manager.sendMessage(
                text,
                topic: "",
                initialMode: .assistant,
                contextualContent: Prompts.quickAssistantTurn
            )
        }
    }

    func stop() {
        manager?.stopGeneration()
    }

    func retry() {
        guard let manager, manager.canRetryLastGeneration else { return }
        Task { await manager.retryLastGeneration() }
    }

    func openInForeverLM() {
        guard let sessionID else { return }
        QuickAssistantController.shared.openChat(sessionID)
        dismiss()
    }

    // MARK: Keys

    func escape() {
        if dictation.isRecording {
            cancelListening()
            if manager == nil { dismiss() }
            return
        }
        dismiss()
    }

    /// Keys the bar takes before any view does: Escape puts it away (or
    /// drops the recording), Return sends what is being said, and typing a
    /// letter while it listens turns it into a text field with that letter in
    /// it. Everything else, typing in the field included, goes on as usual.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Escape
            escape()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return, Enter
            if dictation.isRecording {
                Task { await finishListening(sending: true) }
                return true
            }
            return false
        }
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              input == .voice, !dictation.isTranscribing else { return false }
        switchToKeyboard()
        draft += characters
        return true
    }

    /// Puts the bar away. The chat is already saved; the next summon starts
    /// a new one.
    func dismiss() {
        epoch += 1
        if dictation.isRecording { dictation.cancelRecording() }
        if let manager, manager.hasGenerationWorkInFlight {
            finishing.append(manager)
        }
        finishing.removeAll { !$0.hasGenerationWorkInFlight }
        manager = nil
        draft = ""
        notice = nil
        input = .voice
        close?()
    }
}
