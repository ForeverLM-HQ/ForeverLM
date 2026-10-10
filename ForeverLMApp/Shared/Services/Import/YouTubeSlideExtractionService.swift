import AppKit
import AVFoundation
import Foundation
import OSLog

/// Extracts representative visual slide frames from YouTube storyboard images.
///
/// YouTube exposes time-indexed storyboard contact sheets in the player response.
/// Those are much cheaper and less brittle than downloading full video streams,
/// and they give academic talks enough visual context for slide-aware study.
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
        /// True for a muxed stream from `formats`, false for a video-only one from
        /// `adaptiveFormats`.
        ///
        /// This decides whether frame capture works at all. Adaptive streams are fragmented
        /// DASH: `AVURLAsset` cannot open one from a bare URL without its initialization
        /// segment, so every seek fails. Progressive streams are ordinary seekable MP4 files.
        let isProgressive: Bool

        var area: Int { width * height }
    }

    static let shared = YouTubeSlideExtractionService()

    private static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let innertubeContext: [String: Any] = [
        "client": [
            "clientName": "ANDROID",
            "clientVersion": "20.10.38",
        ]
    ]
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

        let playerJSON = try await fetchPlayerJSON(videoID: videoID)
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

        // One asset, one generator, every timestamp in a single pass.
        var capturedFrames: [Int64: CGImage] = [:]
        if let stream = Self.bestVideoFrameStream(from: Self.parseVideoFrameStreams(playerJSON)) {
            let times = representatives.compactMap(\.timeSeconds).filter { $0 > 0 }
            if !times.isEmpty {
                capturedFrames = await captureHighResolutionFrames(stream: stream, timesSeconds: times)
            }
        }

        let outputDirectory = try SlideFrameExtraction.prepareOutputDirectory(sourceID: sourceID)
        var highResolutionCount = 0
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
            var isHighResolution = false

            if let timeSeconds = scan.timeSeconds,
               let captured = capturedFrames[SlideFrameExtraction.frameTimeKey(timeSeconds)] {
                frameImage = captured
                isHighResolution = true
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
            if isHighResolution {
                highResolutionCount += 1
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
        let storyboardFallbackCount = frames.count - highResolutionCount
        logger.info("Extracted \(frames.count) slide(s) from \(scans.count) tile(s) for \(videoTitle ?? videoID); high-resolution captures: \(highResolutionCount), low-resolution storyboard fallbacks: \(storyboardFallbackCount), repeated frames collapsed: \(repeatCount)")
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
    /// not (`SlideFrameRestorer`). Frames come from the same progressive stream
    /// as at capture, and a frame the stream will not give falls back to its
    /// storyboard tile, as it did then. Returns how many were written.
    func restoreFrames(_ frames: [SlideFrameExtraction.StoredFrame], videoURL: String) async throws -> Int {
        guard let videoID = YouTubeTranscriptService.extractVideoId(from: videoURL) else {
            throw SlideExtractionError.invalidURL
        }
        guard !frames.isEmpty else { return 0 }
        let playerJSON = try await fetchPlayerJSON(videoID: videoID)

        var images: [Int64: CGImage] = [:]
        if let stream = Self.bestVideoFrameStream(from: Self.parseVideoFrameStreams(playerJSON)) {
            images = await captureHighResolutionFrames(stream: stream, timesSeconds: frames.map(\.seconds))
        }
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
        logger.info("Restored \(written) of \(frames.count) missing slide frame(s) of \(videoID); not reached in the stream: \(unreached.count)")
        return written
    }

    /// The frame on screen `seconds` into a YouTube video, read from the same
    /// progressive stream slide capture uses — whatever was showing, whether
    /// or not slide detection kept a slide there. Stored beside the video's
    /// slides so the chat line that names the moment renders it again without
    /// a second trip to YouTube.
    func captureMoment(videoURL: String, sourceID: String, seconds: Int) async throws -> String {
        guard let videoID = YouTubeTranscriptService.extractVideoId(from: videoURL) else {
            throw SlideExtractionError.invalidURL
        }
        let playerJSON = try await fetchPlayerJSON(videoID: videoID)
        if let duration = Self.durationSeconds(from: playerJSON), Double(seconds) >= duration {
            throw SlideExtractionError.momentOutOfRange(seconds: Double(seconds), durationSeconds: duration)
        }
        guard let stream = Self.bestVideoFrameStream(from: Self.parseVideoFrameStreams(playerJSON)) else {
            throw SlideExtractionError.noVideoStream
        }
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "Referer": "https://www.youtube.com/",
        ]
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let frame = try await SlideFrameExtraction.captureMomentFrame(
            asset: asset,
            seconds: Double(seconds),
            maximumSize: CGSize(width: 1920, height: 1080)
        )
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
                    isProgressive: group.isProgressive
                )
            }
        }
    }

    private func fetchPlayerJSON(videoID: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(Self.fallbackAPIKey)") else {
            throw SlideExtractionError.noStoryboardAvailable
        }

        let payload: [String: Any] = [
            "context": Self.innertubeContext,
            "videoId": videoID,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlideExtractionError.noStoryboardAvailable
        }
        return json
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

    /// Captures every representative timestamp from the best progressive stream.
    ///
    /// Failing to open the stream, or to reach a given time in it, is survivable: the caller
    /// falls back to that moment's storyboard tile, which is smaller but still shows the slide.
    private nonisolated func captureHighResolutionFrames(
        stream: VideoFrameStream,
        timesSeconds: [Double]
    ) async -> [Int64: CGImage] {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "Referer": "https://www.youtube.com/",
        ]
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Representatives sit mid-run, so a loose tolerance stays on the same slide while
        // letting the decoder settle for a nearby keyframe instead of decoding forward.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: SlideFrameExtraction.frameTimescale)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: SlideFrameExtraction.frameTimescale)
        generator.maximumSize = CGSize(width: 1920, height: 1080)

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

    /// Picks the stream frames can actually be captured from.
    ///
    /// Resolution is the second consideration, not the first. Sorting purely by area picks
    /// the 1080p adaptive stream, which is video-only fragmented DASH that `AVURLAsset`
    /// cannot open from a bare URL — so every capture fails and every slide silently falls
    /// back to a 160x90 storyboard tile, which reads as nothing at all. A seekable 640x360
    /// progressive frame is worth far more than an unopenable 1080p one.
    nonisolated static func bestVideoFrameStream(from streams: [VideoFrameStream]) -> VideoFrameStream? {
        streams
            .sorted { lhs, rhs in
                if lhs.isProgressive != rhs.isProgressive { return lhs.isProgressive }
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
