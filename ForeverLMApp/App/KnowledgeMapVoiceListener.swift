import AVFoundation
import Foundation
import os
import Speech

// MARK: - Hearing the learner on this Mac, as they speak
//
// Speaking to the Canvas has to answer within a second of letting go (product
// owner, 2026-10-13: "make sure the time is VERY fast for these kind of
// interactive canvas operations", and, of models, "potentially even on-disk
// apple intelligence model if it's supported … try all these options").
// Measured that night: OpenRouter's speech-to-text on the Dictation model
// starts only once the learner lets go, a round trip of the whole recording;
// Apple's on-device recognizer (SpeechAnalyzer) took 83–269 ms for a whole
// 3.5 s clip, and streamed while the learner speaks it has the words the
// moment they stop. So the canvas listens on this Mac when it can: the words
// show in the capsule as they are said, and letting go only finalizes them.
// Where this Mac cannot (an older macOS, a language it has no model for, its
// speech model still downloading) the canvas records and transcribes on the
// Dictation model instead, as dictation does (`KnowledgeMapVoice`).

private let listenerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "CanvasVoice"
)

@available(macOS 26.0, *)
@MainActor
final class KnowledgeMapVoiceListener {
    enum Failure: LocalizedError {
        case microphoneDenied
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access is required to speak to the canvas."
            case .noMicrophone: return "No microphone is available."
            }
        }
    }

    /// The words so far: the finished ones, then the ones still being heard.
    var onWords: ((String) -> Void)?
    /// The microphone's level, 0…1, about thirty times a second.
    var onLevel: ((Double) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finished = ""
    private var volatile = ""
    private var running = false
    /// Whether the microphone's tap is installed. A recording (the eval)
    /// never opens it, and touching `engine.inputNode` when it was never
    /// opened asks for the microphone, which hung `finish` behind the lock
    /// screen on 2026-10-13.
    private var microphoneOpen = false

    /// The locale this Mac can recognize the learner's speech in, if any.
    static func locale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    /// Whether the speech model for `locale` is on this Mac. When it is not,
    /// its download starts in the background and this returns false: the
    /// request in hand goes to the Dictation model rather than wait for it.
    static func isReady(for locale: Locale) async -> Bool {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return true
        case .unsupported:
            return false
        default:
            Task.detached(priority: .utility) {
                do {
                    if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await install.downloadAndInstall()
                    }
                } catch {
                    listenerLogger.error("Speech model download failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return false
        }
    }

    /// Opens the microphone and starts hearing. `recording` (the DEBUG eval's)
    /// stands in for the microphone: it is played through the same tap, in
    /// real time, and this returns once it has all been heard, as when the
    /// learner lets go.
    func start(locale: Locale, recording: URL? = nil) async throws {
        let file = try recording.map { try AVAudioFile(forReading: $0) }
        if file == nil {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let hardware = file?.processingFormat ?? engine.inputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noMicrophone }
        let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? hardware
        let converter = AVAudioConverter(from: hardware, to: wanted)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.input = continuation
        finished = ""
        volatile = ""

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let words = String(result.text.characters)
                    if result.isFinal {
                        self.finished += words
                        self.volatile = ""
                    } else {
                        self.volatile = words
                    }
                    self.onWords?(self.words)
                }
            } catch {
                listenerLogger.error("Speech results ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        let level = VoiceLevelMeter { [weak self] value in
            Task { @MainActor in self?.onLevel?(value) }
        }
        let tap = Self.tap(hardware: hardware, wanted: wanted, converter: converter, input: continuation, level: level)
        if let file {
            try await analyzer.start(inputSequence: stream)
            running = true
            try await Self.play(file, into: tap)
            return
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardware, block: tap)
        microphoneOpen = true
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
        running = true
    }

    /// Stops the microphone and gives back every word, finalized.
    func finish() async -> String {
        guard running else { return words }
        running = false
        stopMicrophone()
        input?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            listenerLogger.error("Speech finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        await results?.value
        let heard = words
        analyzer = nil
        transcriber = nil
        input = nil
        results = nil
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops hearing and drops what was heard.
    func cancel() {
        running = false
        stopMicrophone()
        input?.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
        transcriber = nil
        input = nil
        results = nil
        finished = ""
        volatile = ""
    }

    /// The microphone's tap, made outside the main actor: it runs on the
    /// audio thread, converting each buffer to the format the recognizer
    /// wants and handing it on.
    nonisolated private static func tap(
        hardware: AVAudioFormat,
        wanted: AVAudioFormat,
        converter: AVAudioConverter?,
        input: AsyncStream<AnalyzerInput>.Continuation,
        level: VoiceLevelMeter
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            level.take(buffer)
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = wanted.sampleRate / hardware.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        }
    }

    /// A recording handed to the tap a microphone's buffer at a time, at the
    /// pace it was spoken.
    nonisolated private static func play(_ file: AVAudioFile, into tap: AVAudioNodeTapBlock) async throws {
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 1024
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { return }
            tap(buffer, AVAudioTime(sampleTime: file.framePosition, atRate: format.sampleRate))
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
        }
    }

    private var words: String { (finished + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    private func stopMicrophone() {
        guard microphoneOpen else { return }
        microphoneOpen = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}

/// The level of the microphone's buffers, reported at most thirty times a
/// second, from the audio thread.
final class VoiceLevelMeter: @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var last = Date.distantPast

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func take(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // As the recorder's meter draws it (`ReviewDictationService`): -60 dB
        // and below is silence, then a gentle curve to full scale.
        let decibels = max(20 * log10(max(Double(rms), 1e-9)), -60)
        let level = min(max(pow(pow(10, decibels / 20), 0.35), 0.08), 1)
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(last) >= 1.0 / 30.0
        if due { last = now }
        lock.unlock()
        if due { report(level) }
    }
}
