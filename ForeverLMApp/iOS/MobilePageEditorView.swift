import os
import SwiftUI
import UIKit
import WebKit

// A page on the phone, read and written in the editor the Mac and the web run
// (`App/ArtifactEditorResources`, built from `Web/ArtifactEditor`): the same
// page, `/` menu, selection bar and Markdown input rules, so what is written
// here is the page the Mac opens. This file is only the host. The page keeps
// Markdown as its value, as on the Mac (`ArtifactMarkdownEditorView`): the host
// hands it the text, hears every edit back, and leaves storage to whoever holds
// the page.
//
// What the phone changes is how the page is reached: by a finger, not a
// pointer. `MobilePageEditorTouch` fits the bundle's own controls to a finger
// from outside — a stylesheet and a script injected at load — rather than
// forking the page, which the Mac and the web keep editing.

/// One thing a typed link can point at — a page of the same library, a
/// notebook, an Idea or a chat — as the editor's `setLinkTargets` takes it
/// (the Mac's `ArtifactPageLinkTarget`). `[[` and `@` list these, filtered as
/// the writer types, and write the chosen one as `[Title](foreverlm://<kind>/<id>)`.
struct MobilePageLinkTarget: Equatable, Encodable, Sendable {
    let id: String
    let title: String
    /// The stored address's host: `doc`, `notebook`, `idea` or `chat`.
    let kind: String
    /// The quieter second column: where a page is filed, or Draft.
    var detail: String = ""
}

/// A page the editor linked before it existed. The `/` menu's Page row writes
/// `[Untitled](foreverlm://doc/<id>)` on the line it was chosen on, the id a
/// fresh lowercase UUID of the editor's own, and asks the host to make the
/// page under that id (`pageCreationRequested`). The link is in the text
/// already, and the text has reached the host before this is asked.
struct MobilePageCreationRequest: Equatable, Sendable {
    let id: String
    let title: String
    /// The writer asked to land on the page once it exists, as the Page row does.
    let opensPage: Bool
    /// The page belongs under the page it was made from: the Page row's subpage.
    let isSubpage: Bool
}

struct MobilePageEditorView: UIViewRepresentable {
    let pageID: String
    /// The page's text. Read when the page opens and whenever `textKey`
    /// changes; a new value under the same key is the host echoing the
    /// writer's own edit back and is not sent, so the caret stays put.
    let markdown: String
    /// Changes when the host replaces the text — another device's edit, a
    /// restored version. The editor then takes `markdown`, keeping the caret
    /// where the unchanged text around it puts it.
    let textKey: String
    /// Off, the page reads as a page: no caret, a link opens on a tap, and no
    /// edit is ever reported.
    let isEditable: Bool
    /// What `[[`, `@` and the Link field offer. The whole list goes to the
    /// editor whenever it changes; the editor filters as the writer types.
    var linkTargets: [MobilePageLinkTarget] = []
    /// The page's pictures: a `data:` URL per attachment token, as the page's
    /// package keeps them. A picture the host has not handed over is drawn
    /// as a missing image.
    var attachmentDataURLs: [String: String] = [:]
    /// Every edit, as the editor reports it (a beat after the last keystroke),
    /// and the last one when the page closes or the app goes to the background.
    var onMarkdownChange: (String) -> Void
    /// A link followed: `foreverlm://doc|notebook|idea|chat|source/<id>`, or a
    /// web or mail address.
    var onOpenURL: (URL) -> Void
    /// Makes a page the editor linked before it existed; answers whether it
    /// was made. Nil, the `/` menu offers no Page row.
    var onCreatePage: ((MobilePageCreationRequest) async -> Bool)? = nil
    /// The editor could not load or start, in a sentence.
    var onError: ((String) -> Void)? = nil

    static let messageHandlerName = "artifactEditor"
    /// The prose column's cap: the Mac's Standard width (`ArtifactPageWidth`).
    /// A phone is narrower, so the page fills it; an iPad keeps a readable line.
    static let pageMaxWidth: CGFloat = 760
    /// Dynamic Type sets the page's size up to the first accessibility size;
    /// past it the column holds a word or two a line.
    static let maximumFontSize: CGFloat = 28

    /// The page's text size: the body style at the reader's Dynamic Type size.
    static func fontSize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let size = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        return min(size, maximumFontSize).rounded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Prose: a number or an address in it is not a link to call or map.
        configuration.dataDetectorTypes = []
        // The page has its own AI; Writing Tools would be a second one, as the
        // Mac's editor says (`SharedWebKit.disableSystemWritingTools`).
        if #available(iOS 18.0, *) {
            configuration.writingToolsBehavior = .none
        }
        configuration.userContentController.add(context.coordinator, name: Self.messageHandlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: MobilePageEditorTouch.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.accessibilityIdentifier = "page.editor"
        #if DEBUG
        webView.isInspectable = true
        #endif

        let scrollView = webView.scrollView
        scrollView.backgroundColor = .clear
        // The page owns its margins. SwiftUI lays the view out inside the safe
        // area and above the keyboard, so an inset of UIKit's own would pad twice.
        scrollView.contentInsetAdjustmentBehavior = .never
        // Pulling the page down puts the keyboard away, as in Notes.
        scrollView.keyboardDismissMode = .interactive

        context.coordinator.attach(to: webView, environment: context.environment)
        context.coordinator.loadEditor(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(from: self, environment: context.environment, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView.navigationDelegate = nil
        // The last keystrokes can still be inside the editor's debounce.
        coordinator.flush(in: webView)
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "PageEditor")

        /// Where a page's edits go: the host's callback as it stood for that page.
        private struct MarkdownSink {
            let pageID: String
            var deliver: (String) -> Void
        }

        private weak var webView: WKWebView?
        private var isReady = false
        private var initializationStarted = false
        private var pageID: String
        private var textKey: String
        /// The page's text as the host holds it: what it handed over, or the
        /// last edit delivered to it. The editor is started on this.
        private var heldText: String
        /// The editor's own spelling of `heldText`, read back once the page has
        /// it. A page nobody touched serializes to this, not to the host's
        /// text, and that difference is not an edit.
        private var baseline: String?
        private var deliveredSinceBaseline = false
        /// A body sent and not yet taken. An edit reported before the page
        /// answers is about text the host has replaced, or about the page it
        /// has left, and is not delivered.
        private var replacementsInFlight = 0
        private var sink: MarkdownSink
        private var isEditable: Bool
        private var linkTargets: [MobilePageLinkTarget]
        private var attachmentDataURLs: [String: String]
        /// The tokens the page can already draw (the Mac's `pageAttachmentTokens`).
        private var pageAttachmentTokens: Set<String> = []
        private var offersPages: Bool
        private var fontSize: CGFloat = 17
        private var onOpenURL: (URL) -> Void
        private var onCreatePage: ((MobilePageCreationRequest) async -> Bool)?
        private var onError: ((String) -> Void)?
        private var resignObserver: NSObjectProtocol?

        init(_ view: MobilePageEditorView) {
            pageID = view.pageID
            textKey = view.textKey
            heldText = view.markdown
            sink = MarkdownSink(pageID: view.pageID, deliver: view.onMarkdownChange)
            isEditable = view.isEditable
            linkTargets = view.linkTargets
            attachmentDataURLs = view.attachmentDataURLs
            offersPages = view.onCreatePage != nil
            onOpenURL = view.onOpenURL
            onCreatePage = view.onCreatePage
            onError = view.onError
            super.init()
        }

        deinit {
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
        }

        func attach(to webView: WKWebView, environment: EnvironmentValues) {
            self.webView = webView
            fontSize = MobilePageEditorView.fontSize(for: environment.dynamicTypeSize)
            webView.overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
            // iOS may end the app from the background without a word: the
            // edit still inside the debounce goes to the host on the way out.
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let webView = self.webView else { return }
                self.flush(in: webView)
            }
        }

        func detach() {
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
            resignObserver = nil
            webView = nil
            isReady = false
            initializationStarted = false
        }

        func loadEditor(into webView: WKWebView) {
            let bundledURL = Bundle.main.url(
                forResource: "artifact-editor",
                withExtension: "html",
                subdirectory: "ArtifactEditorResources"
            ) ?? Bundle.main.url(forResource: "artifact-editor", withExtension: "html")
            guard let bundledURL else {
                report("The page editor is missing from this build.")
                return
            }
            webView.loadFileURL(bundledURL, allowingReadAccessTo: bundledURL.deletingLastPathComponent())
        }

        func update(from view: MobilePageEditorView, environment: EnvironmentValues, in webView: WKWebView) {
            onOpenURL = view.onOpenURL
            onCreatePage = view.onCreatePage
            onError = view.onError
            webView.overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light

            let size = MobilePageEditorView.fontSize(for: environment.dynamicTypeSize)
            if size != fontSize {
                fontSize = size
                if isReady { webView.evaluateJavaScript(Self.fontSizeScript(size)) }
            }

            // The text first, under the editability the edits were made with.
            if view.pageID != pageID {
                openPage(view, in: webView)
            } else {
                sink.deliver = view.onMarkdownChange
                if view.textKey != textKey {
                    textKey = view.textKey
                    heldText = view.markdown
                    if isReady { sendText(in: webView) }
                }
            }

            if view.isEditable != isEditable {
                // Edits made while the page could be written are the host's.
                if !view.isEditable { flush(in: webView) }
                isEditable = view.isEditable
                if isReady { webView.evaluateJavaScript(Self.editableScript(isEditable)) }
            }

            if (view.onCreatePage != nil) != offersPages {
                offersPages = view.onCreatePage != nil
                if isReady { webView.evaluateJavaScript(slashFeaturesScript) }
            }

            if view.linkTargets != linkTargets {
                linkTargets = view.linkTargets
                if isReady { deliverLinkTargets(in: webView) }
            }

            if view.attachmentDataURLs != attachmentDataURLs {
                attachmentDataURLs = view.attachmentDataURLs
                // Only a picture the page cannot draw yet is worth drawing the
                // page again for (the Mac's `pageNeedsAttachments`).
                if isReady, !Set(attachmentDataURLs.keys).isSubset(of: pageAttachmentTokens) {
                    deliverAttachmentURLs(in: webView)
                }
            }
        }

        /// Another page in the same view. The page leaving may still hold its
        /// last words inside the editor's debounce: they are read first and go
        /// to that page's callback, and nothing the editor reports before it
        /// holds the new body is delivered at all.
        private func openPage(_ view: MobilePageEditorView, in webView: WKWebView) {
            flush(in: webView)
            pageID = view.pageID
            textKey = view.textKey
            heldText = view.markdown
            sink = MarkdownSink(pageID: view.pageID, deliver: view.onMarkdownChange)
            if isReady { sendText(in: webView) }
        }

        /// Hand the host the page as it stands, when that differs from what
        /// the host holds: the page closing, the app leaving, a page made from
        /// a link the writer has just written. `completion` runs once the page
        /// has answered.
        func flush(in webView: WKWebView, completion: (() -> Void)? = nil) {
            guard isReady, isEditable else {
                completion?()
                return
            }
            let sink = sink
            let held = heldText
            let baseline = baseline
            let edited = deliveredSinceBaseline
            // The web view is held until the page answers: one already let go
            // of by SwiftUI would answer nothing.
            webView.evaluateJavaScript(Self.serializedMarkdownScript) { [weak self, webView] result, _ in
                _ = webView
                if let value = result as? String, value != held, edited || value != baseline {
                    if let self, self.sink.pageID == sink.pageID {
                        self.heldText = value
                        self.deliveredSinceBaseline = true
                    }
                    sink.deliver(value)
                }
                completion?()
            }
        }

        /// Send `heldText` as the page's body, keyed by the page so the editor
        /// knows another page from the same page replaced, and read back the
        /// editor's spelling of it.
        private func sendText(in webView: WKWebView) {
            replacementsInFlight += 1
            webView.evaluateJavaScript(setMarkdownScript()) { [weak self] _, _ in
                self?.replacementsInFlight -= 1
            }
            webView.evaluateJavaScript(Self.serializedMarkdownScript) { [weak self] result, _ in
                guard let self else { return }
                self.baseline = result as? String
                self.deliveredSinceBaseline = false
            }
        }

        private func deliver(_ value: String) {
            guard value != heldText else { return }
            heldText = value
            deliveredSinceBaseline = true
            sink.deliver(value)
        }

        // MARK: - The page's messages

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == MobilePageEditorView.messageHandlerName,
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }

            switch type {
            case "ready":
                if let webView = message.webView { markReady(in: webView) }
            case "markdownChanged", "saveRequested":
                guard isEditable, replacementsInFlight == 0,
                      let value = payload["markdown"] as? String else { return }
                deliver(value)
            case "openLinkRequested", "touchLinkOpenRequested":
                // The Mac's hover pill (an iPad's pointer), or the phone's own
                // pill for the link the caret is in.
                guard let href = payload["href"] as? String,
                      let url = MobilePageEditorAddress.destination(href) else { return }
                onOpenURL(url)
            case "openSourceRequested":
                if let href = payload["href"] as? String, let url = MobilePageEditorAddress.destination(href) {
                    onOpenURL(url)
                } else if let sourceID = payload["sourceID"] as? String,
                          let url = MobilePageEditorAddress.url(kind: "source", id: sourceID) {
                    onOpenURL(url)
                }
            case "openTitleRequested":
                // A page named by its title: the linked page with that title.
                guard let title = payload["title"] as? String,
                      let target = linkTargets.first(where: { $0.kind == "doc" && Self.sameTitle($0.title, title) }),
                      let url = MobilePageEditorAddress.url(kind: "doc", id: target.id) else { return }
                onOpenURL(url)
            case "pageCreationRequested":
                guard let request = Self.pageCreation(from: payload), let webView = message.webView else { return }
                makePage(request, in: webView)
            case "aiEditRequested", "imageGenerationRequested":
                // The phone runs no model for a page yet, and the rows that ask
                // are not offered (`MobilePageEditorTouch`); a request that gets
                // here anyway is answered, so the panel is not left waiting.
                guard let requestID = payload["requestID"] as? String, !requestID.isEmpty else { return }
                message.webView?.evaluateJavaScript(
                    "window.foreverLMArtifactEditor.failAIEdit(\(Self.jsonString(requestID)), \(Self.jsonString(Self.unavailableAIMessage)));"
                )
            case "error":
                report(payload["message"] as? String ?? "The page editor failed to load.")
            default:
                // The selection, folds and references the Mac keeps; Chat,
                // Comment, sources and files, which the phone does not offer.
                break
            }
        }

        /// The link is in the text, so the text reaches the host before the
        /// page it names is made; a page the writer asked to land on opens
        /// once it exists.
        private func makePage(_ request: MobilePageCreationRequest, in webView: WKWebView) {
            guard let onCreatePage else { return }
            let open = onOpenURL
            flush(in: webView) {
                Task { @MainActor in
                    guard await onCreatePage(request), request.opensPage,
                          let url = MobilePageEditorAddress.url(kind: "doc", id: request.id) else { return }
                    open(url)
                }
            }
        }

        private func markReady(in webView: WKWebView) {
            isReady = true
            webView.evaluateJavaScript(Self.fontSizeScript(fontSize))
            webView.evaluateJavaScript(Self.editableScript(isEditable))
            webView.evaluateJavaScript(slashFeaturesScript)
            // `create` took the body already; this names the page, which the
            // editor keys its folds by, and reads back its spelling.
            sendText(in: webView)
            deliverLinkTargets(in: webView)
            deliverAttachmentURLs(in: webView)
        }

        private func deliverLinkTargets(in webView: WKWebView) {
            let data = (try? JSONEncoder().encode(linkTargets)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setLinkTargets(\(json));")
        }

        private func deliverAttachmentURLs(in webView: WKWebView) {
            pageAttachmentTokens = Set(attachmentDataURLs.keys)
            let data = (try? JSONEncoder().encode(attachmentDataURLs)) ?? Data("{}".utf8)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setAttachmentURLs(\(json));")
        }

        private func report(_ message: String) {
            Self.logger.error("\(message, privacy: .public)")
            onError?(message)
        }

        // MARK: - Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !initializationStarted else { return }
            initializationStarted = true
            // `create` returns a Promise, which `evaluateJavaScript` cannot
            // hand back; the script ends on a value it can.
            webView.evaluateJavaScript(startupScript()) { [weak self] _, error in
                if let error {
                    self?.report("Could not start the page editor: \(error.localizedDescription)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report("Could not load the page editor: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report("Could not load the page editor: \(error.localizedDescription)")
        }

        /// iOS ends a web view's content process under memory pressure and the
        /// page goes blank. It is started again on the text the host holds.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            initializationStarted = false
            replacementsInFlight = 0
            pageAttachmentTokens = []
            loadEditor(into: webView)
        }

        /// A link in the page is followed by the host, never inside the
        /// editor's own web view. On a page read as a page that is a tap on the
        /// link; while writing, a tap puts the caret in the link and the pill
        /// under it follows it (`touchLinkOpenRequested`).
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if let destination = MobilePageEditorAddress.destination(url.absoluteString) {
                onOpenURL(destination)
            }
            decisionHandler(.cancel)
        }

        // MARK: - Scripts

        /// What the host answers among the `/` menu's rows that are not the
        /// editor's own: a page made, when the host makes pages. Pictures,
        /// files, drawn pictures and visualizations need a host side the phone
        /// does not have yet, and are not offered.
        private var slashFeaturesScript: String {
            "window.foreverLMArtifactEditor.setSlashFeatures({ pages: \(offersPages), images: false, imageGeneration: false, visualize: false, files: false });"
        }

        /// The page width and the editability go in before `create`, so the
        /// first paint is already the page as it will stay.
        private func startupScript() -> String {
            "window.foreverLMArtifactEditor.setPageWidth(\(Double(MobilePageEditorView.pageMaxWidth))); "
                + Self.editableScript(isEditable)
                + " window.foreverLMArtifactEditor.create(\(Self.jsonString(heldText)), \(Double(fontSize))); true;"
        }

        /// The body with the page's key. The phone keeps no folds, so a page
        /// opens unfolded; the editor keeps those of the page it holds.
        private func setMarkdownScript() -> String {
            "window.foreverLMArtifactEditor.setMarkdown(\(Self.jsonString(heldText)), { key: \(Self.jsonString(pageID)), folds: \"\" });"
        }

        private static let serializedMarkdownScript = "window.foreverLMArtifactEditor.serializedMarkdown();"

        static let unavailableAIMessage = "Writing with AI is not on iPhone and iPad yet."

        private static func fontSizeScript(_ size: CGFloat) -> String {
            "window.foreverLMArtifactEditor.setFontSize(\(Double(size)));"
        }

        private static func editableScript(_ editable: Bool) -> String {
            "window.foreverLMArtifactEditor.setEditable(\(editable));"
        }

        private static func jsonString(_ value: String) -> String {
            let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            return String(data: data, encoding: .utf8) ?? "\"\""
        }

        private static func sameTitle(_ left: String, _ right: String) -> Bool {
            left.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(right.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        /// The editor's `pageCreationRequested`, read as the Mac reads it
        /// (`ArtifactNotesGraphMessage`): a new page names a fresh UUID, and
        /// the Page row, the one request that lands on its page, makes a
        /// subpage unless the editor says otherwise. A day's note is the notes
        /// graph's, which the phone does not keep.
        private static func pageCreation(from payload: [String: Any]) -> MobilePageCreationRequest? {
            guard let id = (payload["docID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  UUID(uuidString: id) != nil,
                  (payload["dayKey"] as? String ?? "").isEmpty else { return nil }
            let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let opens = payload["open"] as? Bool ?? false
            return MobilePageCreationRequest(
                id: id,
                title: title.isEmpty ? "Untitled" : title,
                opensPage: opens,
                isSubpage: payload["nested"] as? Bool ?? opens
            )
        }
    }
}

/// The addresses a page's links carry, as the host follows them. Milkdown's
/// link mark drops a scheme that is not the web's, so the editor writes the
/// app's own addresses as `https://foreverlm.invalid/<kind>/<id>` while the
/// page is open and `foreverlm://<kind>/<id>` in the stored Markdown.
enum MobilePageEditorAddress {
    static let editorHost = "foreverlm.invalid"
    /// The app's own things a link goes to (`project` is the address a
    /// notebook had before the word changed, still read and never written). A
    /// grounded passage and an attached file carry an address too, but it
    /// names the passage's sources or the page's file, not a place to go.
    static let destinationKinds: Set<String> = ["doc", "notebook", "project", "idea", "chat", "source"]

    /// Where a link goes, in the stored form, or nil for an address that is
    /// not a destination.
    static func destination(_ href: String) -> URL? {
        var address = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let editorPrefix = "https://\(editorHost)/"
        if address.lowercased().hasPrefix(editorPrefix) {
            address = "\(MobileDeepLink.productScheme)://" + address.dropFirst(editorPrefix.count)
        }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "mailto":
            return url
        case MobileDeepLink.productScheme, ForeverLMRuntimeIdentity.urlScheme.lowercased():
            guard let kind = url.host?.lowercased(), destinationKinds.contains(kind),
                  url.pathComponents.count > 1 else { return nil }
            return url
        default:
            return nil
        }
    }

    /// `foreverlm://<kind>/<id>`, the id written as a link's path writes it.
    static func url(kind: String, id: String) -> URL? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: "\(MobileDeepLink.productScheme)://\(kind)/\(encoded)")
    }
}

/// The page fitted to a finger, from outside the bundle: a stylesheet and a
/// script the host injects at load. The page the Mac and the web run is left as
/// it is; what differs on a phone is how its controls are reached.
///
/// - Targets a finger can hit: the selection bar, its block menu, the caret
///   lists (`/`, `[[`, `@`) and the link field are at least 44pt tall.
/// - Hover-only chrome is not drawn on a touch-only device — the block handle,
///   the hover pills over links, an unfolded section's chevron — and a `:hover`
///   wash does not stay on a button a finger lifted from.
/// - A press on one of the page's controls leaves the selection and the
///   keyboard where they are.
/// - The selection bar is published again whenever the selection settles
///   (a handle dragged, a long press), and stands under the words on a touch
///   selection, clear of the edit menu iOS draws over them.
/// - While writing, a tap that puts the caret in a link shows a pill under it
///   that follows the link: the least surprising of the choices, since a tap
///   in prose being written places the caret everywhere else too.
/// - The caret stays above the keyboard as the page resizes for it.
/// - What the phone does not answer is not offered: Add sources, Edit with AI,
///   Comment and Chat on the bar, the `/` menu's Generate, a Prompt's Chat
///   about this.
enum MobilePageEditorTouch {
    static let script: String = scriptSource.replacingOccurrences(
        of: "__FOREVERLM_STYLESHEET__",
        with: jsonString(stylesheet)
    )

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    static let stylesheet = #"""
    html { -webkit-text-size-adjust: 100%; }
    body { -webkit-tap-highlight-color: transparent; }
    .milkdown .editor a { -webkit-touch-callout: none; }

    /* The phone's own caret, with its loupe and handles, rather than the
       page's drawn one beside it. */
    .milkdown .editor.virtual-cursor-enabled { caret-color: AccentColor; }
    .ProseMirror .prosemirror-virtual-cursor { display: none !important; }

    /* What the phone does not answer yet. */
    .artifact-selection-group[data-group="sources"],
    .artifact-selection-group[data-group="ai"],
    .artifact-selection-group[data-group="talk"],
    .artifact-callout-chat,
    .foreverlm-unoffered { display: none !important; }
    /* A bar with nothing left on it is not drawn: a page read as a page has
       no marks to set. */
    .artifact-selection-assistant:not(:has(> .artifact-selection-group:not([hidden]):not([data-group="sources"]):not([data-group="ai"]):not([data-group="talk"]))) {
      display: none !important;
    }
    .artifact-selection-group[data-group="format"]::before { display: none; }

    /* Targets a finger can hit. */
    .artifact-selection-assistant { min-height: 50px; border-radius: 13px; }
    .artifact-selection-assistant button {
      height: 44px;
      min-width: 44px;
      padding: 0 12px;
      border-radius: 10px;
      font-size: 14px;
    }
    .artifact-selection-assistant button[data-role="format"] { width: 44px; padding: 0; }
    .artifact-selection-assistant button[data-role="format"] svg { width: 18px; height: 18px; }
    .artifact-selection-group:not(:first-child)::before { height: 22px; }
    .artifact-selection-block-menu { min-width: 220px; }
    .artifact-selection-block-menu button { min-height: 44px; padding: 0 12px; font-size: 15px; }
    .artifact-link-picker { font-size: 15px; }
    .artifact-link-picker-row,
    .artifact-link-picker[data-source="slash"] .artifact-link-picker-row {
      box-sizing: border-box;
      min-height: 44px;
      align-items: center;
      padding: 6px 10px;
    }
    .artifact-link-picker-detail { font-size: 13px; }
    .artifact-link-picker-group,
    .artifact-link-picker-hint { font-size: 12px; }
    .artifact-link-picker-icon { width: 22px; height: 22px; }
    .milkdown .milkdown-link-edit > .link-edit,
    .milkdown .milkdown-link-preview > .link-preview { height: auto; min-height: 44px; align-items: center; }
    .milkdown .milkdown-link-edit > .link-edit > .input-area { font-size: 16px; }
    .milkdown .milkdown-link-edit > .link-edit > .button,
    .milkdown .milkdown-link-preview > .link-preview > .button,
    .milkdown .milkdown-link-preview > .link-preview > .link-icon {
      display: grid;
      box-sizing: border-box;
      min-width: 44px;
      min-height: 44px;
      place-items: center;
    }
    .artifact-inapp-link-tooltip { height: auto; }
    .artifact-inapp-link-tooltip button { min-height: 44px; padding: 0 14px; font-size: 14px; }
    /* A chevron keeps its 20px look and takes a 44px press. */
    .artifact-heading-fold::after { position: absolute; inset: -12px; content: ""; }

    /* Hover is the pointer's. */
    @media not all and (any-pointer: fine) {
      .artifact-block-handle,
      .milkdown .milkdown-link-preview,
      .artifact-inapp-link-tooltip { display: none !important; }
      .artifact-heading-fold:not(.is-collapsed) { visibility: hidden; }
      .artifact-selection-assistant button:hover:not(:active):not([aria-pressed="true"]):not([aria-expanded="true"]),
      .artifact-selection-block-menu button:hover:not(:active) { background: transparent; }
    }

    /* The link the caret is in, offered as a press: the hover pill's look. */
    .foreverlm-touch-link {
      position: fixed;
      z-index: 32;
      display: flex;
      box-sizing: border-box;
      max-width: calc(100vw - 24px);
      padding: 3px;
      border: 1px solid color-mix(in srgb, AccentColor 24%, transparent);
      border-radius: 999px;
      background: Canvas;
      box-shadow: 0 8px 24px color-mix(in srgb, CanvasText 15%, transparent);
    }
    .foreverlm-touch-link[hidden] { display: none; }
    .foreverlm-touch-link button {
      min-width: 0;
      min-height: 44px;
      overflow: hidden;
      padding: 0 16px;
      border: 0;
      border-radius: 999px;
      background: transparent;
      color: AccentColor;
      font: 600 15px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .foreverlm-touch-link button:active { background: color-mix(in srgb, CanvasText 10%, Canvas); }
    """#

    private static let scriptSource = #"""
    (() => {
      'use strict'
      if (window.foreverLMMobileHost) return
      window.foreverLMMobileHost = {}

      const send = (type, detail = {}) => {
        window.webkit?.messageHandlers?.artifactEditor?.postMessage({ type, ...detail })
      }

      // The text size is the reader's Dynamic Type, set by the host. The page
      // never zooms, so a field under 16px does not zoom it as it takes the keyboard.
      document.querySelector('meta[name="viewport"]')
        ?.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1')

      const style = document.createElement('style')
      style.id = 'foreverlm-mobile-host'
      style.textContent = __FOREVERLM_STYLESHEET__
      document.head.append(style)

      const finePointer = window.matchMedia('(any-pointer: fine)')
      const isEditing = () => !document.body.classList.contains('read-only')
      let lastPointerType = ''
      let lastTouchUpAt = 0

      function visibleTop() {
        return window.visualViewport ? window.visualViewport.offsetTop : 0
      }

      function visibleBottom() {
        const viewport = window.visualViewport
        return viewport ? viewport.offsetTop + viewport.height : window.innerHeight
      }

      // ─── A press on the page's own controls ─────────────────────────────────
      // The bar acts on the selection, a caret list on the caret: a tap on one
      // must leave both, and the keyboard, where they are. The tap is taken
      // whole — the press iOS would make of it never happens — and handed to
      // the control as the click it would have been. A finger that moved was
      // scrolling, not pressing.
      const keepsSelection = [
        '.artifact-selection-assistant button',
        '.artifact-selection-block-menu button',
        '.artifact-link-picker-row',
        '.foreverlm-touch-link button',
      ].join(', ')
      let tap = null

      document.addEventListener('touchstart', (event) => {
        const control = event.touches.length === 1 && event.target instanceof Element
          ? event.target.closest(keepsSelection)
          : null
        tap = control ? { control, x: event.touches[0].clientX, y: event.touches[0].clientY } : null
      }, { capture: true, passive: true })

      document.addEventListener('touchmove', (event) => {
        if (!tap) return
        const touch = event.touches[0]
        if (Math.abs(touch.clientX - tap.x) + Math.abs(touch.clientY - tap.y) > 10) tap = null
      }, { capture: true, passive: true })

      document.addEventListener('touchcancel', () => { tap = null }, { capture: true, passive: true })

      document.addEventListener('touchend', (event) => {
        const pressed = tap
        tap = null
        if (!pressed || !pressed.control.isConnected || pressed.control.disabled) return
        event.preventDefault()
        pressed.control.click()
      }, { capture: true, passive: false })

      // A caret list lights the row under a moving pointer by drawing its rows
      // again, which under a finger would take the row it presses away from it.
      document.addEventListener('pointermove', (event) => {
        if (event.pointerType === 'mouse') return
        if (event.target instanceof Element && event.target.closest('.artifact-link-picker')) event.stopPropagation()
      }, true)

      document.addEventListener('pointerdown', (event) => {
        lastPointerType = event.pointerType
        if (touchLink && !touchLink.contains(event.target)) hideTouchLink()
      }, true)

      document.addEventListener('pointerup', (event) => {
        if (event.pointerType === 'mouse') return
        lastTouchUpAt = Date.now()
        // A tap where the caret already was moves no selection.
        setTimeout(refreshTouchLink, 400)
      }, true)

      // ─── The selection bar ──────────────────────────────────────────────────
      // The page publishes its selection on a pointer's release and a key's. A
      // phone moves the selection with neither — a long press, a handle
      // dragged, the keyboard's trackpad — so a key's release the page cannot
      // tell from its own asks it again once the selection settles, and once a
      // scroll that put the bar away has stopped.
      let publishTimer = 0
      function republishSelection(delay) {
        clearTimeout(publishTimer)
        publishTimer = setTimeout(() => {
          document.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }))
        }, delay)
      }

      document.addEventListener('selectionchange', () => {
        republishSelection(150)
        refreshTouchLink()
      })

      let scrollTimer = 0
      document.addEventListener('scroll', () => {
        hideTouchLink()
        clearTimeout(scrollTimer)
        scrollTimer = setTimeout(() => republishSelection(0), 180)
      }, true)

      // iOS draws its edit menu (Cut, Copy, Paste) over a selection made by
      // touch, where the page puts its bar. On such a selection the bar stands
      // under the words, clear of the selection's end handle; where there is
      // no room under them it stays where the page put it.
      function placeSelectionBar(bar) {
        if (bar.hidden || (finePointer.matches && lastPointerType === 'mouse')) return
        const selection = window.getSelection()
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return
        const rects = selection.getRangeAt(0).getClientRects()
        if (rects.length === 0) return
        const top = Math.round(rects[rects.length - 1].bottom + 24)
        if (top + bar.offsetHeight > visibleBottom() - 8) return
        if (bar.style.top !== `${top}px`) bar.style.top = `${top}px`
        if (bar.dataset.placement !== 'below') bar.dataset.placement = 'below'
      }

      // ─── Rows the phone does not answer ─────────────────────────────────────
      // The `/` menu's Generate group asks for a model the phone does not run
      // for a page yet, and the page offers it to every host. Its rows are not
      // drawn; when the keys' row is one of them it moves to the first row
      // that is, so Return never runs what is not on screen.
      const unansweredGroups = new Set(['Generate'])

      function offerAnsweredRows(picker) {
        if (picker.hidden || picker.dataset.source !== 'slash') {
          picker.classList.remove('foreverlm-unoffered')
          return
        }
        let unanswered = false
        let selectedUnanswered = false
        let offered = 0
        for (const child of picker.children) {
          if (child.classList.contains('artifact-link-picker-group')) {
            unanswered = unansweredGroups.has(child.textContent)
            child.classList.toggle('foreverlm-unoffered', unanswered)
          } else if (child.classList.contains('artifact-link-picker-row')) {
            child.classList.toggle('foreverlm-unoffered', unanswered)
            if (unanswered && child.getAttribute('aria-selected') === 'true') selectedUnanswered = true
            if (!unanswered) offered += 1
          }
        }
        picker.classList.toggle('foreverlm-unoffered', offered === 0)
        if (selectedUnanswered && offered > 0) {
          document.querySelector('.ProseMirror')?.dispatchEvent(
            new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true, cancelable: true })
          )
        }
      }

      // The bar and the lists are the page's own children of the body, made the
      // first time they are needed.
      const watched = new WeakSet()
      function watch(element) {
        if (watched.has(element)) return
        if (element.classList.contains('artifact-selection-assistant')) {
          watched.add(element)
          new MutationObserver(() => placeSelectionBar(element))
            .observe(element, { attributes: true, attributeFilter: ['style', 'hidden'] })
          placeSelectionBar(element)
        } else if (element.classList.contains('artifact-link-picker')) {
          watched.add(element)
          new MutationObserver(() => offerAnsweredRows(element))
            .observe(element, { childList: true, attributes: true, attributeFilter: ['hidden'] })
          offerAnsweredRows(element)
        }
      }

      new MutationObserver((records) => {
        for (const record of records) {
          for (const node of record.addedNodes) {
            if (node instanceof HTMLElement) watch(node)
          }
        }
      }).observe(document.body, { childList: true })
      for (const element of document.body.children) watch(element)

      // ─── Following a link while writing ─────────────────────────────────────
      // A tap in prose being written puts the caret there, in a link as
      // anywhere else. When it lands in one, a pill under the line offers to
      // follow it; typing, scrolling or a tap elsewhere puts it away. A
      // notebook's address before the word changed is still read.
      const openLabels = {
        doc: 'Open page',
        notebook: 'Open notebook',
        project: 'Open notebook',
        idea: 'Open idea',
        chat: 'Open chat',
        source: 'Open source',
      }
      let touchLink = null

      function ensureTouchLink() {
        if (touchLink) return touchLink
        touchLink = document.createElement('div')
        touchLink.className = 'foreverlm-touch-link'
        touchLink.hidden = true
        const button = document.createElement('button')
        button.type = 'button'
        button.addEventListener('pointerdown', (event) => event.preventDefault())
        button.addEventListener('click', () => {
          const href = touchLink.dataset.href
          hideTouchLink()
          if (href) send('touchLinkOpenRequested', { href })
        })
        touchLink.append(button)
        document.body.append(touchLink)
        return touchLink
      }

      function hideTouchLink() {
        if (touchLink) touchLink.hidden = true
      }

      function linkAtCaret() {
        const selection = window.getSelection()
        if (!selection || selection.rangeCount === 0 || !selection.isCollapsed) return null
        const node = selection.anchorNode
        const element = node instanceof Element ? node : node?.parentElement
        const anchor = element?.closest('a[href]')
        return anchor && anchor.closest('.milkdown .editor') ? anchor : null
      }

      // Where a link goes and what the pill says, or null for an address that
      // names the page's own things: a grounded passage, an attached file. A
      // source is followed from its card, a line that is nothing but the link.
      function destinationOf(anchor) {
        let url
        try {
          url = new URL(anchor.getAttribute('href') ?? '')
        } catch {
          return null
        }
        if (url.protocol === 'https:' && url.hostname === 'foreverlm.invalid') {
          const [kind, id] = url.pathname.split('/').filter(Boolean)
          const label = openLabels[String(kind ?? '').toLowerCase()]
          if (!label || !id) return null
          if (kind.toLowerCase() === 'source' && !anchor.closest('p.artifact-reference')) return null
          return { label, href: url.href }
        }
        if (url.protocol === 'http:' || url.protocol === 'https:') {
          return { label: `Open ${url.hostname.replace(/^www\./, '')}`, href: url.href }
        }
        if (url.protocol === 'mailto:') return { label: `Email ${url.pathname}`, href: url.href }
        return null
      }

      function refreshTouchLink() {
        if (!isEditing() || Date.now() - lastTouchUpAt > 1000) {
          hideTouchLink()
          return
        }
        const anchor = linkAtCaret()
        const target = anchor ? destinationOf(anchor) : null
        if (!target) {
          hideTouchLink()
          return
        }
        const pill = ensureTouchLink()
        pill.dataset.href = target.href
        pill.firstChild.textContent = target.label
        pill.hidden = false
        const selection = window.getSelection()
        const caret = selection.getRangeAt(0).getClientRects()[0] ?? anchor.getBoundingClientRect()
        pill.style.left = '0px'
        const margin = 12
        let top = caret.bottom + 8
        if (top + pill.offsetHeight > visibleBottom() - margin) top = caret.top - pill.offsetHeight - 8
        const left = Math.min(window.innerWidth - pill.offsetWidth - margin, Math.max(margin, caret.left - 16))
        pill.style.left = `${Math.round(left)}px`
        pill.style.top = `${Math.round(top)}px`
      }

      document.addEventListener('beforeinput', hideTouchLink, true)
      document.addEventListener('focusout', (event) => {
        if (event.target instanceof Element && event.target.closest('.milkdown .editor')) hideTouchLink()
      }, true)

      // ─── The caret above the keyboard ───────────────────────────────────────
      // The host's view ends above the keyboard, so the page's window shrinks
      // as the keyboard comes up, and a caret near the bottom can end up under
      // the new edge. It is brought back into view, a little clear of it.
      function keepCaretVisible() {
        const prose = document.querySelector('.milkdown .editor')
        if (!isEditing() || !prose || !prose.contains(document.activeElement)) return
        const selection = window.getSelection()
        if (!selection || selection.rangeCount === 0) return
        const range = selection.getRangeAt(0).cloneRange()
        range.collapse(false)
        let rect = range.getClientRects()[0]
        if (!rect) {
          const node = selection.focusNode
          const element = node instanceof Element ? node : node?.parentElement
          rect = element?.getBoundingClientRect()
        }
        if (!rect) return
        const margin = 32
        const bottom = visibleBottom() - margin
        const top = visibleTop() + margin
        if (rect.bottom > bottom) window.scrollBy(0, rect.bottom - bottom)
        else if (rect.top < top) window.scrollBy(0, rect.top - top)
      }

      let caretFrame = 0
      function scheduleCaretCheck() {
        if (caretFrame) return
        caretFrame = requestAnimationFrame(() => {
          caretFrame = 0
          keepCaretVisible()
        })
      }

      window.addEventListener('resize', scheduleCaretCheck)
      window.visualViewport?.addEventListener('resize', scheduleCaretCheck)
      document.addEventListener('input', scheduleCaretCheck, true)
      document.addEventListener('focusin', (event) => {
        // After the keyboard has come up and the view has resized for it.
        if (event.target instanceof Element && event.target.closest('.milkdown .editor')) setTimeout(keepCaretVisible, 350)
      }, true)
    })()
    """#
}

#if DEBUG
/// `-foreverlm-uitest-page-editor`: the page editor full screen over a fixed
/// page, writable, with no account, for a Simulator screenshot of the editor;
/// `-foreverlm-uitest-page-editor-read-only` shows the same page read-only.
/// Every edit's length, every link followed and every page made is logged
/// (`log stream --predicate 'category == "PageEditorHarness"'`).
enum MobilePageEditorHarness {
    static let launchArgument = "-foreverlm-uitest-page-editor"
    static let readOnlyLaunchArgument = "-foreverlm-uitest-page-editor-read-only"

    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(launchArgument) || arguments.contains(readOnlyLaunchArgument)
    }

    static var isReadOnly: Bool {
        ProcessInfo.processInfo.arguments.contains(readOnlyLaunchArgument)
    }
}

struct MobilePageEditorHarnessView: View {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "PageEditorHarness")

    @State private var markdown = Self.samplePage

    var body: some View {
        MobilePageEditorView(
            pageID: "page-editor-harness",
            markdown: markdown,
            textKey: "sample",
            isEditable: !MobilePageEditorHarness.isReadOnly,
            linkTargets: Self.linkTargets,
            onMarkdownChange: { value in
                markdown = value
                Self.logger.notice("markdownChanged length=\(value.count, privacy: .public)")
            },
            onOpenURL: { url in
                Self.logger.notice("open \(url.absoluteString, privacy: .public)")
            },
            onCreatePage: { request in
                Self.logger.notice("create page \(request.id, privacy: .public) “\(request.title, privacy: .public)” opens=\(request.opensPage, privacy: .public)")
                return true
            },
            onError: { message in
                Self.logger.error("editor error: \(message, privacy: .public)")
            }
        )
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("pageEditor.harness")
    }

    private static let linkTargets = [
        MobilePageLinkTarget(id: "0c9a7f2e-5b1d-4c3e-9f7a-2d6e8b4a1c00", title: "Krebs cycle notes", kind: "doc", detail: "Mitochondria"),
        MobilePageLinkTarget(id: "5e0b2c71-8f4a-4d9e-b6a3-1c7d9e2f4a10", title: "Uncoupling proteins", kind: "doc", detail: "Draft"),
        MobilePageLinkTarget(id: "9d3f6a12-4c8b-4e7f-a1d2-6b5c8e9f0a21", title: "Mitochondria", kind: "notebook"),
    ]

    private static let samplePage = """
    # The page on a phone

    A page written on the Mac reads the same here. Tap a link to follow it: \
    [Krebs cycle notes](foreverlm://doc/0c9a7f2e-5b1d-4c3e-9f7a-2d6e8b4a1c00), \
    or [a search on PubMed](https://pubmed.ncbi.nlm.nih.gov/?term=atp+synthase).

    ## What to remember

    - The electron transport chain pumps protons across the inner membrane.
    - ATP synthase turns that gradient back into ATP.[^1]
    - Uncoupling proteins let protons back in without making any.

    ## The complexes

    | Complex | Name | Pumps protons |
    | --- | --- | --- |
    | I | NADH dehydrogenase | Yes |
    | II | Succinate dehydrogenase | No |
    | IV | Cytochrome c oxidase | Yes |

    Type / on an empty line for the insert menu, and [[ or @ to link a page.

    [^1]: A mammalian ATP synthase turns about 2.7 protons into one ATP: its rotor has eight c-subunits, and a turn makes three.
    """
}
#endif
