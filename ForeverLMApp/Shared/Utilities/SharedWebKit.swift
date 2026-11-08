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
}
