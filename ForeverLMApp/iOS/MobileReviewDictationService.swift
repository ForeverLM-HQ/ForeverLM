import AVFoundation
import Foundation

@MainActor
final class MobileReviewDictationService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meteringTimer: Timer?
    private var recordingStartedAt: Date?
    private var hasDetectedSpeech = false
    private var silenceStartedAt: Date?
    private var didRequestAutoStop = false
    private var onAutoStopAfterSilence: (() -> Void)?
    private let session: URLSession
    private let speechStartLevel = 0.16
    private let silenceStopLevel = 0.12
    private let silenceStopDuration: TimeInterval = 1.15
    private let minimumAutoStopRecordingDuration: TimeInterval = 0.9

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        super.init()
    }

    func startRecording(onAutoStopAfterSilence: (() -> Void)? = nil) async {
        errorMessage = nil
        do {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw DictationError.microphoneDenied
            }

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try audioSession.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("foreverlm-mobile-review-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            // 16 kHz mono, as on the Mac: the transcription model resamples to
            // it anyway, and on a phone the upload that follows the recording
            // is the part most likely to be on a slow link.
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
            hasDetectedSpeech = false
            silenceStartedAt = nil
            didRequestAutoStop = false
            self.onAutoStopAfterSilence = onAutoStopAfterSilence
            isRecording = true
            startMetering()
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
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
            self.recordingStartedAt = nil
            self.hasDetectedSpeech = false
            self.silenceStartedAt = nil
            self.didRequestAutoStop = false
            self.onAutoStopAfterSilence = nil
        }

        do {
            let text = try await transcribeManaged(fileURL: recordingURL)
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
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        recordingStartedAt = nil
        hasDetectedSpeech = false
        silenceStartedAt = nil
        didRequestAutoStop = false
        onAutoStopAfterSilence = nil
    }

    private func startMetering() {
        stopMetering(reset: false)
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleAudioLevel()
            }
        }
    }

    private func stopMetering(reset: Bool = true) {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    private func sampleAudioLevel() {
        guard isRecording, let recorder else { return }
        recorder.updateMeters()
        let power = max(Double(recorder.averagePower(forChannel: 0)), -60)
        let linearPower = pow(10, power / 20)
        let level = min(max(pow(linearPower, 0.35), 0.08), 1)
        updateAutomaticSilenceStop(level: level)
    }

    private func updateAutomaticSilenceStop(level: Double) {
        guard !didRequestAutoStop, let recordingStartedAt else { return }

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

    private func transcribeManaged(fileURL: URL) async throws -> String {
        let activityID = UUID().uuidString
        let result = try await AIUsageAttribution.$activityID.withValue(activityID) {
            try await AIUsageAttribution.$task.withValue("review_dictation") {
                try await ManagedTranscriptionClient.transcribe(
                    fileURL: fileURL,
                    session: session
                )
            }
        }
        return result.text
    }
}

private enum DictationError: LocalizedError {
    case microphoneDenied
    case recordingFailed
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required for audio review."
        case .recordingFailed:
            return "Could not start audio recording."
        case .missingRecording:
            return "No recording was available to transcribe."
        }
    }
}
