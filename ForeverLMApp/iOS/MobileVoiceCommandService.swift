import AVFoundation
import Foundation
import Speech

/// Apple's speech recognition, listening continuously and handing each
/// utterance over after a short silence. The Siri hands-free loop owns it
/// (holder `.voiceTab`); the holder is whose lease the microphone is taken
/// under (`MobileAudioSessionArbiter`).
@MainActor
final class MobileVoiceCommandService: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?

    var onTranscript: ((String) -> Void)?

    private let holder: MobileAudioSessionArbiter.Holder
    private let recognizer = MobileVoiceCommandService.makeRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptDebounceTask: Task<Void, Never>?
    private var shouldKeepListening = false
    private var isRestarting = false

    init(holder: MobileAudioSessionArbiter.Holder = .voiceTab) {
        self.holder = holder
        super.init()
    }

    /// Dictates in the speaker's own language where the device supports it,
    /// falling back to US English otherwise.
    ///
    /// Safe to localize because nothing downstream matches English keywords:
    /// `handleVoiceTranscript` hands the utterance to the voice agent model,
    /// which reads a Dutch instruction as readily as an English one.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales()
        let preferred = Locale.current

        if supported.contains(where: { $0.identifier == preferred.identifier }) {
            return SFSpeechRecognizer(locale: preferred)
        }
        // A region miss is harmless — an nl-BE speaker dictates fine against the
        // nl-NL model — so only fall back to English if the language is absent.
        if let code = preferred.language.languageCode?.identifier,
           let sameLanguage = supported.first(where: {
               $0.language.languageCode?.identifier == code
           }) {
            return SFSpeechRecognizer(locale: sameLanguage)
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    }

    func start() async {
        guard !shouldKeepListening else { return }
        shouldKeepListening = true

        do {
            try await requestPermissions()
            try await startRecognitionWithRetry()
        } catch {
            errorMessage = error.localizedDescription
            isListening = false
            shouldKeepListening = false
        }
    }

    func stop() async {
        shouldKeepListening = false
        transcriptDebounceTask?.cancel()
        transcriptDebounceTask = nil
        await stopRecognition()
    }

    func resetAfterHandledCommand() {
        guard shouldKeepListening else { return }
        restartRecognition(after: 0.15)
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw MobileVoiceCommandError.speechDenied
        }

        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneGranted else {
            throw MobileVoiceCommandError.microphoneDenied
        }
    }

    private func startRecognitionWithRetry() async throws {
        var lastError: Error?

        for attempt in 0..<3 {
            do {
                try await startRecognition()
                return
            } catch MobileVoiceCommandError.microphoneUnavailable {
                lastError = MobileVoiceCommandError.microphoneUnavailable
                await stopRecognition()
                guard attempt < 2 else { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                throw error
            }
        }

        throw lastError ?? MobileVoiceCommandError.microphoneUnavailable
    }

    private func startRecognition() async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw MobileVoiceCommandError.speechUnavailable
        }

        await stopRecognition()
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }

        // The arbiter owns the session and configures it off the main actor.
        try await MobileAudioSessionArbiter.shared.acquire(holder, for: .record)

        // Starting the engine can block too; doing it on the main thread while the
        // session is active causes UI unresponsiveness (see SessionCore warning).
        let audioEngine = self.audioEngine
        try await Task.detached(priority: .userInitiated) {
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MobileVoiceCommandError.microphoneUnavailable
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
        }.value

        self.request = request
        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.scheduleTranscriptDelivery(self.transcript)
                }

                if error != nil || result?.isFinal == true {
                    self.restartRecognition(after: 0.35)
                }
            }
        }
    }

    private func scheduleTranscriptDelivery(_ text: String) {
        transcriptDebounceTask?.cancel()
        transcriptDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.onTranscript?(trimmed)
            }
        }
    }

    private func restartRecognition(after delay: TimeInterval) {
        guard shouldKeepListening, !isRestarting else { return }
        isRestarting = true
        // `isRestarting` already closes the door on re-entry, so the teardown moves
        // into the restart task rather than blocking the caller on the render thread.
        Task { [weak self] in
            await self?.stopRecognition()
            let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self else { return }
            self.isRestarting = false
            guard self.shouldKeepListening else { return }
            do {
                try await self.startRecognition()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isListening = false
            }
        }
    }

    private func stopRecognition() async {
        transcriptDebounceTask?.cancel()
        transcriptDebounceTask = nil

        // Everything this function will act on is claimed and published before the
        // teardown is awaited, so a start that lands during the handoff cannot be
        // clobbered — or have its fresh request ended — when this resumes.
        let endingRequest = request
        let cancellingTask = recognitionTask
        request = nil
        recognitionTask = nil
        isListening = false

        // stop() and removeTap() both synchronize with the audio render thread —
        // tens to hundreds of milliseconds over Bluetooth HFP — and this sits on
        // the critical path of every audio handoff, because acquire() awaits the
        // preempt handler that leads here. Never on the main actor.
        let audioEngine = self.audioEngine
        await Task.detached(priority: .userInitiated) {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
        }.value

        endingRequest?.endAudio()
        cancellingTask?.cancel()
    }
}

enum MobileVoiceCommandError: LocalizedError {
    case speechDenied
    case microphoneDenied
    case speechUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .speechDenied:
            return "Speech recognition permission is required for hands-free voice. Enable it in Settings › ForeverLM."
        case .microphoneDenied:
            return "Microphone permission is required for hands-free voice. Enable it in Settings › ForeverLM."
        case .speechUnavailable:
            return "Speech recognition is not available right now."
        case .microphoneUnavailable:
            return "Microphone input is not available right now."
        }
    }
}
