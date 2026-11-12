import Foundation
import XCTest
@testable import ForeverLM

/// Stopping a generation cancels its task, and the Listen button used to put
/// Swift's text for that ("The operation couldn’t be completed.
/// (Swift.CancellationError error 1.)") in the error banner. These pin which
/// endings of a generation stay silent.
final class MobileTextToSpeechStopTests: XCTestCase {
    func testTaskCancellationIsSilent() {
        XCTAssertTrue(MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(CancellationError()))
    }

    func testCancelledSpeechRequestIsSilent() {
        XCTAssertTrue(MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(URLError(.cancelled)))
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(bridged))
    }

    func testRealFailuresStillReachTheBanner() {
        XCTAssertFalse(MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(URLError(.notConnectedToInternet)))
        XCTAssertFalse(MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(URLError(.timedOut)))
        XCTAssertFalse(
            MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(CloudArticleTTS.GenerationError.missingAPIKey)
        )
        XCTAssertFalse(
            MobileAudioReviewViewModel.isCancelledTextToSpeechGeneration(MobileTextToSpeechPreparationError.sourceNotFound)
        )
    }

    func testTheListenersOwnStopSaysNothingWhateverTheErrorIs() {
        XCTAssertNil(
            MobileAudioReviewViewModel.textToSpeechFailureMessage(URLError(.timedOut), listenerStopped: true)
        )
        XCTAssertNil(
            MobileAudioReviewViewModel.textToSpeechFailureMessage(CancellationError(), listenerStopped: false)
        )
        XCTAssertEqual(
            MobileAudioReviewViewModel.textToSpeechFailureMessage(
                MobileTextToSpeechPreparationError.sourceNotFound,
                listenerStopped: false
            ),
            "That source is not available on this phone."
        )
    }
}
