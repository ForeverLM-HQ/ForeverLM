import AVFoundation
import Foundation
import OSLog

/// Extracts representative slide frames from a meeting recording on disk.
///
/// The counterpart to `YouTubeSlideExtractionService` for the videos that are not on
/// YouTube: a Google Drive recording the plugin has cached locally, or one imported from
/// a local folder. A file has no storyboard contact sheet to scan, so the scan grid is
/// decoded from the recording itself — one small frame every few seconds, hashed as it
/// arrives and then discarded, which is the cheapest stand-in for what YouTube hands over
/// ready-made.
///
/// Everything past that point is `SlideFrameExtraction`, shared with the YouTube path: where
/// the picture changes, which frame represents each run, which frames are repeats, and the
/// markdown block the reader parses back. So a seminar recording's deck renders beside its
/// transcript exactly the way a lecture's does, and a fix to slide detection lands for both.
actor RecordingSlideExtractionService {
    typealias SlideFrame = SlideFrameExtraction.SlideFrame
    typealias AppendResult = SlideFrameExtraction.AppendResult

    static let shared = RecordingSlideExtractionService()

    /// Seconds between scan samples. Comfortably under `minimumStableSeconds`, so no run
    /// long enough to be kept can hide between two samples, and coarse enough that an hour
    /// of recording costs hundreds of decodes rather than tens of thousands.
    private static let scanIntervalSeconds: Double = 4
    /// Ceiling on scan samples, which stretches the interval on a long recording instead of
    /// letting decode cost grow without bound. 900 samples is an hour at the base interval;
    /// a three-hour recording is sampled every 12 seconds.
    private static let maxScanSamples = 900
    /// Scan resolution. Larger than YouTube's 160x90 storyboard tiles because here the size
    /// is ours to pick, and a dHash taken from a denser frame separates slides that share a
    /// template — the case that matters most — more reliably.
    private static let scanFrameSize = CGSize(width: 480, height: 270)
    private static let captureFrameSize = CGSize(width: 1920, height: 1080)
    /// Seek slack. A sample only has to land on the right slide, and letting the decoder
    /// settle for a keyframe within a second turns hundreds of exact seeks — each decoding
    /// forward from the previous keyframe — into cheap ones.
    private static let seekToleranceSeconds: Double = 1

    private let logger = Logger(subsystem: "com.foreverlm", category: "RecordingSlides")

    /// Captures a recording's slides and appends them to its stored content, or returns the
    /// content untouched with the reason it could not.
    func appendingSlideContext(
        to content: String,
        mediaURL: URL,
        sourceID: String,
        videoTitle: String?
    ) async -> AppendResult {
        if SlideFrameExtraction.containsSlideSection(content) {
            return AppendResult(content: content, slideCount: 0, errorMessage: nil)
        }

        do {
            let frames = try await extractSlides(
                from: mediaURL,
                sourceID: sourceID,
                videoTitle: videoTitle
            )
            return SlideFrameExtraction.appending(frames: frames, to: content)
        } catch {
            logger.warning("Recording slide extraction failed: \(error.localizedDescription)")
            return AppendResult(
                content: content,
                slideCount: 0,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// The frame on screen `seconds` into a recording on disk, stored beside
    /// its slides — the recording counterpart of the YouTube path's
    /// `captureMoment`.
    func captureMoment(mediaURL: URL, sourceID: String, seconds: Int) async throws -> String {
        let asset = AVURLAsset(url: mediaURL)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            throw SlideExtractionError.unreadableRecording
        }
        guard !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty else {
            throw SlideExtractionError.recordingHasNoVideo
        }
        guard Double(seconds) < duration.seconds else {
            throw SlideExtractionError.momentOutOfRange(seconds: Double(seconds), durationSeconds: duration.seconds)
        }
        let frame = try await SlideFrameExtraction.captureMomentFrame(
            asset: asset,
            seconds: Double(seconds),
            maximumSize: Self.captureFrameSize
        )
        return try SlideFrameExtraction.storeMomentFrame(frame, sourceID: sourceID, seconds: seconds)
    }

    /// Captures `frames` of a recording's deck again, each at the second it
    /// was first taken, and writes each where the stored block names it — the
    /// recording counterpart of the YouTube path's `restoreFrames`. Returns
    /// how many were written.
    func restoreFrames(_ frames: [SlideFrameExtraction.StoredFrame], mediaURL: URL) async throws -> Int {
        guard !frames.isEmpty else { return 0 }
        let asset = AVURLAsset(url: mediaURL)
        guard !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty else {
            throw SlideExtractionError.recordingHasNoVideo
        }
        let captured = await captureFrames(asset: asset, timesSeconds: frames.map(\.seconds))
        var written = 0
        for frame in frames {
            guard let image = captured[SlideFrameExtraction.frameTimeKey(frame.seconds)] else { continue }
            try SlideFrameExtraction.storeRestoredFrame(image, at: frame.relativePath)
            written += 1
        }
        logger.info("Restored \(written) of \(frames.count) missing slide frame(s) from \(mediaURL.lastPathComponent)")
        return written
    }

    func extractSlides(
        from mediaURL: URL,
        sourceID: String,
        videoTitle: String?
    ) async throws -> [SlideFrame] {
        let asset = AVURLAsset(url: mediaURL)
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds > 0 else {
            throw SlideExtractionError.unreadableRecording
        }
        // An audio-only recording is a normal thing for a meeting to be, not a failure to
        // diagnose — say which it is rather than reporting that no slides were found.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !videoTracks.isEmpty else {
            throw SlideExtractionError.recordingHasNoVideo
        }

        let interval = Self.scanInterval(forDurationSeconds: duration.seconds)
        let sampleTimes = Self.scanTimes(durationSeconds: duration.seconds, interval: interval)

        // Hash the grid, then find where the picture actually changes.
        let hashes = await scanFrameHashes(asset: asset, timesSeconds: sampleTimes)
        let scans = sampleTimes.enumerated().compactMap { index, seconds -> SlideFrameExtraction.TileScan? in
            guard let hash = hashes[SlideFrameExtraction.frameTimeKey(seconds)] else { return nil }
            return SlideFrameExtraction.TileScan(tileIndex: index, timeSeconds: seconds, hash: hash)
        }
        guard !scans.isEmpty else {
            throw SlideExtractionError.noSlideFramesExtracted
        }

        let runs = SlideFrameExtraction.boundedRuns(SlideFrameExtraction.detectSlideRuns(
            hashes: scans.map(\.hash),
            tileIntervalSeconds: interval
        ))
        guard !runs.isEmpty else {
            throw SlideExtractionError.noSlideFramesExtracted
        }

        // One generator, every representative timestamp in a single pass.
        let representativeTimes = runs.compactMap { scans[$0.representativeIndex].timeSeconds }
        let captured = await captureFrames(asset: asset, timesSeconds: representativeTimes)

        let outputDirectory = try SlideFrameExtraction.prepareOutputDirectory(sourceID: sourceID)
        var kept: [(hash: SlideFrameExtraction.PerceptualHash, frameIndex: Int)] = []
        var frames: [SlideFrame] = []
        var repeatCount = 0
        var missedCaptures = 0

        for run in runs {
            let scan = scans[run.representativeIndex]
            // Where this run's slide is on screen, dated at the midpoint between the last
            // sample of one slide and the first of the next — the best single estimate of the
            // real transition, and what the transcript anchors the frame against.
            let window = SlideFrameExtraction.slideWindow(
                for: run, scans: scans, tileIntervalSeconds: interval
            )

            guard let timeSeconds = scan.timeSeconds,
                  let image = captured[SlideFrameExtraction.frameTimeKey(timeSeconds)] else {
                // The scan already read this moment, so the failure is the full-resolution
                // decode alone. Storing the scan frame in its place would put a 480-wide
                // thumbnail in front of the vision pass, which reads worse than a gap.
                missedCaptures += 1
                continue
            }

            // One deck page reaches this loop more than once whenever the presenter cuts
            // away and back, so the frame being stored is what decides whether it is new. A
            // frame that will not hash is stored rather than dropped: keeping a possible
            // duplicate beats silently losing a slide.
            if let hash = SlideFrameExtraction.perceptualHash(image) {
                if let repeatOf = SlideFrameExtraction.repeatIndex(hash, in: kept.map(\.hash)) {
                    // The frame is dropped, but the appearance is not: its window joins the
                    // kept slide's, so anything keyed to that slide stays current every time
                    // it is on screen, not just the first.
                    repeatCount += 1
                    if let window {
                        frames[kept[repeatOf].frameIndex].windows.append(window)
                    }
                    continue
                }
                kept.append((hash: hash, frameIndex: frames.count))
            }

            let frameNumber = frames.count + 1
            let imageURL = outputDirectory.appendingPathComponent(
                SlideFrameExtraction.imageFilename(index: frameNumber, timeSeconds: timeSeconds)
            )
            try SlideFrameExtraction.writeJPEG(image, to: imageURL)
            frames.append(SlideFrame(
                index: frameNumber,
                timeSeconds: timeSeconds,
                windows: window.map { [$0] } ?? [],
                localImagePath: StorageService.relativeSourcePath(imageURL.path)
            ))
        }

        guard !frames.isEmpty else {
            throw SlideExtractionError.noSlideFramesExtracted
        }
        let label = videoTitle ?? mediaURL.lastPathComponent
        logger.info("Extracted \(frames.count) slide(s) from \(scans.count) sample(s) at \(interval, format: .fixed(precision: 1))s for \(label); repeated frames collapsed: \(repeatCount), full-resolution captures missed: \(missedCaptures)")
        return frames
    }

    // MARK: - Scan grid

    /// Seconds between samples for a recording of this length: the base interval, stretched
    /// only when the recording is long enough that the base would blow the sample budget.
    nonisolated static func scanInterval(forDurationSeconds seconds: Double) -> Double {
        guard seconds > 0 else { return scanIntervalSeconds }
        return max(scanIntervalSeconds, seconds / Double(maxScanSamples))
    }

    /// The sample grid, from the first frame to the last whole interval inside the
    /// recording. Times are exact multiples of the interval so `frameTimeKey` round-trips
    /// them through the generator without float drift.
    nonisolated static func scanTimes(durationSeconds: Double, interval: Double) -> [Double] {
        guard durationSeconds > 0, interval > 0 else { return [] }
        let count = max(1, Int(durationSeconds / interval))
        return (0..<count).map { Double($0) * interval }
    }

    // MARK: - Decoding

    /// Hashes the scan grid without ever holding the frames.
    ///
    /// A two-hour recording samples in the hundreds; keeping those as `CGImage` to hash
    /// afterwards would cost hundreds of megabytes to answer a question that is settled the
    /// moment each frame arrives.
    private nonisolated func scanFrameHashes(
        asset: AVURLAsset,
        timesSeconds: [Double]
    ) async -> [Int64: SlideFrameExtraction.PerceptualHash] {
        await SlideFrameExtraction.captureFrames(
            generator: Self.imageGenerator(for: asset, maximumSize: Self.scanFrameSize),
            timesSeconds: timesSeconds,
            transform: SlideFrameExtraction.perceptualHash
        )
    }

    /// Captures the representative frames at full resolution — the images actually stored,
    /// and what the vision pass reads for cited papers.
    private nonisolated func captureFrames(
        asset: AVURLAsset,
        timesSeconds: [Double]
    ) async -> [Int64: CGImage] {
        await SlideFrameExtraction.captureFrames(
            generator: Self.imageGenerator(for: asset, maximumSize: Self.captureFrameSize),
            timesSeconds: timesSeconds,
            transform: { $0 }
        )
    }

    private nonisolated static func imageGenerator(
        for asset: AVURLAsset,
        maximumSize: CGSize
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(
            seconds: seekToleranceSeconds,
            preferredTimescale: SlideFrameExtraction.frameTimescale
        )
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = maximumSize
        return generator
    }
}
