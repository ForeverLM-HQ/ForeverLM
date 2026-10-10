import AVFoundation
import Combine
import Foundation
import os

#if os(macOS)
/// One line per finished dictation with where its time went. At `.notice` so
/// it survives in the unified log; "dictation is slow" was undiagnosable on
/// 2026-09-07 because nothing recorded how long any step took.
private let dictationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "Dictation"
)

@MainActor
final class ReviewDictationService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevels = Array(repeating: 0.08, count: 48)
    /// Whole seconds since the mic opened, for the composer's recording counter.
    /// Republished only when the second ticks over, so the 30Hz meter doesn't
    /// invalidate the counter's text 30 times a second for no visible change.
    @Published var recordingSeconds = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meteringTimer: Timer?
    private var recordingStartedAt: Date?
    private var shouldAutoStopAfterSilence = false
    private var hasDetectedSpeech = false
    private var silenceStartedAt: Date?
    private var didRequestAutoStop = false
    private var onAutoStopAfterSilence: (() -> Void)?
    private let session: URLSession
    private let speechStartLevel = 0.16
    private let silenceStopLevel = 0.12
    private let silenceStopDuration: TimeInterval = 1.45
    private let minimumAutoStopRecordingDuration: TimeInterval = 0.9

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        super.init()
    }

    func startRecording(
        automaticallyStopsAfterSilence: Bool = false,
        onAutoStopAfterSilence: (() -> Void)? = nil
    ) async {
        errorMessage = nil

        // Every recording is transcribed after it stops, through OpenRouter's
        // speech-to-text (`ManagedTranscriptionClient`). The live realtime
        // rail went on 2026-10-01 with every model that OpenRouter does not
        // serve.
        do {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw DictationError.microphoneDenied
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("foreverlm-review-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            // 16 kHz mono is what every speech model resamples to before it
            // transcribes anything, so the extra bandwidth of a 44.1 kHz
            // high-quality capture buys no accuracy — it only makes the file
            // the learner waits on after the mic closes roughly four times
            // larger to read, base64, and upload.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw DictationError.recordingFailed
            }
            self.recorder = recorder
            recordingURL = url
            recordingStartedAt = Date()
            recordingSeconds = 0
            shouldAutoStopAfterSilence = automaticallyStopsAfterSilence
            hasDetectedSpeech = false
            silenceStartedAt = nil
            didRequestAutoStop = false
            self.onAutoStopAfterSilence = onAutoStopAfterSilence
            isRecording = true
            startMetering()
            // The upload this recording ends in should not start cold.
            ManagedTranscriptionClient.warmConnection(session: session)
        } catch {
            errorMessage = error.localizedDescription
            stopMetering()
        }
    }

    func stopAndTranscribe() async -> String? {
        guard isRecording else { return nil }
        stopMetering()
        recorder?.stop()
        recorder = nil
        isRecording = false

        guard let recordingURL else {
            errorMessage = DictationError.missingRecording.localizedDescription
            return nil
        }

        isTranscribing = true
        defer {
            isTranscribing = false
            // Delete the temp recording off-main; file I/O on the main actor is a
            // stall risk even for small files.
            Task.detached(priority: .utility) { [recordingURL] in
                try? FileManager.default.removeItem(at: recordingURL)
            }
            self.recordingURL = nil
            self.recordingStartedAt = nil
            self.recordingSeconds = 0
            self.shouldAutoStopAfterSilence = false
            self.hasDetectedSpeech = false
            self.silenceStartedAt = nil
            self.didRequestAutoStop = false
            self.onAutoStopAfterSilence = nil
        }

        do {
            let text = try await transcribe(fileURL: recordingURL)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cancelRecording() {
        stopMetering()
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let recordingURL {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }
        recordingURL = nil
        recordingStartedAt = nil
        recordingSeconds = 0
        shouldAutoStopAfterSilence = false
        hasDetectedSpeech = false
        silenceStartedAt = nil
        didRequestAutoStop = false
        onAutoStopAfterSilence = nil
    }

    private func startMetering() {
        stopMetering(resetLevels: false)
        audioLevels = Array(repeating: 0.08, count: audioLevels.count)
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleAudioLevel()
            }
        }
    }

    private func stopMetering(resetLevels: Bool = true) {
        meteringTimer?.invalidate()
        meteringTimer = nil
        if resetLevels {
            audioLevels = Array(repeating: 0.08, count: audioLevels.count)
        }
    }

    private func sampleAudioLevel() {
        guard isRecording, let recorder else { return }
        recorder.updateMeters()
        let power = max(Double(recorder.averagePower(forChannel: 0)), -60)
        let linearPower = pow(10, power / 20)
        let level = min(max(pow(linearPower, 0.35), 0.08), 1)
        audioLevels.removeFirst()
        audioLevels.append(level)
        if let recordingStartedAt {
            let seconds = Int(Date().timeIntervalSince(recordingStartedAt))
            if seconds != recordingSeconds {
                recordingSeconds = seconds
            }
        }
        updateAutomaticSilenceStop(level: level)
    }

    private func updateAutomaticSilenceStop(level: Double) {
        guard shouldAutoStopAfterSilence,
              !didRequestAutoStop,
              let recordingStartedAt else { return }

        let now = Date()
        if level >= speechStartLevel {
            hasDetectedSpeech = true
            silenceStartedAt = nil
            return
        }

        guard hasDetectedSpeech,
              now.timeIntervalSince(recordingStartedAt) >= minimumAutoStopRecordingDuration,
              level <= silenceStopLevel else {
            silenceStartedAt = nil
            return
        }

        if silenceStartedAt == nil {
            silenceStartedAt = now
        }

        guard let silenceStartedAt,
              now.timeIntervalSince(silenceStartedAt) >= silenceStopDuration else { return }

        didRequestAutoStop = true
        onAutoStopAfterSilence?()
    }

    private func transcribe(fileURL: URL) async throws -> String {
        let activityID = UUID().uuidString
        let startedAt = Date()
        let result = try await AIUsageAttribution.$activityID.withValue(activityID) {
            try await AIUsageAttribution.$task.withValue("review_dictation") {
                try await ManagedTranscriptionClient.transcribe(
                    fileURL: fileURL,
                    session: session
                )
            }
        }
        let totalMilliseconds = Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
        dictationLogger.notice(
            "Dictation transcribed model=\(result.model, privacy: .public) audio_s=\(result.report.durationSeconds ?? 0, format: .fixed(precision: 1), privacy: .public) encode_ms=\(result.encodeMilliseconds, privacy: .public) round_trip_ms=\(result.roundTripMilliseconds, privacy: .public) total_ms=\(totalMilliseconds, privacy: .public)"
        )
        // The proxy's debit is the record that matters; this mirror is for
        // the usage pane. It used to be awaited here, which put a write on the
        // storage actor — behind whatever maintenance held its lane — between
        // the transcript arriving and the composer showing it. It is written
        // while the words go into the composer instead, and a failure is
        // logged and counted by the ledger health the same way it always was.
        Task.detached(priority: .utility) {
            do {
                try await AIUsageTracker.shared.record(
                    provider: result.providerName,
                    model: result.model,
                    operation: "speech_to_text",
                    report: result.report,
                    task: "review_dictation",
                    activityID: activityID
                )
            } catch {
                dictationLogger.error(
                    "Could not mirror dictation usage locally: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return result.text
    }

    #if DEBUG
    /// Runs the exact production upload, response validation, and usage-write
    /// path against an existing audio fixture. The opt-in live API suite uses
    /// this instead of opening the microphone, keeping the request repeatable
    /// while still exercising the real managed transcription endpoint.
    func transcribeProbe(fileURL: URL) async throws -> String {
        try await transcribe(fileURL: fileURL)
    }
    #endif

}

private enum DictationError: LocalizedError {
    case microphoneDenied
    case recordingFailed
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required for review dictation."
        case .recordingFailed:
            return "Could not start audio recording."
        case .missingRecording:
            return "No recording was available to transcribe."
        }
    }
}

#endif
