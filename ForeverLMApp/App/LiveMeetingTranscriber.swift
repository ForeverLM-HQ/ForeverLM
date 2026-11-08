import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One voice's live speech-to-text, on this Mac, with Apple's speech model.
///
/// Audio buffers come in from the capture queue in whatever format the source
/// gives; each is converted to the format the analyzer asks for and timed from
/// the start of the meeting, so a result's range is meeting time even across
/// silences the capture skipped. No audio leaves the Mac and no model is billed.
@available(macOS 26.0, *)
final class LiveMeetingTranscriber: @unchecked Sendable {
    enum Update: Sendable {
        /// Words still being heard; replaced by the next update for this voice.
        case volatile(String)
        /// A finished stretch of speech.
        case final(text: String, start: TimeInterval, end: TimeInterval)
    }

    let voice: LiveMeetingVoice
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?

    // Touched only on the capture queue.
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Prepares the speech model for `locale`, downloading it first when this
    /// Mac does not have it yet. Throws when the language is not supported.
    static func prepare(
        voice: LiveMeetingVoice,
        locale: Locale,
        onUpdate: @escaping @Sendable (LiveMeetingVoice, Update) -> Void
    ) async throws -> LiveMeetingTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LiveMeetingError.languageUnsupported(locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveMeetingError.speechModelUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let made = LiveMeetingTranscriber(voice: voice, transcriber: transcriber, analyzer: analyzer, format: format)
        try await made.start(onUpdate: onUpdate)
        return made
    }

    private init(voice: LiveMeetingVoice, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.voice = voice
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.input = stream
        self.inputContinuation = continuation
    }

    private func start(onUpdate: @escaping @Sendable (LiveMeetingVoice, Update) -> Void) async throws {
        let voice = self.voice
        let transcriber = self.transcriber
        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        guard !text.isEmpty else { continue }
                        let start = result.range.start.seconds
                        let end = CMTimeRangeGetEnd(result.range).seconds
                        onUpdate(voice, .final(
                            text: text,
                            start: start.isFinite ? start : 0,
                            end: end.isFinite ? end : (start.isFinite ? start : 0)
                        ))
                    } else {
                        onUpdate(voice, .volatile(text))
                    }
                }
            } catch {
                LiveMeetingLog.capture.error("transcriber \(voice.rawValue, privacy: .public) stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: input)
    }

    /// Takes one captured buffer. Called on the capture queue only.
    func append(_ sampleBuffer: CMSampleBuffer, meetingTime: TimeInterval) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer), pcm.frameLength > 0 else { return }
        guard let converted = convert(pcm) else { return }
        inputContinuation.yield(AnalyzerInput(
            buffer: converted,
            bufferStartTime: CMTime(seconds: meetingTime, preferredTimescale: 48_000)
        ))
    }

    /// Finishes what was heard and stops.
    func finish() async {
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            LiveMeetingLog.capture.error("finishing transcriber \(self.voice.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await analyzer.cancelAndFinishNow()
        }
        _ = await resultsTask?.value
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == analyzerFormat { return buffer }
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converter?.primeMethod = .none
            converterSourceFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            LiveMeetingLog.capture.error("audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    /// Copies a captured audio sample buffer into a PCM buffer of its own format.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
