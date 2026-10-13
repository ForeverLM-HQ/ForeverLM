import AVFoundation
import CoreVideo
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ForeverLM

@Suite("Segmented Video Frame Capture")
struct SegmentedVideoFrameCaptureTests {

    // MARK: - Segment index

    @Test("Reads a version 0 segment index")
    func parsesVersion0Index() throws {
        let box = Self.segmentIndexBox(
            version: 0,
            timescale: 1_000,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: [(size: 100, duration: 5_000), (size: 200, duration: 5_000), (size: 300, duration: 4_000)]
        )

        let index = try SegmentedVideoFrameCapture.parseSegmentIndex(box, fileOffset: 742)

        // The media starts on the byte after the box.
        let media = 742 + box.count
        #expect(index.segments == [
            .init(startSeconds: 0, durationSeconds: 5, byteRange: media...(media + 99)),
            .init(startSeconds: 5, durationSeconds: 5, byteRange: (media + 100)...(media + 299)),
            .init(startSeconds: 10, durationSeconds: 4, byteRange: (media + 300)...(media + 599)),
        ])
    }

    @Test("Reads a version 1 index that starts late and leaves a gap before the media")
    func parsesVersion1Index() throws {
        let box = Self.segmentIndexBox(
            version: 1,
            timescale: 12_800,
            earliestPresentationTime: 6_400,
            firstOffset: 16,
            references: [(size: 1_000, duration: 64_000), (size: 2_000, duration: 64_000)]
        )
        // What follows the box in the file is not part of the index.
        let followed = box + Data([0, 0, 0, 8] + Array("moof".utf8))

        let index = try SegmentedVideoFrameCapture.parseSegmentIndex(followed, fileOffset: 0)

        let media = box.count + 16
        #expect(index.segments == [
            .init(startSeconds: 0.5, durationSeconds: 5, byteRange: media...(media + 999)),
            .init(startSeconds: 5.5, durationSeconds: 5, byteRange: (media + 1_000)...(media + 2_999)),
        ])
    }

    @Test("Refuses what is not a flat segment index")
    func rejectsUnsupportedIndexes() {
        let references = [(size: 100, duration: 5_000)]
        let good = Self.segmentIndexBox(version: 0, timescale: 1_000, earliestPresentationTime: 0, firstOffset: 0, references: references)

        var wrongType = good
        wrongType.replaceSubrange(4..<8, with: Array("moof".utf8))
        #expect(throws: SegmentedVideoFrameCapture.IndexError.notASegmentIndex(found: "moof")) {
            try SegmentedVideoFrameCapture.parseSegmentIndex(wrongType, fileOffset: 0)
        }

        #expect(throws: SegmentedVideoFrameCapture.IndexError.truncated) {
            try SegmentedVideoFrameCapture.parseSegmentIndex(good.dropLast(4), fileOffset: 0)
        }

        let nested = Self.segmentIndexBox(
            version: 0, timescale: 1_000, earliestPresentationTime: 0, firstOffset: 0,
            references: references, referencesAnotherIndex: true
        )
        #expect(throws: SegmentedVideoFrameCapture.IndexError.nestedIndex) {
            try SegmentedVideoFrameCapture.parseSegmentIndex(nested, fileOffset: 0)
        }

        let untimed = Self.segmentIndexBox(version: 0, timescale: 0, earliestPresentationTime: 0, firstOffset: 0, references: references)
        #expect(throws: SegmentedVideoFrameCapture.IndexError.missingTimescale) {
            try SegmentedVideoFrameCapture.parseSegmentIndex(untimed, fileOffset: 0)
        }

        var futureVersion = good
        futureVersion[8] = 2
        #expect(throws: SegmentedVideoFrameCapture.IndexError.unsupportedVersion(2)) {
            try SegmentedVideoFrameCapture.parseSegmentIndex(futureVersion, fileOffset: 0)
        }
    }

    // MARK: - Timeline

    @Test("Finds the segment on screen at a time; a boundary belongs to the segment it starts")
    func findsSegmentContainingTime() {
        let index = Self.threeSegments

        #expect(index.segmentIndex(containing: 0) == 0)
        #expect(index.segmentIndex(containing: 4.999) == 0)
        #expect(index.segmentIndex(containing: 5) == 1)
        #expect(index.segmentIndex(containing: 13.9) == 2)
        #expect(index.segmentIndex(containing: 14) == nil)
        #expect(index.segmentIndex(containing: -0.1) == nil)
        #expect(SegmentedVideoFrameCapture.SegmentIndex(segments: []).segmentIndex(containing: 1) == nil)
    }

    @Test("Asks each segment once for its times, in file order, leaving out times past the end")
    func groupsRequestsBySegment() {
        let requests = SegmentedVideoFrameCapture.segmentRequests(
            for: [12, 1, 3, 7, 1, 20],
            in: Self.threeSegments
        )

        #expect(requests == [
            .init(segment: 0, timesSeconds: [1, 3]),
            .init(segment: 1, timesSeconds: [7]),
            .init(segment: 2, timesSeconds: [12]),
        ])
    }

    /// A file holding one segment starts its timeline at that segment's first frame, so the
    /// talk's 600th second is 3.44 s into the segment that starts at 596.56 s.
    @Test("Maps a time onto a lone segment's own timeline")
    func mapsTimeIntoSegment() {
        let segment = SegmentedVideoFrameCapture.SegmentIndex.Segment(
            startSeconds: 596.56, durationSeconds: 5, byteRange: 0...1
        )

        #expect(abs(SegmentedVideoFrameCapture.localSeconds(600, in: segment) - 3.44) < 1e-9)
        #expect(SegmentedVideoFrameCapture.localSeconds(596, in: segment) == 0)
        #expect(SegmentedVideoFrameCapture.localSeconds(602, in: segment) == 5)
    }

    /// Asked for the talk's own second 600 instead of the segment's 3.44, a lone segment
    /// answers with its last frame at 4.96 s; that frame shows another moment and is refused.
    @Test("Refuses a frame further from the request than the tolerance allows")
    func refusesDistantFrame() {
        #expect(SegmentedVideoFrameCapture.isFrame(at: 3.9, closeEnoughTo: 3.44, toleranceSeconds: 1))
        #expect(SegmentedVideoFrameCapture.isFrame(at: 3.5, closeEnoughTo: 3.44, toleranceSeconds: 0.1))
        #expect(!SegmentedVideoFrameCapture.isFrame(at: 3.7, closeEnoughTo: 3.44, toleranceSeconds: 0.1))
        #expect(!SegmentedVideoFrameCapture.isFrame(at: 4.96, closeEnoughTo: 600, toleranceSeconds: 1))
    }

    // MARK: - Capture

    /// The whole read against a real fragmented H.264 file served by range: every captured
    /// frame must show the page that was on screen at the second asked for, which only holds
    /// if each segment is found, fetched and decoded on the timeline `localSeconds` assumes.
    @Test("Captures each time from its own segment, showing the moment asked for")
    func capturesTheMomentsAskedFor() async throws {
        let video = try await FragmentedVideo.shared.value
        let url = RangeServer.serve(video.file)
        let times = [1.5, 6.25, 9.75, 13.5, 17.5]

        let outcome = await SegmentedVideoFrameCapture.captureFrames(
            from: video.source(at: url),
            timesSeconds: times,
            session: RangeServer.session,
            toleranceSeconds: SlideFrameExtraction.momentToleranceSeconds,
            maximumSize: CGSize(width: 1920, height: 1080)
        )

        #expect(outcome.failure == nil)
        #expect(outcome.images.count == times.count)
        for seconds in times {
            let image = try #require(outcome.images[SlideFrameExtraction.frameTimeKey(seconds)])
            #expect(image.width == FragmentedVideo.width)
            #expect(try FragmentedVideo.pageShown(in: image) == Int(seconds))
        }
        let segments = Set(times.compactMap { video.index.segmentIndex(containing: $0) })
        #expect(outcome.segmentsDecoded == segments.count)
        // The head once, then exactly the segments that hold a requested time.
        #expect(RangeServer.ranges(for: url).count == 1 + segments.count)
    }

    /// What googlevideo does with a gated stream: it serves the first stretch and answers 403
    /// beyond it. The frames read before the refusal are kept; the rest are left to the
    /// progressive stream.
    @Test("Keeps the frames the stream gave before it refused")
    func keepsFramesBeforeTheRefusal() async throws {
        let video = try await FragmentedVideo.shared.value
        let segments = video.index.segments
        try #require(segments.count > SegmentedVideoFrameCapture.maxConcurrentSegments + 2)
        let url = RangeServer.serve(video.file, refusingFrom: segments[2].byteRange.lowerBound)
        let times = segments.map { $0.startSeconds + 0.5 }

        let outcome = await SegmentedVideoFrameCapture.captureFrames(
            from: video.source(at: url),
            timesSeconds: times,
            session: RangeServer.session,
            toleranceSeconds: SlideFrameExtraction.momentToleranceSeconds,
            maximumSize: CGSize(width: 1920, height: 1080)
        )

        #expect(Set(outcome.images.keys) == Set(times.prefix(2).map(SlideFrameExtraction.frameTimeKey)))
        #expect(outcome.failure?.contains("HTTP 403") == true)
        #expect(RangeServer.ranges(for: url).count < 1 + segments.count)
    }

    /// A refused stream is refused for good, so the segments still waiting are never asked
    /// for: only the first batch, already in flight when the refusal came back, reached it.
    @Test("Asks for nothing more once the stream refuses")
    func stopsAtTheFirstRefusal() async throws {
        let video = try await FragmentedVideo.shared.value
        let segments = video.index.segments
        try #require(segments.count > SegmentedVideoFrameCapture.maxConcurrentSegments + 2)
        let url = RangeServer.serve(video.file, refusingFrom: segments[0].byteRange.lowerBound)

        let outcome = await SegmentedVideoFrameCapture.captureFrames(
            from: video.source(at: url),
            timesSeconds: segments.map { $0.startSeconds + 0.5 },
            session: RangeServer.session,
            toleranceSeconds: SlideFrameExtraction.momentToleranceSeconds,
            maximumSize: CGSize(width: 1920, height: 1080)
        )

        #expect(outcome.images.isEmpty)
        #expect(outcome.failure?.contains("HTTP 403") == true)
        #expect(RangeServer.ranges(for: url).count == 1 + SegmentedVideoFrameCapture.maxConcurrentSegments)
    }

    @Test("Gives nothing, and says why, when the server ignores the range")
    func refusesAWholeFileAnswer() async throws {
        let video = try await FragmentedVideo.shared.value
        let url = RangeServer.serve(video.file, ignoringRange: true)

        let outcome = await SegmentedVideoFrameCapture.captureFrames(
            from: video.source(at: url),
            timesSeconds: [1.5],
            session: RangeServer.session,
            toleranceSeconds: SlideFrameExtraction.momentToleranceSeconds,
            maximumSize: CGSize(width: 1920, height: 1080)
        )

        #expect(outcome.images.isEmpty)
        #expect(outcome.failure?.contains("HTTP 200") == true)
        #expect(RangeServer.ranges(for: url).count == 1)
    }

    @Test("Leaves a time past the stream's end to the fallback")
    func leavesTimesPastTheEnd() async throws {
        let video = try await FragmentedVideo.shared.value
        let url = RangeServer.serve(video.file)

        let outcome = await SegmentedVideoFrameCapture.captureFrames(
            from: video.source(at: url),
            timesSeconds: [2.5, 500],
            session: RangeServer.session,
            toleranceSeconds: SlideFrameExtraction.momentToleranceSeconds,
            maximumSize: CGSize(width: 1920, height: 1080)
        )

        #expect(Set(outcome.images.keys) == [SlideFrameExtraction.frameTimeKey(2.5)])
        #expect(outcome.failure == nil)
    }

    // MARK: - Fixtures

    private static let threeSegments = SegmentedVideoFrameCapture.SegmentIndex(segments: [
        .init(startSeconds: 0, durationSeconds: 5, byteRange: 0...99),
        .init(startSeconds: 5, durationSeconds: 5, byteRange: 100...299),
        .init(startSeconds: 10, durationSeconds: 4, byteRange: 300...599),
    ])

    /// A `sidx` box (ISO/IEC 14496-12, 8.16.3) as a DASH packager writes one.
    static func segmentIndexBox(
        version: UInt8,
        timescale: UInt32,
        earliestPresentationTime: UInt64,
        firstOffset: UInt64,
        references: [(size: Int, duration: Int)],
        referencesAnotherIndex: Bool = false
    ) -> Data {
        var body = Data()
        func append(_ value: UInt64, bytes: Int) {
            for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
                body.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
        append(UInt64(version), bytes: 1)
        append(0, bytes: 3)  // flags
        append(1, bytes: 4)  // reference_ID
        append(UInt64(timescale), bytes: 4)
        append(earliestPresentationTime, bytes: version == 0 ? 4 : 8)
        append(firstOffset, bytes: version == 0 ? 4 : 8)
        append(0, bytes: 2)  // reserved
        append(UInt64(references.count), bytes: 2)
        for reference in references {
            append((referencesAnotherIndex ? 0x8000_0000 : 0) | UInt64(reference.size), bytes: 4)
            append(UInt64(reference.duration), bytes: 4)
            append(0x9000_0000, bytes: 4)  // starts with a type 1 stream access point
        }
        var box = Data()
        let size = UInt32(8 + body.count)
        box.append(contentsOf: [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        box.append(contentsOf: Array("sidx".utf8))
        box.append(body)
        return box
    }
}

/// A short H.264 video laid out as a DASH server lays out an adaptive stream: the
/// initialization segment, a `sidx` over the media segments, then the segments, in one file.
/// Every second shows its own page of random cells, so a frame tells which second it is from.
private struct FragmentedVideo: Sendable {
    static let width = 320
    static let height = 180
    static let seconds = 18
    static let framesPerSecond: Int32 = 4

    let file: Data
    let initRange: ClosedRange<Int>
    let indexRange: ClosedRange<Int>
    let index: SegmentedVideoFrameCapture.SegmentIndex

    static let shared = Task { try await make() }

    func source(at url: URL) -> SegmentedVideoFrameCapture.Source {
        SegmentedVideoFrameCapture.Source(url: url, initRange: initRange, indexRange: indexRange, headers: [:])
    }

    /// The second whose page `image` shows, by the nearest perceptual hash.
    static func pageShown(in image: CGImage) throws -> Int {
        let hash = try #require(SlideFrameExtraction.perceptualHash(image))
        let distances = pageHashes.map { $0.distance(to: hash) }
        let nearest = try #require(distances.indices.min { distances[$0] < distances[$1] })
        #expect(distances[nearest] <= SlideFrameExtraction.duplicateDistance)
        return nearest
    }

    private static let pageHashes: [SlideFrameExtraction.PerceptualHash] = (0..<seconds).map {
        SlideFrameExtraction.perceptualHash(page($0))!
    }

    private static func page(_ second: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        let columns = 8
        let rows = 6
        for row in 0..<rows {
            for column in 0..<columns {
                var value = UInt64(second * 977 + row * 131 + column * 31 + 7)
                value = value &* 0x2545_F491_4F6C_DD1D
                value ^= value >> 29
                guard value & 1 == 1 else { continue }
                context.fill(CGRect(
                    x: column * width / columns, y: row * height / rows,
                    width: width / columns, height: height / rows
                ))
            }
        }
        return context.makeImage()!
    }

    private static func make() async throws -> FragmentedVideo {
        let collector = SegmentCollector()
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond),
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw FixtureError.writer(writer.error) }
        writer.startSession(atSourceTime: .zero)

        for second in 0..<seconds {
            let buffer = try pixelBuffer(showing: page(second), pool: adaptor.pixelBufferPool)
            for frame in 0..<Int64(framesPerSecond) {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                adaptor.append(buffer, withPresentationTime: CMTime(
                    value: Int64(second) * Int64(framesPerSecond) + frame,
                    timescale: framesPerSecond
                ))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.writer(writer.error) }
        return try collector.assemble()
    }

    private static func pixelBuffer(showing image: CGImage, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        guard let buffer else { throw FixtureError.pixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { throw FixtureError.pixelBuffer }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    enum FixtureError: Error {
        case writer(Error?)
        case pixelBuffer
        case segments(String)
    }

    /// Gathers what the writer emits and lays it out as one indexed file.
    private final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var initialization: Data?
        private var segments: [(data: Data, start: CMTime, duration: CMTime)] = []

        func assetWriter(
            _ writer: AVAssetWriter,
            didOutputSegmentData segmentData: Data,
            segmentType: AVAssetSegmentType,
            segmentReport: AVAssetSegmentReport?
        ) {
            lock.withLock {
                switch segmentType {
                case .initialization:
                    initialization = segmentData
                case .separable:
                    if let track = segmentReport?.trackReports.first {
                        segments.append((segmentData, track.earliestPresentationTimeStamp, track.duration))
                    }
                @unknown default:
                    break
                }
            }
        }

        func assemble() throws -> FragmentedVideo {
            try lock.withLock {
                guard let initialization, segments.count > 2 else {
                    throw FixtureError.segments("initialization \(initialization?.count ?? 0) bytes, \(segments.count) segments")
                }
                let timescale: CMTimeScale = 600
                let box = SegmentedVideoFrameCaptureTests.segmentIndexBox(
                    version: 0,
                    timescale: UInt32(timescale),
                    earliestPresentationTime: UInt64(segments[0].start.convertScale(timescale, method: .roundHalfAwayFromZero).value),
                    firstOffset: 0,
                    references: segments.map {
                        (size: $0.data.count, duration: Int($0.duration.convertScale(timescale, method: .roundHalfAwayFromZero).value))
                    }
                )
                var file = initialization
                file.append(box)
                for segment in segments {
                    file.append(segment.data)
                }
                let indexRange = initialization.count...(initialization.count + box.count - 1)
                let index = try SegmentedVideoFrameCapture.parseSegmentIndex(box, fileOffset: indexRange.lowerBound)
                return FragmentedVideo(
                    file: file,
                    initRange: 0...(initialization.count - 1),
                    indexRange: indexRange,
                    index: index
                )
            }
        }
    }
}

/// Serves registered files by byte range over a stub URLSession and records every range asked
/// for. `refusingFrom` answers 403 to any range starting at or past that byte, as googlevideo
/// does past a gated stream's first minute; `ignoringRange` answers 200 with the whole file.
private final class RangeServer: URLProtocol {
    private struct Route {
        let file: Data
        let refusingFrom: Int?
        let ignoringRange: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var requested: [String: [ClosedRange<Int>]] = [:]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        return URLSession(configuration: configuration)
    }()

    static func serve(_ file: Data, refusingFrom: Int? = nil, ignoringRange: Bool = false) -> URL {
        let url = URL(string: "https://segments.example.org/\(UUID().uuidString).mp4")!
        lock.withLock {
            routes[url.path] = Route(file: file, refusingFrom: refusingFrom, ignoringRange: ignoringRange)
        }
        return url
    }

    static func ranges(for url: URL) -> [ClosedRange<Int>] {
        lock.withLock { requested[url.path] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "segments.example.org"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let route = Self.lock.withLock({ Self.routes[url.path] }),
              let range = Self.range(from: request.value(forHTTPHeaderField: "Range")) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.requested[url.path, default: []].append(range) }

        let status: Int
        let body: Data
        var headers = ["Content-Type": "video/mp4"]
        if route.ignoringRange {
            status = 200
            body = route.file
        } else if let refusingFrom = route.refusingFrom, range.lowerBound >= refusingFrom {
            status = 403
            body = Data()
        } else if range.lowerBound >= route.file.count {
            status = 416
            body = Data()
        } else {
            let upper = min(range.upperBound, route.file.count - 1)
            status = 206
            body = route.file.subdata(in: range.lowerBound..<(upper + 1))
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(upper)/\(route.file.count)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func range(from header: String?) -> ClosedRange<Int>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
        return bounds[0]...bounds[1]
    }
}
