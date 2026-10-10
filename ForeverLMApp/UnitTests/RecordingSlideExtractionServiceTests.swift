import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import ForeverLM

/// Slide extraction from a recording file, the path a Google Drive or local-folder meeting
/// takes. The end-to-end case writes a real H.264 file and reads it back, because everything
/// this service adds over the shared core is AVFoundation behaviour — sampling a grid,
/// decoding at two resolutions, and dating what it finds — which no amount of pure-function
/// testing exercises.
@Suite("Recording Slide Extraction")
struct RecordingSlideExtractionServiceTests {

    // MARK: - Scan grid

    @Test("Samples a short recording at the base interval")
    func usesBaseIntervalForShortRecording() {
        #expect(RecordingSlideExtractionService.scanInterval(forDurationSeconds: 600) == 4)
        #expect(RecordingSlideExtractionService.scanInterval(forDurationSeconds: 3_600) == 4)
    }

    /// The budget, not the base interval, is what bounds decode cost. A three-hour recording
    /// sampled every four seconds would be 2,700 decodes.
    @Test("Stretches the interval past the sample budget")
    func stretchesIntervalForLongRecording() {
        let interval = RecordingSlideExtractionService.scanInterval(forDurationSeconds: 10_800)

        #expect(interval == 12)
        #expect(RecordingSlideExtractionService.scanTimes(
            durationSeconds: 10_800, interval: interval
        ).count == 900)
    }

    @Test("Lays the scan grid inside the recording")
    func laysScanGridInsideRecording() {
        let times = RecordingSlideExtractionService.scanTimes(durationSeconds: 30, interval: 4)

        #expect(times == [0, 4, 8, 12, 16, 20, 24])
        #expect(times.allSatisfy { $0 < 30 })
    }

    /// The grid's times are the lookup keys the generator's results come back under, so a
    /// time that does not round-trip through `frameTimeKey` silently loses its frame.
    @Test("Grid times round-trip through the frame key")
    func gridTimesRoundTripThroughFrameKey() {
        let interval = RecordingSlideExtractionService.scanInterval(forDurationSeconds: 5_000)
        let times = RecordingSlideExtractionService.scanTimes(durationSeconds: 5_000, interval: interval)

        let keys = Set(times.map(SlideFrameExtraction.frameTimeKey))

        #expect(keys.count == times.count)
    }

    @Test("Refuses a zero-length recording")
    func refusesZeroLengthRecording() {
        #expect(RecordingSlideExtractionService.scanTimes(durationSeconds: 0, interval: 4).isEmpty)
        #expect(RecordingSlideExtractionService.scanTimes(durationSeconds: 30, interval: 0).isEmpty)
    }

    // MARK: - End to end

    @Test("Extracts one frame per slide from a recording file")
    func extractsSlidesFromRecordingFile() async throws {
        let patterns = (0..<3).map(Self.slidePattern(index:))
        // If the drawn pages do not separate, nothing downstream can: assert the premise
        // before blaming the decoder for a merged run.
        let hashes = patterns.compactMap(SlideFrameExtraction.perceptualHash)
        try #require(hashes.count == 3)
        #expect(hashes[0].distance(to: hashes[1]) > SlideFrameExtraction.transitionDistance)
        #expect(hashes[1].distance(to: hashes[2]) > SlideFrameExtraction.transitionDistance)

        let recordingURL = try await Self.writeRecording(pages: patterns, secondsPerPage: 12)
        defer { try? FileManager.default.removeItem(at: recordingURL) }

        let sourceID = "test_recording_slides_\(UUID().uuidString)"
        defer {
            if let directory = try? SlideFrameExtraction.prepareOutputDirectory(sourceID: sourceID) {
                try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
            }
        }

        let frames = try await RecordingSlideExtractionService.shared.extractSlides(
            from: recordingURL,
            sourceID: sourceID,
            videoTitle: "Synthetic deck"
        )

        #expect(frames.count == 3)
        #expect(frames.map(\.index) == [1, 2, 3])
        // Each page holds for twelve seconds, so the representative frames land inside
        // successive thirds of the recording rather than bunching at the start.
        let times = frames.compactMap(\.timeSeconds)
        #expect(times.count == 3)
        #expect(times == times.sorted())
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 8 })

        for frame in frames {
            let path = StorageService.locateSourceFile(frame.localImagePath)
            #expect(path != nil, "slide \(frame.index) was recorded but not written")
            #expect(frame.windows.count == 1)
        }
    }

    @Test("Reports an audio-only recording as having no slides")
    func reportsAudioOnlyRecording() async throws {
        let url = try await Self.writeSilentAudio(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: SlideExtractionError.recordingHasNoVideo) {
            try await RecordingSlideExtractionService.shared.extractSlides(
                from: url,
                sourceID: "test_audio_only",
                videoTitle: "Audio only"
            )
        }
    }

    @Test("Reports a file that is not media at all")
    func reportsUnreadableRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: SlideExtractionError.unreadableRecording) {
            try await RecordingSlideExtractionService.shared.extractSlides(
                from: url,
                sourceID: "test_unreadable",
                videoTitle: "Broken"
            )
        }
    }

    // MARK: - Fixtures

    private static let frameSize = CGSize(width: 640, height: 360)

    /// A page with enough structure to hash apart from its neighbours. A flat colour would
    /// not: every cell of a dHash equals the one beside it, so three solid slides all hash
    /// to zero and read as one unbroken run. Nor does a moved bar — two pages sharing most
    /// of their layout landed 28 bits apart, under the 32 that means "the picture changed".
    /// A per-page cell pattern on the hash's own grid separates them by roughly half the
    /// signature, which is the margin a real deck's pages have.
    private static func slidePattern(index: Int) -> CGImage {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let grid = SlideFrameExtraction.hashGridSize
        let cellWidth = width / grid
        let cellHeight = height / grid
        for row in 0..<grid {
            for column in 0..<grid {
                guard Self.patternBit(index: index, row: row, column: column) else { continue }
                context.fill(CGRect(
                    x: column * cellWidth,
                    y: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                ))
            }
        }
        return context.makeImage()!
    }

    /// Deterministic per-cell coin flip, so a page is reproducible across runs but shares no
    /// structure with the pages either side of it.
    private static func patternBit(index: Int, row: Int, column: Int) -> Bool {
        var value = UInt64(bitPattern: Int64(index &* 0x9E37_79B9))
        value = value &+ UInt64(bitPattern: Int64(row &* 0x85EB_CA6B))
        value = value &+ UInt64(bitPattern: Int64(column &* 0xC2B2_AE35))
        value ^= value >> 15
        value = value &* 0x2545_F491_4F6C_DD1D
        value ^= value >> 27
        return value & 1 == 1
    }

    /// Writes the pages out as a real H.264 file, each held for `secondsPerPage`.
    private static func writeRecording(pages: [CGImage], secondsPerPage: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
            AVVideoCompressionPropertiesKey: [
                // Flat graphics at a generous bitrate stay near-lossless, so the decoded
                // frame hashes like the one that was drawn.
                AVVideoAverageBitRateKey: 4_000_000,
                // A keyframe every second, which is what lets the extractor's one-second
                // seek slack land without decoding forward through the whole page.
                AVVideoMaxKeyFrameIntervalKey: 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(frameSize.width),
                kCVPixelBufferHeightKey as String: Int(frameSize.height),
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Two frames a second is plenty: nothing here reads motion, and every extra frame
        // is encoder time in a test that has to stay cheap.
        let framesPerSecond: Int32 = 2
        var frameIndex: Int64 = 0
        for page in pages {
            let buffer = try pixelBuffer(from: page, pool: adaptor.pixelBufferPool)
            for _ in 0..<(secondsPerPage * Int(framesPerSecond)) {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: frameIndex, timescale: framesPerSecond)
                )
                frameIndex += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? SlideExtractionError.unreadableRecording
        }
        return url
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        guard let buffer else { throw SlideExtractionError.unreadableRecording }
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
        ) else {
            throw SlideExtractionError.unreadableRecording
        }
        context.draw(image, in: CGRect(origin: .zero, size: frameSize))
        return buffer
    }

    /// A recording with sound and no picture — an ordinary shape for a meeting to be
    /// exported in, and the case that must say so instead of reporting no slides found.
    private static func writeSilentAudio(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let sampleRate = 44_100
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var description: CMAudioFormatDescription?
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        let frameCount = sampleRate * seconds
        var samples = [Int16](repeating: 0, count: frameCount)
        var blockBuffer: CMBlockBuffer?
        try samples.withUnsafeMutableBytes { raw in
            let status = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: raw.baseAddress,
                blockLength: raw.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: raw.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { throw SlideExtractionError.unreadableRecording }
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: blockBuffer!,
            formatDescription: description!,
            sampleCount: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { throw SlideExtractionError.unreadableRecording }
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        input.append(sampleBuffer)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? SlideExtractionError.unreadableRecording
        }
        return url
    }
}
