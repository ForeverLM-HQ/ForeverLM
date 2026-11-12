import AVFoundation
import Foundation

/// Reads frames out of a fragmented MP4 that can only be fetched by byte range: the adaptive
/// (DASH) streams that carry YouTube's 720p and 1080p video.
///
/// `AVURLAsset` cannot open one of these from its URL: it fails before reading a frame
/// (error -12190, measured). So this reads the file the way a DASH player does.
/// One request fetches the initialization segment (`ftyp` and `moov`) and the segment index
/// (`sidx`) that follows it. The index dates every media segment and gives its byte range,
/// so only the segments that hold a requested time are fetched. Each is decoded from a small
/// local file holding the initialization segment and that one segment. A five-second segment
/// of a 1080p talk is a few hundred kilobytes, so a 90-minute talk's slides cost tens of
/// megabytes, not the half-gigabyte file.
enum SegmentedVideoFrameCapture {

    /// A stream and the two byte ranges a player reads before any media. YouTube reports both
    /// with each adaptive format (`initRange`, `indexRange`).
    struct Source: Sendable {
        let url: URL
        let initRange: ClosedRange<Int>
        let indexRange: ClosedRange<Int>
        let headers: [String: String]
    }

    /// A stream's media segments in presentation order, read from its `sidx` box.
    struct SegmentIndex: Equatable, Sendable {
        struct Segment: Equatable, Sendable {
            let startSeconds: Double
            let durationSeconds: Double
            let byteRange: ClosedRange<Int>

            var endSeconds: Double { startSeconds + durationSeconds }
        }

        let segments: [Segment]

        /// The segment whose span holds `seconds`. A boundary belongs to the segment it
        /// starts; a time before the first segment or at or after the last one's end has none.
        func segmentIndex(containing seconds: Double) -> Int? {
            var low = 0
            var high = segments.count - 1
            while low <= high {
                let middle = (low + high) / 2
                let segment = segments[middle]
                if seconds < segment.startSeconds {
                    high = middle - 1
                } else if seconds >= segment.endSeconds {
                    low = middle + 1
                } else {
                    return middle
                }
            }
            return nil
        }
    }

    /// The times one segment is asked for, in the order they were requested.
    struct SegmentRequest: Equatable, Sendable {
        let segment: Int
        let timesSeconds: [Double]
    }

    enum IndexError: Error, Equatable {
        case truncated
        case notASegmentIndex(found: String)
        case unsupportedVersion(UInt8)
        /// A reference that points at another `sidx` rather than at media. YouTube's indexes
        /// are flat, so a hierarchical one is a different producer, not something to guess at.
        case nestedIndex
        case missingTimescale
        case malformed
    }

    enum FetchError: Error, Equatable {
        case notHTTP
        case status(Int)
        case length(expected: Int, received: Int)
    }

    /// What a capture produced, and why it stopped short when it did.
    struct Outcome {
        /// Frames keyed by `SlideFrameExtraction.frameTimeKey` of the time asked for.
        var images: [Int64: CGImage] = [:]
        var segmentsDecoded = 0
        var bytesFetched = 0
        /// The first thing that went wrong, for the log: a refused request, an index that
        /// would not parse, a segment that would not decode. Nil when every time was captured.
        var failure: String?
    }

    /// Segments fetched and decoded at once. Each is a few hundred kilobytes, so four keep
    /// the connection busy without holding many decoders.
    static let maxConcurrentSegments = 4
    /// The initialization segment and index together. YouTube's are about 13 KB for a
    /// 90-minute talk; anything far larger is not the layout this reads.
    static let maxHeadBytes = 4 << 20
    /// One media segment. A slide talk's 1080p segments run 0.2 to 1 MB.
    static let maxSegmentBytes = 64 << 20
    /// Rounding allowance between a requested time and the decoded frame's, on top of the
    /// generator's own tolerance.
    static let frameTimeSlackSeconds = 0.01

    // MARK: - Capture

    /// Captures a frame at each of `timesSeconds`, keyed by `SlideFrameExtraction.frameTimeKey`.
    ///
    /// A time the stream does not give is simply absent, for the caller's fallback. An HTTP
    /// 4xx on any request means the server has turned the stream away, so no further
    /// segments are requested; a transport error or a segment that will not decode costs
    /// only that segment's frames.
    static func captureFrames(
        from source: Source,
        timesSeconds: [Double],
        session: URLSession,
        toleranceSeconds: Double,
        maximumSize: CGSize
    ) async -> Outcome {
        var outcome = Outcome()
        guard !timesSeconds.isEmpty else { return outcome }

        let headRange = min(source.initRange.lowerBound, source.indexRange.lowerBound)
            ... max(source.initRange.upperBound, source.indexRange.upperBound)
        guard headRange.lowerBound >= 0, headRange.count <= maxHeadBytes else {
            outcome.failure = "initialization and index span \(headRange.count) bytes"
            return outcome
        }
        let head: Data
        do {
            head = try await fetch(headRange, of: source, session: session)
        } catch {
            outcome.failure = "initialization segment: \(describe(error))"
            return outcome
        }
        outcome.bytesFetched += head.count

        let initialization = head.subdata(in: slice(source.initRange, of: headRange))
        let index: SegmentIndex
        do {
            index = try parseSegmentIndex(
                head.subdata(in: slice(source.indexRange, of: headRange)),
                fileOffset: source.indexRange.lowerBound
            )
        } catch {
            outcome.failure = "segment index: \(error)"
            return outcome
        }

        let requests = segmentRequests(for: timesSeconds, in: index)
        guard !requests.isEmpty else {
            outcome.failure = "no requested time falls inside the stream's \(index.segments.count) segments"
            return outcome
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-segments-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            outcome.failure = "work directory: \(error.localizedDescription)"
            return outcome
        }
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        await withTaskGroup(of: SegmentResult.self) { group in
            var pending = requests[...]
            var refused = false

            func addNext() {
                guard !refused, let request = pending.popFirst() else { return }
                let segment = index.segments[request.segment]
                group.addTask {
                    await captureSegment(
                        request,
                        segment: segment,
                        initialization: initialization,
                        source: source,
                        session: session,
                        toleranceSeconds: toleranceSeconds,
                        maximumSize: maximumSize,
                        workDirectory: workDirectory
                    )
                }
            }

            for _ in 0..<maxConcurrentSegments {
                addNext()
            }
            while let result = await group.next() {
                switch result {
                case .decoded(let images, let bytes, let problem):
                    outcome.images.merge(images) { first, _ in first }
                    outcome.segmentsDecoded += 1
                    outcome.bytesFetched += bytes
                    if outcome.failure == nil { outcome.failure = problem }
                case .refused(let reason):
                    refused = true
                    outcome.failure = "the server refused a segment (\(reason)); no further segments were requested"
                case .failed(let reason):
                    if outcome.failure == nil { outcome.failure = reason }
                }
                addNext()
            }
        }
        return outcome
    }

    private enum SegmentResult: Sendable {
        case decoded(images: [Int64: CGImage], bytes: Int, problem: String?)
        /// The server turned the stream away; no later segment would answer either.
        case refused(String)
        /// This segment alone was lost.
        case failed(String)
    }

    private static func captureSegment(
        _ request: SegmentRequest,
        segment: SegmentIndex.Segment,
        initialization: Data,
        source: Source,
        session: URLSession,
        toleranceSeconds: Double,
        maximumSize: CGSize,
        workDirectory: URL
    ) async -> SegmentResult {
        guard segment.byteRange.count <= maxSegmentBytes else {
            return .failed("segment \(request.segment) is \(segment.byteRange.count) bytes")
        }
        let media: Data
        do {
            media = try await fetch(segment.byteRange, of: source, session: session)
        } catch FetchError.status(let status) where (400..<500).contains(status) {
            return .refused("HTTP \(status)")
        } catch {
            return .failed("segment \(request.segment): \(describe(error))")
        }

        let file = workDirectory.appendingPathComponent("segment-\(request.segment).mp4")
        do {
            try (initialization + media).write(to: file)
        } catch {
            return .failed("segment \(request.segment): \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: SlideFrameExtraction.frameTimescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = maximumSize

        var images: [Int64: CGImage] = [:]
        var problem: String?
        for seconds in request.timesSeconds {
            let local = localSeconds(seconds, in: segment)
            do {
                let frame = try await generator.image(
                    at: CMTime(seconds: local, preferredTimescale: SlideFrameExtraction.frameTimescale)
                )
                let actual = frame.actualTime.seconds
                guard isFrame(at: actual, closeEnoughTo: local, toleranceSeconds: toleranceSeconds) else {
                    // The local timeline is not where `localSeconds` says, so this frame shows
                    // some other moment. Storing it would put the wrong slide under a time.
                    problem = "segment \(request.segment) answered \(local)s with a frame at \(actual)s"
                    continue
                }
                images[SlideFrameExtraction.frameTimeKey(seconds)] = frame.image
            } catch {
                problem = "segment \(request.segment) at \(local)s: \(error.localizedDescription)"
            }
        }
        return .decoded(images: images, bytes: media.count, problem: problem)
    }

    // MARK: - Fetching

    /// Exactly `range` of the stream. The status is checked as soon as the headers arrive, so
    /// a server that ignores `Range` and starts sending the whole file is cut off there.
    static func fetch(_ range: ClosedRange<Int>, of source: Source, session: URLSession) async throws -> Data {
        var request = URLRequest(url: source.url)
        for (field, value) in source.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw FetchError.notHTTP
        }
        guard http.statusCode == 206 else {
            bytes.task.cancel()
            throw FetchError.status(http.statusCode)
        }
        var data = Data()
        data.reserveCapacity(range.count)
        for try await byte in bytes {
            data.append(byte)
            if data.count > range.count { break }
        }
        guard data.count == range.count else {
            bytes.task.cancel()
            throw FetchError.length(expected: range.count, received: data.count)
        }
        return data
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case FetchError.status(let status): return "HTTP \(status)"
        case FetchError.length(let expected, let received): return "expected \(expected) bytes, received \(received)"
        case FetchError.notHTTP: return "not an HTTP response"
        default: return error.localizedDescription
        }
    }

    /// Where `range` sits inside a fetched `span` of the file.
    private static func slice(_ range: ClosedRange<Int>, of span: ClosedRange<Int>) -> Range<Int> {
        (range.lowerBound - span.lowerBound)..<(range.upperBound - span.lowerBound + 1)
    }

    // MARK: - Index and timeline

    /// Reads the `sidx` box at the start of `data`, which sits at byte `fileOffset` of the
    /// stream (ISO/IEC 14496-12, 8.16.3).
    ///
    /// Each reference is one media segment: its size in bytes and its duration in the box's
    /// timescale. They lie end to end, in bytes from `first_offset` past the end of the box,
    /// and in time from `earliest_presentation_time`.
    static func parseSegmentIndex(_ data: Data, fileOffset: Int) throws -> SegmentIndex {
        var header = ByteReader(data)
        let declaredSize = try header.unsigned(4)
        let type = String(decoding: try header.bytes(4), as: UTF8.self)
        guard type == "sidx" else { throw IndexError.notASegmentIndex(found: type) }
        let boxSize: UInt64
        switch declaredSize {
        case 1: boxSize = try header.unsigned(8)
        case 0: throw IndexError.malformed  // "to the end of the file" cannot describe an index ahead of its media
        default: boxSize = declaredSize
        }
        guard boxSize <= UInt64(data.count) else { throw IndexError.truncated }

        var reader = ByteReader(data.prefix(Int(boxSize)))
        reader.position = header.position
        let version = UInt8(try reader.unsigned(1))
        _ = try reader.unsigned(3)  // flags
        guard version <= 1 else { throw IndexError.unsupportedVersion(version) }
        _ = try reader.unsigned(4)  // reference_ID
        let timescale = try reader.unsigned(4)
        guard timescale > 0 else { throw IndexError.missingTimescale }
        let fieldWidth = version == 0 ? 4 : 8
        let earliestPresentationTime = try reader.unsigned(fieldWidth)
        let firstOffset = try reader.unsigned(fieldWidth)
        _ = try reader.unsigned(2)  // reserved
        let referenceCount = Int(try reader.unsigned(2))
        guard referenceCount > 0, firstOffset <= UInt64(Int32.max), fileOffset >= 0 else {
            throw IndexError.malformed
        }

        var segments: [SegmentIndex.Segment] = []
        segments.reserveCapacity(referenceCount)
        var time = earliestPresentationTime
        var offset = fileOffset + Int(boxSize) + Int(firstOffset)
        for _ in 0..<referenceCount {
            let reference = try reader.unsigned(4)
            let duration = try reader.unsigned(4)
            _ = try reader.unsigned(4)  // starts_with_SAP, SAP_type, SAP_delta_time
            guard reference & 0x8000_0000 == 0 else { throw IndexError.nestedIndex }
            let size = Int(reference & 0x7FFF_FFFF)
            guard size > 0, duration > 0 else { throw IndexError.malformed }
            segments.append(SegmentIndex.Segment(
                startSeconds: Double(time) / Double(timescale),
                durationSeconds: Double(duration) / Double(timescale),
                byteRange: offset...(offset + size - 1)
            ))
            time += duration
            offset += size
        }
        return SegmentIndex(segments: segments)
    }

    /// The requested times grouped by the segment that holds them, in file order. A repeated
    /// time is asked for once; a time no segment holds is left out for the caller's fallback.
    static func segmentRequests(for timesSeconds: [Double], in index: SegmentIndex) -> [SegmentRequest] {
        var seenKeys = Set<Int64>()
        var timesBySegment: [Int: [Double]] = [:]
        for seconds in timesSeconds {
            guard seenKeys.insert(SlideFrameExtraction.frameTimeKey(seconds)).inserted,
                  let segment = index.segmentIndex(containing: seconds) else { continue }
            timesBySegment[segment, default: []].append(seconds)
        }
        return timesBySegment.keys.sorted().map {
            SegmentRequest(segment: $0, timesSeconds: timesBySegment[$0] ?? [])
        }
    }

    /// Where `seconds` falls in a file holding only `segment`.
    ///
    /// Such a file's timeline starts at the segment's first frame: AVFoundation lays a lone
    /// fragment's samples from zero rather than from its `tfdt` decode time, and the
    /// initialization segment's edit list absorbs the composition offset (measured on
    /// YouTube's H.264 streams). `isFrame(at:closeEnoughTo:toleranceSeconds:)`
    /// rejects the frame if that ever stops holding.
    static func localSeconds(_ seconds: Double, in segment: SegmentIndex.Segment) -> Double {
        min(max(0, seconds - segment.startSeconds), segment.durationSeconds)
    }

    /// Whether a decoded frame is the one asked for: a generator honouring its tolerance
    /// never answers further away than that, so a frame further off means the timeline was
    /// not where it was expected.
    static func isFrame(at actualSeconds: Double, closeEnoughTo requestedSeconds: Double, toleranceSeconds: Double) -> Bool {
        abs(actualSeconds - requestedSeconds) <= toleranceSeconds + frameTimeSlackSeconds
    }

    /// Big-endian reads over box bytes, failing on a short box rather than trapping.
    private struct ByteReader {
        let data: Data
        var position: Int

        init(_ data: Data) {
            self.data = data
            self.position = data.startIndex
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - position >= count else { throw IndexError.truncated }
            defer { position += count }
            return data[position..<(position + count)]
        }

        mutating func unsigned(_ width: Int) throws -> UInt64 {
            try bytes(width).reduce(0) { $0 << 8 | UInt64($1) }
        }
    }
}
