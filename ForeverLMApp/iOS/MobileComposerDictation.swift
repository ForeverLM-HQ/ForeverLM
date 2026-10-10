import AVFoundation
import Foundation
import os
#if canImport(Speech)
import Speech
#endif

private let composerDictationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "ComposerDictation"
)

// Tap-to-talk dictation for the chat composer.
//
// One utterance per tap, unlike MobileVoiceCommandService's continuous listen
// loop: partial results stream into `partialText` so words appear in the
// composer as they are spoken, and the utterance finalizes on a short silence
// (or on a second tap). The final text is handed back exactly once.
//
// Recognition stays on device: Apple's speech recognition, free, private, and
// usable offline. It is not a model the learner picks. The realtime rail that
// could stream the microphone to OpenAI's transcription session went on
// 2026-10-01, when every model moved to OpenRouter.
//
// This type never touches AVAudioSession. It leases the mic from
// MobileAudioSessionArbiter, which is what keeps the Voice tab and the reading
// chat from reconfiguring the route out from under each other.
@MainActor
final class MobileComposerDictation: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case denied(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialText = ""
    /// Whether the mic button exists at all. Starts false and is published from
    /// `refreshAvailability()`, because answering it means constructing an
    /// SFSpeechRecognizer — an XPC round trip to the speech daemon that must never
    /// happen while a view body is evaluating.
    @Published private(set) var isAvailable = false

    // The listening utterance owns the delivery.
    private var onFinalText: (@MainActor (String) -> Void)?
    private var didDeliver = false

    // Seconds of silence after the last partial result before the utterance ends.
    private static let silenceTimeout: TimeInterval = 1.5

    func refreshAvailability() async {
        guard !isAvailable else { return }
        await refreshOnDeviceAvailability()
    }

    func toggle(onFinalText: @escaping @MainActor (String) -> Void) {
        switch state {
        case .listening:
            Task { await finish() }
        case .requestingPermission:
            // Nothing has been transcribed yet, so a second tap means "never mind".
            Task { await cancel() }
        case .idle, .denied, .failed:
            beginOnDevice(onFinalText: onFinalText)
        }
    }

    /// Finalizes the current utterance and delivers its transcript. Exposed so a
    /// composer can wait for the delivered text before immediately sending it.
    func finish() async {
        await finalizeOnDevice()
    }

    // Published state settles before the engine teardown is awaited, so a tap that
    // lands during the handoff cannot be overwritten when this resumes.
    func cancel() async {
        await cancelOnDevice()
    }

    private func deliver(_ text: String) {
        let handler = onFinalText
        onFinalText = nil       // one-shot: the silence timer, isFinal and the error
                                // path all race to finalize, and only one may land
        guard !text.isEmpty else { return }
        handler?(text)
    }

#if canImport(Speech)
    // The composer follows the user's language rather than the hardcoded en_US
    // the driving/Siri paths use, since it transcribes free-form typing input.
    // Resolved lazily off-main; init constructs nothing.
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init() {
        // The arbiter drives this when another holder takes the session, so a
        // preempted composer tears its tap down instead of leaving a dead one
        // installed and a mic indicator burning.
        Task { [weak self] in
            await MobileAudioSessionArbiter.shared.register(.readingDictation) { [weak self] in
                await self?.cancel()
            }
        }
    }

    /// Resolves the recognizer once, off-main, and keeps it for the session — so
    /// the answer costs one XPC round trip whether or not the user dictates.
    private func refreshOnDeviceAvailability() async {
        isAvailable = (try? await resolveRecognizer()) != nil
    }

    private func cancelOnDevice() async {
        didDeliver = true
        onFinalText = nil
        startTask?.cancel()
        startTask = nil
        partialText = ""
        state = .idle
        await teardown()
    }

    private func beginOnDevice(onFinalText: @escaping @MainActor (String) -> Void) {
        self.onFinalText = onFinalText
        didDeliver = false
        partialText = ""
        state = .requestingPermission

        // Permission prompts, the session lease and the engine start all block;
        // none of it may run inline on the main actor.
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.requestPermissions()
                try Task.checkCancellation()
                try await MobileAudioSessionArbiter.shared.acquire(.readingDictation, for: .record)
                try Task.checkCancellation()
                try await self.startRecognition()
                self.startTask = nil
            } catch is CancellationError {
                // cancel() already tore everything down.
            } catch let error as MobileComposerDictationError {
                await self.fail(with: error.localizedDescription, isPermissionDenial: error.isPermissionDenial)
            } catch {
                await self.fail(with: error.localizedDescription, isPermissionDenial: false)
            }
        }
    }

    private static func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw MobileComposerDictationError.speechDenied
        }

        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneGranted else {
            throw MobileComposerDictationError.microphoneDenied
        }
    }

    private func resolveRecognizer() async throws -> SFSpeechRecognizer {
        if let recognizer { return recognizer }
        let resolved = await Task.detached(priority: .userInitiated) {
            SFSpeechRecognizer(locale: Locale.current)
        }.value
        guard let resolved else { throw MobileComposerDictationError.speechUnavailable }
        recognizer = resolved
        return resolved
    }

    private func startRecognition() async throws {
        let recognizer = try await resolveRecognizer()
        guard recognizer.isAvailable else {
            throw MobileComposerDictationError.speechUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Constructing the engine builds its node graph and reaches into CoreAudio,
        // so it happens on first use rather than in init() — and off-main, like the
        // tap install and start that follow it. Stored before it is configured, so
        // teardown() can still stop an engine whose start() threw.
        if audioEngine == nil {
            audioEngine = await Task.detached(priority: .userInitiated) { AVAudioEngine() }.value
        }
        guard let audioEngine else {
            throw MobileComposerDictationError.microphoneUnavailable
        }

        try await Task.detached(priority: .userInitiated) {
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MobileComposerDictationError.microphoneUnavailable
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
        }.value

        self.request = request
        state = .listening
        scheduleSilenceFinalize()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    if result.isFinal {
                        await self.finalizeOnDevice()
                        return
                    }
                    self.scheduleSilenceFinalize()
                }

                if let error {
                    // Recognition routinely errors out at the tail of an utterance
                    // (no speech detected, request ended). Whatever was heard is
                    // still the user's text; only report when there is nothing.
                    if self.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await self.fail(with: error.localizedDescription, isPermissionDenial: false)
                    } else {
                        await self.finalizeOnDevice()
                    }
                }
            }
        }
    }

    private func scheduleSilenceFinalize() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            let nanoseconds = UInt64(max(Self.silenceTimeout, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.finalizeOnDevice()
        }
    }

    private func finalizeOnDevice() async {
        guard !didDeliver else { return }
        didDeliver = true

        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .idle
        deliver(text)
        await teardown()
    }

    private func fail(with message: String, isPermissionDenial: Bool) async {
        // A late error from a task cancelled during teardown must not overwrite an
        // utterance that already ended cleanly.
        guard !didDeliver else { return }
        didDeliver = true
        onFinalText = nil
        startTask = nil
        partialText = ""
        state = isPermissionDenial ? .denied(message) : .failed(message)
        await teardown()
    }

    // Safe to call twice — every step is guarded or already idempotent.
    private func teardown() async {
        silenceTask?.cancel()
        silenceTask = nil

        // stop() and removeTap() both synchronize with the audio render thread —
        // tens to hundreds of milliseconds over Bluetooth HFP — and this sits on
        // the critical path of every audio handoff, because acquire() awaits the
        // preempt handler that calls cancel(). Never on the main actor.
        if let audioEngine = self.audioEngine {
            await Task.detached(priority: .userInitiated) {
                if audioEngine.isRunning {
                    audioEngine.stop()
                }
                audioEngine.inputNode.removeTap(onBus: 0)
            }.value
        }

        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        // Deliberately not awaited: this can run from the arbiter's preempt
        // handler, and a handler must never re-enter the arbiter it is running
        // inside. A stale release is a no-op — release() checks the holder.
        Task { await MobileAudioSessionArbiter.shared.release(.readingDictation) }
    }
#else
    // Without the Speech framework there is nothing to dictate with.
    private func refreshOnDeviceAvailability() async {}

    private func beginOnDevice(onFinalText _: @escaping @MainActor (String) -> Void) {
        state = .failed(MobileComposerDictationError.speechUnavailable.localizedDescription)
    }

    private func finalizeOnDevice() async {}

    private func cancelOnDevice() async {
        state = .idle
    }
#endif
}

private enum MobileComposerDictationError: LocalizedError {
    case speechDenied
    case microphoneDenied
    case speechUnavailable
    case microphoneUnavailable

    var isPermissionDenial: Bool {
        switch self {
        case .speechDenied, .microphoneDenied:
            return true
        case .speechUnavailable, .microphoneUnavailable:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .speechDenied:
            return "Speech recognition permission is required to dictate. Enable it in Settings › ForeverLM."
        case .microphoneDenied:
            return "Microphone permission is required to dictate. Enable it in Settings › ForeverLM."
        case .speechUnavailable:
            return "Speech recognition is not available right now."
        case .microphoneUnavailable:
            return "Microphone input is not available right now."
        }
    }
}
