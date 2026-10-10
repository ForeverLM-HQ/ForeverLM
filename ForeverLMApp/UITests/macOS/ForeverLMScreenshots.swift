import XCTest

/// Deterministic release screenshot capture for the current macOS Studio.
///
/// Run from `ForeverLMApp/`:
/// ```
/// xcodebuild test \
///   -project ForeverLM.xcodeproj \
///   -scheme 'ForeverLM (macOS)' \
///   -destination 'platform=macOS' \
///   -only-testing:ForeverLMMacUITests/ForeverLMScreenshots/test01_StudioView \
///   CODE_SIGN_STYLE=Automatic \
///   SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RECORDING_PRIVACY'
/// ```
@MainActor
final class ForeverLMScreenshots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()

        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func test01_StudioView() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60), "Main window should appear")

        let newChat = app.buttons["New chat"].firstMatch
        if newChat.waitForExistence(timeout: 10) {
            newChat.click()
            app.typeKey(.escape, modifierFlags: [])
        }

        Thread.sleep(forTimeInterval: 5.0)
        takeScreenshot(named: "01_studio")
    }

    private func takeScreenshot(named name: String) {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ForeverLM_Screenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent("\(name).png")
        if let tiffData = screenshot.image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: destination)
            print("[SCREENSHOT] Saved: \(destination.path)")
        }
    }
}
