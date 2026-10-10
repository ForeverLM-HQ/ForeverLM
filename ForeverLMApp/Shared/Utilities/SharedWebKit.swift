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
    static func disableSystemWritingTools(on configuration: WKWebViewConfiguration) {
        #if os(macOS)
        if #available(macOS 15.0, *),
           configuration.responds(to: Selector(("setWritingToolsBehavior:"))) {
            configuration.setValue(NSWritingToolsBehavior.none.rawValue, forKey: "writingToolsBehavior")
        }
        #endif
    }

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
