import CloudKit
import Foundation
import XCTest
@testable import ForeverLM

/// These pin the wording that names the activity a failed iCloud read stopped.
final class MobileModelRouteErrorTests: XCTestCase {
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
