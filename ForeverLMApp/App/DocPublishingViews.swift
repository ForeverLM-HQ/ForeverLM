import AppKit
import SwiftUI
import WebKit

/// Publishing a Doc to foreverlm.com, and updating the page it already has.
///
/// One sheet for both: it says what is about to happen — anyone with the link
/// can read the page, only this account can change or remove it — and after
/// the publish it shows the address with Copy Link and Open, because the
/// address is the thing the writer came for. The address can be the writer's
/// own — `foreverlm.com/share/<their-words>` — and a page that moves keeps its old
/// address forwarding. A Mac without a managed session is told where to sign
/// in instead of being sent a request that will fail.
/// Spec: docs/docs-design.md → Publishing.
struct PublishDocSheet: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: ArtifactRecord
    let existing: PublishedDocStatus?
    /// The access change and, when the writer typed one, the address to
    /// publish at; nil keeps the current address (random on a first publish).
    let publish: (DocPageAccess, String?) async throws -> PublishedDocStatus
    let published: (PublishedDocStatus) -> Void

    @State private var publishTask: Task<Void, Never>?
    @State private var result: PublishedDocStatus?
    @State private var errorMessage: String?
    @State private var didCopy = false
    @State private var restrictsReaders = false
    @State private var readersDraft = ""
    @State private var addressDraft = ""

    private var isPublishing: Bool { publishTask != nil }
    private var isUpdate: Bool { existing != nil }
    private var isSignedIn: Bool { ManagedAI.isSignedIn }
    private var isRestrictedAlready: Bool { existing?.isProtected == true }
    /// A page still guarded by a password set before reader lists existed.
    private var hasLegacyPassword: Bool { existing?.isProtected == true && existing?.readers.isEmpty == true }

    /// The address to send: nil when the field is empty or names the page's
    /// current address, the normalised slug when it is a valid new one, and
    /// `.some(nil)` is never produced — an invalid draft disables Publish.
    private var addressChange: String?? {
        let draft = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty { return .some(nil) }
        guard let slug = DocPublishing.normalizeCustomSlug(draft) else { return nil }
        return .some(slug == existing?.slug ? nil : slug)
    }
    private var addressIsInvalid: Bool { addressChange == nil }
    private var addressMoves: Bool {
        if case .some(let slug?) = addressChange, existing != nil { return slug != existing?.slug }
        return false
    }

    /// What this publish does to who can read the page: nil while the list as
    /// typed cannot be sent (an address that is not one, or none at all).
    private var accessChange: DocPageAccess? {
        if !restrictsReaders { return isRestrictedAlready ? .open : .keep }
        guard let readers = DocPublishing.normalizeReaders(readersDraft), !readers.isEmpty,
              readers.count <= DocPublishing.maxReaders else { return nil }
        if readers == existing?.readers { return .keep }
        return .readers(readers)
    }
    private var readersAreInvalid: Bool { restrictsReaders && !readersDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && accessChange == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(isUpdate ? "Update the published page" : "Publish to foreverlm.com", systemImage: "globe")
                .font(.system(size: 14, weight: .semibold))
            if let result {
                Text(isUpdate
                     ? (result.slug != existing?.slug
                        ? "The page now lives at its new address and shows the current text of “\(artifact.title)”. Its old address forwards here."
                        : "The page now shows the current text of “\(artifact.title)”.")
                     : result.isProtected
                        ? "“\(artifact.title)” is live. Only the people it is shared with can open it: they enter their email address on the page and follow the link that is sent to them."
                        : "“\(artifact.title)” is live. Anyone with the link can read it.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(result.url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(didCopy ? "Copied" : "Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
                        didCopy = true
                    }
                    Button("Open") { NSWorkspace.shared.open(result.url) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
                if result.isProtected {
                    Text(result.readers.isEmpty
                         ? "Still guarded by its old password\(result.password.map { ": \($0)" } ?? ""). Add readers to switch to sharing by email."
                         : "Shared with \(result.readers.joined(separator: ", "))")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
                }
            } else {
                Text(isUpdate
                     ? "The page at \(existing?.url.absoluteString ?? "") is replaced with the current text of “\(artifact.title)”. Its address stays the same unless you change it below."
                     : "“\(artifact.title)” becomes a page on foreverlm.com. Anyone with the link can read it; it is not listed anywhere, and only you can update or take it down. Sources cited in this Page stay as links; pictures attached to this Page are not published.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("foreverlm.com/share/")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField(isUpdate ? (existing?.slug ?? "") : "random address", text: $addressDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .disabled(isPublishing)
                        .accessibilityLabel("Custom address")
                }
                Text(addressIsInvalid
                     ? "An address is 3 to 64 lowercase letters, digits and single hyphens, and starts and ends with a letter or digit."
                     : addressMoves
                        ? (isRestrictedAlready
                           ? "The page moves to the new address; the old one forwards there. Readers sign in again."
                           : "The page moves to the new address; the old one forwards there.")
                        : isUpdate
                            ? "Type a new address to move the page; leave it as it is to keep the current one."
                            : "Leave it empty for a random twelve-character address, or choose your own words. An address in use by another page is refused.")
                    .font(.system(size: 11))
                    .foregroundStyle(addressIsInvalid ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Share with specific people only", isOn: $restrictsReaders)
                    .font(.system(size: 12))
                    .disabled(isPublishing)
                if restrictsReaders {
                    TextField("Email addresses, separated by commas or lines", text: $readersDraft, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .autocorrectionDisabled()
                        .disabled(isPublishing)
                        .accessibilityLabel("Reader email addresses")
                    Text(readersAreInvalid
                         ? "One of these is not an email address."
                         : hasLegacyPassword
                           ? "This page is still guarded by its old password\(existing?.password.map { " (\($0))" } ?? ""). Listing readers replaces it; turning the switch off opens the page to anyone with the link."
                         : "Each reader enters their address on the page and follows the link that is emailed to them; the page then remembers them for thirty days. Removing an address shuts them out at once.")
                        .font(.system(size: 11))
                        .foregroundStyle(readersAreInvalid ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isSignedIn {
                    Text("Publishing is tied to your ForeverLM account. Sign in with Apple in Settings › Billing first.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isPublishing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(isUpdate ? "Updating the page…" : "Publishing…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if result != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        publishTask?.cancel()
                        publishTask = nil
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(isUpdate ? "Update" : "Publish") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(isPublishing || !isSignedIn || accessChange == nil || addressIsInvalid)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            restrictsReaders = isRestrictedAlready
            readersDraft = existing?.readers.joined(separator: ", ") ?? ""
            if let existing, existing.isCustomSlug { addressDraft = existing.slug }
        }
    }

    private func submit() {
        guard !isPublishing, let accessChange, case .some(let slug) = addressChange else { return }
        errorMessage = nil
        publishTask = Task {
            do {
                let status = try await publish(accessChange, slug)
                guard !Task.isCancelled else { return }
                publishTask = nil
                result = status
                published(status)
            } catch is CancellationError {
                publishTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                publishTask = nil
            }
        }
    }
}


/// The doc as a page: the HTML foreverlm.com renders from the doc's current
/// text, shown in a web view inside the Docs pane. Links out of the page open
/// in the browser; the page's own anchors work in place; and its **Add to
/// library** controls, which on the web hand the address to Web Studio, here
/// file the source straight into this Mac's library through the same import the
/// pane's reference cards use. Spec: docs/docs-design.md → Publishing.
///
/// With `editing` set the page's Edit mode is on: a hover over a block offers
/// **Edit**, the writer's instruction comes back as `onEditMessage`, and the
/// review state is drawn on the page after each load (`ForeverLMPage.review`).
/// Spec: docs/docs-design.md → Edit with AI → On the page.
/// The Page view's web view. The app-wide key monitor normally claims Cmd+F
/// before it reaches this view; this is the fallback for a press that arrives
/// here anyway, so the shortcut never dies in the web process — the same
/// fallback the editor's `ArtifactEditorWebView` keeps.
final class DocPageWebView: WKWebView {
    weak var findState: ReaderFindState?

    /// No Apple Intelligence badge on a selection (`SharedWebKit.allowsWritingToolsAffordance(in:)`).
    @objc(allowsWritingToolsAffordance)
    var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }
    /// macOS 27.0.1 shows the badge without asking the property above; an empty
    /// selection rect keeps it hidden (`SharedWebKit.unionRectInVisibleSelectedRange(in:)`).
    @objc(unionRectInVisibleSelectedRange)
    var unionRectInVisibleSelectedRange: NSRect { SharedWebKit.unionRectInVisibleSelectedRange(in: self) }

    override func keyDown(with event: NSEvent) {
        if event.isCommandFindShortcut, let findState {
            findState.show()
            return
        }
        super.keyDown(with: event)
    }
}

struct ArtifactPageWebView: NSViewRepresentable {
    let html: String
    /// The Edit mode's state, or nil for a page that only reads (a team Doc).
    var editing: DocPageEditing? = nil
    let onAddToLibrary: (String) -> Void
    var onEditMessage: (DocPageEditMessage) -> Void = { _ in }
    /// The block's own Markdown for the page's Edit text, or nil when the
    /// marks no longer fit the draft.
    var sourceForLines: (Int, Int) -> String? = { _, _ in nil }
    /// Find-in-doc on the rendered page, driven the way the editor and every
    /// reader drive it: the bar bumps `findRevision`, and WebKit's own find
    /// selects the match and scrolls it into view. Nil for a page with no find
    /// bar over it.
    var findState: ReaderFindState? = nil
    var findRevision: Int = 0

    /// False while Pages is kept mounted behind another tab of its pane.
    @Environment(\.studioPaneTabIsShown) private var paneTabIsShown

    static let editMessageHandlerName = "foreverLMPage"
    /// The address a page is rendered under, so its relative links resolve
    /// against the site; the handler listens to this origin only.
    static let previewBaseURL = URL(string: "https://foreverlm.com/share/preview")!

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: config)
        SharedWebKit.disableSystemWritingTools(on: config)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: Self.editMessageHandlerName)
        let webView = DocPageWebView(frame: .zero, configuration: config)
        webView.findState = findState
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        StudioKeptPaneTabs.apply(isShown: paneTabIsShown, to: webView)
        context.coordinator.parent = self
        context.coordinator.load(html, into: webView)
        context.coordinator.applyEditing(to: webView)
        (webView as? DocPageWebView)?.findState = findState
        if let findState {
            context.coordinator.performFindIfNeeded(in: webView, revision: findRevision, state: findState)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? DocPageWebView)?.findState = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: editMessageHandlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: ArtifactPageWebView
        private var loadedHTML: String?
        /// The Edit state the loaded page was last told; a load clears it.
        private var appliedEditing: DocPageEditing??
        private var isLoaded = false
        private var lastFindRevision = 0

        init(parent: ArtifactPageWebView) {
            self.parent = parent
        }

        /// One search per press of Return or the chevrons. Run outside the
        /// update pass: the result lands in `statusText`, which is view state.
        func performFindIfNeeded(in webView: WKWebView, revision: Int, state: ReaderFindState) {
            guard revision > 0, revision != lastFindRevision else { return }
            lastFindRevision = revision
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                ReaderFindPerformer.performWebFind(
                    in: webView,
                    state: state,
                    query: state.query,
                    backwards: state.searchesBackward
                )
            }
        }

        func load(_ html: String, into webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            isLoaded = false
            appliedEditing = nil
            // The page's relative links (its Markdown address, the favicon)
            // resolve against the site, and the page's own script runs: it is
            // ours, and the web view applies no policy of its own.
            webView.loadHTMLString(html, baseURL: ArtifactPageWebView.previewBaseURL)
        }

        /// Tell the page its Edit state: on, and what to draw for the request
        /// in flight. Runs once the page has loaded and again whenever the
        /// state changes, so a proposal drawn into a fresh page and a failure
        /// shown on the page already there take the same path.
        func applyEditing(to webView: WKWebView) {
            guard isLoaded else { return }
            let editing = parent.editing
            if case .some(let applied) = appliedEditing, applied == editing { return }
            appliedEditing = .some(editing)
            let script: String
            if let editing {
                let review = editing.review.map(\.json) ?? "null"
                script = "if (window.ForeverLMPage) { window.ForeverLMPage.enableEditing(); window.ForeverLMPage.review(\(review)); } true;"
            } else {
                script = "if (window.ForeverLMPage) { window.ForeverLMPage.disableEditing(); } true;"
            }
            webView.evaluateJavaScript(script) { _, _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            applyEditing(to: webView)
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the rendered page itself, at the address it is rendered
            // under (`load(_:into:)`), never a frame inside it or a page it
            // navigated to (`ScriptMessageSender`). WebKit delivers on main.
            let base = ArtifactPageWebView.previewBaseURL
            let fromPage = MainActor.assumeIsolated {
                message.isFrom(.appOrigin(scheme: base.scheme ?? "", host: base.host ?? ""))
            }
            guard fromPage, message.name == ArtifactPageWebView.editMessageHandlerName else { return }
            let body = message.body
            let webView = message.webView
            Task { @MainActor in
                guard let parsed = DocPageEditMessage(body: body) else { return }
                if case .sourceRequested(let start, let end) = parsed {
                    // Answered here, with the draft the host holds: the page
                    // shows the lines in a field and posts textEdited back.
                    guard let markdown = parent.sourceForLines(start, end), let webView else { return }
                    let payload: [String: Any] = ["start": start, "end": end, "markdown": markdown]
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let json = String(data: data, encoding: .utf8) else { return }
                    webView.evaluateJavaScript("if (window.ForeverLMPage) { window.ForeverLMPage.source(\(json)); } true;") { _, _ in }
                    return
                }
                parent.onEditMessage(parsed)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // A link in a frame inside the page (a Visualize block runs
            // model-written script, and a script can click) is not the
            // page's own, and opens nothing.
            guard navigationAction.sourceFrame.isMainFrame else {
                decisionHandler(.cancel)
                return
            }
            // A jump within the page — contents, a citation chip, a directory card.
            if url.fragment != nil, url.host?.lowercased() == "foreverlm.com", url.path.hasPrefix("/share/") {
                decisionHandler(.allow)
                return
            }
            if let add = Self.addToLibraryTarget(url) {
                parent.onAddToLibrary(add)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // `target="_blank"` links: source cards and external references,
            // the page's own only.
            guard navigationAction.sourceFrame.isMainFrame else { return nil }
            if let url = navigationAction.request.url {
                if let add = Self.addToLibraryTarget(url) { parent.onAddToLibrary(add) } else { NSWorkspace.shared.open(url) }
            }
            return nil
        }

        /// The address a page's Add to library control carries, when `url` is one.
        static func addToLibraryTarget(_ url: URL) -> String? {
            guard url.host?.lowercased() == "app.foreverlm.com",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let add = components.queryItems?.first(where: { $0.name == "add" })?.value,
                  add.lowercased().hasPrefix("http") else { return nil }
            return add
        }
    }
}


/// What the Page view's Edit mode is showing: on, with the review for the
/// request in flight, if any.
struct DocPageEditing: Equatable {
    var review: DocPageEditReview?
}
