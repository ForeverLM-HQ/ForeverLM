import CloudKit
import Foundation
import XCTest
@testable import ForeverLM

/// The reader and chat screens log source activity from a SwiftUI `.task`, so a
/// dismissed screen used to cancel the CloudKit write and put "Operation … was
/// cancelled" in an error banner. These pin which failures stay silent.
final class MobileSourceActivityCancellationTests: XCTestCase {
    func testTaskCancellationIsSilent() {
        XCTAssertTrue(MobileAudioReviewViewModel.isCancelledCloudWrite(CancellationError()))
    }

    func testCloudKitCancelledOperationIsSilent() {
        XCTAssertTrue(MobileAudioReviewViewModel.isCancelledCloudWrite(CKError(.operationCancelled)))
        let bridged = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.operationCancelled.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Operation 741B1D8F116D28A4 was cancelled"]
        )
        XCTAssertTrue(MobileAudioReviewViewModel.isCancelledCloudWrite(bridged))
    }

    func testOtherFailuresStillReachTheBanner() {
        XCTAssertFalse(MobileAudioReviewViewModel.isCancelledCloudWrite(CKError(.networkUnavailable)))
        XCTAssertFalse(MobileAudioReviewViewModel.isCancelledCloudWrite(CKError(.serverRecordChanged)))
        XCTAssertFalse(MobileAudioReviewViewModel.isCancelledCloudWrite(URLError(.cancelled)))
        XCTAssertFalse(MobileAudioReviewViewModel.isCancelledCloudWrite(MobileCloudMutationError.conflict))
    }
}
