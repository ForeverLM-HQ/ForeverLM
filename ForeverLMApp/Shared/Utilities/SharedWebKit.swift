import Foundation
import WebKit
#if os(macOS)
import AppKit
#endif

/// Hook for shared WebKit configuration across chat and readers.
/// macOS 12+ already uses one shared WebKit process; this centralizes future tuning.
enum SharedWebKit {
    static func applySharedProcessPool(to configuration: WKWebViewConfiguration) {
        _ = configuration
    }

    /// Keeps system Writing Tools off a page ForeverLM shows as its own.
    ///
    /// A web view's default is the limited experience, and on a selection of
    /// read-only text that draws Apple's badge in the margin and proofreading
    /// underlines under phrases of the paragraph — marks the page never wrote.
    /// `foreverlmWritingToolsDisabled()` does the same for SwiftUI text; a web
    /// view takes it on its configuration instead. Browser tabs are left out: a
    /// page there is the web's, not ForeverLM's.
    ///
    /// WebKit declares `writingToolsBehavior` on the configuration only for a
    /// deployment target of macOS 15 or later, and ours is 14, so it is set by
    /// key; a system without the property never answers the selector.
    ///
    /// The configuration is half of it: the view answers for the badge itself,
    /// in `allowsWritingToolsAffordance(in:)`.
    static func disableSystemWritingTools(on configuration: WKWebViewConfiguration) {
        #if os(macOS)
        if #available(macOS 15.0, *),
           configuration.responds(to: Selector(("setWritingToolsBehavior:"))) {
            configuration.setValue(NSWritingToolsBehavior.none.rawValue, forKey: "writingToolsBehavior")
        }
        #endif
    }

    /// What every ForeverLM web view class answers when AppKit asks it
    /// `allowsWritingToolsAffordance`: no on a page whose configuration
    /// `disableSystemWritingTools(on:)` set, WebKit's own answer anywhere else.
    ///
    /// The configuration alone left the badge and the underlines up. On a
    /// selection AppKit asks the view itself whether it may show its Apple
    /// Intelligence badge, and WebKit answers yes for any selection whatever
    /// the configuration says (macOS 27: `none` set, yes answered). A no makes
    /// AppKit dismiss the badge at once, and the proofreading pass that draws
    /// the underlines starts only from a badge that opened. One class backs a
    /// reader and a Browser tab alike, so the configuration decides, not the
    /// class.
    static func allowsWritingToolsAffordance(in webView: WKWebView) -> Bool {
        #if os(macOS)
        // WebKit's own method, which the app's classes stand in front of.
        let selector = NSSelectorFromString("allowsWritingToolsAffordance")
        // A WebKit without the method has no badge to offer.
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return false }
        if systemWritingToolsDisabled(in: webView.configuration) { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(webView, selector)
        #else
        return false
        #endif
    }

    /// What every ForeverLM web view class answers when AppKit asks it
    /// `unionRectInVisibleSelectedRange`: no rect for a selection on a page
    /// whose configuration `disableSystemWritingTools(on:)` set, WebKit's own
    /// rect anywhere else.
    ///
    /// macOS 27.0.1 stopped asking `allowsWritingToolsAffordance`: on every
    /// selection change `-[NSTextInputContext
    /// _textInputClientDidUpdateSelectionDebounced]` hands the selection's
    /// rect straight to WritingToolsUI, which draws the badge in its own
    /// `WTAffordanceWindow` beside it and leaves proofreading underlines in
    /// the passage (product owner, 2026-11-07, on a chat reply: "why do these
    /// underlines show up; i don't like that"). The rect is the one thing
    /// that call reads from the view, and with an empty one the window stays
    /// hidden (measured in a harness: badge shown with WebKit's rect, hidden
    /// with `.zero`). A caret is a rect with no width and keeps WebKit's
    /// answer, so an editor's dictation and input-mode indicators still
    /// find the cursor.
    #if os(macOS)
    static func unionRectInVisibleSelectedRange(in webView: WKWebView) -> NSRect {
        let selector = NSSelectorFromString("unionRectInVisibleSelectedRange")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return .zero }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
        let rect = unsafeBitCast(method_getImplementation(method), to: Getter.self)(webView, selector)
        if rect.width > 0, systemWritingToolsDisabled(in: webView.configuration) { return .zero }
        return rect
    }

    private static func systemWritingToolsDisabled(in configuration: WKWebViewConfiguration) -> Bool {
        guard #available(macOS 15.0, *),
              configuration.responds(to: Selector(("writingToolsBehavior"))) else { return false }
        return (configuration.value(forKey: "writingToolsBehavior") as? Int) == NSWritingToolsBehavior.none.rawValue
    }
    #endif

    /// The user agent every ForeverLM web view and page scraper presents.
    ///
    /// WKWebView's stock user agent omits the `Version/… Safari/…` tokens, so
    /// sites that gate on a supported-browser list — Google Docs, Sheets and
    /// Slides are the loudest — show a "this browser version is no longer
    /// supported" banner instead of the document. We present the installed
    /// Safari instead. The version is derived rather than pinned: a hardcoded
    /// string ages into exactly the same banner it was added to avoid.
    static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/\(safariVersion) Safari/605.1.15"

    /// Safari's major version has tracked the macOS major version since macOS 26
    /// (Safari 26). Older systems keep the last version that shipped for them.
    private static var safariVersion: String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return major >= 26 ? "\(major).0" : "18.6"
    }

    /// Whether a response is Cloudflare's bot check ("Performing security
    /// verification", titled *Just a moment...*). Cloudflare marks the
    /// challenge document with `cf-mitigated: challenge`.
    static func isCloudflareChallenge(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let mitigated = http.value(forHTTPHeaderField: "cf-mitigated") else { return false }
        return mitigated.trimmingCharacters(in: .whitespaces).lowercased() == "challenge"
    }

    /// Cloudflare's bot check never clears for a web view that presents
    /// `desktopSafariUserAgent`: it spins on *Verifying…* for good, because
    /// the page can tell a WKWebView claiming to be Safari from Safari. The
    /// same web view under WebKit's own user agent clears it in seconds
    /// (measured 2026-11-08 on a tandfonline.com paper: three runs each, a
    /// fresh data store, still on the check after 39 s with the Safari tokens,
    /// through it with WebKit's own).
    ///
    /// Called first from a `decidePolicyFor navigationResponse`: when the
    /// document is that check and the web view is presenting the Safari user
    /// agent, it drops the override for this web view only (the clearance
    /// cookie is tied to the user agent that earned it, so the web view keeps
    /// WebKit's own from here on) and asks for the page again. Returns whether
    /// it did, and then the caller answers the response `.cancel`.
    ///
    /// Cancel, not allow: a load started while an allowed challenge commits
    /// is dropped about three times in four, leaving the check on screen.
    /// The cancel reports `didFailProvisionalNavigation` with WebKit's
    /// "frame load interrupted" (102) before the new load starts; a delegate
    /// that would treat that as a failure asks
    /// `isCloudflareRetryInterruption(_:in:)` first.
    @MainActor
    static func retryCloudflareChallengeWithWebKitUserAgent(
        _ navigationResponse: WKNavigationResponse,
        in webView: WKWebView
    ) -> Bool {
        guard navigationResponse.isForMainFrame,
              webView.customUserAgent == desktopSafariUserAgent,
              isCloudflareChallenge(navigationResponse.response),
              let url = navigationResponse.response.url else { return false }
        webView.customUserAgent = nil
        cloudflareRetryWebViews.add(webView)
        DispatchQueue.main.async { [weak webView] in
            webView?.load(URLRequest(url: url))
        }
        return true
    }

    /// Whether a navigation failure is the cancel
    /// `retryCloudflareChallengeWithWebKitUserAgent` answered the challenge
    /// with, which the page asked for again replaces. Answers once per retry.
    @MainActor
    static func isCloudflareRetryInterruption(_ error: Error, in webView: WKWebView) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == WKErrorDomain || nsError.domain == "WebKitErrorDomain",
              nsError.code == 102,
              cloudflareRetryWebViews.contains(webView) else { return false }
        cloudflareRetryWebViews.remove(webView)
        return true
    }

    @MainActor
    private static let cloudflareRetryWebViews = NSHashTable<WKWebView>.weakObjects()
}

/// Who a web view's script message handlers listen to.
///
/// WebKit exposes a page's `window.webkit.messageHandlers` to every frame of
/// it, and nothing about a message says the app's own script sent it. A
/// chat reply's visualization runs model-written script in a sandboxed frame
/// of the chat page, and that frame could post `webLinks` and have the app
/// open any address, no click needed; a publisher's page can post whatever
/// the reader's injected scripts post. So every handler first asks where a
/// message came from: the main frame only, and on a page the app serves, a
/// frame showing that page. A subframe that has something to say (a
/// visualization's height) tells the page with `postMessage`, and the page's
/// own script decides what to pass on.
///
/// A page from the web shares its world with whatever the app injects there,
/// so for one the main-frame check is all a handler can do; a reader that
/// acts on what such a page posts keeps its scripts and handler in a content
/// world of its own (`WKContentWorld.world(name:)`), which the page's script
/// cannot reach.
enum ScriptMessageSender {
    /// The page a handler belongs to.
    enum Page: Equatable, Sendable {
        /// A page the app ships and loads from a file (`loadFileURL`): the
        /// chat, the transcript, the Canvas, the page editor.
        case appFile
        /// A page the app renders under an address of its own
        /// (`loadHTMLString(_:baseURL:)` with that base).
        case appOrigin(scheme: String, host: String)
        /// A page from the web or a book, whose own script runs in the world
        /// the handler is in: only the frame can be checked.
        case web
    }

    /// Whether a message from a frame with this origin is the page's own.
    /// A sandboxed frame without `allow-same-origin` has an opaque origin
    /// (empty protocol), and is never the main frame.
    static func accepts(isMainFrame: Bool, originProtocol: String, originHost: String, from page: Page) -> Bool {
        guard isMainFrame else { return false }
        switch page {
        case .appFile:
            return originProtocol.lowercased() == "file"
        case .appOrigin(let scheme, let host):
            return originProtocol.lowercased() == scheme.lowercased() && originHost.lowercased() == host.lowercased()
        case .web:
            return true
        }
    }
}

extension WKScriptMessage {
    /// Whether the message came from `page`'s own main frame
    /// (`ScriptMessageSender`). Every handler asks before it reads the body.
    @MainActor
    func isFrom(_ page: ScriptMessageSender.Page) -> Bool {
        let origin = frameInfo.securityOrigin
        return ScriptMessageSender.accepts(
            isMainFrame: frameInfo.isMainFrame,
            originProtocol: origin.protocol,
            originHost: origin.host,
            from: page
        )
    }
}
