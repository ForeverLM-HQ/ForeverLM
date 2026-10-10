import XCTest

// Deterministic guards for the two things a live voice session showed a
// learner on 2026-08-31 that nobody was checking for: colour the brand does
// not contain, and an error banner over a conversation that was working.
//
// Neither needs a provider, a signed-in account, or a billable session. Both
// run against `-foreverlm-uitest-voice-surface`, the debug-only harness that
// renders the shared surface with fixed state, so they are cheap enough to be
// worth running on every change to the voice screen.
final class MobileVoiceSurfaceRegressionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // An iCloud or account prompt can land over the app at any moment on a
        // simulator that is signed in. Left alone it dims the whole screen,
        // which for a test that measures colour is worse than a crash: a
        // dimmed orb is *less* saturated, so the palette check would pass
        // while measuring an alert.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for title in ["Not Now", "Cancel", "Don’t Allow", "Don't Allow", "Dismiss", "OK"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    // MARK: - The mark's palette

    /// Saturation of the most saturated pixel in the shipped mark,
    /// `brand/foreverlm-logo-transparent-tight.png`, measured over its opaque
    /// pixels as `(max - min) / max` of the RGB channels — with the 99th
    /// percentile at 0.562. Everything the orb draws is that artwork, so this
    /// is the hard upper bound on anything it can honestly put on screen.
    /// Quoted in failures for context; the ceiling below is what is enforced.
    private static let artworkPeakSaturation: Double = 0.684

    /// Where the correct composite stops.
    ///
    /// Not the artwork's peak — the orb is the artwork masked, blurred and
    /// laid over itself, and that composite tops out well below its source.
    /// Over 32 frames of the shipped build the highest was 0.612 and most sit
    /// near 0.56. Reported in the log for context; the two constants below are
    /// what the test actually enforces.
    private static let saturationCeiling: Double = 0.62

    /// A pixel this saturated is not the mark, at any phase of the drift.
    ///
    /// Held well above the ceiling on purpose. The orb's own antialiased edge
    /// against the background produces a scatter of pixels in the low 0.6s —
    /// harmless, and the reason an earlier version of this test cried wolf.
    private static let stainCutoff: Double = 0.72

    /// How many such pixels make it a stain rather than noise.
    ///
    /// Judging the single most saturated pixel was the obvious rule and it was
    /// wrong: one shipped frame in twenty-four peaked at 0.992 on *two* pixels.
    /// It also misstates the defect, which was patches of wrong colour.
    ///
    /// Counting pixels past `stainCutoff` across eight frames of each build,
    /// on the same simulator and harness:
    ///
    ///     shipped (1.12)    0  0  0  0  0  0  0  0
    ///     regressed (1.35) 22  0  0 48 51 17 68 87
    ///
    /// Ten leaves five times the worst noise ever observed, and still fails six
    /// of the eight regressed frames — and the test only needs one of them.
    private static let stainedPixelAllowance = 10

    /// A grey orb would satisfy a ceiling on its own. The mark is iridescent,
    /// so the frame has to stay colourful as well as inside the palette — this
    /// is what fails if a drift layer stops compositing and the ribbon goes
    /// flat.
    private static let saturationFloor: Double = 0.30

    /// The orb draws only colours the logo already contains.
    ///
    /// The bug this pins: the drift re-saturated a composite that already held
    /// the artwork at full strength, which pushed parts of the ribbon to
    /// saturated red and orange — hues the mark has none of — that wandered
    /// the loop as the drift orbited. It was visible, nobody could have caught
    /// it in a build log, and it is trivial to measure.
    func testOrbNeverLeavesTheBrandPalette() throws {
        // The orb on an otherwise empty screen. Everything else on the voice
        // surface is a source of colour this must not count — the source cards
        // carry per-type tint glyphs at full saturation, the End button is pure
        // red — and cropping around them proved unreliable: the first version
        // of this test measured a purple thumbnail and blamed the mark.
        app.launchArguments = [
            "-foreverlm-uitest-voice-surface",
            "-foreverlm-uitest-voice-surface-orb-only",
        ]
        app.launch()

        let orb = app.descendants(matching: .any)["voice.status"]
        XCTAssertTrue(orb.waitForExistence(timeout: 20), "The voice orb never rendered.")

        // The drift takes about eighteen seconds to go round, and the stains
        // only appeared at some points on that orbit. Sample across it rather
        // than trusting one frame.
        var brightest = 0.0
        for sample in 0..<8 {
            let frame = try saturationProfile()
            brightest = max(brightest, frame.peak)

            // Left in on purpose: a nightly failure is read from a log by
            // someone who was not watching it happen, and the shape of the run
            // up to the failing frame is most of the diagnosis.
            print(String(
                format: "orb frame %d: peak %.3f, %d px past %.2f, %d past %.2f",
                sample, frame.peak,
                frame.beyondCeiling, Self.saturationCeiling,
                frame.stainedPixels, Self.stainCutoff
            ))
            if frame.stainedPixels > Self.stainedPixelAllowance {
                // Keep the evidence. A number in a nightly log is not enough to
                // tell a real regression from something that wandered over the
                // app while it was being measured.
                let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                evidence.name = "orb-frame-\(sample)"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            XCTAssertLessThanOrEqual(
                frame.stainedPixels,
                Self.stainedPixelAllowance,
                """
                Frame \(sample): \(frame.stainedPixels) pixels are more saturated than \
                \(Self.stainCutoff) (peak \(String(format: "%.3f", frame.peak))). The shipped mark \
                peaks at \(Self.artworkPeakSaturation) and the correct composite never gets near \
                this, so the orb is showing colour the compositing invented. The attached image is \
                the frame that was measured.
                """
            )
            Thread.sleep(forTimeInterval: 2.2)
        }

        XCTAssertGreaterThanOrEqual(
            brightest,
            Self.saturationFloor,
            """
            The orb never exceeded saturation \(String(format: "%.3f", brightest)) across eight \
            frames. The mark is iridescent; this reads as a ribbon that has lost its colour \
            rather than one that is inside the palette.
            """
        )
    }

    // MARK: - Error chrome

    /// A healthy session shows no error banner.
    ///
    /// A benign rejection used to be rendered as a red banner on the orb in
    /// the middle of a working conversation (2026-08-31, on the realtime
    /// session the turn-by-turn conversation replaced). This pins the
    /// surface, so a future path that routes some other benign failure into
    /// `inlineErrorMessage` is caught here rather than by a person using the
    /// app.
    func testHealthySessionShowsNoErrorBanner() throws {
        app.launchArguments = ["-foreverlm-uitest-voice-surface"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["voice.status"].waitForExistence(timeout: 20),
            "The voice surface never rendered."
        )
        // Give the surface a beat to settle: asserting absence immediately
        // after launch would also pass against a banner that has not been laid
        // out yet.
        Thread.sleep(forTimeInterval: 2)
        // An alert over the app would hide the banner just as effectively as
        // not drawing it, and this test cannot tell those apart.
        try requireAnUnobstructedApp()

        XCTAssertFalse(
            app.descendants(matching: .any)["voice.inlineError"].exists,
            "A live voice session with nothing wrong is showing an error banner."
        )
    }

    /// The absence check above is querying something real.
    ///
    /// Without this, renaming or dropping the banner's identifier would leave
    /// `testHealthySessionShowsNoErrorBanner` passing forever while the banner
    /// itself went back to appearing over healthy sessions.
    func testErrorBannerIsFoundWhenItIsActuallyShown() throws {
        app.launchArguments = [
            "-foreverlm-uitest-voice-surface",
            "-foreverlm-uitest-voice-surface-error",
        ]
        app.launch()

        let banner = app.descendants(matching: .any)["voice.inlineError"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 20),
            """
            The inline error banner was not found by the same query the absence \
            test uses, so that test proves nothing.
            """
        )
    }

    // MARK: - Pixels

    /// Refuses to measure a screen that something else is covering.
    ///
    /// The interruption monitor only fires when the test interacts with the
    /// app, and this test mostly just looks at it — so an alert can sit there
    /// unhandled for the whole run. Nudge the app to trigger the monitor, then
    /// insist the coast is clear rather than measuring whatever is on top.
    private func requireAnUnobstructedApp() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard springboard.alerts.count > 0 || app.state != .runningForeground else { return }

        app.activate()
        // Interacting is what gives the interruption monitor its chance to run.
        app.tap()
        Thread.sleep(forTimeInterval: 1)

        guard springboard.alerts.count == 0, app.state == .runningForeground else {
            throw XCTSkip(
                """
                A system alert is covering the app and would not dismiss, so the pixels on                 screen are not the voice surface. Measuring them would report a dimmed                 alert as a pass.
                """
            )
        }
    }

    private struct SaturationProfile {
        /// Most saturated pixel in the frame, for the failure message.
        let peak: Double
        /// Bright enough to carry a hue worth judging.
        let sampled: Int
        /// Past what the correct composite reaches. Logged, not enforced.
        let beyondCeiling: Int
        /// Past what edge noise can explain. This is what fails the test.
        let stainedPixels: Int
    }

    /// Peak HSV-style saturation over the bright pixels of one element.
    ///
    /// The whole screen, which under `-foreverlm-uitest-voice-surface-orb-only`
    /// holds the orb and its background and nothing else. Two earlier versions
    /// tried to isolate the orb instead — hand-converting points to pixels,
    /// then `XCUIElement.screenshot()` — and both measured the wrong region.
    /// Controlling what is on screen beats cropping what is.
    private func saturationProfile() throws -> SaturationProfile {
        try requireAnUnobstructedApp()

        guard let cgImage = XCUIScreen.main.screenshot().image.cgImage,
              cgImage.width > 0, cgImage.height > 0 else {
            throw XCTSkip("The screenshot carried no bitmap to measure.")
        }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not build a bitmap context for the orb's pixels.")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var peak = 0.0
        var sampled = 0
        var beyondCeiling = 0
        var stainedPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let highest = max(red, green, blue)
            // Dark pixels carry no meaningful hue and the ratio below is noisy
            // there; the ribbon is high-key everywhere it is drawn.
            guard highest > 0.25 else { continue }
            let lowest = min(red, green, blue)
            let saturation = (highest - lowest) / highest
            peak = max(peak, saturation)
            sampled += 1
            if saturation > Self.saturationCeiling { beyondCeiling += 1 }
            if saturation > Self.stainCutoff { stainedPixels += 1 }
        }

        guard sampled > 0 else {
            throw XCTSkip("The orb's area held no measurable pixels.")
        }
        return SaturationProfile(
            peak: peak,
            sampled: sampled,
            beyondCeiling: beyondCeiling,
            stainedPixels: stainedPixels
        )
    }
}
