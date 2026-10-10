import XCTest
@testable import ForeverLM

final class ReviewSessionTitleHeuristicsTests: XCTestCase {
    func testGenericInitialTitleIsAConstantRatherThanAClassifier() {
        XCTAssertEqual(ReviewSessionTitleHeuristics.genericSelectedSourcesTitle, "Selected sources")
    }
}
