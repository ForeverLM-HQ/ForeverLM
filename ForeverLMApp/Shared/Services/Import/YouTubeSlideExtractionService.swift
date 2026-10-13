import AppKit
import AVFoundation
import Foundation
import OSLog

/// Extracts representative visual slide frames from YouTube storyboard images.
///
/// YouTube exposes time-indexed storyboard contact sheets in the player response.
/// Those are much cheaper and less brittle than downloading full video streams,
/// and they give academic talks enough visual context for slide-aware study.
/// The frame stored for each slide is then read from a video stream at that one
/// moment: the 1080p adaptive stream where YouTube serves it, the 360p
/// progressive stream otherwise, and the storyboard tile as the last resort.
actor YouTubeSlideExtractionService {
    // Detection, deduplication, JPEG storage and the stored markdown block are shared with
    // `RecordingSlideExtractionService`; only locating the frames differs between them.
    typealias SlideFrame = SlideFrameExtraction.SlideFrame
    typealias AppendResult = SlideFrameExtraction.AppendResult
    typealias PerceptualHash = SlideFrameExtraction.PerceptualHash
    typealias SlideRun = SlideFrameExtraction.SlideRun
    typealias TileScan = SlideFrameExtraction.TileScan

    struct StoryboardLevel: Equatable {
        let levelIndex: Int
        let urlTemplate: String
        let width: Int
        let height: Int
        let thumbnailCount: Int
        let columns: Int
        let rows: Int
        let intervalMilliseconds: Int?
        /// Per-level filename template substituted for `$N` in the shared URL.
        /// YouTube normally returns `M$M`, but the untimed overview uses `default`.
        let sheetNameTemplate: String
        let signature: String?

        var tilesPerSheet: Int { max(1, columns * rows) }
        var area: Int { width * height }

        func sheetURL(sheetIndex: Int) -> URL? {
            var value = urlTemplate
            let sheetName = sheetNameTemplate.replacingOccurrences(
                of: "$M", with: "\(sheetIndex)"
            )
            value = value.replacingOccurrences(of: "$L", with: "\(levelIndex)")
            value = value.replacingOccurrences(of: "$N", with: sheetName)
            value = value.replacingOccurrences(of: "$M", with: "\(sheetIndex)")
            if let signature {
                if value.contains("$A") {
                    value = value.replacingOccurrences(of: "$A", with: signature)
                } else {
                    // Some specs carry the signature only as a per-level field, with no `$A`
                    // placeholder in the template. Substitution then silently does nothing,
                    // every sheet request 403s, and slide extraction fails for the entire
                    // video — appending it is what makes those URLs resolve.
                    value += (value.contains("?") ? "&" : "?") + "sigh=" + signature
                }
            }
            return URL(string: value)
        }

        func timeSeconds(for thumbnailIndex: Int) -> Double? {
            guard let intervalMilliseconds, intervalMilliseconds > 0 else { return nil }
            return Double(thumbnailIndex * intervalMilliseconds) / 1_000.0
        }
    }

    struct VideoFrameStream: Equatable {
        let url: URL
        let width: Int
        let height: Int
        let qualityLabel: String?
        /// The codecs its MIME type names: `avc1.640028` for H.264, `av01.…` for AV1. A muxed
        /// stream lists its audio codec as well.
        let codecs: [String]
        let framesPerSecond: Int?
        let bitrate: Int?
        /// True for a muxed stream from `formats`, false for a video-only one from
        /// `adaptiveFormats`.
        ///
        /// The two are read differently. A progressive stream is an ordinary seekable MP4 that
        /// `AVURLAsset` opens from its URL. An adaptive stream is a fragmented MP4 that
        /// `AVURLAsset` cannot open (-12190), so it is read segment by segment through the two
        /// byte ranges below (`SegmentedVideoFrameCapture`).
        let isProgressive: Bool
        /// The initialization segment's bytes. Adaptive streams only.
        let initRange: ClosedRange<Int>?
        /// The segment index's bytes. Adaptive streams only.
        let indexRange: ClosedRange<Int>?

        var area: Int { width * height }
        var isH264: Bool { codecs.contains { $0.hasPrefix("avc1") || $0.hasPrefix("avc3") } }

        /// The pixels a capture of this stream keeps once it is scaled to fit `maximumSize`. A
        /// generator only ever scales down, so this is never more than the stream has.
        func capturedArea(within maximumSize: CGSize) -> Double {
            guard width > 0, height > 0 else { return 0 }
            let scale = min(1, maximumSize.width / Double(width), maximumSize.height / Double(height))
            return (Double(width) * scale) * (Double(height) * scale)
        }
    }

    static let shared = YouTubeSlideExtractionService()

    private static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    /// The client every request but the adaptive-stream one uses: its answer carries the
    /// storyboard, the progressive stream, and the visitor id the visionOS request needs.
    private static let androidClient: [String: Any] = [
        "clientName": "ANDROID",
        "clientVersion": "20.10.38",
    ]
    /// The client whose adaptive streams can be read to the end; see `segmentedStream(videoID:playerJSON:)`.
    private static let visionOSClient: [String: Any] = [
        "clientName": "VISIONOS",
        "clientVersion": "0.1",
    ]
    /// Visitor ids tried with the visionOS client before giving up on its streams.
    private static let visionOSVisitorAttempts = 3
    private static let streamRequestHeaders = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        "Referer": "https://www.youtube.com/",
    ]
    /// The largest frame kept. Every capture path scales to fit it, and the stream choice
    /// counts only the pixels that survive it.
    static let captureMaximumSize = CGSize(width: 1920, height: 1080)
    /// Representatives sit mid-run, so a loose tolerance stays on the same slide while
    /// letting the decoder settle for a nearby keyframe instead of decoding forward.
    private static let slideSeekToleranceSeconds: Double = 1
    private static let maxStoryboardSheets = 28
    private let logger = Logger(subsystem: "com.foreverlm", category: "YouTubeSlides")
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func appendingSlideContext(
        to transcript: String,
        videoURL: String,
        sourceID: String,
        videoTitle: String?
    ) async -> AppendResult {
        if SlideFrameExtraction.containsSlideSection(transcript) {
            return AppendResult(content: transcript, slideCount: 0, errorMessage: nil)
        }

        do {
            let frames = try await extractSlides(
                from: videoURL,
                sourceID: sourceID,
                videoTitle: videoTitle
            )
            return SlideFrameExtraction.appending(frames: frames, to: transcript)
        } catch {
            logger.warning("YouTube slide extraction failed: \(error.localizedDescription)")
            return AppendResult(
                content: transcript,
                slideCount: 0,
                errorMessage: error.localizedDescription
            )
        }
    }

    func extractSlides(from videoURL: String, sourceID: String, videoTitle: String?) async throws -> [SlideFrame] {
        guard let videoID = YouTubeTranscriptService.extractVideoId(from: videoURL) else {
            throw SlideExtractionError.invalidURL
        }

        let playerJSON = try await fetchPlayerJSON(videoID: videoID, client: Self.androidClient)
        guard let spec = Self.storyboardSpec(from: playerJSON) else {
            throw SlideExtractionError.noStoryboardAvailable
        }
        let levels = Self.parseStoryboardSpec(spec)
        guard let level = Self.bestStoryboardLevel(from: levels) else {
            throw SlideExtractionError.invalidStoryboardSpec
        }

        // Hash every storyboard tile, then find where the picture actually changes.
        let (scans, sheetCache) = try await scanStoryboardTiles(level: level)
        let runs = SlideFrameExtraction.boundedRuns(SlideFrameExtraction.detectSlideRuns(
            hashes: scans.map(\.hash),
            tileIntervalSeconds: level.intervalMilliseconds.map { Double($0) / 1_000 }
        ))
        guard !runs.isEmpty else {
            throw SlideExtractionError.noSlideFramesExtracted
        }
        let representatives = runs.map { scans[$0.representativeIndex] }

        let times = representatives.compactMap(\.timeSeconds).filter { $0 > 0 }
        let captured = await captureVideoFrames(
            at: times,
            videoID: videoID,
            playerJSON: playerJSON,
            toleranceSeconds: Self.slideSeekToleranceSeconds
        )

        let outputDirectory = try SlideFrameExtraction.prepareOutputDirectory(sourceID: sourceID)
        var segmentedCount = 0
        var progressiveCount = 0
        var repeatCount = 0
        var kept: [(hash: PerceptualHash, frameIndex: Int)] = []
        var frames: [SlideFrame] = []

        let tileIntervalSeconds = level.intervalMilliseconds.map { Double($0) / 1_000 }
        for run in runs {
            let scan = scans[run.representativeIndex]
            // Where this run's slide is on screen, dated at the midpoint between the last tile
            // of one slide and the first tile of the next — the best single estimate of the
            // real transition. The first tile that shows a new slide lags that transition by
            // up to a full interval, so anchoring against it drifts every slide late.
            let window = SlideFrameExtraction.slideWindow(for: run, scans: scans, tileIntervalSeconds: tileIntervalSeconds)

            var frameImage: CGImage?
            var capturedKey: Int64?

            if let timeSeconds = scan.timeSeconds,
               let image = captured.images[SlideFrameExtraction.frameTimeKey(timeSeconds)] {
                frameImage = image
                capturedKey = SlideFrameExtraction.frameTimeKey(timeSeconds)
            }
            if frameImage == nil, let sheet = sheetCache[scan.tileIndex / level.tilesPerSheet] {
                frameImage = Self.cropThumbnail(from: sheet, thumbnailIndex: scan.tileIndex, level: level)
            }
            guard let image = frameImage else { continue }

            // One deck page reaches this loop more than once whenever the presenter cuts
            // away and back, so the frame being stored is what decides whether it is new. A
            // frame that will not hash is stored rather than dropped: keeping a possible
            // duplicate beats silently losing a slide.
            if let hash = SlideFrameExtraction.perceptualHash(image) {
                if let repeatOf = SlideFrameExtraction.repeatIndex(hash, in: kept.map(\.hash)) {
                    // The frame is dropped, but the appearance is not: its window joins the
                    // kept slide's, so anything keyed to that slide (its cited papers) stays
                    // current every time it is on screen, not just the first.
                    repeatCount += 1
                    if let window {
                        frames[kept[repeatOf].frameIndex].windows.append(window)
                    }
                    continue
                }
                kept.append((hash: hash, frameIndex: frames.count))
            }
            if let capturedKey {
                if captured.segmentedKeys.contains(capturedKey) {
                    segmentedCount += 1
                } else {
                    progressiveCount += 1
                }
            }

            let frameNumber = frames.count + 1
            let imageURL = outputDirectory.appendingPathComponent(
                SlideFrameExtraction.imageFilename(index: frameNumber, timeSeconds: scan.timeSeconds)
            )
            try SlideFrameExtraction.writeJPEG(image, to: imageURL)
            frames.append(SlideFrame(
                index: frameNumber,
                timeSeconds: scan.timeSeconds,
                windows: window.map { [$0] } ?? [],
                localImagePath: StorageService.relativeSourcePath(imageURL.path)
            ))
        }

        guard !frames.isEmpty else {
            throw SlideExtractionError.noSlideFramesExtracted
        }
        let storyboardFallbackCount = frames.count - segmentedCount - progressiveCount
        logger.info("Extracted \(frames.count) slide(s) from \(scans.count) tile(s) for \(videoTitle ?? videoID); captured from \(captured.segmentedLabel): \(segmentedCount), from \(captured.progressiveLabel): \(progressiveCount), low-resolution storyboard fallbacks: \(storyboardFallbackCount), repeated frames collapsed: \(repeatCount)")
        if storyboardFallbackCount > 0 {
            // Storyboard tiles are small, so text recognized from them is materially worse.
            // Say so rather than letting the degradation pass silently.
            logger.warning("\(storyboardFallbackCount) slide(s) fell back to low-resolution storyboard tiles for \(videoTitle ?? videoID); recognized text from those frames will be weaker.")
        }
        return frames
    }

    /// Captures `frames` of a video's deck again, each at the second it was
    /// first taken, and writes each where the stored block names it. For a
    /// deck captured on the other Mac: the block synced here and its JPEGs did
    /// not (`SlideFrameRestorer`). Frames come through the same streams as at
    /// capture, and a frame neither stream will give falls back to its
    /// storyboard tile, as it did then. Returns how many were written.
    func restoreFrames(_ frames: [SlideFrameExtraction.StoredFrame], videoURL: String) async throws -> Int {
        guard let videoID = YouTubeTranscriptService.extractVideoId(from: videoURL) else {
            throw SlideExtractionError.invalidURL
        }
        guard !frames.isEmpty else { return 0 }
        let playerJSON = try await fetchPlayerJSON(videoID: videoID, client: Self.androidClient)

        let captured = await captureVideoFrames(
            at: frames.map(\.seconds),
            videoID: videoID,
            playerJSON: playerJSON,
            toleranceSeconds: Self.slideSeekToleranceSeconds
        )
        var images = captured.images
        let unreached = frames.filter { images[SlideFrameExtraction.frameTimeKey($0.seconds)] == nil }
        if !unreached.isEmpty,
           let spec = Self.storyboardSpec(from: playerJSON),
           let level = Self.bestStoryboardLevel(from: Self.parseStoryboardSpec(spec)),
           let interval = level.intervalMilliseconds, interval > 0, level.thumbnailCount > 0 {
            var sheets: [Int: CGImage] = [:]
            var failedSheets = Set<Int>()
            for frame in unreached {
                // The inverse of `StoryboardLevel.timeSeconds(for:)`, which dated the tile.
                let tileIndex = min(level.thumbnailCount - 1, Int((frame.seconds * 1_000 / Double(interval)).rounded()))
                let sheetIndex = tileIndex / level.tilesPerSheet
                if sheets[sheetIndex] == nil, !failedSheets.contains(sheetIndex) {
                    if let url = level.sheetURL(sheetIndex: sheetIndex), let sheet = try? await fetchImage(from: url) {
                        sheets[sheetIndex] = sheet
                    } else {
                        failedSheets.insert(sheetIndex)
                    }
                }
                guard let sheet = sheets[sheetIndex],
                      let tile = Self.cropThumbnail(from: sheet, thumbnailIndex: tileIndex, level: level) else { continue }
                images[SlideFrameExtraction.frameTimeKey(frame.seconds)] = tile
            }
        }

        var written = 0
        for frame in frames {
            guard let image = images[SlideFrameExtraction.frameTimeKey(frame.seconds)] else { continue }
            try SlideFrameExtraction.storeRestoredFrame(image, at: frame.relativePath)
            written += 1
        }
        logger.info("Restored \(written) of \(frames.count) missing slide frame(s) of \(videoID); from \(captured.segmentedLabel): \(captured.segmentedKeys.count), from \(captured.progressiveLabel): \(captured.images.count - captured.segmentedKeys.count), not reached in either stream: \(unreached.count)")
        return written
    }

    /// The frame on screen `seconds` into a YouTube video, read through the
    /// same streams slide capture uses — whatever was showing, whether or not
    /// slide detection kept a slide there. Stored beside the video's slides so
    /// the chat line that names the moment renders it again without a second
    /// trip to YouTube.
    func captureMoment(videoURL: String, sourceID: String, seconds: Int) async throws -> String {
        guard let videoID = YouTubeTranscriptService.extractVideoId(from: videoURL) else {
            throw SlideExtractionError.invalidURL
        }
        let playerJSON = try await fetchPlayerJSON(videoID: videoID, client: Self.androidClient)
        if let duration = Self.durationSeconds(from: playerJSON), Double(seconds) >= duration {
            throw SlideExtractionError.momentOutOfRange(seconds: Double(seconds), durationSeconds: duration)
        }
        let captured = await captureVideoFrames(
            at: [Double(seconds)],
            videoID: videoID,
            playerJSON: playerJSON,
            toleranceSeconds: SlideFrameExtraction.momentToleranceSeconds
        )
        guard captured.segmentedStream != nil || captured.progressiveStream != nil else {
            throw SlideExtractionError.noVideoStream
        }
        guard let frame = captured.images[SlideFrameExtraction.frameTimeKey(Double(seconds))] else {
            throw SlideExtractionError.momentUnreachable(seconds: Double(seconds))
        }
        let path = try SlideFrameExtraction.storeMomentFrame(frame, sourceID: sourceID, seconds: seconds)
        logger.info("Captured the frame at \(seconds)s of \(videoID) (\(frame.width)x\(frame.height))")
        return path
    }

    nonisolated static func durationSeconds(from playerJSON: [String: Any]) -> Double? {
        guard let details = playerJSON["videoDetails"] as? [String: Any] else { return nil }
        if let text = details["lengthSeconds"] as? String, let seconds = Double(text), seconds > 0 { return seconds }
        if let seconds = details["lengthSeconds"] as? Double, seconds > 0 { return seconds }
        if let seconds = details["lengthSeconds"] as? Int, seconds > 0 { return Double(seconds) }
        return nil
    }

    /// Hashes every tile the sheet budget allows, in temporal order. The sheets are kept so
    /// representative tiles can still be cropped if high-resolution capture is unavailable.
    private func scanStoryboardTiles(
        level: StoryboardLevel
    ) async throws -> (scans: [TileScan], sheets: [Int: CGImage]) {
        var sheetCache: [Int: CGImage] = [:]
        var failedSheets = Set<Int>()
        var scans: [TileScan] = []

        for tileIndex in 0..<level.thumbnailCount {
            let sheetIndex = tileIndex / level.tilesPerSheet
            guard !failedSheets.contains(sheetIndex) else { continue }

            if sheetCache[sheetIndex] == nil {
                guard sheetCache.count < Self.maxStoryboardSheets else { break }
                guard let url = level.sheetURL(sheetIndex: sheetIndex),
                      let image = try? await fetchImage(from: url) else {
                    failedSheets.insert(sheetIndex)
                    continue
                }
                sheetCache[sheetIndex] = image
            }

            guard let sheet = sheetCache[sheetIndex],
                  let tile = Self.cropThumbnail(from: sheet, thumbnailIndex: tileIndex, level: level),
                  let hash = SlideFrameExtraction.perceptualHash(tile) else { continue }

            scans.append(TileScan(
                tileIndex: tileIndex,
                timeSeconds: level.timeSeconds(for: tileIndex),
                hash: hash
            ))
        }

        guard !scans.isEmpty else {
            throw SlideExtractionError.noSlideFramesExtracted
        }
        return (scans, sheetCache)
    }

    nonisolated static func parseStoryboardSpec(_ spec: String) -> [StoryboardLevel] {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let template = parts.first, !template.isEmpty else { return [] }

        return parts.dropFirst().enumerated().compactMap { offset, rawLevel in
            let fields = rawLevel.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5,
                  let width = Int(fields[0]),
                  let height = Int(fields[1]),
                  let count = Int(fields[2]),
                  let columns = Int(fields[3]),
                  let rows = Int(fields[4]),
                  width > 0,
                  height > 0,
                  count > 0,
                  columns > 0,
                  rows > 0 else {
                return nil
            }

            // YouTube's overview level reports 0, which means untimed rather than a
            // zero-length interval. Keeping it as 0 makes that overview sort ahead
            // of the real, timed levels even though it cannot anchor any slides.
            let rawInterval = fields.count > 5 ? Int(fields[5]) : nil
            let interval = rawInterval.flatMap { $0 > 0 ? $0 : nil }
            let sheetNameTemplate = fields.count > 6 && !fields[6].isEmpty
                ? fields[6]
                : "M$M"
            let signature = fields.count > 7
                ? fields.last.flatMap { $0.isEmpty ? nil : $0 }
                : nil
            return StoryboardLevel(
                levelIndex: offset,
                urlTemplate: template,
                width: width,
                height: height,
                thumbnailCount: count,
                columns: columns,
                rows: rows,
                intervalMilliseconds: interval,
                sheetNameTemplate: sheetNameTemplate,
                signature: signature
            )
        }
    }

    nonisolated static func parseVideoFrameStreams(_ json: [String: Any]) -> [VideoFrameStream] {
        guard let streamingData = json["streamingData"] as? [String: Any] else { return [] }
        let formatGroups: [(formats: [[String: Any]], isProgressive: Bool)] = [
            (streamingData["formats"] as? [[String: Any]] ?? [], true),
            (streamingData["adaptiveFormats"] as? [[String: Any]] ?? [], false),
        ]

        return formatGroups.flatMap { group in
            group.formats.compactMap { format -> VideoFrameStream? in
                guard let rawURL = format["url"] as? String,
                      let url = URL(string: rawURL) else { return nil }
                let mimeType = format["mimeType"] as? String ?? ""
                guard mimeType.contains("video/mp4") else {
                    return nil
                }
                let width = format["width"] as? Int ?? 0
                let height = format["height"] as? Int ?? 0
                guard width > 0, height > 0 else { return nil }
                return VideoFrameStream(
                    url: url,
                    width: width,
                    height: height,
                    qualityLabel: format["qualityLabel"] as? String,
                    codecs: codecs(fromMimeType: mimeType),
                    framesPerSecond: format["fps"] as? Int,
                    bitrate: format["bitrate"] as? Int,
                    isProgressive: group.isProgressive,
                    initRange: byteRange(format["initRange"]),
                    indexRange: byteRange(format["indexRange"])
                )
            }
        }
    }

    /// The codecs a MIME type's `codecs` parameter lists: `["avc1.42001E", "mp4a.40.2"]` from
    /// `video/mp4; codecs="avc1.42001E, mp4a.40.2"`.
    nonisolated static func codecs(fromMimeType mimeType: String) -> [String] {
        guard let marker = mimeType.range(of: "codecs=") else { return [] }
        return mimeType[marker.upperBound...]
            .prefix { $0 != ";" }
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter { !$0.isEmpty }
    }

    /// A byte range as YouTube reports one, `{"start": "0", "end": "741"}`, inclusive at both ends.
    nonisolated static func byteRange(_ value: Any?) -> ClosedRange<Int>? {
        guard let range = value as? [String: Any] else { return nil }
        func integer(_ field: Any?) -> Int? {
            if let text = field as? String { return Int(text) }
            return field as? Int
        }
        guard let start = integer(range["start"]),
              let end = integer(range["end"]),
              start >= 0, end >= start else { return nil }
        return start...end
    }

    /// The visitor id YouTube issued with an answer, which a later request carries so it is
    /// not taken for a bot.
    nonisolated static func visitorData(from playerJSON: [String: Any]) -> String? {
        guard let context = playerJSON["responseContext"] as? [String: Any],
              let visitorData = context["visitorData"] as? String,
              !visitorData.isEmpty else { return nil }
        return visitorData
    }

    private func fetchPlayerJSON(videoID: String, client: [String: Any]) async throws -> [String: Any] {
        let answer = try await requestPlayer(videoID: videoID, client: client)
        guard (200...299).contains(answer.status), let json = answer.json else {
            throw SlideExtractionError.noStoryboardAvailable
        }
        return json
    }

    /// YouTube's player answer for `videoID` as `client` sees it, with its HTTP status, so a
    /// caller can tell a refusal from a failure.
    private func requestPlayer(videoID: String, client: [String: Any]) async throws -> (status: Int, json: [String: Any]?) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(Self.fallbackAPIKey)") else {
            throw SlideExtractionError.noStoryboardAvailable
        }

        let payload: [String: Any] = [
            "context": ["client": client],
            "videoId": videoID,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SlideExtractionError.noStoryboardAvailable
        }
        return (httpResponse.statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fetchImage(from url: URL) async throws -> CGImage {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SlideExtractionError.noSlideFramesExtracted
        }
        return cgImage
    }

    /// Frames captured for a list of times, and which stream gave each.
    struct CapturedVideoFrames {
        /// Keyed by `SlideFrameExtraction.frameTimeKey` of the time asked for.
        var images: [Int64: CGImage] = [:]
        /// The keys of `images` read from the adaptive stream; the rest came from the
        /// progressive one.
        var segmentedKeys = Set<Int64>()
        /// The adaptive stream frames were asked of first, when there was one.
        var segmentedStream: VideoFrameStream?
        /// The progressive stream, when YouTube offered one.
        var progressiveStream: VideoFrameStream?

        var segmentedLabel: String { Self.label(segmentedStream, kind: "adaptive") }
        var progressiveLabel: String { Self.label(progressiveStream, kind: "progressive") }

        private static func label(_ stream: VideoFrameStream?, kind: String) -> String {
            stream.map { "the \($0.width)x\($0.height) \(kind) stream" } ?? "no \(kind) stream"
        }
    }

    /// A frame at each of `timesSeconds`, each from the sharpest stream that gives it.
    ///
    /// The adaptive stream (1080p for most talks) is asked first and the progressive one
    /// (360p) takes whatever it did not give, so a refused or unreachable adaptive stream costs
    /// resolution, never a frame. A time neither gives is left out for the caller's storyboard
    /// fallback. Why the adaptive stream fell short is logged, never passed over in silence.
    private func captureVideoFrames(
        at timesSeconds: [Double],
        videoID: String,
        playerJSON: [String: Any],
        toleranceSeconds: Double
    ) async -> CapturedVideoFrames {
        var captured = CapturedVideoFrames()
        captured.progressiveStream = Self.bestProgressiveFrameStream(from: Self.parseVideoFrameStreams(playerJSON))
        guard !timesSeconds.isEmpty else { return captured }

        if let stream = await segmentedStream(videoID: videoID, playerJSON: playerJSON),
           let initRange = stream.initRange,
           let indexRange = stream.indexRange {
            captured.segmentedStream = stream
            let started = Date()
            let outcome = await SegmentedVideoFrameCapture.captureFrames(
                from: SegmentedVideoFrameCapture.Source(
                    url: stream.url,
                    initRange: initRange,
                    indexRange: indexRange,
                    headers: Self.streamRequestHeaders
                ),
                timesSeconds: timesSeconds,
                session: session,
                toleranceSeconds: toleranceSeconds,
                maximumSize: Self.captureMaximumSize
            )
            captured.images = outcome.images
            captured.segmentedKeys = Set(outcome.images.keys)
            let elapsed = Date().timeIntervalSince(started)
            let summary = "\(outcome.images.count) of \(timesSeconds.count) frame(s) of \(videoID) from \(captured.segmentedLabel) in \(String(format: "%.1f", elapsed))s (\(outcome.segmentsDecoded) segment(s), \(outcome.bytesFetched / 1_024) KB)"
            if let failure = outcome.failure {
                logger.warning("Captured \(summary); the rest fall back to \(captured.progressiveLabel): \(failure)")
            } else {
                logger.info("Captured \(summary)")
            }
        }

        let remaining = timesSeconds.filter { captured.images[SlideFrameExtraction.frameTimeKey($0)] == nil }
        if !remaining.isEmpty, let stream = captured.progressiveStream {
            let images = await captureProgressiveFrames(stream: stream, timesSeconds: remaining, toleranceSeconds: toleranceSeconds)
            captured.images.merge(images) { segmented, _ in segmented }
        }
        return captured
    }

    /// The adaptive stream frames are read from first, or nil when YouTube offers none that
    /// can be read.
    ///
    /// It is asked of YouTube's visionOS client. The ANDROID client this service uses for
    /// everything else lists the same 720p and 1080p streams, but googlevideo answers 403 to
    /// any byte of them past roughly the first minute of the video. IOS and ANDROID_VR fare the
    /// same (measured 2026-10-13): those copies are gated on a playback token. The visionOS
    /// client's copies answer to the end of the file. It needs a visitor id from an ANDROID
    /// answer; without one it is turned away as a possible bot. If YouTube closes this too, the
    /// first refused segment ends the stream and the progressive one takes the rest.
    private func segmentedStream(videoID: String, playerJSON: [String: Any]) async -> VideoFrameStream? {
        var visitorData = Self.visitorData(from: playerJSON)
        var attempt = 1
        while true {
            guard let visitor = visitorData else {
                logger.warning("YouTube's answer for \(videoID) carried no visitor id, so its adaptive streams were not asked for")
                return nil
            }
            var client = Self.visionOSClient
            client["visitorData"] = visitor
            let answer: (status: Int, json: [String: Any]?)
            do {
                answer = try await requestPlayer(videoID: videoID, client: client)
            } catch {
                logger.warning("YouTube's adaptive streams for \(videoID) could not be listed: \(error.localizedDescription)")
                return nil
            }
            if answer.status == 400, attempt < Self.visionOSVisitorAttempts {
                // The visionOS client turns some visitor ids away for good: HTTP 400,
                // FAILED_PRECONDITION, for about one in eight on 2026-10-13, and the same id
                // failed every time it was retried while a fresh one went through. So a refusal
                // asks the ANDROID client for a new id rather than repeating the request.
                attempt += 1
                let fresh = try? await fetchPlayerJSON(videoID: videoID, client: Self.androidClient)
                visitorData = fresh.flatMap(Self.visitorData(from:))
                continue
            }
            guard (200...299).contains(answer.status), let json = answer.json else {
                logger.warning("YouTube's visionOS client answered HTTP \(answer.status) for \(videoID) after \(attempt) visitor id(s), so its adaptive streams are out of reach")
                return nil
            }
            let playability = json["playabilityStatus"] as? [String: Any]
            guard let status = playability?["status"] as? String, status == "OK" else {
                let reason = playability?["reason"] as? String ?? "no reason given"
                logger.warning("YouTube refused \(videoID) to its visionOS client (\(playability?["status"] as? String ?? "no status"): \(reason)), so its adaptive streams are out of reach")
                return nil
            }
            guard let stream = Self.bestSegmentedFrameStream(from: Self.parseVideoFrameStreams(json)) else {
                logger.warning("YouTube offered \(videoID) no H.264 adaptive stream with a segment index")
                return nil
            }
            return stream
        }
    }

    /// Captures every time from the progressive stream through one asset and one generator.
    ///
    /// Failing to open the stream, or to reach a given time in it, is survivable: the caller
    /// falls back to that moment's storyboard tile, which is smaller but still shows the slide.
    private nonisolated func captureProgressiveFrames(
        stream: VideoFrameStream,
        timesSeconds: [Double],
        toleranceSeconds: Double
    ) async -> [Int64: CGImage] {
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": Self.streamRequestHeaders])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: SlideFrameExtraction.frameTimescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = Self.captureMaximumSize

        return await SlideFrameExtraction.captureFrames(
            generator: generator,
            timesSeconds: timesSeconds,
            transform: { $0 }
        )
    }

    private static func storyboardSpec(from json: [String: Any]) -> String? {
        guard let storyboards = json["storyboards"] as? [String: Any],
              let renderer = storyboards["playerStoryboardSpecRenderer"] as? [String: Any],
              let spec = renderer["spec"] as? String,
              !spec.isEmpty else {
            return nil
        }
        return spec
    }

    nonisolated static func bestStoryboardLevel(from levels: [StoryboardLevel]) -> StoryboardLevel? {
        levels
            .filter { $0.thumbnailCount > 0 && $0.tilesPerSheet > 0 }
            .sorted { lhs, rhs in
                let lhsSheetCount = Int(ceil(Double(lhs.thumbnailCount) / Double(lhs.tilesPerSheet)))
                let rhsSheetCount = Int(ceil(Double(rhs.thumbnailCount) / Double(rhs.tilesPerSheet)))
                let lhsOverBudget = lhsSheetCount > Self.maxStoryboardSheets
                let rhsOverBudget = rhsSheetCount > Self.maxStoryboardSheets
                if lhsOverBudget != rhsOverBudget { return !lhsOverBudget }
                // Timing precision is the point of the storyboard now. The stored slide image
                // comes from the MP4 capture, and detection downsamples every tile to the same
                // 17x16 dHash regardless of the tile's own size, so the finest-interval level
                // costs nothing in detection quality and buys a tighter grid to date slide
                // changes on — which is what the transcript anchors against. A level with no
                // interval can date nothing, so it sorts last.
                let lhsInterval = lhs.intervalMilliseconds ?? .max
                let rhsInterval = rhs.intervalMilliseconds ?? .max
                if lhsInterval != rhsInterval { return lhsInterval < rhsInterval }
                if lhs.area != rhs.area { return lhs.area > rhs.area }
                return lhs.thumbnailCount > rhs.thumbnailCount
            }
            .first
    }

    /// The adaptive stream frames are read from first: the sharpest one this Mac decodes that
    /// can be read segment by segment.
    ///
    /// Only H.264 qualifies. Every Mac decodes it in hardware, and YouTube serves it up to
    /// 1080p, which is all a capture keeps; its AV1 copies decode in hardware only on recent
    /// chips, and VP9 comes as WebM, which AVFoundation does not read. A stream also needs both
    /// byte ranges, since its frames are reached only through its segment index. Among those
    /// the most pixels kept wins. A stream larger than the capture keeps no more than one that
    /// fills it, so ties go to the lower frame rate and then the lower bitrate: the same
    /// picture for fewer bytes.
    nonisolated static func bestSegmentedFrameStream(
        from streams: [VideoFrameStream],
        maximumSize: CGSize = captureMaximumSize
    ) -> VideoFrameStream? {
        streams
            .filter { !$0.isProgressive && $0.isH264 && $0.initRange != nil && $0.indexRange != nil }
            .sorted { lhs, rhs in
                let lhsArea = lhs.capturedArea(within: maximumSize)
                let rhsArea = rhs.capturedArea(within: maximumSize)
                if lhsArea != rhsArea { return lhsArea > rhsArea }
                // An unknown rate or bitrate sorts after a known one.
                let lhsRate = lhs.framesPerSecond ?? .max
                let rhsRate = rhs.framesPerSecond ?? .max
                if lhsRate != rhsRate { return lhsRate < rhsRate }
                return (lhs.bitrate ?? .max) < (rhs.bitrate ?? .max)
            }
            .first
    }

    /// The muxed stream `AVURLAsset` opens from its URL: the fallback for any frame the
    /// adaptive stream does not give, and the only stream when YouTube offers no adaptive one.
    ///
    /// Never an adaptive stream. `AVURLAsset` cannot open one (-12190), and the ANDROID
    /// client's copies are refused past their first minute (HTTP 403) besides. Choosing the
    /// 1080p adaptive stream here once failed every capture and sent every slide to a 160x90
    /// storyboard tile.
    nonisolated static func bestProgressiveFrameStream(from streams: [VideoFrameStream]) -> VideoFrameStream? {
        streams
            .filter(\.isProgressive)
            .sorted { lhs, rhs in
                if lhs.area != rhs.area { return lhs.area > rhs.area }
                return (lhs.qualityLabel ?? "") > (rhs.qualityLabel ?? "")
            }
            .first
    }

    private static func cropThumbnail(from sheet: CGImage, thumbnailIndex: Int, level: StoryboardLevel) -> CGImage? {
        let tileIndex = thumbnailIndex % level.tilesPerSheet
        let column = tileIndex % level.columns
        let row = tileIndex / level.columns
        let x = column * level.width
        let y = row * level.height
        let rect = CGRect(x: x, y: y, width: level.width, height: level.height)
        guard x + level.width <= sheet.width,
              y + level.height <= sheet.height else {
            return nil
        }
        return sheet.cropping(to: rect)
    }
}
