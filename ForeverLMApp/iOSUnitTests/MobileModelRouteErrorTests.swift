import CloudKit
import Foundation
import XCTest
@testable import ForeverLM

/// A reader on a weak connection who taps Listen used to get "iCloud could not
/// be reached, so this setting could not be checked" at once, with no retry and
/// no word about what did not start. These pin the one silent retry and the
/// wording that names the activity.
final class MobileModelRouteErrorTests: XCTestCase {
    func testTransientCloudKitFailuresAreRetriedOnce() {
        for code: CKError.Code in [.networkUnavailable, .networkFailure, .requestRateLimited, .serviceUnavailable, .zoneBusy, .accountTemporarilyUnavailable] {
            let delay = MobileModelRouteError.transientRetryDelay(for: CKError(code))
            XCTAssertNotNil(delay, "\(code) should be retried")
            XCTAssertEqual(delay, .seconds(2), "\(code) without a hint waits the default two seconds")
        }
    }

    func testNonTransientFailuresAreNotRetried() {
        XCTAssertNil(MobileModelRouteError.transientRetryDelay(for: CKError(.unknownItem)))
        XCTAssertNil(MobileModelRouteError.transientRetryDelay(for: CKError(.serverRecordChanged)))
        XCTAssertNil(MobileModelRouteError.transientRetryDelay(for: CKError(.permissionFailure)))
        XCTAssertNil(MobileModelRouteError.transientRetryDelay(for: CancellationError()))
        XCTAssertNil(MobileModelRouteError.transientRetryDelay(for: URLError(.notConnectedToInternet)))
    }

    func testRetryHonoursCloudKitsHintWithinBounds() {
        func throttled(after seconds: Double) -> CKError {
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: seconds)])
        }
        XCTAssertEqual(MobileModelRouteError.transientRetryDelay(for: throttled(after: 1.5)), .seconds(1.5))
        // "Retry after 14.7 seconds" must not hold a tap on Listen for a quarter of a minute.
        XCTAssertEqual(MobileModelRouteError.transientRetryDelay(for: throttled(after: 14.7)), .seconds(3))
        // And a zero hint does not retry straight back into the same outage.
        XCTAssertEqual(MobileModelRouteError.transientRetryDelay(for: throttled(after: 0)), .seconds(0.5))
    }

    func testUnreachableICloudNamesWhatDidNotStart() throws {
        let listen = MobileModelRouteError.from(CKError(.networkUnavailable), activity: AITask.paperTextToSpeechPreparation.mobileActivityName)
        let message = try XCTUnwrap(listen.errorDescription)
        XCTAssertTrue(message.hasPrefix("Listen could not start because iCloud could not be reached."), message)
        XCTAssertTrue(message.contains("tried twice"), message)
        XCTAssertTrue(message.contains("no request was sent"), message)
        XCTAssertFalse(message.contains("this setting"), message)

        let chat = MobileModelRouteError.from(CKError(.requestRateLimited), activity: AITask.chat.mobileActivityName)
        XCTAssertTrue(try XCTUnwrap(chat.errorDescription).hasPrefix("The chat could not start"))
    }

    func testBackgroundReadsKeepTheSettingsWording() throws {
        // A background pass resolving a route nobody tapped names no activity.
        XCTAssertNil(AITask.automaticAudioFiltering.mobileActivityName)
        let plain = MobileModelRouteError.from(CKError(.zoneBusy))
        let message = try XCTUnwrap(plain.errorDescription)
        XCTAssertTrue(message.hasPrefix("iCloud could not be reached, so this setting could not be checked."), message)
        XCTAssertFalse(message.contains("could not start"), message)
    }

    func testCallersStillMatchTheCaseWithoutItsPayload() {
        // The automatic-audio passes swallow this case by pattern; the payload
        // added for the wording must not break that match.
        let error: Error = MobileModelRouteError.from(CKError(.networkFailure), activity: "Listen")
        var matched = false
        if case .iCloudUnavailable? = error as? MobileModelRouteError { matched = true }
        XCTAssertTrue(matched)

        let other: Error = MobileModelRouteError.from(CKError(.permissionFailure))
        var matchedOther = false
        if case .iCloudUnavailable? = other as? MobileModelRouteError { matchedOther = true }
        XCTAssertFalse(matchedOther)
    }
}
