import AVFoundation
import Foundation
import OSLog

/// Managed transcription of meeting recordings and podcast audio.
///
/// Pipeline: download a Google Drive recording through the plugin's authenticated
/// cache → extract `.m4a` audio → split long media into bounded sequential units →
/// leave out every unit with no speech in it (`RecordingSpeechLevel`) → send each
/// remaining unit to OpenRouter through `ManagedTranscriptionClient` → return
/// plain text.
///
/// All blocking media work runs off the main actor. The proxy owns the provider
/// credential and meters every unit before its transcript is served.
actor MeetingTranscriptionService {
    /// The ledger's label for a meeting recording's transcription: what AI
    /// Usage files it under, and the step a Stop under Running in the
    /// background stops.
    static let meetingTask = "meeting_transcription"

    static let shared = MeetingTranscriptionService()
    private static let maximumChunkDuration: TimeInterval = 10 * 60
    private let logger = Logger(subsystem: "ForeverLM", category: "MeetingTranscription")
    private var transcriptionInProgress = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    enum TranscriptionError: LocalizedError {
        case invalidDriveFile
        case downloadFailed(String)
        case audioExtractionFailed(String)
        case emptyTranscript
        /// Nothing in the recording reaches speech level
        /// (`RecordingSpeechLevel`), so nothing was sent to be transcribed.
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .invalidDriveFile:
                return "Could not determine the Google Drive file id for the recording."
            case .downloadFailed(let m):
                return "Failed to download the recording: \(m)"
            case .audioExtractionFailed(let m):
                return "Failed to extract audio from the recording: \(m)"
            case .emptyTranscript:
                return "Transcription produced no text."
            case .noSpeech:
                return "The recording has no speech in it."
            }
        }
    }

    /// Transcribe a Google Drive recording identified by its file id (or any
    /// Drive file URL). Returns the transcript text.
    func transcribe(driveFileURLOrID: String) async throws -> String {
        await acquireTranscriptionTurn()
        defer { releaseTranscriptionTurn() }

        let fileID = Self.driveFileID(from: driveFileURLOrID)
        guard let fileID, !fileID.isEmpty else { throw TranscriptionError.invalidDriveFile }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcribe-\(fileID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let media: URL
        do {
            media = try await GoogleDriveService.shared.cachedRecordingURL(
                fileURLOrID: driveFileURLOrID,
                mimeType: nil,
                modifiedAt: nil
            )
        } catch {
            throw TranscriptionError.downloadFailed(error.localizedDescription)
        }
        let audioURL = try await extractAudio(from: media, into: workDir)
        logger.info("Transcribing recording \(fileID, privacy: .public)")
        return try await transcribeAudio(audioURL, into: workDir, task: Self.meetingTask)
    }

    /// Transcribe a media file already on disk (any AVFoundation-readable
    /// container, e.g. a downloaded Zoom recording). Returns the transcript text.
    /// `task` names the work in the usage ledger (`course_video_transcription`
    /// for a course lecture's audio).
    func transcribe(localMediaURL: URL, task: String = MeetingTranscriptionService.meetingTask) async throws -> String {
        await acquireTranscriptionTurn()
        defer { releaseTranscriptionTurn() }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcribe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let audioURL = try await extractAudio(from: localMediaURL, into: workDir)
        logger.info("Transcribing local recording \(localMediaURL.lastPathComponent, privacy: .public)")
        return try await transcribeAudio(audioURL, into: workDir, task: task)
    }

    /// Download and transcribe an exact remote media asset. Podcast ingestion
    /// uses this when Apple exposes the episode audio but has no TTML transcript.
    /// The asset is temporary and never becomes part of the knowledge base;
    /// only the resulting text is persisted through the normal source API.
    func transcribe(remoteMediaURL: URL) async throws -> String {
        await acquireTranscriptionTurn()
        defer { releaseTranscriptionTurn() }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-media-transcribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var request = URLRequest(url: remoteMediaURL)
        request.setValue("Mozilla/5.0 ForeverLM", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw TranscriptionError.downloadFailed("episode audio HTTP \(http.statusCode)")
        }

        let fileExtension = remoteMediaURL.pathExtension.isEmpty ? "mp3" : remoteMediaURL.pathExtension
        let mediaURL = workDir.appendingPathComponent("episode-audio.\(fileExtension)")
        try FileManager.default.moveItem(at: temporaryURL, to: mediaURL)
        let audioURL = try await extractAudio(from: mediaURL, into: workDir)
        logger.info("Transcribing downloaded episode audio")
        return try await transcribeAudio(audioURL, into: workDir, task: "podcast_transcription")
    }

    /// Actor methods are reentrant at every download/provider await. An explicit
    /// FIFO turn keeps one long media job from interleaving its ordered chunks
    /// with another without blocking a thread.
    private func acquireTranscriptionTurn() async {
        if !transcriptionInProgress {
            transcriptionInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func releaseTranscriptionTurn() {
        guard !transcriptionWaiters.isEmpty else {
            transcriptionInProgress = false
            return
        }
        transcriptionWaiters.removeFirst().resume()
    }

    /// A chunk with no speech in it is never uploaded: a speech model makes
    /// something up for silence (`RecordingSpeechLevel`), and it would be
    /// billed and stored as the recording's words. A recording none of whose
    /// chunks has speech fails with `noSpeech` before anything is sent. A
    /// chunk that cannot be measured is sent as before.
    private func transcribeAudio(_ audioURL: URL, into dir: URL, task: String) async throws -> String {
        let chunks = try await transcriptionChunks(from: audioURL, into: dir)
        let activityID = UUID().uuidString
        var transcriptParts: [String] = []
        transcriptParts.reserveCapacity(chunks.count)
        var spokenChunks = 0
        for (index, chunk) in chunks.enumerated() {
            if let level = await RecordingSpeechLevel.measure(mediaURL: chunk), !level.hasSpeech {
                logger.info("Audio chunk \(index + 1)/\(chunks.count) has no speech (\(RecordingSpeechLevel.summary(level), privacy: .public)); not sent")
                continue
            }
            spokenChunks += 1
            logger.info("Transcribing managed audio chunk \(index + 1)/\(chunks.count)")
            let result = try await AIUsageAttribution.$activityID.withValue(activityID) {
                try await AIUsageAttribution.$task.withValue(task) {
                    // Listed for the background-work list, where Stop cancels
                    // it: a Zoom recording's or an episode's transcription.
                    try await AIInFlightCalls.current.track(step: task) { _ in
                        try await ManagedTranscriptionClient.transcribe(
                            fileURL: chunk,
                            session: URLSession.shared,
                            purpose: .media
                        )
                    }
                }
            }
            try await AIUsageTracker.shared.record(
                provider: result.providerName,
                model: result.model,
                operation: "speech_to_text",
                report: result.report,
                task: task,
                activityID: activityID,
                generationID: result.generationID
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { transcriptParts.append(text) }
        }
        guard spokenChunks > 0 else { throw TranscriptionError.noSpeech }
        let text = transcriptParts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return text
    }

    // MARK: - Drive identity

    /// Parse a Drive file id out of a `/file/d/<id>/...` or `?id=<id>` URL, or
    /// return the input unchanged if it already looks like a bare id.
    nonisolated static func driveFileID(from value: String) -> String? {
        GoogleDriveService.fileID(from: value)
    }

    // MARK: - Audio extraction

    /// Extract the audio track to `.m4a`, which gives the provider a compact,
    /// consistent container even when the source is a large video.
    private func extractAudio(from videoURL: URL, into dir: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let output = dir.appendingPathComponent("audio.m4a")
        try? FileManager.default.removeItem(at: output)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed("Could not create export session.")
        }
        export.outputURL = output
        export.outputFileType = .m4a

        await export.export()
        switch export.status {
        case .completed:
            return output
        case .failed, .cancelled:
            throw TranscriptionError.audioExtractionFailed(export.error?.localizedDescription ?? "export \(export.status.rawValue)")
        default:
            throw TranscriptionError.audioExtractionFailed("unexpected export status \(export.status.rawValue)")
        }
    }

    private func transcriptionChunks(from audioURL: URL, into dir: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw TranscriptionError.audioExtractionFailed("The audio duration was unavailable.")
        }
        guard seconds > Self.maximumChunkDuration else { return [audioURL] }

        var chunks: [URL] = []
        var start: TimeInterval = 0
        while start < seconds {
            let index = chunks.count
            let output = dir.appendingPathComponent(String(format: "audio-%04d.m4a", index))
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriptionError.audioExtractionFailed("Could not create chunk export session.")
            }
            export.outputURL = output
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(
                    seconds: min(Self.maximumChunkDuration, seconds - start),
                    preferredTimescale: 600
                )
            )
            await export.export()
            guard export.status == .completed else {
                throw TranscriptionError.audioExtractionFailed(
                    export.error?.localizedDescription ?? "chunk export \(export.status.rawValue)"
                )
            }
            chunks.append(output)
            start += Self.maximumChunkDuration
        }
        return chunks
    }
}

/// Whether a recording has anything in it a speech model could transcribe,
/// measured from its own samples on this Mac before any of it is uploaded.
///
/// A speech model handed silence does not answer with nothing. GPT-4o mini
/// Transcribe, the default batch model, answered the Zoom standup recordings
/// in which nobody spoke with an empty text, with "Thank you for watching."
/// (a 3-minute recording, 2026-09-25), and with fluent paragraphs in Russian,
/// Spanish and German (1-minute recordings, 2026-09-16 and 2026-09-20; two
/// calls on the same file gave two different ones), which were filed as those
/// English standups' transcripts. OpenRouter's response carries only `text`
/// and `usage`: no language, no segments and no no-speech probability for
/// that model, and a model the learner picks may reject `verbose_json`. So
/// nothing the provider returns can tell a hallucination from a short
/// meeting, and neither can the text: 67 words in 64 s is an ordinary pace
/// for a meeting that barely happened.
///
/// The samples can. Zoom's noise suppression records a call in which nobody
/// speaks as near-digital silence. Measured on 2026-09-28 over every
/// recording in `~/Documents/Zoom`: the five in which nobody spoke (2 s to
/// 17 min) had no 100 ms window louder than −52.5 dBFS RMS and at most 0.2 s
/// louder than −55, while each of the ten standups that happened spent about
/// two thirds of its length at or above −50 dBFS and peaked between −5 and
/// −9 dBFS. The rule is that a recording holds speech when at least a second
/// of it, in 100 ms windows, reaches −50 dBFS RMS. A second is about what one
/// word takes, so a click or a chair scrape stays out, and a real call clears
/// it in its first seconds, so a recording with speech is read only that far.
enum RecordingSpeechLevel {
    /// A window is at speech level when its RMS reaches this.
    static let speechFloorDBFS: Double = -50
    static let windowSeconds: Double = 0.1
    /// How much of a recording must be at speech level for it to hold speech.
    static let minimumSpeechSeconds: Double = 1
    /// The rate samples are measured at. Loudness does not need more, and
    /// decoding an hour of meeting at it is quick.
    static let sampleRate: Double = 16_000

    struct Measurement: Equatable, Sendable {
        /// Seconds of audio read. Reading stops once speech is found, so for
        /// a recording with speech this is how far in it was found.
        var measuredSeconds: Double
        /// Seconds of 100 ms windows at or above `speechFloorDBFS`.
        var speechSeconds: Double
        /// The loudest window's RMS; `-infinity` for digital silence.
        var loudestWindowDBFS: Double

        var hasSpeech: Bool { speechSeconds >= RecordingSpeechLevel.minimumSpeechSeconds }
    }

    /// Folds samples into windows, one RMS each. Pure.
    struct Meter {
        let samplesPerWindow: Int
        private var sumOfSquares: Double = 0
        private var samplesInWindow = 0
        private var samplesRead = 0
        private var speechWindows = 0
        private var loudest = -Double.infinity
        private let sampleRate: Double

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            self.samplesPerWindow = max(1, Int((sampleRate * RecordingSpeechLevel.windowSeconds).rounded()))
        }

        mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            for sample in samples {
                let value = Double(sample)
                sumOfSquares += value * value
                samplesInWindow += 1
                if samplesInWindow == samplesPerWindow { closeWindow() }
            }
            samplesRead += samples.count
        }

        mutating func add(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { add($0) }
        }

        /// A trailing part-window is measured as the window it is.
        mutating func finish() {
            if samplesInWindow > 0 { closeWindow() }
        }

        /// True once enough speech is heard that reading further cannot
        /// change the answer.
        var heardSpeech: Bool {
            Double(speechWindows) * RecordingSpeechLevel.windowSeconds >= RecordingSpeechLevel.minimumSpeechSeconds
        }

        var measurement: Measurement {
            Measurement(
                measuredSeconds: Double(samplesRead) / sampleRate,
                speechSeconds: Double(speechWindows) * RecordingSpeechLevel.windowSeconds,
                loudestWindowDBFS: loudest
            )
        }

        private mutating func closeWindow() {
            let meanSquare = sumOfSquares / Double(samplesInWindow)
            let level = meanSquare > 0 ? 10 * log10(meanSquare) : -Double.infinity
            loudest = max(loudest, level)
            if level >= RecordingSpeechLevel.speechFloorDBFS { speechWindows += 1 }
            sumOfSquares = 0
            samplesInWindow = 0
        }
    }

    /// The measurement of samples already in memory. Pure.
    static func measure(samples: [Float], sampleRate: Double) -> Measurement {
        var meter = Meter(sampleRate: sampleRate)
        meter.add(samples)
        meter.finish()
        return meter.measurement
    }

    /// Measure the first audio track of a media file, decoded to mono at
    /// `sampleRate`, stopping as soon as it holds speech. Nil when the file
    /// has no audio track or cannot be decoded: an unreadable file is not a
    /// silent one, and whoever asked goes on to fail on it in their own words.
    /// Decoding blocks, so this must never be called on the main actor.
    static func measure(mediaURL: URL) async -> Measurement? {
        let asset = AVURLAsset(url: mediaURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var meter = Meter(sampleRate: sampleRate)
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count != count { samples = [Float](repeating: 0, count: count) }
            let copied = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else {
                reader.cancelReading()
                return nil
            }
            meter.add(samples)
            if meter.heardSpeech || Task.isCancelled {
                reader.cancelReading()
                break
            }
        }
        if Task.isCancelled { return nil }
        if reader.status == .failed { return nil }
        meter.finish()
        return meter.measurement
    }

    /// "loudest −84.3 dBFS, 0.0 s at speech level in 64.2 s" for a log line.
    static func summary(_ measurement: Measurement) -> String {
        let loudest = measurement.loudestWindowDBFS.isFinite
            ? String(format: "%.1f dBFS", measurement.loudestWindowDBFS)
            : "digital silence"
        return String(
            format: "loudest %@, %.1f s at speech level in %.1f s",
            loudest, measurement.speechSeconds, measurement.measuredSeconds
        )
    }
}

private extension AVAssetExportSession {
    /// macOS 14-compatible async wrapper around `exportAsynchronously`.
    func export() async {
        await withCheckedContinuation { continuation in
            self.exportAsynchronously {
                continuation.resume()
            }
        }
    }
}
