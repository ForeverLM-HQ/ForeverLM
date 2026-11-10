#if os(macOS)
import AVFoundation
import AppKit
import CoreAudio
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

/// The Mac's part of a voice call: the microphone permission, and watching the
/// default speaker and microphone. WebRTC opens the defaults itself when a
/// call opens and cancels echo in software, but keeps those devices for the
/// whole call, so putting AirPods in mid-call would leave it on the built-in
/// speaker and microphone until the controller reopens it.
///
/// The default microphone is also kept running for the whole call, from before
/// WebRTC opens anything (`MacCallMicrophoneHold`), so a Bluetooth headset is
/// already in its call mode, at the sample rate it keeps, when WebRTC opens it.
final class MacRealtimeVoicePlatformAudio: RealtimeVoicePlatformAudio, @unchecked Sendable {
    private let lock = NSLock()
    private var watcher: MacDefaultAudioDevicesWatcher?
    private var microphone: MacCallMicrophoneHold?

    func prepare(
        usesMicrophone: Bool,
        onPreempted: @escaping @Sendable () -> Void,
        onDevicesChanged: @escaping @Sendable () -> Void
    ) async throws {
        if usesMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw MacRealtimeVoiceError.microphoneDenied
        }
        let microphone = usesMicrophone ? MacCallMicrophoneHold() : nil
        await microphone?.holdDefaultMicrophone()
        // The call reopens on the new devices only once the new microphone is
        // held and the new speaker has settled, for the same reason.
        let watcher = MacDefaultAudioDevicesWatcher(onChange: {
            Task {
                await microphone?.holdDefaultMicrophone()
                onDevicesChanged()
            }
        })
        let previous = lock.withLock {
            let previous = (self.watcher, self.microphone)
            self.watcher = watcher
            self.microphone = microphone
            return previous
        }
        previous.0?.stop()
        previous.1?.release()
    }

    func finish() async {
        let held = lock.withLock {
            let held = (self.watcher, self.microphone)
            self.watcher = nil
            self.microphone = nil
            return held
        }
        held.0?.stop()
        held.1?.release()
    }
}

/// Keeps the Mac's default microphone running for the whole call, started
/// before WebRTC opens any device.
///
/// A Bluetooth headset such as AirPods plays at 48 kHz and drops to its call
/// mode, 24 or 16 kHz, the moment any app starts its microphone. WebRTC on the
/// Mac opens the speaker first and the microphone after it, so the speaker's
/// rate changed under a call that was already playing, and WebRTC went on
/// writing 48 kHz audio into a 24 kHz device: the voice played at half speed,
/// an octave down (product owner, 2026-11-09: "it just sounds like it's very
/// slowed down and very deep"; the log showed AirPods' output going from 48000
/// to 24000 Hz as WebRTC started their microphone). With the microphone already
/// running, the headset is in call mode before WebRTC opens it, and stays there
/// across the controller's reopens.
final class MacCallMicrophoneHold: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoice")
    /// How long a Bluetooth speaker's sample rate must stay put before the call
    /// opens on it, and the longest the call waits for that. AirPods can take
    /// a second or two to bring their call mode up.
    private static let settledFor: Duration = .milliseconds(700)
    private static let longestWait: Duration = .seconds(3)
    private static let pollInterval: Duration = .milliseconds(100)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Starts the current default microphone, leaving any other one this hold
    /// was running, then, when the default speaker is Bluetooth, waits until
    /// its sample rate has stopped changing.
    func holdDefaultMicrophone() async {
        let input = MacAudioDevice.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let output = MacAudioDevice.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        hold(input)
        guard output != kAudioObjectUnknown, MacAudioDevice.isBluetooth(output) else { return }
        let clock = ContinuousClock()
        let started = clock.now
        let before = MacAudioDevice.nominalSampleRate(output)
        var rate = before
        var stableSince = started
        while clock.now - started < Self.longestWait, clock.now - stableSince < Self.settledFor {
            try? await Task.sleep(for: Self.pollInterval)
            let now = MacAudioDevice.nominalSampleRate(output)
            if now != rate {
                rate = now
                stableSince = clock.now
            }
        }
        let waited = clock.now - started
        Self.logger.notice(
            "Voice Bluetooth speaker \(output, privacy: .public) at \(rate, privacy: .public) Hz (was \(before, privacy: .public)) after \(String(describing: waited), privacy: .public)"
        )
    }

    /// Stops the microphone. Safe to call more than once.
    func release() {
        lock.withLock { stopHeld() }
    }

    private func hold(_ input: AudioDeviceID) {
        lock.withLock {
            if procID != nil, device == input { return }
            stopHeld()
            guard input != kAudioObjectUnknown else { return }
            var created: AudioDeviceIOProcID?
            // Nothing is read: a running input is what puts the headset in call
            // mode. WebRTC captures the microphone on its own.
            var status = AudioDeviceCreateIOProcIDWithBlock(&created, input, nil) { _, _, _, _, _ in }
            guard status == noErr, let created else {
                Self.logger.error("Voice cannot open microphone \(input, privacy: .public): \(status, privacy: .public)")
                return
            }
            status = AudioDeviceStart(input, created)
            guard status == noErr else {
                AudioDeviceDestroyIOProcID(input, created)
                Self.logger.error("Voice cannot start microphone \(input, privacy: .public): \(status, privacy: .public)")
                return
            }
            device = input
            procID = created
        }
    }

    /// Under `lock`.
    private func stopHeld() {
        guard let held = procID else { return }
        AudioDeviceStop(device, held)
        AudioDeviceDestroyIOProcID(device, held)
        procID = nil
        device = AudioDeviceID(kAudioObjectUnknown)
    }
}

/// The few CoreAudio device properties voice mode reads.
enum MacAudioDevice {
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// 0 when the device cannot say.
    static func nominalSampleRate(_ device: AudioDeviceID) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}

/// Calls `onChange` when the Mac's default output or input device has become
/// a different one. AirPods switch both, a moment apart, so changes are
/// settled for a short while and reported once.
final class MacDefaultAudioDevicesWatcher: @unchecked Sendable {
    private static let selectors = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]
    private static let settleDelay: DispatchTimeInterval = .milliseconds(600)
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoice")

    private let queue = DispatchQueue(label: "com.foreverlm.voice.audio-devices")
    private let onChange: @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    // Read and written on `queue` only.
    private var reported: [AudioDeviceID]
    private var pendingCheck: DispatchWorkItem?
    private var isStopped = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        reported = Self.currentDefaults()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleCheck()
        }
        self.listener = listener
        for selector in Self.selectors {
            var address = Self.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            )
            if status != noErr {
                Self.logger.error("Voice cannot watch the default audio device (\(selector)): \(status)")
            }
        }
    }

    /// Stops watching. Never called on `queue`.
    func stop() {
        queue.sync {
            isStopped = true
            pendingCheck?.cancel()
            pendingCheck = nil
        }
        guard let listener else { return }
        self.listener = nil
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            )
        }
    }

    /// On `queue`, where CoreAudio calls the listener.
    private func scheduleCheck() {
        guard !isStopped else { return }
        pendingCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            let now = Self.currentDefaults()
            guard now != self.reported else { return }
            self.reported = now
            Self.logger.notice("Voice default audio devices changed (output, input): \(now, privacy: .public)")
            self.onChange()
        }
        pendingCheck = check
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: check)
    }

    private static func currentDefaults() -> [AudioDeviceID] {
        selectors.map { selector in
            var address = address(selector)
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            )
            return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
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
