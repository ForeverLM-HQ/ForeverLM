import AppKit
import AVFoundation
import Foundation
import OSLog

/// Why a slide extraction stopped.
///
/// Shared by both extraction paths, so the reader and the MCP tools surface one vocabulary
/// of failures. The storyboard cases can only arise on the YouTube path, which is the only
/// one that has a storyboard to parse.
enum SlideExtractionError: LocalizedError, Equatable {
    case invalidURL
    case noStoryboardAvailable
    case invalidStoryboardSpec
    case noSlideFramesExtracted
    case unreadableRecording
    case recordingHasNoVideo
    case noVideoStream
    case momentOutOfRange(seconds: Double, durationSeconds: Double)
    case momentUnreachable(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid YouTube URL."
        case .noStoryboardAvailable:
            return "No YouTube storyboard images are available for this video."
        case .invalidStoryboardSpec:
            return "YouTube returned an unsupported storyboard format."
        case .noSlideFramesExtracted:
            return "No distinct slide frames could be extracted."
        case .unreadableRecording:
            return "This recording could not be opened for reading frames."
        case .recordingHasNoVideo:
            return "This recording is audio only, so it has no slides to show."
        case .noVideoStream:
            return "YouTube offered no video stream a frame could be read from."
        case .momentOutOfRange(let seconds, let duration):
            return "\(SlideFrameExtraction.displayTime(seconds)) is past the end of the video, which runs \(SlideFrameExtraction.displayTime(duration))."
        case .momentUnreachable(let seconds):
            return "No frame could be read at \(SlideFrameExtraction.displayTime(seconds))."
        }
    }
}

/// The half of slide extraction that does not care where the frames came from.
///
/// Two services feed it. `YouTubeSlideExtractionService` finds slide changes in YouTube's
/// storyboard contact sheets and captures the representative frames from the video's
/// streams; `RecordingSlideExtractionService` does the same over a meeting recording already
/// on disk. Everything downstream of "here are frames on a time grid" is identical for
/// both — the perceptual hash, run detection, on-screen windows, deduplication, JPEG
/// storage, and the stored markdown block — so it lives here. That is what lets the reader
/// parse one format regardless of where a video came from, and what makes a fix to slide
/// detection land for every video at once instead of only for talks that happen to be on
/// YouTube.
enum SlideFrameExtraction {

    // MARK: - Types

    /// A stored slide image and where it sits in the video.
    ///
    /// No text. Slides are read by a vision model from the image itself, so running a
    /// separate on-device text-recognition pass over a downsampled frame would only produce a
    /// worse copy of what the model already sees.
    struct SlideFrame: Equatable, Sendable {
        let index: Int
        /// The representative (mid-run) capture time, which is where the stored image was
        /// taken from.
        let timeSeconds: Double?
        /// Every stretch of the video during which this slide is on screen, from the sample
        /// runs it was detected in. A page the presenter cuts away from and back to collapses
        /// to one stored frame carrying one window per appearance. Empty when the sample grid
        /// carries no usable times.
        var windows: [SlideTimeWindow]
        let localImagePath: String
    }

    struct AppendResult: Sendable {
        let content: String
        let slideCount: Int
        let errorMessage: String?
    }

    /// Perceptual signature of one frame, as a 256-bit difference hash.
    struct PerceptualHash: Equatable, Sendable {
        let words: [UInt64]

        func distance(to other: PerceptualHash) -> Int {
            guard words.count == other.words.count else { return .max }
            return zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        }
    }

    /// A stretch of consecutive samples showing the same slide.
    struct SlideRun: Equatable, Sendable {
        let startIndex: Int
        let endIndex: Int
        /// Index sampled from the middle of the run, which avoids fade and build artifacts
        /// at the edges.
        let representativeIndex: Int
        let hash: PerceptualHash
    }

    /// One sample on the scan grid: a hashed low-resolution frame and the moment it is from.
    ///
    /// Named for the storyboard tile it started life as. A recording's samples are decoded
    /// from the file rather than cropped out of a contact sheet, but they play exactly the
    /// same role — a cheap, evenly spaced signature of the picture over time.
    struct TileScan: Equatable, Sendable {
        let tileIndex: Int
        let timeSeconds: Double?
        let hash: PerceptualHash
    }

    /// Accumulates the results of `generateCGImagesAsynchronously`, whose completion handler
    /// fires once per requested time on arbitrary threads.
    ///
    /// Generic in what it keeps, because the two passes want different things from the same
    /// mechanism. The capture pass keeps the images. The scan pass hashes each frame on
    /// arrival and keeps only the 32-byte signature: a two-hour recording samples in the
    /// hundreds of frames, and holding those as `CGImage` would cost hundreds of megabytes
    /// to answer a question already settled the moment each one is hashed.
    final class FrameCollector<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let transform: (CGImage) -> Value?
        private var values: [Int64: Value] = [:]
        private var remaining: Int
        private var finished = false

        init(expected: Int, transform: @escaping (CGImage) -> Value?) {
            self.remaining = expected
            self.transform = transform
        }

        /// Returns the collected values exactly once, on the final callback.
        func record(requestedTime: CMTime, image: CGImage?) -> [Int64: Value]? {
            let value = image.flatMap(transform)
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return nil }
            if let value {
                values[requestedTime.value] = value
            }
            remaining -= 1
            guard remaining <= 0 else { return nil }
            finished = true
            return values
        }
    }

    // MARK: - Tuning

    static let slideSectionHeader = "## Extracted video slide frames"
    /// Upper bound on stored slides. Generous, because the count is now driven by how
    /// many distinct slides a talk actually has rather than by a sampling budget.
    static let maxStoredFrames = 120
    static let frameTimescale: CMTimeScale = 600
    /// How far a captured moment may sit from the second asked for. Tight on purpose; see
    /// `captureMomentFrame(asset:seconds:maximumSize:)`.
    static let momentToleranceSeconds: Double = 0.1

    /// dHash grid. 16 columns of comparisons across 16 rows gives a 256-bit signature.
    /// The previous 8x8 average hash could not tell apart two slides sharing a template
    /// but listing different papers, which is exactly the case that matters most here.
    static let hashGridSize = 16
    /// Distance above which consecutive samples are treated as a slide change.
    static let transitionDistance = 32
    /// Distance below which a stored frame is treated as a repeat of one already kept.
    /// Deliberately strict: only near-identical frames collapse, so template-similar slides
    /// survive. Applied to the captured frame, never to the scan sample — see `repeatIndex`.
    static let duplicateDistance = 12
    /// A run must hold still for at least this many consecutive samples. Filters out
    /// transition animations and handheld footage, which never stabilize.
    static let minimumStableTiles = 2
    /// …and for at least this long in wall-clock terms. Sample intervals vary widely by
    /// video — a 19-minute talk was observed at 10s per storyboard tile, where two tiles is
    /// already 20 seconds, while a denser grid can put two samples inside 4. Expressing the
    /// floor in seconds keeps the filter meaning the same thing at either density.
    static let minimumStableSeconds: Double = 8

    // MARK: - Detection

    /// Splits a temporal hash sequence into stable runs, one per continuous stretch of
    /// unchanging picture.
    ///
    /// A run is not the same thing as a distinct slide, and trying to make it one here does
    /// not work. A cutaway to the presenter splits a single deck page into two runs, and a
    /// locked-off camera on the podium holds still enough to form a run of its own. Repeats
    /// are collapsed downstream against the captured frames, where the evidence is good
    /// enough to recognize them — see `repeatIndex`.
    static func detectSlideRuns(
        hashes: [PerceptualHash],
        tileIntervalSeconds: Double? = nil
    ) -> [SlideRun] {
        guard !hashes.isEmpty else { return [] }

        var stableTiles = minimumStableTiles
        if let tileIntervalSeconds, tileIntervalSeconds > 0 {
            stableTiles = max(stableTiles, Int((minimumStableSeconds / tileIntervalSeconds).rounded(.up)))
        }
        let requiredTiles = max(1, min(stableTiles, hashes.count))
        var runs: [SlideRun] = []
        var runStart = 0

        func closeRun(endingAt end: Int) {
            let length = end - runStart + 1
            guard length >= requiredTiles else { return }
            let representative = min(runStart + length / 2, end)
            runs.append(SlideRun(
                startIndex: runStart,
                endIndex: end,
                representativeIndex: representative,
                hash: hashes[representative]
            ))
        }

        for index in 1..<max(1, hashes.count) where hashes[index].distance(to: hashes[index - 1]) > transitionDistance {
            closeRun(endingAt: index - 1)
            runStart = index
        }
        closeRun(endingAt: hashes.count - 1)
        return runs
    }

    /// Which kept frame a frame about to be stored repeats, if any.
    ///
    /// This has to run on the captured frame, not on the low-resolution sample the frame was
    /// located by. At 160x90 a deck page shown twice hashes 32-36 bits apart — at or above
    /// the `transitionDistance` that means "different picture" — so at that size no
    /// threshold separates a repeat from a scene change, and deduplication collapsed
    /// nothing at all. The captured frames of those same moments are 0-9 apart, against a
    /// nearest genuinely-distinct pair of 20, which separates cleanly.
    ///
    /// Returns the index so the repeat's on-screen window can be merged into the frame it
    /// duplicates: dropping the frame must not drop the appearance.
    static func repeatIndex(_ hash: PerceptualHash, in kept: [PerceptualHash]) -> Int? {
        kept.firstIndex { $0.distance(to: hash) <= duplicateDistance }
    }

    static func isRepeat(_ hash: PerceptualHash, of kept: [PerceptualHash]) -> Bool {
        repeatIndex(hash, in: kept) != nil
    }

    /// Keeps the stored slide count sane on very long decks by thinning evenly across the
    /// talk rather than truncating the tail.
    static func boundedRuns(_ runs: [SlideRun]) -> [SlideRun] {
        guard runs.count > maxStoredFrames, maxStoredFrames > 1 else { return runs }
        return (0..<maxStoredFrames).map { index in
            let position = (Double(index) / Double(maxStoredFrames - 1)) * Double(runs.count - 1)
            return runs[Int(position.rounded())]
        }
    }

    /// The stretch of the video a run's slide is on screen, dated at the midpoints between
    /// adjacent samples rather than at the sample that first shows the change.
    ///
    /// A slide's transition happens somewhere between the last sample of the previous picture
    /// and the first sample of the new one; the sample index alone can only place it at the
    /// later end, which lags the truth by up to a full interval and biases every anchored
    /// slide late. Splitting the difference removes that bias, and because neighbouring runs
    /// share the same midpoint their windows stay contiguous. The first run has no earlier
    /// sample, so it opens at its first one; the last has no later run, so it closes one
    /// interval on.
    static func slideWindow(
        for run: SlideRun,
        scans: [TileScan],
        tileIntervalSeconds: Double?
    ) -> SlideTimeWindow? {
        guard run.startIndex >= 0,
              run.startIndex <= run.endIndex,
              run.endIndex < scans.count,
              let firstTileTime = scans[run.startIndex].timeSeconds,
              let lastTileTime = scans[run.endIndex].timeSeconds else {
            return nil
        }

        let start: Double
        if run.startIndex > 0, let previousTime = scans[run.startIndex - 1].timeSeconds {
            start = (previousTime + firstTileTime) / 2
        } else {
            start = firstTileTime
        }

        let end: Double
        if run.endIndex + 1 < scans.count, let nextTime = scans[run.endIndex + 1].timeSeconds {
            end = (lastTileTime + nextTime) / 2
        } else if let tileIntervalSeconds {
            end = lastTileTime + tileIntervalSeconds
        } else {
            end = lastTileTime
        }

        return SlideTimeWindow(start: start, end: max(start, end))
    }

    /// 256-bit difference hash.
    ///
    /// Downsampling through a grayscale context makes each cell an average of its region
    /// rather than one sampled pixel, so small text blocks still move the signature. Each
    /// bit records whether a cell is brighter than its right-hand neighbour, which keys on
    /// structure instead of absolute brightness.
    static func perceptualHash(_ image: CGImage) -> PerceptualHash? {
        let width = hashGridSize + 1
        let height = hashGridSize
        var pixels = [UInt8](repeating: 0, count: width * height)

        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        let bitCount = hashGridSize * hashGridSize
        var words = [UInt64](repeating: 0, count: (bitCount + 63) / 64)
        var bit = 0
        for y in 0..<height {
            for x in 0..<hashGridSize {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    words[bit / 64] |= UInt64(1) << UInt64(bit % 64)
                }
                bit += 1
            }
        }
        return PerceptualHash(words: words)
    }

    // MARK: - Frame capture

    /// Stable lookup key for a capture request. Derived from the same `CMTime` the generator
    /// echoes back, so the round trip never depends on float comparison.
    static func frameTimeKey(_ seconds: Double) -> Int64 {
        CMTime(seconds: seconds, preferredTimescale: frameTimescale).value
    }

    /// Captures every requested timestamp through a single generator, reducing each frame to
    /// `Value` as it arrives.
    ///
    /// Constructing an asset and generator per frame re-opens the media each time, which is
    /// what made high-resolution capture expensive enough to need a give-up latch. Here a
    /// frame that fails costs only that frame.
    static func captureFrames<Value>(
        generator: AVAssetImageGenerator,
        timesSeconds: [Double],
        transform: @escaping (CGImage) -> Value?
    ) async -> [Int64: Value] {
        // The generator reports once per requested time, and the collector finishes by
        // counting those reports down to zero. A repeated timestamp would leave it waiting
        // on a callback that never arrives, so collapse duplicates before requesting.
        var seenKeys = Set<Int64>()
        let times = timesSeconds.compactMap { seconds -> NSValue? in
            let time = CMTime(seconds: seconds, preferredTimescale: frameTimescale)
            guard seenKeys.insert(time.value).inserted else { return nil }
            return NSValue(time: time)
        }
        guard !times.isEmpty else { return [:] }
        let collector = FrameCollector(expected: times.count, transform: transform)

        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, image, _, _, _ in
                if let finished = collector.record(requestedTime: requestedTime, image: image) {
                    continuation.resume(returning: finished)
                }
            }
        }
    }

    // MARK: - Storage

    static func prepareOutputDirectory(sourceID: String) throws -> URL {
        let directory = URL(fileURLWithPath: StorageService.libraryRootPath)
            .appendingPathComponent("Videos")
            .appendingPathComponent(sourceID)
            .appendingPathComponent("Slides")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Moments

    /// Where the frame captured for one moment of a video lives, relative to
    /// the library's content root: beside the video's slides, so it syncs and
    /// is cleared with them, under a name that is the moment itself.
    static func momentFrameRelativePath(sourceID: String, seconds: Int) -> String {
        "Videos/\(sourceID)/Moments/" + String(format: "moment_%06ds.jpg", max(0, seconds))
    }

    /// The captured frame for a moment on this Mac, across every content root;
    /// nil when it was never captured here or has not synced down.
    static func existingMomentFramePath(sourceID: String, seconds: Int) -> String? {
        guard let path = StorageService.locateSourceFile(momentFrameRelativePath(sourceID: sourceID, seconds: seconds)),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Writes a captured moment where `existingMomentFramePath` finds it.
    @discardableResult
    static func storeMomentFrame(_ image: CGImage, sourceID: String, seconds: Int) throws -> String {
        let url = URL(fileURLWithPath: StorageService.absoluteSourcePath(
            momentFrameRelativePath(sourceID: sourceID, seconds: seconds)
        ))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJPEG(image, to: url)
        return url.path
    }

    // MARK: - Frames this Mac lacks

    /// A slide frame the stored block names: where it is kept, relative to the
    /// content root, and the second of the video it shows.
    struct StoredFrame: Hashable, Sendable {
        let relativePath: String
        let seconds: Double
    }

    /// The frames of `slides` this Mac does not hold, with the second each
    /// was captured at. A block names frames by a path under the content
    /// root, and that root is local to each Mac, so a deck captured on the
    /// other Mac arrives here as a listing of files that are not on disk.
    /// Stats the filesystem: keep it off the main actor.
    static func missingFrames(_ slides: [YouTubeSlideFrameContext]) -> [StoredFrame] {
        slides.compactMap { slide in
            let relativePath = StorageService.relativeSourcePath(slide.imagePath)
            // Only a frame kept under the content root can be put back where
            // every reader of the block looks for it.
            guard !relativePath.hasPrefix("/"), !relativePath.contains("://"),
                  StorageService.locateSourceFile(slide.imagePath) == nil,
                  let seconds = capturedSeconds(of: slide) else { return nil }
            return StoredFrame(relativePath: relativePath, seconds: seconds)
        }
    }

    /// The second a slide's frame was taken at: the one its file name records
    /// (`slide_013_000450s.jpg` → 450), which is the middle of the run the
    /// slide was found in, not the moment it came on screen. A name without
    /// one falls back to the middle of the slide's first window.
    static func capturedSeconds(of slide: YouTubeSlideFrameContext) -> Double? {
        if let seconds = SourceImageReference.SlideFramePath(pathOrURL: slide.imagePath)?.fileNameSeconds {
            return Double(seconds)
        }
        if let window = slide.windows.first, let end = window.end, end > window.start {
            return (window.start + end) / 2
        }
        return slide.timeSeconds
    }

    /// Writes a frame captured again where the stored block says it is.
    static func storeRestoredFrame(_ image: CGImage, at relativePath: String) throws {
        let url = URL(fileURLWithPath: StorageService.absoluteSourcePath(relativePath))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJPEG(image, to: url)
    }

    /// Decodes the one frame at `seconds`. The tolerance is tight on purpose:
    /// slide capture settles for a nearby keyframe because any frame of a run
    /// shows the same slide, but a moment is the instant the learner named —
    /// an animation step, a pointer on a diagram, a line being drawn.
    static func captureMomentFrame(asset: AVAsset, seconds: Double, maximumSize: CGSize) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: momentToleranceSeconds, preferredTimescale: frameTimescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = maximumSize
        let frames = await captureFrames(generator: generator, timesSeconds: [seconds], transform: { $0 })
        guard let frame = frames.values.first else { throw SlideExtractionError.momentUnreachable(seconds: seconds) }
        return frame
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            throw SlideExtractionError.noSlideFramesExtracted
        }
        try data.write(to: url, options: .atomic)
    }

    static func imageFilename(index: Int, timeSeconds: Double?) -> String {
        if let timeSeconds {
            return String(format: "slide_%03d_%06ds.jpg", index, Int(timeSeconds.rounded()))
        }
        return String(format: "slide_%03d.jpg", index)
    }

    // MARK: - Stored markdown

    static func containsSlideSection(_ content: String) -> Bool {
        content.contains(slideSectionHeader)
    }

    /// The stored content as the assistant reads it: the slide block with each
    /// frame's file path replaced by the tool call that shows the slide.
    ///
    /// The paths are this device's, and a Markdown image written from one draws
    /// nothing in a chat — which is what a model did when handed them (2026-09-10).
    /// The model needs the slide numbers and their on-screen windows to choose a
    /// slide, and `show_source_image` to display it; the file names it never needs.
    static func assistantFacingContent(_ content: String) -> String {
        guard containsSlideSection(content) else { return content }
        var inSlideSection = false
        var currentIndex: Int?
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                let line = String(rawLine)
                if line == slideSectionHeader {
                    inSlideSection = true
                    return line
                }
                guard inSlideSection else { return line }
                if line.hasPrefix("### Slide frame ") {
                    currentIndex = Int(line.dropFirst("### Slide frame ".count).prefix { $0.isNumber })
                    return line
                }
                if line.hasPrefix("Representative slide screenshots") {
                    return "Representative slides captured from this video's frames, numbered as show_source_image expects them. Each bracketed range is a stretch of the video during which the slide is on screen."
                }
                if line.hasPrefix("Image:") {
                    if let currentIndex {
                        return "Show: call show_source_image with this source_id and slide \(currentIndex) to show this slide in the reply. Its file is not addressable from a reply."
                    }
                    return "Show: call show_source_image with this source_id to show this slide in the reply."
                }
                return line
            }
        return lines.joined(separator: "\n")
    }

    static func formatSlideMarkdown(_ frames: [SlideFrame]) -> String {
        guard !frames.isEmpty else { return "" }
        var lines = [slideSectionHeader]
        lines.append("")
        lines.append("Representative slide screenshots extracted from this video's frames. Each bracketed range is a stretch of the video during which the slide is on screen. Image paths are relative to the ForeverLM content root.")

        for frame in frames {
            // Windows are the on-screen truth; the representative capture time stands in
            // only when the sample grid carried no times to derive them from.
            let windowLabels = frame.windows.map { window -> String in
                guard let end = window.end else { return " [\(displayTime(window.start))]" }
                return " [\(displayTime(window.start))–\(displayTime(end))]"
            }.joined()
            let timestamp = windowLabels.isEmpty
                ? frame.timeSeconds.map { " [\(displayTime($0))]" } ?? ""
                : windowLabels
            lines.append("")
            lines.append("### Slide frame \(frame.index)\(timestamp)")
            lines.append("Image: \(frame.localImagePath)")
        }

        return lines.joined(separator: "\n")
    }

    /// Appends a freshly extracted deck to a video's stored content, or returns the content
    /// untouched when the extraction found nothing.
    static func appending(frames: [SlideFrame], to content: String) -> AppendResult {
        let markdown = formatSlideMarkdown(frames)
        guard !markdown.isEmpty else {
            return AppendResult(content: content, slideCount: 0, errorMessage: nil)
        }
        let merged = [content.trimmingCharacters(in: .whitespacesAndNewlines), markdown]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return AppendResult(content: merged, slideCount: frames.count, errorMessage: nil)
    }

    static func displayTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Captures again the slide frames a stored block names but this Mac does not hold.
///
/// A deck's listing is part of its source's text and syncs with it; the frames
/// are JPEGs in the content root, which is local to each Mac, and no record
/// carries them. So a deck captured on one Mac arrived on the other as a list
/// of missing files, and the transcript margin drew an empty frame for every
/// slide: Finbow's "Mitochondrial Cristae" talk (86 slides) and nine other
/// videos on the MacBook, 2026-09-30. Each frame is the video at the second its
/// file name records, so it is taken again from the same video and written
/// under the same path, where every reader of the block already looks.
actor SlideFrameRestorer {
    static let shared = SlideFrameRestorer()

    /// Posted on the main actor when frames of a source were written;
    /// `object` is the source id. A thumb that found no file reads again.
    static let framesRestored = Notification.Name("ForeverLM.slideFramesRestored")

    private let logger = Logger(subsystem: "com.foreverlm", category: "SlideFrameRestore")
    /// One capture per source at a time, so the reader opening and a chat
    /// drawing the same deck do not both fetch the video.
    private var running: [String: (token: UUID, task: Task<Bool, Never>)] = [:]
    /// Frames already asked for this launch. A video YouTube no longer serves,
    /// or a recording no longer reachable, is not asked again on every open.
    private var attempted: Set<String> = []

    /// Restores whichever of `slides` this Mac lacks, from the YouTube video
    /// or, given `storage` to find it through, the meeting's recording. True
    /// when any frame was written. Free when every frame is on disk: that
    /// costs one stat per frame.
    @discardableResult
    func restore(_ slides: [YouTubeSlideFrameContext], of article: StudioArticle, storage: StorageService?) async -> Bool {
        let isYouTube = YouTubeTranscriptService.isYouTubeURL(article.url)
        guard isYouTube || (article.sourceType == .meeting && storage != nil) else { return false }
        var restoredAny = false
        while true {
            if let current = running[article.id] {
                restoredAny = await current.task.value || restoredAny
                if running[article.id]?.token == current.token { running[article.id] = nil }
                continue
            }
            let missing = await Task.detached(priority: .utility) {
                SlideFrameExtraction.missingFrames(slides)
            }.value.filter { !attempted.contains($0.relativePath) }
            // The stat let another call in; if it started a capture, wait on that.
            if running[article.id] != nil { continue }
            guard !missing.isEmpty else { return restoredAny }
            attempted.formUnion(missing.map(\.relativePath))

            let token = UUID()
            let logger = logger
            let task = Task<Bool, Never> {
                do {
                    let written = try await Self.capture(missing, of: article, isYouTube: isYouTube, storage: storage)
                    guard written > 0 else { return false }
                    await MainActor.run {
                        NotificationCenter.default.post(name: Self.framesRestored, object: article.id)
                    }
                    return true
                } catch {
                    logger.warning("Could not restore \(missing.count) slide frame(s) of \(article.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            running[article.id] = (token, task)
            restoredAny = await task.value || restoredAny
            if running[article.id]?.token == token { running[article.id] = nil }
            return restoredAny
        }
    }

    private static func capture(
        _ frames: [SlideFrameExtraction.StoredFrame],
        of article: StudioArticle,
        isYouTube: Bool,
        storage: StorageService?
    ) async throws -> Int {
        if isYouTube {
            return try await YouTubeSlideExtractionService.shared.restoreFrames(frames, videoURL: article.url)
        }
        guard let storage else { return 0 }
        let mediaURL = try await ReviewSessionManager.meetingRecordingURL(for: article.id, storage: storage)
        return try await RecordingSlideExtractionService.shared.restoreFrames(frames, mediaURL: mediaURL)
    }
}
