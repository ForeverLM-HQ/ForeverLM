import AVFoundation
import Combine
import Foundation
import os

#if os(macOS)
/// One line per finished dictation with where its time went. At `.notice` so
/// it survives in the unified log; "dictation is slow" can be diagnosed from
/// how long each step took.
private let dictationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "Dictation"
)

/// The recording's level meter and second counter, apart from the service.
///
/// The meter changes 30 times a second. Published on the service itself, it
/// re-ran the body of every view that holds the service — the whole chat pane,
/// transcript included — 30 times a second for as long as the mic was open,
/// which is what made recording feel glitchy. Only the meter's own views
/// observe this.
@MainActor
final class DictationMeter: ObservableObject {
    static let silentLevel = 0.08
    @Published var levels = Array(repeating: DictationMeter.silentLevel, count: 48)
    /// Whole seconds since the mic opened. Republished only when the second
    /// ticks over.
    @Published var seconds = 0

    func reset() {
        levels = Array(repeating: Self.silentLevel, count: levels.count)
        if seconds != 0 { seconds = 0 }
    }
}

/// Carries a recorder opened off the main thread back to it.
private final class RecorderBox: @unchecked Sendable {
    let recorder: AVAudioRecorder
    init(_ recorder: AVAudioRecorder) { self.recorder = recorder }
}

@MainActor
final class ReviewDictationService: NSObject, ObservableObject {
    /// True from the click on: the waveform shows at once, while the mic is
    /// still being opened (`openMic`), rather than after it.
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var errorMessage: String?
    let meter = DictationMeter()

    private var recorder: AVAudioRecorder?
    /// The mic being opened, off the main thread. Stop and cancel wait for it.
    private var startTask: Task<Void, Never>?
    /// Bumped by every start and cancel, so a mic that finishes opening after
    /// the learner cancelled is closed rather than adopted.
    private var recordingGeneration = 0
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

    /// The usage ledger's label for what this recorder transcribes for.
    private let usageTask: String

    override convenience init() {
        self.init(usageTask: "review_dictation")
    }

    init(usageTask: String) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        self.usageTask = usageTask
        super.init()
    }

    func startRecording(
        automaticallyStopsAfterSilence: Bool = false,
        onAutoStopAfterSilence: (() -> Void)? = nil
    ) async {
        guard !isRecording, !isTranscribing else { return }
        errorMessage = nil
        recordingGeneration += 1
        let generation = recordingGeneration
        // The waveform shows on the click itself. Opening the mic can take a
        // few hundred milliseconds (more when AirPods switch profile), and
        // that wait used to sit on the main thread with nothing on screen.
        meter.reset()
        isRecording = true
        recordingStartedAt = Date()
        shouldAutoStopAfterSilence = automaticallyStopsAfterSilence
        hasDetectedSpeech = false
        silenceStartedAt = nil
        didRequestAutoStop = false
        self.onAutoStopAfterSilence = onAutoStopAfterSilence

        let task = Task { [weak self] in
            guard let self else { return }
            await self.openMic(generation: generation)
        }
        startTask = task
        await task.value
    }

    private func openMic(generation: Int) async {
        defer { if generation == recordingGeneration { startTask = nil } }
        // Every recording is transcribed after it stops, through OpenRouter's
        // speech-to-text (`ManagedTranscriptionClient`). There is no live
        // realtime rail: it needed models that OpenRouter does not serve.
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
            // Creating, preparing and starting the recorder wakes the audio
            // hardware; it is done off the main thread so the click never
            // stalls the window.
            let box = try await Task.detached(priority: .userInitiated) { () throws -> RecorderBox in
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.isMeteringEnabled = true
                recorder.prepareToRecord()
                guard recorder.record() else {
                    throw DictationError.recordingFailed
                }
                return RecorderBox(recorder)
            }.value
            guard generation == recordingGeneration, isRecording else {
                // Cancelled while the mic was opening.
                Self.discard(box.recorder, at: url)
                return
            }
            self.recorder = box.recorder
            recordingURL = url
            // The counter starts when the mic is really listening.
            recordingStartedAt = Date()
            startMetering()
            // The upload this recording ends in should not start cold.
            ManagedTranscriptionClient.warmConnection(session: session)
        } catch {
            guard generation == recordingGeneration else { return }
            errorMessage = error.localizedDescription
            resetRecordingState()
        }
    }

    private nonisolated static func discard(_ recorder: AVAudioRecorder, at url: URL) {
        let box = RecorderBox(recorder)
        Task.detached(priority: .utility) {
            box.recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stops the recorder off the main thread; `stop()` finalises the file,
    /// which the transcription then reads.
    private nonisolated static func finish(_ recorder: AVAudioRecorder) async {
        let box = RecorderBox(recorder)
        await Task.detached(priority: .userInitiated) {
            box.recorder.stop()
        }.value
    }

    private func resetRecordingState() {
        stopMetering()
        isRecording = false
        recordingStartedAt = nil
        shouldAutoStopAfterSilence = false
        hasDetectedSpeech = false
        silenceStartedAt = nil
        didRequestAutoStop = false
        onAutoStopAfterSilence = nil
    }

    func stopAndTranscribe() async -> String? {
        guard isRecording else { return nil }
        // A stop that lands while the mic is still opening waits for it, so
        // a quick click-click records the moment rather than failing.
        if let startTask { await startTask.value }
        guard isRecording else { return nil }
        stopMetering()
        // The transcribing state shows before the file is finalised, so the
        // row moves straight from the waveform to the spinner.
        isTranscribing = true
        isRecording = false
        let finishing = recorder
        recorder = nil
        if let finishing { await Self.finish(finishing) }

        guard let recordingURL else {
            isTranscribing = false
            errorMessage = DictationError.missingRecording.localizedDescription
            return nil
        }

        defer {
            isTranscribing = false
            // Delete the temp recording off-main; file I/O on the main actor is a
            // stall risk even for small files.
            Task.detached(priority: .utility) { [recordingURL] in
                try? FileManager.default.removeItem(at: recordingURL)
            }
            self.recordingURL = nil
            self.recordingStartedAt = nil
            self.meter.reset()
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
        // A mic still opening is closed when it arrives (`openMic`).
        recordingGeneration += 1
        startTask = nil
        if let recorder, let recordingURL {
            Self.discard(recorder, at: recordingURL)
        } else if let recordingURL {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }
        recorder = nil
        recordingURL = nil
        resetRecordingState()
        meter.reset()
    }

    private func startMetering() {
        stopMetering(resetLevels: false)
        meter.reset()
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
            meter.reset()
        }
    }

    private func sampleAudioLevel() {
        guard isRecording, let recorder else { return }
        recorder.updateMeters()
        let power = max(Double(recorder.averagePower(forChannel: 0)), -60)
        let linearPower = pow(10, power / 20)
        let level = min(max(pow(linearPower, 0.35), 0.08), 1)
        var levels = meter.levels
        levels.removeFirst()
        levels.append(level)
        meter.levels = levels
        if let recordingStartedAt {
            let seconds = Int(Date().timeIntervalSince(recordingStartedAt))
            if seconds != meter.seconds {
                meter.seconds = seconds
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
            try await AIUsageAttribution.$task.withValue(usageTask) {
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
        // the usage pane. It is not awaited before the words show, since that
        // would put a write on the storage actor — behind whatever maintenance
        // held its lane — between the transcript arriving and the composer
        // showing it. It is written while the words go into the composer
        // instead, and a failure is logged and counted by the ledger health.
        let usageTask = usageTask
        Task.detached(priority: .utility) {
            do {
                try await AIUsageTracker.shared.record(
                    provider: result.providerName,
                    model: result.model,
                    operation: "speech_to_text",
                    report: result.report,
                    task: usageTask,
                    activityID: activityID,
                    generationID: result.generationID
                )
            } catch {
                dictationLogger.error(
                    "Could not mirror dictation usage locally: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return result.text
    }

    /// A recording made elsewhere (the canvas keeps its own while the Mac
    /// shows the words live), transcribed by the same model and path as
    /// dictation, and counted under this recorder's usage label.
    func transcribeRecording(at fileURL: URL) async throws -> String {
        try await transcribe(fileURL: fileURL)
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
            return "Microphone access is required for dictation."
        case .recordingFailed:
            return "Could not start audio recording."
        case .missingRecording:
            return "No recording was available to transcribe."
        }
    }
}

#endif
