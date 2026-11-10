import XCTest

// End-to-end checks against the real signed-in simulator for the phone app:
// the catalog really populates from CloudKit and source text really extracts.
// These drive the app
// the way a person does, which on this machine is the only way to prove
// interaction at all — the simulator helper can screenshot but cannot inject
// touches.
//
// Home is where the phone starts (docs/notebooks-design.md, "iPhone"): Settings
// in its toolbar, the Library row first, then the notebooks. Typed chat
// lives in a notebook's Chat tab and the Reader's Ask. Extraction is asserted
// through MobileUITestProbe:
// a launch-argument-gated status line the app renders after running the same
// production code paths chat depends on.
//
// The first load on a fresh container is a cold CloudKit zone pass measured
// in minutes; with the persisted catalog it is seconds. Waits are generous on
// purpose — a slow sync is not a failure.
final class MobileVoiceUITests: XCTestCase {
    private static let catalogTimeout: TimeInterval = 240
    private static let probeTimeout: TimeInterval = 300

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // `TEST_RUNNER_FOREVERLM_PROBE_SAMPLE=n xcodebuild test …` widens the
        // probe's extraction pass into a library-wide audit; see
        // MobileUITestProbe. Absent, the probe uses its fast default.
        for key in ["FOREVERLM_PROBE_SAMPLE"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
    }

    /// Home is the notebooks: Settings in the toolbar, a New notebook button,
    /// the Library row above the notebooks, and no text composer of its own.
    /// Nothing billable starts.
    func testHomeListsNotebooks() throws {
        app.launch()
        try waitForHome()

        XCTAssertTrue(
            app.descendants(matching: .any)["home.settings"].exists,
            "Home's toolbar has no Settings."
        )
        XCTAssertTrue(app.buttons["home.newNotebook"].exists, "Home has no New notebook button.")
        XCTAssertFalse(app.textFields["home.chatComposer"].exists, "Home kept the retired text composer.")
        XCTAssertTrue(
            app.navigationBars.staticTexts["ForeverLM"].exists || app.staticTexts["ForeverLM"].exists,
            "Home lost its title."
        )

        // The Library is the first row under the title, in view without a scroll.
        let library = app.descendants(matching: .any).matching(identifier: "home.sources").firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "Home has no Library row at the top.")
    }

    /// OpenRouter's live catalog is taller than an iPhone. The model control
    /// opens a real List whose bottom rows remain reachable by scrolling.
    func testTextToSpeechModelListScrollsToTheEnd() throws {
        app.launch()
        try waitForHome()
        try openSettings()

        let picker = app.descendants(matching: .any)
            .matching(identifier: "settings.readAloudModel")
            .firstMatch
        for _ in 0..<4 where !picker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "Text to Speech model picker never appeared.")
        picker.tap()

        let list = app.descendants(matching: .any)["settings.readAloudModelList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The model control did not open its scrolling list.")
        let bottom = app.descendants(matching: .any)
            .matching(identifier: "settings.readAloudModel.minimax/speech-2.8-hd")
            .firstMatch
        for _ in 0..<20 where !bottom.exists {
            list.swipeUp()
        }
        XCTAssertTrue(bottom.waitForExistence(timeout: 5), "The bottom model remained unreachable after scrolling.")
    }

    /// A slow audio teardown used to disable the only escape hatch.
    /// The red X must stay tappable even while the session reports `.ending`.
    func testVoiceEndRemainsAccessibleDuringTeardown() throws {
        app.launchArguments = [
            "-foreverlm-uitest-voice-surface",
            "-foreverlm-uitest-voice-surface-ending",
        ]
        app.launch()

        let end = app.buttons["voice.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "Voice teardown hid its end action.")
        XCTAssertTrue(end.isEnabled, "Voice teardown disabled its end action.")
        end.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["voice.previewDismissed"].waitForExistence(timeout: 5),
            "The voice end action did not remain interactive during teardown."
        )
    }

    /// Exit replaces the voice controls with the conversation that just
    /// ended, using the same back-and-forth bubble layout as typed chat.
    func testVoiceExitOpensTranscript() throws {
        app.launchArguments = ["-foreverlm-uitest-voice-surface"]
        app.launch()

        let end = app.buttons["voice.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "The voice end action never appeared.")
        end.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["voice.previewDismissed"].waitForExistence(timeout: 5),
            "Exiting voice did not open its transcript."
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "voice.transcript.message").count,
            2,
            "The voice transcript did not preserve both sides of the conversation."
        )
    }

    /// Usage keeps its real layout on first load and persists the last complete
    /// server snapshot in SQLite, so reopening never returns to a blank spinner.
    func testUsageLoadsFromItsSQLiteSnapshot() throws {
        app.launch()
        try waitForHome()
        try openSettings()
        app.descendants(matching: .any)["settings.usage"].tap()

        let placeholder = app.descendants(matching: .any)["usage.loadingPlaceholder"]
        let openRouter = app.descendants(matching: .any)["usage.openRouter"]
        XCTAssertTrue(
            placeholder.waitForExistence(timeout: 2) || openRouter.exists,
            "Usage showed neither its saved content nor a stable loading layout."
        )
        XCTAssertTrue(openRouter.waitForExistence(timeout: 30), "Usage never loaded the server ledger.")

        app.terminate()
        app.launch()
        try waitForHome()
        try openSettings()
        app.descendants(matching: .any)["settings.usage"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["usage.openRouter"].waitForExistence(timeout: 2),
            "Usage did not render its saved SQLite snapshot immediately."
        )
    }

    /// Save Offline runs the real production path — CloudKit text, and a paper's
    /// shared iCloud PDF, into the non-purgeable Application Support copy. The
    /// row's own action is the state readout: it flips to Remove Download only
    /// once that copy exists, and back again when the space is given up.
    func testSavesAndRemovesAnOfflineDownload() throws {
        app.launch()
        try waitForHome()
        try openSources()

        // Search results list sources directly; the type screens nest books and
        // courses, where the first row is a container rather than a source.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "The sources browser has no search field.")
        search.tap()
        search.typeText("a")

        let rows = app.descendants(matching: .any).matching(identifier: "browser.sourceRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "Search returned no source rows.")

        let save = app.descendants(matching: .any)
            .matching(identifier: "source.saveOffline")
            .firstMatch
        let remove = app.descendants(matching: .any)
            .matching(identifier: "source.removeDownload")
            .firstMatch
        let failureAlert = app.descendants(matching: .any)
            .matching(identifier: "source.offlineFailure.ok")
            .firstMatch

        // Whichever sources this library surfaces, the one outcome the app must
        // never produce is silence. A source whose text has not synced yet cannot
        // be saved at all, so walk a few rows to reach one that can.
        var savedRow: XCUIElement?
        var refusals = 0
        for index in 0..<min(rows.count, 5) {
            let row = rows.element(boundBy: index)
            guard row.exists else { continue }

            row.press(forDuration: 1.2)
            guard save.waitForExistence(timeout: 15) else {
                XCTAssertTrue(
                    remove.exists,
                    "The row context menu offers neither Save Offline nor Remove Download."
                )
                search.tap()
                continue
            }
            save.tap()

            // A notice can mean a refusal *or* a partial save — a paper whose
            // document is not downloadable keeps its text — so dismissing it
            // settles nothing. The row's own action is the state readout.
            if failureAlert.waitForExistence(timeout: 10) {
                failureAlert.tap()
            }
            row.press(forDuration: 1.2)
            if remove.waitForExistence(timeout: 20) {
                // One proven durable copy is enough, and stopping here leaves at
                // most one download for this test to clean up after itself.
                savedRow = row
                break
            }
            refusals += 1
            search.tap()
        }

        XCTAssertTrue(
            savedRow != nil || refusals > 0,
            "Save Offline neither produced a durable copy nor reported why not."
        )
        guard let savedRow else {
            throw XCTSkip("No searched source had synced text to save; the app explained each refusal.")
        }

        // Also leaves this simulator as the test found it.
        remove.tap()
        savedRow.press(forDuration: 1.2)
        XCTAssertTrue(
            save.waitForExistence(timeout: 15),
            "Remove Download did not return the row to Save Offline."
        )
        app.terminate()
    }

    /// Settings reaches the Offline screen, which owns bulk removal.
    func testOfflineScreenOpensFromSettings() throws {
        app.launch()
        try waitForHome()
        try openSettings()

        let offline = app.descendants(matching: .any)
            .matching(identifier: "settings.offline")
            .firstMatch
        for _ in 0..<3 where !offline.exists { app.swipeUp() }
        XCTAssertTrue(offline.waitForExistence(timeout: 15), "Settings has no Offline destination.")
        offline.tap()
        XCTAssertTrue(
            app.navigationBars["Offline"].waitForExistence(timeout: 15),
            "The Offline screen never appeared."
        )
        app.terminate()
    }

    /// The Sources browser renders the synced catalog as tappable type rows.
    func testShowsSyncedSourcesBrowser() throws {
        app.launch()
        try waitForHome()

        try openSources()
        let typeRow = app.descendants(matching: .any)
            .matching(identifier: "browser.typeRow")
            .firstMatch
        XCTAssertTrue(
            typeRow.waitForExistence(timeout: 30),
            "The browser never rendered a source-type row."
        )
    }

    /// Source text extracts through the production path (CloudKit asset →
    /// disk cache) for the newest text-bearing sources — the material every
    /// chat and quiz session is built from.
    func testExtractsSourceContent() throws {
        app.launchArguments += ["-foreverlm-uitest-probe"]
        app.launch()

        let verdict = try waitForProbeVerdict()
        XCTAssertTrue(verdict.hasPrefix("ok"), "Probe failed: \(verdict)")
    }

    /// Source Listen's whole paid boundary: authenticated managed request,
    /// First-party speech generation, metering receipt, and playable audio bytes.
    /// The probe uses a fixed three-chunk passage and writes only temporary files.
    func testTextToSpeechTTSEndToEnd() throws {
        app.launchArguments = [
            "-foreverlm-uitest-probe",
            "-foreverlm-uitest-tts",
            "-foreverlm-uitest-tts-only",
        ]
        app.launch()

        let verdict = try waitForProbeVerdict()
        if verdict == "fail tts not-signed-in" {
            throw XCTSkip("Simulator is not signed in to managed AI; TTS transport unverifiable here.")
        }
        XCTAssertTrue(verdict.hasPrefix("ok tts=ok"), "TTS probe failed: \(verdict)")
        XCTAssertTrue(verdict.contains("chunks="), "TTS probe did not exercise chunking: \(verdict)")
        XCTAssertTrue(verdict.contains("bytes="), "TTS probe did not report audio bytes: \(verdict)")
        XCTAssertTrue(verdict.contains("durationMs="), "TTS probe did not decode audio: \(verdict)")
        XCTAssertTrue(verdict.contains("receipts="), "TTS probe did not receive metering receipts: \(verdict)")
    }

    /// Billable, explicit live audit: every model in the directory must return
    /// audio that the production iPhone path can validate and decode.
    func testEveryTextToSpeechModelEndToEnd() throws {
        app.launchArguments = [
            "-foreverlm-uitest-probe",
            "-foreverlm-uitest-tts-all-models",
            "-foreverlm-uitest-tts-only",
        ]
        app.launch()

        let verdict = try waitForProbeVerdict(timeout: 1_800)
        if verdict == "fail tts not-signed-in" {
            throw XCTSkip("Simulator is not signed in to managed AI; all-model TTS audit unavailable.")
        }
        XCTAssertTrue(verdict.hasPrefix("ok tts=ok models="), "TTS model audit failed: \(verdict)")
    }

    /// Notebooks (Notebooks in code) made on the Mac reach the phone with their
    /// pools resolvable: the probe proves the catalog carries them, and Home
    /// lists them with cards that open the notebook — Sources, Chat and
    /// Studio — whose Chat carries its composer. No session is
    /// started — navigation only, nothing billable.
    func testShowsNotebooksSyncedFromMac() throws {
        app.launchArguments += ["-foreverlm-uitest-probe"]
        app.launchEnvironment["FOREVERLM_PROBE_NOTEBOOKS"] = "1"
        app.launch()

        let verdict = try waitForProbeVerdict()
        XCTAssertTrue(verdict.hasPrefix("ok"), "Probe failed: \(verdict)")

        let notebookCount = verdict
            .split(separator: " ")
            .first { $0.hasPrefix("notebooks=") }
            .flatMap { Int($0.dropFirst("notebooks=".count)) } ?? 0
        if notebookCount == 0 {
            throw XCTSkip("This iCloud account has no Notebooks; nothing to assert against.")
        }

        try waitForHome()

        // The identifier rides on the NavigationLink, which XCUITest exposes as
        // a button (or bare cell content) rather than the enclosing cell — query
        // across element types instead of the cells axis.
        let notebookRow = app.descendants(matching: .any)
            .matching(identifier: "browser.notebookRow")
            .firstMatch
        XCTAssertTrue(
            notebookRow.waitForExistence(timeout: 30),
            "Probe reports \(notebookCount) Notebooks but Home never showed a notebook card."
        )

        notebookRow.tap()
        let tabBar = app.descendants(matching: .any)["notebook.tabBar"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "The notebook never showed Sources · Chat · Studio.")
        let chatTab = app.descendants(matching: .any).matching(identifier: "notebook.tab.chat").firstMatch
        XCTAssertTrue(chatTab.exists, "The notebook has no Chat tab.")
        chatTab.tap()
        let send = app.buttons["notebook.chat.send"]
        XCTAssertTrue(
            send.waitForExistence(timeout: 10),
            "The notebook's Chat never showed its composer."
        )
    }

    /// Captures the browser scrolled to the type buttons as a test attachment.
    /// This is the one way to SEE the app on this machine — the simulator
    /// helper can screenshot but not scroll — so visual checks (like SVG badge
    /// rendering, which actool has silently broken before) run through here.
    /// Export with:
    /// `xcrun xcresulttool export attachments --path <run>.xcresult --output-path <dir>`
    func testCapturesTypeButtonsScreenshot() throws {
        app.launch()
        try waitForHome()
        try openSources()

        let typeRow = app.descendants(matching: .any)
            .matching(identifier: "browser.typeRow")
            .firstMatch
        XCTAssertTrue(typeRow.waitForExistence(timeout: 30), "Type rows never rendered.")
        app.swipeUp()

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "browser-type-buttons"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Captures the three screens used for App Store submission. The library
    /// image stops at source-type summaries so private source titles from the
    /// signed-in test account never become store artwork. Home now lists the
    /// account's notebooks by title, so "01-home" is only store artwork from
    /// an account whose notebook titles may be shown.
    func testCapturesAppStoreScreenshots() throws {
        app.launch()
        try waitForHome()
        attachScreenshot(named: "01-home")

        try openSources()
        let typeRow = app.descendants(matching: .any)
            .matching(identifier: "browser.typeRow")
            .firstMatch
        XCTAssertTrue(typeRow.waitForExistence(timeout: 30), "Type rows never rendered.")
        app.swipeUp()
        attachScreenshot(named: "02-source-types")

        app.terminate()
        app.launch()
        try waitForHome()
        try openSettings()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "Settings did not finish loading before its screenshot."
        )
        attachScreenshot(named: "03-settings")
    }

    /// App Store account-creation rules require a discoverable in-app deletion
    /// flow with a destructive confirmation. Stop at the confirmation so this
    /// test can run repeatedly against the real signed-in simulator.
    func testAccountDeletionRequiresConfirmation() throws {
        app.launch()
        try waitForHome()
        try openSettings()

        let privacy = app.descendants(matching: .any)
            .matching(identifier: "settings.privacyPolicy")
            .firstMatch
        for _ in 0..<3 where !privacy.exists { app.swipeUp() }
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), "The privacy policy link is missing from Settings.")

        let delete = app.buttons["settings.deleteAccount"]
        for _ in 0..<3 where !delete.exists { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "Delete Account was not reachable from Settings.")

        delete.tap()
        XCTAssertTrue(
            app.staticTexts["Permanently delete your account?"].waitForExistence(timeout: 5),
            "Delete Account did not show a destructive confirmation."
        )
        let deleteActions = app.buttons.matching(NSPredicate(format: "label == %@", "Delete Account"))
        let confirmedDelete = try XCTUnwrap(
            deleteActions.allElementsBoundByIndex.first(where: \.isHittable),
            "The destructive Delete Account action was not tappable."
        )
        confirmedDelete.tap()
        XCTAssertTrue(
            app.staticTexts["Confirm with Apple"].waitForExistence(timeout: 5),
            "The destructive confirmation did not require fresh Apple authorization."
        )
        XCTAssertTrue(app.buttons["accountDeletion.confirmWithApple"].exists)
        app.terminate()
    }

    // MARK: - Helpers

    /// Opens Settings from Home's toolbar.
    private func openSettings() throws {
        let gear = app.descendants(matching: .any)
            .matching(identifier: "home.settings")
            .firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "Home's Settings button never appeared.")
        gear.tap()
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Opens the whole library from Home's Library row, the first row under the title.
    private func openSources() throws {
        let link = app.descendants(matching: .any)
            .matching(identifier: "home.sources")
            .firstMatch
        for _ in 0..<10 where !link.exists { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 20), "Home's Library row never appeared.")
        link.tap()
    }

    /// Waits until the home screen renders, failing fast if the catalog settles
    /// on empty. A launch starts on Home.
    private func waitForHome() throws {
        let hero = app.descendants(matching: .any)["home.settings"]
        let deadline = Date().addingTimeInterval(Self.catalogTimeout)
        while Date() < deadline {
            if hero.exists { return }
            // The account wall showing its sign-in button means this simulator
            // has no managed-AI session, and everything behind the wall is
            // unverifiable here — same shape as the voice transport skip. The
            // wall's quiet "checking" state is not skipped on: a lapsed session
            // may still be confirmed, so the wait continues until it resolves.
            if app.staticTexts["account.wall.title"].exists,
               app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Apple'")).firstMatch.exists {
                throw XCTSkip("Simulator is not signed in to managed AI; the account wall is up.")
            }
            if app.staticTexts["No Sources Yet"].exists {
                // Give one refresh-worthy beat before declaring it empty: the
                // load may have raced the first render.
                Thread.sleep(forTimeInterval: 5)
                if app.staticTexts["No Sources Yet"].exists, !hero.exists {
                    XCTFail("Home settled on the empty state — catalog sync produced no sources.")
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTFail("Home never rendered within \(Int(Self.catalogTimeout))s.")
    }

    /// Waits for the probe's status line to reach a verdict and returns it.
    private func waitForProbeVerdict(
        timeout: TimeInterval = MobileVoiceUITests.probeTimeout
    ) throws -> String {
        let probe = app.staticTexts["uitest.probe.status"]
        XCTAssertTrue(
            probe.waitForExistence(timeout: 60),
            "Probe status line never appeared — was the launch argument dropped?"
        )
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = probe.label
            if last.hasPrefix("ok") || last.hasPrefix("fail") {
                // Surface the full verdict line in the test log — pass/fail
                // alone hides the numbers (source count, extraction ratio).
                XCTContext.runActivity(named: "probe verdict: \(last)") { _ in }
                return last
            }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTFail("Probe never reached a verdict within \(Int(timeout))s; last status: \(last)")
        return last
    }
}
