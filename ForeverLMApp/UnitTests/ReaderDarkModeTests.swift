import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import ForeverLM

/// The contract the reader's dark page rests on. Readers follow the Mac, so what
/// these tests pin is that the theme every reader is handed really does
/// delegate, that the forced-dark fallback stays conditional, and that the one
/// preference left — the reader's opt-out from an invented page — only ever
/// subtracts from Dark Mode.
@Suite("Reader dark mode")
struct ReaderDarkModeTests {

    /// `.system` is what every reader is constructed with. It must delegate on
    /// all four channels — the composed readers key their CSS off the raw value
    /// and the `color-scheme` property, and the live web views off the
    /// appearance, which is what a publisher page's `prefers-color-scheme`
    /// resolves against.
    @Test("The reader theme follows the app on every channel")
    func systemThemeDelegates() {
        #expect(ReaderColorTheme.system.rawValue == "system")
        #expect(ReaderColorTheme.system.cssColorScheme == "light dark")
        #expect(ReaderColorTheme.system.colorSchemeOverride == nil)
        #expect(ReaderColorTheme.system.nsAppearanceOverride == nil)
        // A theme that follows the app needs no canvas of its own: the pane
        // behind the transparent page is already the right colour.
        #expect(ReaderColorTheme.system.opaqueReaderCanvas == nil)
    }

    /// The raw value is not cosmetic: it is the attribute
    /// `EPUBReaderStyles.css` selects on to swap in its dark tokens.
    @Test("The dark theme carries the values each reader reads")
    func darkThemeIsWiredThrough() throws {
        #expect(ReaderColorTheme.dark.rawValue == "dark")
        #expect(ReaderColorTheme.dark.cssColorScheme == "dark")
        #expect(ReaderColorTheme.dark.colorSchemeOverride == .dark)
        #expect(ReaderColorTheme.dark.nsAppearanceOverride?.name == .darkAqua)
        // A composed reader's page is transparent, so a page pinned dark has to
        // bring a canvas of its own; the themes that follow the app must not.
        #expect(ReaderColorTheme.dark.opaqueReaderCanvas != nil)
        #expect(ReaderColorTheme.light.opaqueReaderCanvas == nil)
    }

    /// The setting is gone, so nothing should be syncing its key any more — a
    /// stale entry would keep replicating a value no reader reads.
    @Test("The retired toggle no longer syncs")
    func retiredPreferenceIsNotSynced() {
        #expect(!SyncedPreferenceKeys.isSynced("extremeDarkMode"))
    }

    /// Dark Mode is still what a reader gets without touching anything, and that
    /// rests on the polarity of the stored flag: an unset `Bool` reads false, so
    /// the preference has to name the opt-out rather than the dark page.
    @Test("A reader darkens the page until the opt-out is set")
    func darkPageIsTheDefault() {
        let suite = "ReaderDarkModeTests.defaults"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(!defaults.bool(forKey: ReaderDarkMode.originalPageColorsKey))
        #expect(ReaderDarkMode.darkensPage(
            in: .dark,
            originalPageColors: defaults.bool(forKey: ReaderDarkMode.originalPageColorsKey)
        ))
    }

    /// The opt-out subtracts and never adds: it turns the dark page off in Dark
    /// Mode, and cannot conjure one in Light Mode.
    @Test("The opt-out only ever removes the invented page")
    func originalPageColorsOnlySubtracts() {
        #expect(!ReaderDarkMode.darkensPage(in: .dark, originalPageColors: true))
        #expect(!ReaderDarkMode.darkensPage(in: .light, originalPageColors: false))
        #expect(!ReaderDarkMode.darkensPage(in: .light, originalPageColors: true))
    }

    /// Undotted, or `AppStorage`'s KVO observation never fires and the paper on
    /// screen keeps its inverted page until the reader is rebuilt.
    @Test("The opt-out key is undotted and follows the account")
    func originalPageColorsKeySyncs() {
        #expect(!ReaderDarkMode.originalPageColorsKey.contains("."))
        #expect(SyncedPreferenceKeys.isSynced(ReaderDarkMode.originalPageColorsKey))
    }

    /// The forced-dark pass is the fallback, not the mechanism: it may only
    /// invert a page that stayed light, and it has to put media back so figures
    /// and photographs keep their real colors.
    @Test("The forced-dark script measures before it inverts")
    func forcedDarkScriptIsConditional() {
        let script = ReaderDarkMode.forcedDarkWebPageScript
        #expect(script.contains("pageIsLight"))
        #expect(script.contains("invert(1) hue-rotate(180deg)"))
        #expect(script.contains("var forced = enabled && !hasOwnDarkDesign;"))
        #expect(script.contains("classList.toggle(CLASS_NAME, forced)"))
        // Inert until pushed, so a switch to Dark Mode reaches pages that are
        // already open rather than waiting for the next load.
        #expect(script.contains("var enabled = false;"))
        #expect(script.contains("__flmReaderDarkPending"))
    }

    /// The flicker fix. A page that picks its theme on hydration is light when
    /// the filter goes on and dark a moment later, and re-deciding on every
    /// measurement showed that dark page inverted into a white one. Seeing the
    /// page dark once has to be final for that document.
    @Test("A page with its own dark design latches out of the forced-dark pass")
    func forcedDarkScriptLatchesOncePageGoesDark() {
        let script = ReaderDarkMode.forcedDarkWebPageScript
        #expect(script.contains("var hasOwnDarkDesign = false;"))
        #expect(script.contains("if (enabled && !hasOwnDarkDesign && !pageIsLight()) {"))
        #expect(script.contains("hasOwnDarkDesign = true;"))
        // Nothing sets it back, so forcing switches off at most once per
        // document and can never switch on again.
        #expect(script.components(separatedBy: "hasOwnDarkDesign = ").count == 3)
    }

    /// Watching for the theme rather than polling for it: the fixed ticks alone
    /// left a light page on screen for up to 400ms after the site had already
    /// gone dark.
    @Test("The forced-dark script re-measures when the page restyles itself")
    func forcedDarkScriptWatchesForLateThemes() {
        let script = ReaderDarkMode.forcedDarkWebPageScript
        #expect(script.contains("new MutationObserver(scheduleRefresh)"))
        #expect(script.contains("observer.observe(document.documentElement, attributes)"))
        #expect(script.contains("observer.observe(document.head, { childList: true })"))
        // Coalesced onto a frame, so style has resolved before it is read and a
        // burst of hydration writes costs one measurement.
        #expect(script.contains("requestAnimationFrame"))
        // Bounded backstops remain: a stylesheet already in `head` repaints the
        // page when it loads without mutating anything.
        #expect(script.contains("window.addEventListener('load', scheduleRefresh)"))
        #expect(script.contains("setTimeout(scheduleRefresh, 250)"))
    }

    // MARK: - The script, running

    /// Substack's publication pages paint a white wrapper on a transparent
    /// body. Once the filter is on, the root's computed background is the dark
    /// canvas the script itself painted, and a measurement that read it would
    /// take the page for one with a dark design of its own, latch, and drop the
    /// filter for good — which is what showed a light Substack post in a dark
    /// reader on 2026-09-06. The second `set` here is the push `didFinish`
    /// makes, and the explicit `refresh` stands in for the observer and the
    /// backstop ticks; every one of them has to keep the page inverted.
    @MainActor
    @Test("A light page on a transparent body stays inverted past the reader's own canvas")
    func forcedDarkKeepsInvertingLightPageWithTransparentBody() async throws {
        let webView = try await Self.loadReaderPage(html: """
            <!doctype html><html><head><style>
              html, body { margin: 0; }
              body { background: transparent; }
              .wrap { background: #fff; color: #111; min-height: 100vh; }
            </style></head><body><div class="wrap"><p>Light page on a bare body.</p></div></body></html>
            """)

        let afterFirstPush = try await Self.forced(in: webView, after: "window.__flmReaderDark.set(true);")
        #expect(afterFirstPush)
        let afterSecondPush = try await Self.forced(in: webView, after: "window.__flmReaderDark.set(true);")
        #expect(afterSecondPush)
        let afterRefresh = try await Self.forced(in: webView, after: "window.__flmReaderDark.refresh();")
        #expect(afterRefresh)
    }

    /// The other side of the same measurement: a page whose own dark theme lands
    /// on the root element, underneath the reader's `!important` canvas, still
    /// has to be seen — that is the flicker fix — so the canvas has to be lifted
    /// while the page is read and put back before anything paints.
    @MainActor
    @Test("A dark design that lands on the root element is still detected under the canvas")
    func forcedDarkSeesLateRootThemeUnderItsOwnCanvas() async throws {
        let webView = try await Self.loadReaderPage(html: """
            <!doctype html><html><head><style>
              html, body { margin: 0; }
              body { background: transparent; color: #111; }
              html.dark { background: #111; color: #eee; }
            </style></head><body><p>Light until hydration.</p></body></html>
            """)

        let whileLight = try await Self.forced(in: webView, after: "window.__flmReaderDark.set(true);")
        #expect(whileLight)
        let onceDark = try await Self.forced(
            in: webView,
            after: "document.documentElement.classList.add('dark'); window.__flmReaderDark.refresh();"
        )
        #expect(!onceDark)
        // Latched: nothing measured later brings the filter back.
        let styleStillGone = try await webView.evaluateJavaScript(
            "document.getElementById('foreverlm-reader-dark') === null"
        ) as? Bool
        #expect(styleStillGone == true)
        let afterAnotherPush = try await Self.forced(in: webView, after: "window.__flmReaderDark.set(true);")
        #expect(!afterAnotherPush)
    }

    /// A dark theme that lands on the body is the common case, and the body is
    /// never the reader's to paint — the measurement reads it as it is.
    @MainActor
    @Test("A dark design that lands on the body latches the filter off")
    func forcedDarkSeesLateBodyTheme() async throws {
        let webView = try await Self.loadReaderPage(html: """
            <!doctype html><html><head><style>
              body { background: #fff; color: #111; }
              body.dark { background: #111; color: #eee; }
            </style></head><body><p>Light until hydration.</p></body></html>
            """)

        let whileLight = try await Self.forced(in: webView, after: "window.__flmReaderDark.set(true);")
        #expect(whileLight)
        let onceDark = try await Self.forced(
            in: webView,
            after: "document.body.classList.add('dark'); window.__flmReaderDark.refresh();"
        )
        #expect(!onceDark)
    }

    /// What the inverted page paints, rather than what the script says it will.
    /// press.asimov.com draws its article straight onto `html`, and on
    /// 2026-09-28 the reader showed it as pale grey text on a pale grey ground:
    /// WebKit filters the root's background along with the page, so the
    /// post-inverted `#191919` the rule stated came back light. The page is one
    /// line long, so the foot of the window is canvas below the root's content.
    @MainActor
    @Test("A light page painted on the root element renders on a dark ground")
    func forcedDarkRootGroundRendersDark() async throws {
        let webView = try await Self.loadReaderPage(html: """
            <!doctype html><html style="background: #fcfbf9; color: #262626">
            <body style="margin: 0 40px"><p>Painted straight onto the root.</p></body></html>
            """)
        // Offscreen but ordered in, or WebKit has nothing to snapshot.
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.close() }

        let forced = try await Self.forced(in: webView, after: "window.__flmReaderDark.set(true);")
        #expect(forced)
        let image = try await Self.snapshot(of: webView)
        let beside = try #require(Self.luminance(in: image, x: 0.98, y: 0.05))
        let below = try #require(Self.luminance(in: image, x: 0.5, y: 0.95))
        #expect(beside < 0.25, "the ground beside the text rendered light (\(beside))")
        #expect(below < 0.25, "the canvas below a short page rendered light (\(below))")
    }

    @MainActor
    private static func snapshot(of webView: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    /// Relative luminance of the pixel at a fraction of the image's width and
    /// height, measured from the top left.
    private static func luminance(in image: NSImage, x: CGFloat, y: CGFloat) -> CGFloat? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(
                  x: Int(CGFloat(bitmap.pixelsWide - 1) * x),
                  y: Int(CGFloat(bitmap.pixelsHigh - 1) * y)
              )?.usingColorSpace(.sRGB)
        else { return nil }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    /// Whether the reader's inversion is on the page after `javaScript` has run.
    @MainActor
    private static func forced(in webView: WKWebView, after javaScript: String) async throws -> Bool {
        let result = try await webView.evaluateJavaScript(
            javaScript + " document.documentElement.classList.contains('flm-reader-dark');"
        )
        return result as? Bool ?? false
    }

    /// A web view with the reader's real script installed, the way
    /// `WebViewReader.makeNSView` installs it, showing `html` and finished loading.
    @MainActor
    private static func loadReaderPage(html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ReaderDarkMode.forcedDarkWebPageScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        await waiter.load(html, in: webView)
        let installed = try await webView.evaluateJavaScript("typeof window.__flmReaderDark === 'object'") as? Bool
        try #require(installed == true, "the reader script did not run at document end")
        return webView
    }

    /// Resolves once the page has finished loading. Held by the caller for the
    /// load's duration, since the web view's delegate reference is weak.
    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?

        func load(_ html: String, in webView: WKWebView) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                continuation?.resume()
                continuation = nil
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                continuation?.resume()
                continuation = nil
            }
        }
    }
}
