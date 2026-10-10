import XCTest

/// macOS UI coverage for the current Studio shell.
///
/// Run from `ForeverLMApp/`:
/// ```
/// xcodebuild test \
///   -project ForeverLM.xcodeproj \
///   -scheme 'ForeverLM (macOS)' \
///   -destination 'platform=macOS' \
///   -only-testing:ForeverLMMacUITests/ForeverLMMacUITests \
///   -quiet
/// ```
@MainActor
final class ForeverLMMacUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()

        // A closed WindowGroup is valid restorable state on macOS. Command-N
        // asks this exact test application for its main Studio window.
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testAppLaunchesOnMac() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "Studio window should appear")
        XCTAssertTrue(app.buttons["New chat"].firstMatch.waitForExistence(timeout: 8))
    }

    func testStudioChromeShowsPrimarySurfaces() {
        XCTAssertTrue(app.buttons["New chat"].firstMatch.waitForExistence(timeout: 8))
        // The rail leads with the notebooks (shell stage 4): New chat,
        // Memory, Browser and Library, then the Notebooks header, which opens
        // the Space. Activity is reached from the Now chip; Courses and
        // Artifacts from the Space.
        XCTAssertTrue(app.buttons["studio.navigation.notebooks"].exists)
        XCTAssertTrue(app.buttons["studio.navigation.memory"].exists)
        XCTAssertTrue(app.buttons["studio.navigation.library"].exists)
        XCTAssertFalse(app.buttons["studio.navigation.activity"].exists)
        XCTAssertFalse(app.buttons["studio.navigation.courses"].exists)
        XCTAssertFalse(app.buttons["studio.navigation.artifacts"].exists)
        XCTAssertTrue(app.buttons[AccessibilityID.accountMenuButton].exists)
        XCTAssertTrue(app.buttons["Articles"].exists)
        XCTAssertTrue(app.buttons["Papers"].exists)
    }

    func testStudioWindowsKeepNavigationRailsIndependent() {
        let newChatButtons = app.buttons.matching(identifier: "New chat")
        XCTAssertTrue(newChatButtons.firstMatch.waitForExistence(timeout: 8))

        app.typeKey("n", modifierFlags: .command)
        let secondWindow = app.windows.element(boundBy: 1)
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 5))
        waitForCount(2, in: newChatButtons, message: "Both Studio windows should begin with a navigation rail")

        // Hide the rail in the key (new) window. The other window must keep its
        // own rail instead of observing the same app-wide preference binding.
        app.typeKey("s", modifierFlags: [.command, .control])
        waitForCount(1, in: newChatButtons, message: "Only the key window's navigation rail should close")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            newChatButtons.firstMatch.waitForExistence(timeout: 3),
            "Closing the compact window should reveal the original window with its rail intact"
        )
    }

    func testPinnedDocsSurviveSidebarNavigationAndWorkspaceCanBeSaved() {
        // Pages is not a rail row: a UI test run starts on the Notebooks home,
        // whose Space tab holds the pages, sites, pictures and Ideas; the
        // Space sidebar's Pages row lists the pages beside it.
        let docsTab = app.buttons["notebooks.home.tab.docs"]
        XCTAssertTrue(docsTab.waitForExistence(timeout: 8))
        docsTab.tap()
        let pagesRow = app.buttons["space.sidebar.pages"]
        XCTAssertTrue(pagesRow.waitForExistence(timeout: 8))
        pagesRow.tap()

        let docsLabels = app.staticTexts.matching(identifier: "Pages")
        waitForMinimumCount(
            1,
            in: docsLabels,
            message: "Pages should be visible in a center pane"
        )
        let docsPaneTitle = try? XCTUnwrap(
            docsLabels.allElementsBoundByAccessibilityElement.max { $0.frame.midX < $1.frame.midX }
        )
        let pinButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "studio.centerPane.",
            ".pin"
        ))
        waitForMinimumCount(1, in: pinButtons, message: "Every center pane should expose a pin")
        let docsPin = pinButtons.allElementsBoundByAccessibilityElement.min {
            abs($0.frame.midX - (docsPaneTitle?.frame.midX ?? 0))
                < abs($1.frame.midX - (docsPaneTitle?.frame.midX ?? 0))
        }
        XCTAssertNotNil(docsPin)
        guard let docsPin else { return }
        docsPin.tap()
        XCTAssertEqual(docsPin.value as? String, "Pinned")

        // The rail's Notebooks header opens the Space's All list beside the
        // pinned pane, never over it.
        let notebooks = app.buttons["studio.navigation.notebooks"]
        XCTAssertTrue(notebooks.waitForExistence(timeout: 5))
        notebooks.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["space.search"].waitForExistence(timeout: 5),
            "The Space should open"
        )
        waitForMinimumCount(
            1,
            in: docsLabels,
            message: "The pinned Pages pane should remain visible beside the Space"
        )
        XCTAssertEqual(docsPin.value as? String, "Pinned")

        // A named workspace is the whole app arrangement, not a per-window
        // preset. Add a second window before saving, then prove reopening the
        // workspace recreates it after that window has been closed.
        app.typeKey("n", modifierFlags: .command)
        let secondWindow = app.windows.element(boundBy: 1)
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 5))

        openViewWorkspacesMenu()

        let saveCurrent = app.menuItems["Save Current Workspace…"]
        XCTAssertTrue(saveCurrent.waitForExistence(timeout: 3))
        saveCurrent.tap()

        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("UI Test Pinned Docs")
        app.buttons["Save"].tap()

        app.typeKey("w", modifierFlags: .command)
        waitForCount(1, in: app.windows, message: "The second Studio window should close")

        openViewWorkspacesMenu()
        let savedWorkspace = app.menuItems["UI Test Pinned Docs"]
        XCTAssertTrue(savedWorkspace.waitForExistence(timeout: 3))
        savedWorkspace.tap()

        waitForCount(2, in: app.windows, message: "Restoring the workspace should recreate both Studio windows")
        waitForMinimumCount(
            1,
            in: app.buttons.matching(NSPredicate(format: "value == %@", "Pinned")),
            message: "The recreated workspace should retain its pinned Pages pane"
        )
    }

    /// Saved workspaces live under View ▸ Workspaces in the menu bar.
    private func openViewWorkspacesMenu() {
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let workspaces = viewMenu.menuItems["Workspaces"]
        XCTAssertTrue(workspaces.waitForExistence(timeout: 3))
        workspaces.hover()
    }

    func testIdleReaderCloseButtonAcceptsPhysicalClick() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        let closeReader = app.buttons["studio.reader.closePane"]
        XCTAssertTrue(closeReader.waitForExistence(timeout: 8))

        // `tap()` may invoke AXPress directly, which worked even when the
        // titlebar's AppKit drag blocker swallowed real pointer events. Click
        // the element's screen coordinate to cover the physical mouse path.
        closeReader
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()

        let closed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: closeReader
        )
        wait(for: [closed], timeout: 3)

        // The first close merges Reader into Chat and leaves a single center
        // pane. Reopen Reader there and prove its close action remains a real
        // pointer target instead of disappearing in the exact layout where a
        // full-width video otherwise becomes a dead end.
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(closeReader.waitForExistence(timeout: 3))
        closeReader
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()

        let closedFromSolePane = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: closeReader
        )
        wait(for: [closedFromSolePane], timeout: 3)
        XCTAssertTrue(app.buttons["New chat"].firstMatch.waitForExistence(timeout: 3))
    }

    func testWindowedReaderCloseTargetsItsOwnInactiveWindow() {
        let originalWindow = app.windows.firstMatch
        XCTAssertTrue(originalWindow.waitForExistence(timeout: 8))
        let originalClose = originalWindow.buttons["studio.reader.closePane"]
        XCTAssertTrue(originalClose.waitForExistence(timeout: 8))

        // A second window becomes key. The original titlebar control accepts
        // first mouse, so its action can arrive before AppKit changes the key
        // window; it must still close the pane it is drawn inside.
        app.typeKey("n", modifierFlags: .command)
        let secondWindow = app.windows.element(boundBy: 1)
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 5))
        let secondClose = secondWindow.buttons["studio.reader.closePane"]
        XCTAssertTrue(secondClose.waitForExistence(timeout: 5))

        originalClose
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()

        let originalClosed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: originalClose
        )
        wait(for: [originalClosed], timeout: 3)
        XCTAssertTrue(
            secondClose.exists,
            "Closing a background window's Reader must not mutate the key window"
        )
    }

    func testAccountMenuShowsSettingsAndSignOut() {
        let accountMenuButton = app.buttons[AccessibilityID.accountMenuButton]
        XCTAssertTrue(accountMenuButton.waitForExistence(timeout: 8))
        accountMenuButton.tap()

        XCTAssertTrue(app.buttons[AccessibilityID.settingsButton].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[AccessibilityID.signOutButton].exists)
    }

    func testSettingsWindowOpens() {
        let accountMenuButton = app.buttons[AccessibilityID.accountMenuButton]
        XCTAssertTrue(accountMenuButton.waitForExistence(timeout: 8))
        accountMenuButton.tap()

        let settingsButton = app.buttons[AccessibilityID.settingsButton]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3))
        settingsButton.tap()

        XCTAssertTrue(
            app.staticTexts["Settings"].waitForExistence(timeout: 5),
            "Settings content should appear"
        )
    }

    private func waitForCount(
        _ expectedCount: Int,
        in query: XCUIElementQuery,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", expectedCount),
            object: query
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            message
        )
    }

    private func waitForMinimumCount(
        _ expectedCount: Int,
        in query: XCUIElementQuery,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count >= %d", expectedCount),
            object: query
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            message
        )
    }
}
