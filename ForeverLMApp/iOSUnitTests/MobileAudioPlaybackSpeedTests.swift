import AVFoundation
import Foundation
import XCTest
@testable import ForeverLM

/// The speed table behind the Listen tab's speed menu and the voice agent's
/// `set_speed` tool. Listening used to stop at 2×; these pin the wider range.
final class MobileAudioPlaybackSpeedTests: XCTestCase {
    func testPresetsReachBeyondDoubleSpeed() {
        let options = MobileAudioPlaybackSpeed.options
        XCTAssertEqual(options, options.sorted(), "The menu lists speeds slowest to fastest.")
        XCTAssertEqual(options.last, 3.0)
        XCTAssertTrue(options.contains(2.5))
        XCTAssertTrue(options.contains(1.0), "Normal speed stays available.")
        XCTAssertEqual(Set(options).count, options.count, "No preset repeats.")
    }

    func testClampCoversEveryPreset() {
        for option in MobileAudioPlaybackSpeed.options {
            XCTAssertEqual(MobileAudioPlaybackSpeed.clamped(option), option, "\(option)x is a preset and must survive clamping.")
        }
        XCTAssertEqual(MobileAudioPlaybackSpeed.clamped(10), MobileAudioPlaybackSpeed.maximum)
        XCTAssertEqual(MobileAudioPlaybackSpeed.clamped(0), MobileAudioPlaybackSpeed.minimum)
        XCTAssertEqual(MobileAudioPlaybackSpeed.maximum, MobileAudioPlaybackSpeed.options.last)
    }

    func testAgentRangeSpansThePresets() {
        let range = MobileAudioPlaybackSpeed.agentRange
        XCTAssertEqual(range.lowerBound, 0.75)
        XCTAssertEqual(range.upperBound, 3.0)
    }

    func testLabelsForFasterSpeeds() {
        XCTAssertEqual(MobileAudioPlaybackSpeed.label(for: 2.25), "2.25x")
        XCTAssertEqual(MobileAudioPlaybackSpeed.label(for: 2.5), "2.5x")
        XCTAssertEqual(MobileAudioPlaybackSpeed.label(for: 3.0), "3x")
        XCTAssertEqual(MobileAudioPlaybackSpeed.label(for: 4.0), "3x", "Out-of-range values read as the clamped speed.")
    }
}

/// What the car shows once voice mode has handed the audio to a source's
/// narration (`listen_to_source`): the narration while no conversation runs,
/// and the way back to the assistant when it ends.
final class CarPlayVoiceScreenTests: XCTestCase {
    private let listen = MobileVoiceListen(sourceID: "s9", title: "Mitochondria at Rest")

    func testTheConversationIsShownUnlessANarrationVoiceStartedIsPlaying() {
        XCTAssertEqual(CarPlayVoiceScreen.resolve(conversationIsIdle: true, listen: nil, isPlaying: false), .conversation)
        // A conversation that is running keeps the screen, whatever the player holds.
        XCTAssertEqual(CarPlayVoiceScreen.resolve(conversationIsIdle: false, listen: listen, isPlaying: true), .conversation)
        XCTAssertEqual(
            CarPlayVoiceScreen.resolve(conversationIsIdle: true, listen: listen, isPlaying: true),
            .narration(title: "Mitochondria at Rest", isPlaying: true)
        )
        XCTAssertEqual(
            CarPlayVoiceScreen.resolve(conversationIsIdle: true, listen: listen, isPlaying: false),
            .narration(title: "Mitochondria at Rest", isPlaying: false)
        )
    }

    func testANarrationThatEndedSendsTheLearnerBackToTheAssistant() {
        var finished = listen
        finished.ended = .finished
        XCTAssertEqual(
            CarPlayVoiceScreen.resolve(conversationIsIdle: true, listen: finished, isPlaying: false),
            .backToAssistant(.init(sourceID: "s9", title: "Mitochondria at Rest", outcome: .finished))
        )
        var failed = listen
        failed.ended = .failed("The voice does not read German.")
        XCTAssertEqual(
            CarPlayVoiceScreen.resolve(conversationIsIdle: true, listen: failed, isPlaying: false),
            .backToAssistant(.init(
                sourceID: "s9",
                title: "Mitochondria at Rest",
                outcome: .failed("The voice does not read German.")
            ))
        )
        // The assistant is already back: nothing to do twice.
        XCTAssertEqual(CarPlayVoiceScreen.resolve(conversationIsIdle: false, listen: finished, isPlaying: false), .conversation)
    }
}

/// Audio that replaces what is playing (a longer prefix of a narration still
/// being made, or the whole narration taking over from its opening) goes in
/// at the second the listener is at when it goes in. Listen once noted that
/// second before assembling the new audio, and put the listener back by as
/// long as the assembly took.
final class MobileAudioHandoverTests: XCTestCase {
    func testTheHandoverIsThePlayersOwnSecondNotTheLastTick() {
        // The last tick is from before the new audio was assembled.
        XCTAssertEqual(
            MobileAudioReviewViewModel.handoverSecond(playerSecond: 71.4, lastTick: 58, newDuration: 2_400),
            71.4
        )
    }

    func testTheHandoverStaysInsideTheNewAudio() {
        XCTAssertEqual(MobileAudioReviewViewModel.handoverSecond(playerSecond: 71.4, lastTick: 58, newDuration: 60), 60)
        XCTAssertEqual(MobileAudioReviewViewModel.handoverSecond(playerSecond: -1, lastTick: 58, newDuration: 60), 0)
    }

    func testWithNothingInThePlayerTheLastTickIsUsed() {
        XCTAssertEqual(MobileAudioReviewViewModel.handoverSecond(playerSecond: nil, lastTick: 58, newDuration: 2_400), 58)
        // An item that has not loaded reports no time.
        XCTAssertEqual(MobileAudioReviewViewModel.handoverSecond(playerSecond: .nan, lastTick: 58, newDuration: 2_400), 58)
    }
}

/// A longer narration takes over from the one that is sounding on a second
/// player started in step with the first, so the listener hears no break
/// (product owner, 2026-11-11: "Playback still has to be seamless").
@MainActor
final class MobileGaplessPlayerHandoverTests: XCTestCase {
    func testTheHandoverSecondIsTheLeadAheadAtTheListeningSpeed() {
        XCTAssertEqual(
            MobileGaplessPlayerHandover.handoverSecond(
                outgoingSecond: 10, lead: 0.4, rate: 2, outgoingDuration: 60, incomingDuration: 120
            ),
            10.8
        )
    }

    func testThereIsNoHandoverWhenTheOutgoingAudioIsAboutToEnd() {
        // 0.4 s of lead and 1.5 s to settle, both at 2x, do not fit in 3 s.
        XCTAssertNil(
            MobileGaplessPlayerHandover.handoverSecond(
                outgoingSecond: 57, lead: 0.4, rate: 2, outgoingDuration: 60, incomingDuration: 120
            )
        )
        XCTAssertNil(
            MobileGaplessPlayerHandover.handoverSecond(
                outgoingSecond: .nan, lead: 0.4, rate: 1, outgoingDuration: 60, incomingDuration: 120
            )
        )
    }

    func testTheIncomingPlayerTakesOverInStepAtNormalAndDoubleSpeed() async throws {
        let chunks = try Self.silentChunks(count: 6, seconds: 3)
        defer { try? FileManager.default.removeItem(at: chunks[0].deletingLastPathComponent()) }

        for rate: Float in [1, 2] {
            let outgoing = AVPlayer(playerItem: AVPlayerItem(asset: try await Self.composition(Array(chunks.prefix(3)))))
            outgoing.isMuted = true
            outgoing.playImmediately(atRate: rate)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let outgoingTimebase = try XCTUnwrap(outgoing.currentItem?.timebase)

            let longer = AVPlayerItem(asset: try await Self.composition(chunks))
            var adopted: AVPlayer?
            var apartAtHandover = Double.nan
            let handedOver = await MobileGaplessPlayerHandover.run(
                from: outgoing,
                to: longer,
                rate: rate,
                stillWanted: { true },
                adopt: { incoming in
                    adopted = incoming
                    // Both clocks, read while both players still run.
                    apartAtHandover = incoming.currentTime().seconds - CMTimebaseGetTime(outgoingTimebase).seconds
                }
            )

            XCTAssertTrue(handedOver, "at \(rate)x")
            let incoming = try XCTUnwrap(adopted)
            XCTAssertLessThan(abs(apartAtHandover), 0.03 * Double(rate), "at \(rate)x the players were \(apartAtHandover) s apart")
            XCTAssertEqual(incoming.rate, rate)
            XCTAssertTrue(incoming.currentItem === longer)
            XCTAssertNil(outgoing.currentItem, "The outgoing player is let go.")
            incoming.pause()
        }
    }

    func testAPausedPlayerIsLeftAsItIs() async throws {
        let chunks = try Self.silentChunks(count: 4, seconds: 3)
        defer { try? FileManager.default.removeItem(at: chunks[0].deletingLastPathComponent()) }
        let outgoing = AVPlayer(playerItem: AVPlayerItem(asset: try await Self.composition(Array(chunks.prefix(2)))))
        outgoing.isMuted = true
        let item = try XCTUnwrap(outgoing.currentItem)

        let handedOver = await MobileGaplessPlayerHandover.run(
            from: outgoing,
            to: AVPlayerItem(asset: try await Self.composition(chunks)),
            rate: 1,
            stillWanted: { true },
            adopt: { _ in XCTFail("Nothing takes over from a player that is not sounding.") }
        )

        XCTAssertFalse(handedOver)
        XCTAssertTrue(outgoing.currentItem === item)
    }

    func testAHandoverThatIsNoLongerWantedLeavesTheOutgoingPlayerPlaying() async throws {
        let chunks = try Self.silentChunks(count: 6, seconds: 3)
        defer { try? FileManager.default.removeItem(at: chunks[0].deletingLastPathComponent()) }
        let outgoing = AVPlayer(playerItem: AVPlayerItem(asset: try await Self.composition(Array(chunks.prefix(3)))))
        outgoing.isMuted = true
        outgoing.playImmediately(atRate: 1)
        try await Task.sleep(nanoseconds: 500_000_000)

        let handedOver = await MobileGaplessPlayerHandover.run(
            from: outgoing,
            to: AVPlayerItem(asset: try await Self.composition(chunks)),
            rate: 1,
            stillWanted: { false },
            adopt: { _ in XCTFail("The caller said no.") }
        )

        XCTAssertFalse(handedOver)
        XCTAssertEqual(outgoing.rate, 1)
        XCTAssertNotNil(outgoing.currentItem)
        outgoing.pause()
    }

    /// Silent 24 kHz mono WAV files, the shape narration chunks have.
    private static func silentChunks(count: Int, seconds: Double) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gapless-handover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sampleRate = 24_000
        let byteCount = Int(seconds * Double(sampleRate)) * 2
        var header = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(Data("RIFF".utf8)); append32(UInt32(36 + byteCount)); header.append(Data("WAVEfmt ".utf8))
        append32(16); append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2))
        append16(2); append16(16)
        header.append(Data("data".utf8)); append32(UInt32(byteCount))
        let file = header + Data(count: byteCount)
        return try (0..<count).map { index in
            let url = folder.appendingPathComponent("chunk-\(index).wav")
            try file.write(to: url)
            return url
        }
    }

    private static func composition(_ urls: [URL]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        )
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let source = try XCTUnwrap(tracks.first)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        return composition
    }
}
