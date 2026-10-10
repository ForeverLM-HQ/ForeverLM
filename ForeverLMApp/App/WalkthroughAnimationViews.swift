#if os(macOS)
import SwiftUI
import WebKit

/// A walkthrough step's animation, loaded as one document into a web view
/// that lets nothing in or out: no storage, no navigation, no network beyond
/// the document's own policy (`PaperWalkthroughAnimationDocument`). Hosted
/// under the step's row in the chat transcript, and in `WalkthroughAnimationSheet`
/// when the learner asks for it larger.
struct WalkthroughAnimationWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: configuration)
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        load(html, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(html, into: webView, coordinator: context.coordinator)
    }

    private func load(_ html: String, into webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        webView.loadHTMLString(PaperWalkthroughAnimationDocument.document(for: html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The document itself loads as about:blank; a link, a form or a
            // frame inside it goes nowhere.
            let isDocument = navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isDocument ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

/// A saved animation's page in a step's card: the page at its library
/// address, `foreverlm-site://<id>/?embed=1&step=N&c=…`, served from the
/// library (`LocalSiteSchemeHandler`) — or, for a record still pointing at
/// sites.foreverlm.com, the hosted page loaded with the account's bearer — in
/// a store of its own. Navigation stays on the animation; links out, forms
/// and popups go nowhere. The page shows its stage alone at
/// the step and holds the last frame with the motion running.
struct WalkthroughHostedAnimationWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: configuration)
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        LocalSiteSchemeHandler.install(on: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = SharedWebKit.desktopSafariUserAgent
        load(url, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(url, into: webView, coordinator: context.coordinator)
    }

    private func load(_ url: URL, into webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedURL != url else { return }
        coordinator.loadedURL = url
        webView.load(LinkedDocWebView.initialRequest(url: url, kind: .foreverlmSite))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The page and the host's own redirects; a link out of the site,
            // a form or a frame to anywhere else goes nowhere.
            let url = navigationAction.request.url
            let onSiteHost = url?.host?.lowercased() == LinkedPage.foreverlmSitesHost
                || url.flatMap(LinkedPage.localSiteID(from:)) != nil
            let isDocument = navigationAction.targetFrame?.isMainFrame == true
            decisionHandler(onSiteHost && (isDocument || navigationAction.navigationType == .other) ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

/// The animation played large, as a sheet over the window — the way the
/// image lightbox enlarges a picture.
struct WalkthroughAnimationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let content: WalkthroughAnimationContent

    init(title: String, content: WalkthroughAnimationContent) {
        self.title = title
        self.content = content
    }

    init(title: String, html: String) {
        self.init(title: title, content: .inline(html: html))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            switch content {
            case .inline(let html): WalkthroughAnimationWebView(html: html)
            case .hosted(let url): WalkthroughHostedAnimationWebView(url: url)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 640)
    }
}
#endif
