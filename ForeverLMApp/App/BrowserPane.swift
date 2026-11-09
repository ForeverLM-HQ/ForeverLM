import AppKit
import SwiftUI
import WebKit

/// The Browser center tab: a WebKit browser inside ForeverLM.
///
/// It is here for two things the readers cannot do. A page can be signed in
/// to under a **profile** — a cookie jar of its own — so ChatGPT can run on
/// one Google account while the Google Drive plugin, which signs in
/// through the system browser and keeps an OAuth token in the keychain,
/// stays on another. And any page can be added to Sources from where it is
/// read, with the page the browser rendered standing in for a fetch the
/// publisher would refuse a headless client.
struct BrowserPane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    /// The pane of a side browser (`StudioCenterTab.secondaryBrowser`), whose
    /// tabs are its own; nil for the window's Browser.
    var sidePaneID: UUID? = nil

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    @State private var addingPageKey: String?
    @State private var savedPageKeys: Set<String> = []
    @State private var isManagingProfiles = false
    @State private var newProfileName = ""
    @State private var isNamingProfile = false
    /// Find in the page, one bar for the pane: Cmd+F opens it over the active
    /// tab, Return and the chevrons step through WebKit's matches, Escape
    /// closes it. Switching tabs puts it away — the query belonged to the page
    /// that left.
    @State private var findState = ReaderFindState()

    private var workspace: BrowserWorkspace {
        if let sidePaneID, let side = BrowserWorkspace.existing(forSidePane: sidePaneID) { return side }
        return BrowserWorkspace.forWindow(windowState.id)
    }

    var body: some View {
        let workspace = workspace
        let activeTab = workspace.activeTab
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                BrowserTabStrip(workspace: workspace)
                Divider()
            }
            if let activeTab {
                ReaderFindBar(state: findState, prompt: "Find in page")
                ZStack(alignment: .top) {
                    BrowserWebViewHostView(workspace: workspace, tab: activeTab, findState: findState)
                    VStack(spacing: 0) {
                        if let message = activeTab.loadErrorMessage {
                            loadErrorBanner(message, tab: activeTab)
                        }
                        if let url = activeTab.passkeyRequestURL {
                            passkeyBanner(url, tab: activeTab)
                        }
                    }
                }
            } else {
                startPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioChromeLineHeader {
            toolbar(workspace: workspace, tab: activeTab)
                .padding(.horizontal, 12)
                .background(WindowDragBlocker())
        }
        .studioCenterTabCloseChrome(for: .browser)
        .background {
            // Shortcuts a browser is expected to answer. Hidden buttons keep
            // them in the window's responder chain without drawing anything.
            Group {
                Button("") { addressFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                Button("") { openNewTab(profileID: BrowserWorkspace.newTabProfileID) }
                    .keyboardShortcut("t", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .background {
            // Cmd+F reaches the page while focus is anywhere in the pane — the
            // page, the address field, or the find bar itself — and from the
            // rest of the window when no reader holds focus: the same claim
            // every reader makes. The app-wide key monitor consumes the press
            // before WebKit sees it, so a hidden button would never fire.
            ReaderShortcutTarget(find: { findState.show() })
        }
        .onAppear {
            WebPagePolicy.library = vm
            consumeOpenRequest()
            syncAddress(from: activeTab)
        }
        .onChange(of: activeTab?.id) { _, _ in
            syncAddress(from: workspace.activeTab)
            findState.resetForDocumentChange()
        }
        .onChange(of: findState.searchRevision) { _, _ in
            performFind()
        }
        .onChange(of: activeTab?.url) { _, _ in
            guard !addressFocused else { return }
            syncAddress(from: workspace.activeTab)
        }
        .onChange(of: activeTab?.isLoading) { _, _ in
            notePageDeclaredIdentity(of: workspace.activeTab)
        }
        .onChange(of: vm.browserOpenRequest) { _, _ in
            consumeOpenRequest()
        }
        .onChange(of: workspace.notice) { _, notice in
            if let notice { vm.showToast(notice.message) }
        }
        .sheet(isPresented: $isManagingProfiles) {
            BrowserProfilesSheet(workspace: workspace)
        }
        .alert("New Profile", isPresented: $isNamingProfile) {
            TextField("Name", text: $newProfileName)
            Button("Create") {
                let profile = workspace.profiles.add(name: newProfileName)
                newProfileName = ""
                openNewTab(profileID: profile.id)
            }
            Button("Cancel", role: .cancel) { newProfileName = "" }
        } message: {
            Text("A profile keeps its own cookies and logins, separate from every other profile and from the readers.")
        }
    }

    // MARK: Find

    private func performFind() {
        guard findState.searchRevision > 0, let webView = workspace.activeTab?.webView else { return }
        ReaderFindPerformer.performWebFind(
            in: webView,
            state: findState,
            query: findState.query,
            backwards: findState.searchesBackward
        )
    }

    // MARK: Toolbar

    /// The full row when it fits; when the pane is narrow, the labelled
    /// buttons drop to icons so the address keeps its room.
    ///
    /// Quiet chrome (docs/ui-design.md, 2026-10-06): ‹ ›, the address (what
    /// the pane shows, with Reload or Stop at its trailing end, where Safari
    /// keeps it), Add to Sources on a page the library does not hold, the ⋯
    /// and the pane's ×. New Tab and the profiles, which stood on the line
    /// until then, are the ⋯'s.
    private func toolbar(workspace: BrowserWorkspace, tab: BrowserTab?) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(workspace: workspace, tab: tab, compact: false)
            toolbarRow(workspace: workspace, tab: tab, compact: true)
        }
    }

    private func toolbarRow(workspace: BrowserWorkspace, tab: BrowserTab?, compact: Bool) -> some View {
        HStack(spacing: 6) {
            navigationButton("chevron.left", help: "Back", enabled: tab?.canGoBack == true) {
                tab?.webView?.goBack()
            }
            .accessibilityIdentifier("studio.browser.back")
            navigationButton("chevron.right", help: "Forward", enabled: tab?.canGoForward == true) {
                tab?.webView?.goForward()
            }
            .accessibilityIdentifier("studio.browser.forward")

            addressField(workspace: workspace, tab: tab, compact: compact)

            if let url = addablePageURL(for: tab) {
                let state = addPageState(for: url)
                Button {
                    addCurrentPage(url, from: tab)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.systemImage)
                        if !compact {
                            Text(state.title)
                        }
                    }
                    .fixedSize()
                }
                .buttonStyle(.hoverWash)
                .disabled(!state.isEnabled)
                .help(state.help)
                .accessibilityIdentifier(ReaderTitlebarActionButton.addPageAccessibilityIdentifier)
            }

            moreMenu(workspace: workspace, tab: tab)
        }
    }

    private func navigationButton(
        _ systemImage: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.hoverWash)
        .disabled(!enabled)
        .help(help)
    }

    /// Reload, or Stop while the page loads: a small glyph inside the address
    /// field's trailing end.
    private func reloadButton(tab: BrowserTab?) -> some View {
        let isLoading = tab?.isLoading == true
        return Button {
            guard let tab else { return }
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
        } label: {
            Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.hoverWash(cornerRadius: 5, inset: 2, opacity: 0.10))
        .disabled(tab?.webView == nil)
        .help(isLoading ? "Stop" : "Reload")
        .accessibilityLabel(isLoading ? "Stop" : "Reload")
        .accessibilityIdentifier("studio.browser.reload")
    }

    private func addressField(workspace: BrowserWorkspace, tab: BrowserTab?, compact: Bool) -> some View {
        let profile = tab.map { workspace.profile(for: $0) }
        return HStack(spacing: 6) {
            if let profile, !profile.isLibrary, !compact {
                Text(profile.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .help("This tab is signed in under the \(profile.name) profile")
            }
            Image(systemName: addressIcon(for: tab))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search or enter an address", text: $addressText)
                .textFieldStyle(.plain)
                .focused($addressFocused)
                .onSubmit { submitAddress() }
                .onExitCommand {
                    addressFocused = false
                    syncAddress(from: tab)
                }
                .accessibilityIdentifier("studio.browser.address")
            if tab != nil {
                reloadButton(tab: tab)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, tab != nil ? 6 : 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .strokeBorder(addressFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .frame(minWidth: compact ? 80 : 160, maxWidth: .infinity)
    }

    private func addressIcon(for tab: BrowserTab?) -> String {
        guard let url = tab?.url else { return "magnifyingglass" }
        if url.scheme?.lowercased() == "https", tab?.hasOnlySecureContent != false { return "lock.fill" }
        return "globe"
    }

    /// Everything else the browser does, from one ⋯: New Tab, New Tab in ▸ a
    /// profile, New Profile…, Manage Profiles… (each profile keeps its own
    /// cookies and logins), Reload or Stop, and Find in Page. ⌘T and ⌘F stay
    /// the pane's own (`body`), so the items carry no shortcut of their own
    /// to compete with them. On the chrome line a SwiftUI `Menu` works
    /// because the row stands on a `WindowDragBlocker`.
    private func moreMenu(workspace: BrowserWorkspace, tab: BrowserTab?) -> some View {
        Menu {
            Button("New Tab", systemImage: "plus") {
                openNewTab(profileID: tab?.profileID ?? BrowserWorkspace.newTabProfileID)
            }
            Menu("New Tab in", systemImage: "person.crop.circle") {
                ForEach(workspace.profiles.profiles) { profile in
                    Button {
                        openNewTab(profileID: profile.id)
                    } label: {
                        let count = workspace.tabs(in: profile.id).count
                        if count > 0 {
                            Text("\(profile.name) — \(count) \(count == 1 ? "tab" : "tabs")")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
            Button("New Profile…") { isNamingProfile = true }
            Button("Manage Profiles…") { isManagingProfiles = true }
            if let tab, tab.webView != nil {
                Divider()
                if tab.isLoading {
                    Button("Stop", systemImage: "xmark") { tab.webView?.stopLoading() }
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") { tab.webView?.reload() }
                }
                Button("Find in Page", systemImage: "magnifyingglass") { findState.show() }
            }
        } label: {
            RowMoreActionsLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: New Tab (⌘T), profiles, Find in Page (⌘F)")
        .accessibilityLabel("More")
        .accessibilityIdentifier("studio.browser.more")
    }

    // MARK: Start page

    private var startPage: some View {
        let workspace = workspace
        return ContentUnavailableView {
            Label("Browser", systemImage: "safari")
        } description: {
            Text("Sign in to sites in their own profiles. A profile keeps its own cookies, so ChatGPT can use one Google account while Google Drive uses another. Any page can be added to Sources from here.")
        } actions: {
            HStack {
                Button("New Tab") { openNewTab(profileID: BrowserWorkspace.newTabProfileID) }
                    .buttonStyle(.borderedProminent)
                if workspace.profiles.profiles.count == 1 {
                    Button("New Profile…") { isNamingProfile = true }
                }
            }
        }
    }

    private func loadErrorBanner(_ message: String, tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Try Again") { tab.webView?.reload() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous))
        .padding(12)
    }

    /// A page asked for a passkey and this build cannot answer one
    /// (`BrowserPasskeySupport`): say so, and offer the page in the browser
    /// that can.
    private func passkeyBanner(_ url: URL, tab: BrowserTab) -> some View {
        let browser = BrowserPasskeySupport.externalBrowser
        let destination = browser?.name ?? "your browser"
        return HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .foregroundStyle(.secondary)
            Text("This page asked for a passkey, which ForeverLM's browser can't answer yet. Sign in another way here, or open the page in \(destination) to use your passkey.")
                .font(.callout)
                .lineLimit(3)
            Spacer()
            Button("Open in \(destination)") {
                BrowserPasskeySupport.openOutside(tab.url ?? url)
            }
            .controlSize(.small)
            Button {
                tab.passkeyRequestURL = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss passkey notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous))
        .padding(12)
        // A group of its own: on a plain container the identifier landed on
        // both buttons.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.passkeyNotice")
    }

    // MARK: Actions

    private func openNewTab(profileID: UUID) {
        workspace.openTab(url: nil, profileID: profileID)
        addressText = ""
        addressFocused = true
    }

    private func submitAddress() {
        guard let url = BrowserWorkspace.resolveAddress(addressText) else { return }
        if let tab = workspace.activeTab {
            workspace.load(url, in: tab)
        } else {
            workspace.openTab(url: url)
        }
        addressFocused = false
        addressText = BrowserWorkspace.displayAddress(for: url)
    }

    private func syncAddress(from tab: BrowserTab?) {
        addressText = BrowserWorkspace.displayAddress(for: tab?.url ?? tab?.requestedURL)
    }

    /// A page the view model asked the browser to show, from a source's
    /// "Open in Browser" or a chat link. The request is consumed once.
    private func consumeOpenRequest() {
        // "Open in Browser" is the window's Browser's; a side browser keeps
        // what it shows.
        guard sidePaneID == nil, let request = vm.browserOpenRequest else { return }
        vm.browserOpenRequest = nil
        workspace.openTab(url: request.url, profileID: request.profileID ?? BrowserWorkspace.newTabProfileID)
        addressFocused = false
    }

    // MARK: Add to Sources

    private func addablePageURL(for tab: BrowserTab?) -> URL? {
        guard let url = tab?.url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func pageKey(_ url: URL) -> String {
        SourceDiscovery.normalizedURL(url.absoluteString)
    }

    private func addPageState(for url: URL) -> ReaderAddPageToolbarState {
        let key = pageKey(url)
        return ReaderAddPageToolbarState(
            isAdding: addingPageKey == key,
            isSaved: savedPageKeys.contains(key) || vm.livePageIsAdded(url, in: windowState)
        )
    }

    /// View in Sources: the page is in the library, so open that source in
    /// the Reader — by address, by the DOI in the address, or by the DOI the
    /// loaded page declared about itself.
    private func openSavedSource(for url: URL) {
        guard let sourceID = vm.librarySourceID(forURL: url.absoluteString) else {
            vm.showToast("Already in Library")
            return
        }
        Task { await vm.revealSourceInReader(sourceID) }
    }

    /// The page in the active tab has finished loading; let the view model
    /// read which paper it says it is, so a PubMed page of a saved paper
    /// reads View in Sources rather than offering to add it again.
    private func notePageDeclaredIdentity(of tab: BrowserTab?) {
        guard let tab, !tab.isLoading, let webView = tab.webView,
              let pageURL = addablePageURL(for: tab) else { return }
        Task { @MainActor [weak webView] in
            guard let webView, webView.url?.absoluteString == pageURL.absoluteString,
                  let head = await WebViewReader.Coordinator.renderedPageHead(of: webView) else { return }
            await vm.notePageDeclaredIdentity(pageURLs: [pageURL], headHTML: head)
        }
    }

    /// The reader's Add to Sources (`addLivePageToSources`: the library, and
    /// the window's notebook when it is in one), plus one step the reader
    /// takes on its own: after the source exists, the page as this browser
    /// rendered it — signed in, past a bot check — is offered as the
    /// source's content when the fetch could not get it.
    private func addCurrentPage(_ url: URL, from tab: BrowserTab?) {
        let key = pageKey(url)
        let state = addPageState(for: url)
        if state.opensSavedSource {
            openSavedSource(for: url)
            return
        }
        vm.showToast(state.activationMessage)
        guard state == .available else { return }

        addingPageKey = key
        let webView = tab?.webView
        Task { @MainActor in
            await Task.yield()
            defer {
                if addingPageKey == key { addingPageKey = nil }
            }

            // Into the library, and into this window's notebook when it is
            // in one; the toast says where it went.
            let result = await vm.addLivePageToSources(url, in: windowState)
            if result.landed { savedPageKeys.insert(key) }
            guard let sourceID = result.addedSourceID else { return }
            await offerRenderedPage(of: webView, for: sourceID, expectedURL: url)
        }
    }

    /// Waits for the source's own fetch, then hands over the rendered page
    /// if the fetch left the source without text. Same order as the reader:
    /// a fetch that succeeds makes the page unnecessary, and a fetch the
    /// publisher blocks makes it the only copy there is.
    private func offerRenderedPage(of webView: WKWebView?, for articleID: String, expectedURL: URL) async {
        guard let webView else { return }
        var waitedSeconds = 0
        while waitedSeconds < 90, vm.sourceFetchIsInFlight(articleID) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waitedSeconds += 1
        }
        guard webView.url == expectedURL || webView.url?.absoluteString == expectedURL.absoluteString,
              vm.readerPageCanSupplySourceContent(articleID),
              let page = await WebViewReader.Coordinator.renderedPageSnapshot(of: webView) else { return }
        let adoption = await vm.adoptRenderedReaderPage(
            articleId: articleID,
            html: page.html,
            pageTitle: page.title,
            visibleText: page.text
        )
        if adoption == .adoptedArticle {
            vm.showToast("Saved the page as you see it")
        }
    }
}

// MARK: - Tab strip

private struct BrowserTabStrip: View {
    let workspace: BrowserWorkspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.tabs) { tab in
                    BrowserTabChip(
                        tab: tab,
                        profile: workspace.profile(for: tab),
                        isActive: tab.id == workspace.activeTabID,
                        select: { workspace.select(tab) },
                        close: { workspace.close(tab) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("studio.browser.tabs")
    }
}

private struct BrowserTabChip: View {
    let tab: BrowserTab
    let profile: BrowserProfile
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if tab.isDrivenByChat {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("A chat is working in this tab")
            } else if !profile.isLibrary {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .help(profile.name)
            }
            Text(tab.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
            // A background tab's × is built only under the pointer, the hidden
            // glyph holding its place: a button at opacity 0 is still a live
            // control, and while an assistive app reads the screen SwiftUI
            // walks every control in the window for each one an update
            // builds (2026-10-03).
            if showsClose {
                Button(action: close) {
                    closeGlyph
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            } else {
                closeGlyph
                    .hidden()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .fill(isActive
                      ? Color(nsColor: .controlBackgroundColor)
                      : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .strokeBorder(isActive ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        // The help goes below the combined element: above it, every child
        // carried it and the chip's help read three times over. The press is
        // the chip's own: combined, AXPress ran the Close button inside and
        // closed the tab, which stays offered as the Close action.
        .accessibilityElement(children: .combine)
        .help([tab.title, tab.url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityAction { select() }
        // Close for VoiceOver while the × is not built; while it is, the
        // combined chip carries its press as the Close action already.
        .accessibilityActions {
            if !showsClose {
                Button("Close Tab", action: close)
            }
        }
    }

    private var showsClose: Bool { hovering || isActive }

    private var closeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 16, height: 16)
    }
}

// MARK: - Web view host

/// Holds the active tab's web view. Frame-driven like the reader's host: the
/// same view moves in and out as tabs are switched, and constraints would
/// have to be torn down on every move.
final class BrowserWebViewHost: NSView {
    private(set) var webView: WKWebView?
    let progressBar = ReaderLoadProgressBar(frame: .zero)
    private var progressObservations: [NSKeyValueObservation] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(progressBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ webView: WKWebView, findState: ReaderFindState) {
        (webView as? ForeverLMWebView)?.findState = findState
        guard self.webView !== webView else { return }
        stopObservingProgress()
        self.webView?.removeFromSuperview()
        self.webView = webView
        webView.frame = bounds
        addSubview(webView, positioned: .below, relativeTo: progressBar)
        observeProgress(of: webView)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        progressBar.frame = CGRect(
            x: 0,
            y: bounds.height - ReaderLoadProgressBar.thickness,
            width: bounds.width,
            height: ReaderLoadProgressBar.thickness
        )
    }

    private func observeProgress(of webView: WKWebView) {
        let publish: (WKWebView) -> Void = { [weak self] webView in
            self?.progressBar.update(isLoading: webView.isLoading, estimatedProgress: webView.estimatedProgress)
        }
        progressObservations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { webView, _ in
                MainActor.assumeIsolated { publish(webView) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { publish(webView) }
            },
        ]
    }

    private func stopObservingProgress() {
        progressObservations.forEach { $0.invalidate() }
        progressObservations = []
        progressBar.reset()
    }
}

struct BrowserWebViewHostView: NSViewRepresentable {
    let workspace: BrowserWorkspace
    let tab: BrowserTab
    let findState: ReaderFindState

    func makeNSView(context: Context) -> BrowserWebViewHost {
        let host = BrowserWebViewHost(frame: .zero)
        host.install(workspace.webView(for: tab), findState: findState)
        return host
    }

    func updateNSView(_ host: BrowserWebViewHost, context: Context) {
        host.install(workspace.webView(for: tab), findState: findState)
    }
}

// MARK: - Profiles sheet

private struct BrowserProfilesSheet: View {
    let workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var pendingRemoval: BrowserProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles")
                    .font(.title2.weight(.semibold))
                Text("Each profile is a separate set of cookies and logins. Library is the one the readers and paper downloads share; the others are the browser's alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(workspace.profiles.profiles) { profile in
                    BrowserProfileRow(
                        profile: profile,
                        tabCount: workspace.tabs(in: profile.id).count,
                        rename: { workspace.profiles.rename(profile.id, to: $0) },
                        remove: { pendingRemoval = profile }
                    )
                    if profile.id != workspace.profiles.profiles.last?.id {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack {
                TextField("New profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addProfile)
                Button("Add", action: addProfile)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "profile")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { profile in
            Button("Remove Profile and Its Logins", role: .destructive) {
                Task { await workspace.removeProfile(profile.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            let count = workspace.tabs(in: profile.id).count
            Text(count > 0
                 ? "Its \(count) open \(count == 1 ? "tab closes" : "tabs close") and every cookie and login it holds is deleted."
                 : "Every cookie and login it holds is deleted.")
        }
    }

    private func addProfile() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        workspace.profiles.add(name: name)
        newName = ""
    }
}

private struct BrowserProfileRow: View {
    let profile: BrowserProfile
    let tabCount: Int
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var draftName = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.isLibrary ? "books.vertical" : "person.crop.circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            if profile.isLibrary {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                    Text("Shared with the readers and paper downloads")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { _, isEditing in
                        if !isEditing { commit() }
                    }
            }
            Spacer()
            if tabCount > 0 {
                Text("\(tabCount) \(tabCount == 1 ? "tab" : "tabs")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !profile.isLibrary {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this profile and its logins")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { draftName = profile.name }
        .onChange(of: profile.name) { _, name in
            if !editing { draftName = name }
        }
    }

    private func commit() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != profile.name else {
            draftName = profile.name
            return
        }
        rename(name)
    }
}
