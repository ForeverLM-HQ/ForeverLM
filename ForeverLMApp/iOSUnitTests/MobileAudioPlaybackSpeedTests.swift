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
