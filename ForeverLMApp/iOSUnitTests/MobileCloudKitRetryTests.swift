import CloudKit
import Foundation
import XCTest
@testable import ForeverLM

/// The phone calls CloudKit directly, with no sync engine to retry for it, and
/// "Highlights could not be loaded … (CKErrorDomain error 4.)" was one dropped
/// connection reaching the learner. These pin which failures are retried, how
/// long each wait is, and what is said once the retries are spent.
final class MobileCloudKitRetryTests: XCTestCase {
    func testTransientFailuresAreRetriedAndPermanentOnesAreNot() {
        for code: CKError.Code in [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost, .accountTemporarilyUnavailable] {
            XCTAssertTrue(MobileCloudKitRetry.isTransient(CKError(code)), "\(code) should be retried")
        }
        // A conflict, an expired token and a missing record each have their own
        // handling upstream; repeating the call would only hide it.
        for code: CKError.Code in [.serverRecordChanged, .changeTokenExpired, .unknownItem, .permissionFailure, .quotaExceeded, .notAuthenticated] {
            XCTAssertFalse(MobileCloudKitRetry.isTransient(CKError(code)), "\(code) must not be retried")
        }
        XCTAssertFalse(MobileCloudKitRetry.isTransient(CancellationError()))
        XCTAssertFalse(MobileCloudKitRetry.isTransient(URLError(.timedOut)))
    }

    func testPartialFailureIsTransientOnlyWhenEveryItemIs() {
        let first = CKRecord.ID(recordName: "first")
        let second = CKRecord.ID(recordName: "second")
        let allTransient = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [first: CKError(.networkFailure), second: CKError(.zoneBusy)],
        ])
        XCTAssertTrue(MobileCloudKitRetry.isTransient(allTransient))
        let mixed = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [first: CKError(.networkFailure), second: CKError(.permissionFailure)],
        ])
        XCTAssertFalse(MobileCloudKitRetry.isTransient(mixed))
    }

    func testWaitsDoubleAndHonourCloudKitsHintWithinBounds() {
        XCTAssertEqual(MobileCloudKitRetry.delay(after: CKError(.networkFailure), attempt: 1), .seconds(1))
        XCTAssertEqual(MobileCloudKitRetry.delay(after: CKError(.networkFailure), attempt: 2), .seconds(2))
        XCTAssertEqual(MobileCloudKitRetry.delay(after: CKError(.networkFailure), attempt: 3), .seconds(4))
        func throttled(after seconds: Double) -> CKError {
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: seconds)])
        }
        XCTAssertEqual(MobileCloudKitRetry.delay(after: throttled(after: 14.7), attempt: 1), .milliseconds(14_700))
        XCTAssertEqual(MobileCloudKitRetry.delay(after: throttled(after: 120), attempt: 1), .seconds(30))
        XCTAssertEqual(MobileCloudKitRetry.delay(after: throttled(after: 0), attempt: 1), .milliseconds(500))
        XCTAssertNil(MobileCloudKitRetry.delay(after: CKError(.unknownItem), attempt: 1))
    }

    func testRunRepeatsATransientFailureUntilItSucceeds() async throws {
        let calls = CallCounter()
        let value = try await MobileCloudKitRetry.run("test", attempts: 3) {
            let call = await calls.next()
            // A zero retry-after hint keeps the wait at the half-second floor.
            if call == 1 { throw CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 0)]) }
            return "fetched on call \(call)"
        }
        XCTAssertEqual(value, "fetched on call 2")
    }

    func testRunThrowsAPermanentFailureAtOnceWithItsOwnCode() async {
        let calls = CallCounter()
        do {
            _ = try await MobileCloudKitRetry.run("test") {
                _ = await calls.next()
                throw CKError(.serverRecordChanged)
            }
            XCTFail("a conflict must reach the caller")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .serverRecordChanged)
        }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testRunStopsAfterItsAttemptsAndThrowsTheLastError() async {
        let calls = CallCounter()
        do {
            _ = try await MobileCloudKitRetry.run("test", attempts: 2) {
                _ = await calls.next()
                throw CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 0)])
            }
            XCTFail("a failure that outlasts the retries must reach the caller")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .zoneBusy)
        }
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testSpentRetriesAreDescribedInPlainWords() {
        XCTAssertEqual(
            MobileCloudKitRetry.describe(CKError(.networkFailure)),
            "iCloud could not be reached. Check the connection and try again in a moment."
        )
        XCTAssertEqual(
            MobileCloudKitRetry.describe(CKError(.requestRateLimited)),
            "iCloud is busy right now. Try again in a moment."
        )
        XCTAssertFalse(MobileCloudKitRetry.describe(CKError(.networkFailure)).contains("CKErrorDomain"))
        // A permanent failure keeps the description that names it.
        let permanent = CKError(.permissionFailure)
        XCTAssertEqual(MobileCloudKitRetry.describe(permanent), permanent.localizedDescription)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
