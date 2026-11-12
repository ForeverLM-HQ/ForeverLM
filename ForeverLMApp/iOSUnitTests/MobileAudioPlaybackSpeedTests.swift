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
