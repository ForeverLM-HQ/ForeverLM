import Foundation
import XCTest
@testable import ForeverLM

/// The roomy screen's notebook as the Mac's three columns, and Home as its
/// gallery (`MobileNotebookColumnLayout`, docs/notebooks-design.md, "iPhone"):
/// the columns only in regular width and regular height with room for both
/// sides open at their narrowest and the chat at its own (an iPad, an iPhone
/// Duo's inner display, never decided by the device's idiom), the Mac's side
/// share within the bounds, the chat never short of its minimum, and the folds
/// kept on the device under one key per side.
final class MobileNotebookColumnLayoutTests: XCTestCase {
    private typealias Layout = MobileNotebookColumnLayout

    func testTheColumnsNeedBothSidesAndTheChatAtTheirNarrowest() {
        XCTAssertEqual(Layout.minimumWidth, 922)
        XCTAssertTrue(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: 922))
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: 921.5))
    }

    func testAnIPadInLandscapeOrA13InchInPortraitDrawsTheColumns() {
        // iPad mini, iPad and 11-inch iPads in landscape; 13-inch in both.
        for width: CGFloat in [1133, 1180, 1194, 1210, 1024, 1032, 1366, 1376] {
            XCTAssertTrue(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: width), "\(width)")
        }
        // The 11-inch iPads and the iPad mini in portrait keep the tab bar.
        for width: CGFloat in [744, 820, 834] {
            XCTAssertFalse(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: width), "\(width)")
        }
    }

    func testCompactWidthAndAPhoneHeldSidewaysKeepTheTabs() {
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: false, isRegularHeight: true, width: 1366))
        // A large phone in landscape is regular width but compact height: it
        // keeps its tabs, with no help from its idiom.
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: true, isRegularHeight: false, width: 956))
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: true, isRegularHeight: false, width: 1366))
    }

    func testAnIPhoneDuoDrawsTheColumnsOnlyOpenAndWide() {
        // Open, the inner display is regular both ways in either turn
        // (669 by 951 points by App Store Connect's screenshot size). Held
        // wide it has the room; held tall it keeps the tab bar, as an iPad
        // mini does.
        XCTAssertTrue(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: 951))
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: 669))
        // The panel's own pixel count over three, should Device Hub report
        // that instead: tall is still tabs.
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: 626))
        // Closed, the outer display (466 by 678) is compact width and regular
        // height held tall, compact both ways held wide.
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: false, isRegularHeight: true, width: 466))
        XCTAssertFalse(Layout.usesColumns(isRegularWidth: false, isRegularHeight: false, width: 678))
    }

    func testTheColumnsFollowWidthAndSizeClassesAlone() {
        // Folding the Duo while a notebook is open moves between the two on
        // the same inputs the iPad's window resize does.
        for width: CGFloat in stride(from: 300, through: 1400, by: 25) {
            let open = Layout.usesColumns(isRegularWidth: true, isRegularHeight: true, width: width)
            XCTAssertEqual(open, width >= Layout.minimumWidth, "\(width)")
            XCTAssertFalse(Layout.usesColumns(isRegularWidth: false, isRegularHeight: false, width: width), "\(width)")
        }
    }

    func testASideTakesTheMacsShareWithinItsBounds() {
        XCTAssertEqual(Layout.sideWidth(totalWidth: 1024), Layout.sideMinimumWidth)
        XCTAssertEqual(Layout.sideWidth(totalWidth: 1366), 1366 * 0.24, accuracy: 0.001)
        XCTAssertEqual(Layout.sideWidth(totalWidth: 2000), Layout.sideMaximumWidth)
    }

    func testAFoldedSideIsTheMacsStrip() {
        XCTAssertEqual(Layout.width(folded: true, totalWidth: 1366), 56)
        XCTAssertEqual(Layout.width(folded: false, totalWidth: 1366), Layout.sideWidth(totalWidth: 1366))
    }

    func testEachSideKeepsItsFoldUnderItsOwnLocalKey() {
        XCTAssertEqual(Layout.foldedDefaultsKey(.sources), "ios.notebooks.columns.sourcesFolded")
        XCTAssertEqual(Layout.foldedDefaultsKey(.studio), "ios.notebooks.columns.studioFolded")
        // The device's own namespace, beside the last notebook's key.
        XCTAssertTrue(Layout.foldedDefaultsKey(.sources).hasPrefix("ios.notebooks."))
        XCTAssertTrue(MobileNotebookResume.defaultsKey.hasPrefix("ios.notebooks."))
    }

    func testHomeIsAGalleryOnlyInRegularWidthAndHeight() {
        XCTAssertTrue(Layout.usesGallery(isRegularWidth: true, isRegularHeight: true))
        XCTAssertFalse(Layout.usesGallery(isRegularWidth: false, isRegularHeight: true))
        // A large phone in landscape keeps the list.
        XCTAssertFalse(Layout.usesGallery(isRegularWidth: true, isRegularHeight: false))
        XCTAssertFalse(Layout.usesGallery(isRegularWidth: false, isRegularHeight: false))
    }
}
