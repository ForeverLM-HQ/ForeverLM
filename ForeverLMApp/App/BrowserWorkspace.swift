import AppKit
import Foundation
import Observation
import Security
import WebKit

// MARK: - Profiles

/// A named cookie jar.
///
/// The browser exists so a learner can be signed in to two Google accounts at
/// once — ChatGPT on one, the Google Drive plugin on another — and the
/// web has exactly one mechanism for that: separate website data stores.
/// The **Library** profile is `WKWebsiteDataStore.default()`, the jar every
/// reader and every paper fetch already share, so a publisher sign-in made
/// there serves the whole app. Every other profile is a persistent store of
/// its own (`WKWebsiteDataStore(forIdentifier:)`) that nothing else reads:
/// a login there is invisible to the readers, to the paper pipeline and to
/// the other profiles.
struct BrowserProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String

    static let libraryID = UUID(uuidString: "6B1B9A6C-0F5B-4F9A-9C8E-000000000001")!
    static let library = BrowserProfile(id: libraryID, name: "Library")

    var isLibrary: Bool { id == Self.libraryID }
}

/// The profile list, persisted locally. Profiles are per Mac on purpose:
/// their data stores live on this disk and nothing else, so a synced list
/// would name jars another Mac does not have.
@MainActor
@Observable
final class BrowserProfileStore {
    static let profilesKey = "browser.profiles.v1"

    /// The app's one profile list: every window's Browser pane and every
    /// linked page read the same jars, so a profile made in one window is
    /// offered in the next.
    static let shared = BrowserProfileStore()

    private let defaults: UserDefaults
    private(set) var profiles: [BrowserProfile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [BrowserProfile] = []
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([BrowserProfile].self, from: data) {
            loaded = decoded
        }
        profiles = Self.withLibraryFirst(loaded)
    }

    func profile(id: UUID) -> BrowserProfile? {
        profiles.first { $0.id == id }
    }

    /// Every profile but the given one: the jars a page could switch to. A
    /// linked page's "Use another account" offers these before it makes a new
    /// jar, because a profile signed in once keeps that sign-in on disk, and
    /// reassigning the page to it is the switch — no second login.
    func profiles(otherThan id: UUID) -> [BrowserProfile] {
        profiles.filter { $0.id != id }
    }

    /// Adds a profile with a fresh, empty data store. A blank or duplicate
    /// name gets a number so two jars are never indistinguishable in a menu.
    @discardableResult
    func add(name: String) -> BrowserProfile {
        let profile = BrowserProfile(id: UUID(), name: Self.uniqueName(name, among: profiles))
        profiles.append(profile)
        persist()
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        guard id != BrowserProfile.libraryID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let others = profiles.filter { $0.id != id }
        profiles[index].name = Self.uniqueName(name, among: others)
        persist()
    }

    /// Forgets a profile and deletes its cookies, storage and caches. The
    /// caller closes the profile's tabs first: WebKit refuses to remove a
    /// store a live web view still holds.
    func remove(_ id: UUID) async {
        guard id != BrowserProfile.libraryID else { return }
        profiles.removeAll { $0.id == id }
        persist()
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    func dataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        profile.isLibrary ? .default() : WKWebsiteDataStore(forIdentifier: profile.id)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
    }

    static func withLibraryFirst(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        var result = profiles.filter { !$0.isLibrary }
        result.insert(.library, at: 0)
        return result
    }

    static func uniqueName(_ proposed: String, among profiles: [BrowserProfile]) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Profile" : trimmed
        let taken = Set(profiles.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

/// Which browser profile a linked page — a Codex site, a Claude artifact, a
/// Google Doc in the Docs and Sites panes — opens under. Unassigned pages use
/// Library, the jar those panes have always shared with the readers; a page
/// assigned to a profile signs in as that profile does. Local, like the
/// profiles themselves: the jars are on this Mac.
@MainActor
@Observable
final class LinkedPageProfiles {
    static let key = "browser.linkedPageProfiles.v1"
    static let shared = LinkedPageProfiles()

    private let defaults: UserDefaults
    private var assignments: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assignments = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// The profile the page opens under; Library when none is assigned or
    /// the assigned profile no longer exists.
    func profile(for artifactID: String, in store: BrowserProfileStore) -> BrowserProfile {
        guard let raw = assignments[artifactID], let id = UUID(uuidString: raw),
              let profile = store.profile(id: id) else { return .library }
        return profile
    }

    func assign(_ profileID: UUID?, to artifactID: String) {
        if let profileID, profileID != BrowserProfile.libraryID {
            assignments[artifactID] = profileID.uuidString
        } else {
            assignments.removeValue(forKey: artifactID)
        }
        defaults.set(assignments, forKey: Self.key)
    }
}

// MARK: - Tabs

/// One page in one profile. The web view is created the first time the tab
/// is shown, so a restored session of twenty tabs costs one web process at
/// launch, not twenty.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let profileID: UUID
    /// What the address bar shows before the first navigation commits, and
    /// what a restored tab loads when it is first shown.
    var requestedURL: URL?
    var url: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var estimatedProgress = 0.0
    var hasOnlySecureContent = false
    /// The last navigation failure, cleared by the next load that commits.
    var loadErrorMessage: String?
    /// The page that asked for a passkey while this app cannot answer one
    /// (`BrowserPasskeySupport`), for the pane to offer in the default
    /// browser. Cleared by a load the learner starts, a commit on another
    /// host, or the notice's own ×.
    var passkeyRequestURL: URL?
    /// True for the tab a chat opened and drives (`StudioChatBrowserAgent`).
    /// The strip marks it, and it renders in the chat's hidden host while no
    /// pane shows it.
    var isDrivenByChat = false

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored fileprivate var controller: BrowserTabController?

    init(id: UUID = UUID(), profileID: UUID, requestedURL: URL?) {
        self.id = id
        self.profileID = profileID
        self.requestedURL = requestedURL
        self.url = requestedURL
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = (url ?? requestedURL)?.host { return host }
        return "New Tab"
    }

    fileprivate func attach(_ webView: WKWebView, controller: BrowserTabController) {
        self.webView = webView
        self.controller = controller
    }

    fileprivate func detach() {
        controller?.stop()
        controller = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}

/// A restored session: which pages were open, in which profiles.
struct BrowserSessionSnapshot: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var profileID: UUID
        var url: URL?
        var title: String
    }

    var tabs: [Tab]
    var activeIndex: Int?
}

// MARK: - Workspace

/// The tabs of one window's Browser pane.
///
/// One workspace per Studio window: an `NSView` has one superview, so two
/// windows showing the Browser tab cannot share web views. The first
/// workspace created in a launch restores the saved session and is the one
/// that keeps saving it; later windows start with a blank tab.
@MainActor
@Observable
final class BrowserWorkspace {
    static let sessionKey = "browser.session.v1"

    /// New tabs start here. The Library profile, so a page saved from the
    /// start of a session lands where the readers can use its cookies.
    nonisolated static let newTabProfileID = BrowserProfile.libraryID

    let profiles: BrowserProfileStore
    private(set) var tabs: [BrowserTab] = []
    var activeTabID: UUID? {
        didSet { persistSession() }
    }
    /// Emitted for the pane to show as a toast: a finished download, a
    /// refused popup.
    var notice: BrowserNotice?

    private let defaults: UserDefaults
    private let persistsSession: Bool
    /// Whether WebKit can answer a page's passkey call in this process; when
    /// it cannot, every tab's page reports the call instead.
    let answersPasskeys: Bool

    struct BrowserNotice: Equatable {
        let message: String
        let token = UUID()
    }

    // MARK: Per-window registry

    private static var byWindow: [UUID: BrowserWorkspace] = [:]
    private static var sessionOwnerWindow: UUID?
    /// Side browsers (`StudioCenterTab.secondaryBrowser`): one workspace per
    /// pane, with the window that pane is in, so pruning one window's panes
    /// never closes another's. They neither restore nor save the session.
    private static var bySidePane: [UUID: (window: UUID, workspace: BrowserWorkspace)] = [:]

    /// The workspace of the side browser in `paneID`'s pane, made the first
    /// time with one tab on `url` (blank when nil).
    static func forSidePane(_ paneID: UUID, inWindow windowID: UUID, startingAt url: URL?) -> BrowserWorkspace {
        if let existing = bySidePane[paneID] { return existing.workspace }
        let workspace = BrowserWorkspace(profiles: BrowserProfileStore.shared)
        workspace.openTab(url: url)
        bySidePane[paneID] = (windowID, workspace)
        return workspace
    }

    /// A side browser's workspace if its pane has drawn, without making one.
    static func existing(forSidePane paneID: UUID) -> BrowserWorkspace? {
        bySidePane[paneID]?.workspace
    }

    /// Lets go of `windowID`'s side browsers whose panes are gone, and with
    /// them their web views.
    static func releaseSidePanes(inWindow windowID: UUID, keeping live: Set<UUID>) {
        bySidePane = bySidePane.filter { $0.value.window != windowID || live.contains($0.key) }
    }

    /// The workspace a chat's tab joins: the front Studio window's, so the
    /// tab is where the learner looks when the chat's preview is clicked;
    /// failing a registered window, the one that owns the session.
    static func forChatTabs() -> BrowserWorkspace {
        let registry = StudioWindowRegistry.shared
        if let active = registry.activeState { return forWindow(active.id) }
        if let owner = sessionOwnerWindow { return forWindow(owner) }
        if let any = registry.states.first { return forWindow(any.id) }
        // No Studio window registered — a chat outside one. A workspace of
        // its own, so it neither claims nor restores the saved session.
        return BrowserWorkspace(profiles: BrowserProfileStore.shared)
    }

    /// The Studio window whose Browser pane shows a workspace's tabs.
    static func windowID(of workspace: BrowserWorkspace) -> UUID? {
        byWindow.first { $0.value === workspace }?.key
    }

    /// The workspace a Studio window already has, without creating one: a
    /// look at what the Browser shows must not claim the saved session.
    static func existing(forWindow windowID: UUID) -> BrowserWorkspace? {
        byWindow[windowID]
    }

    /// The workspace for a Studio window, created on first use.
    static func forWindow(_ windowID: UUID) -> BrowserWorkspace {
        if let existing = byWindow[windowID] { return existing }
        let ownsSession = sessionOwnerWindow == nil
        if ownsSession { sessionOwnerWindow = windowID }
        let workspace = BrowserWorkspace(
            profiles: BrowserProfileStore.shared,
            defaults: .standard,
            restoreSession: ownsSession,
            persistSession: ownsSession
        )
        byWindow[windowID] = workspace
        return workspace
    }

    init(
        profiles: BrowserProfileStore,
        defaults: UserDefaults = .standard,
        restoreSession: Bool = false,
        persistSession: Bool = false,
        answersPasskeys: Bool = BrowserPasskeySupport.appAnswersPasskeys
    ) {
        self.profiles = profiles
        self.defaults = defaults
        self.persistsSession = persistSession
        self.answersPasskeys = answersPasskeys
        if restoreSession,
           let data = defaults.data(forKey: Self.sessionKey),
           let snapshot = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data) {
            restore(snapshot)
        }
    }

    var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func profile(for tab: BrowserTab) -> BrowserProfile {
        profiles.profile(id: tab.profileID) ?? .library
    }

    func tabs(in profileID: UUID) -> [BrowserTab] {
        tabs.filter { $0.profileID == profileID }
    }

    // MARK: Opening and closing

    /// Opens a tab. `beside` puts it right after a tab — where a popup or a
    /// "new tab" from a page belongs — rather than at the end of the strip.
    @discardableResult
    func openTab(
        url: URL?,
        profileID: UUID = BrowserWorkspace.newTabProfileID,
        beside anchor: BrowserTab? = nil,
        activate: Bool = true
    ) -> BrowserTab {
        let resolvedProfile = profiles.profile(id: profileID) ?? .library
        let tab = BrowserTab(profileID: resolvedProfile.id, requestedURL: url)
        if let anchor, let index = tabs.firstIndex(where: { $0.id == anchor.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if activate || activeTabID == nil {
            activeTabID = tab.id
        } else {
            persistSession()
        }
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        activeTabID = tab.id
    }

    /// Closes a tab and, when it was the active one, moves to its right-hand
    /// neighbour, or the left-hand one at the end of the strip.
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tab.detach()
        if activeTabID == tab.id {
            if tabs.isEmpty {
                activeTabID = nil
            } else {
                activeTabID = tabs[min(index, tabs.count - 1)].id
            }
        } else {
            persistSession()
        }
    }

    /// Closes every tab in a profile — the step before the profile itself
    /// can be removed.
    func closeTabs(in profileID: UUID) {
        for tab in tabs(in: profileID) { close(tab) }
    }

    /// Removes a profile: its tabs first, then the store behind them.
    func removeProfile(_ id: UUID) async {
        closeTabs(in: id)
        await profiles.remove(id)
    }

    // MARK: Navigation

    /// Loads what the learner typed into the address bar.
    func load(address: String, in tab: BrowserTab) {
        guard let url = Self.resolveAddress(address) else { return }
        load(url, in: tab)
    }

    func load(_ url: URL, in tab: BrowserTab) {
        tab.requestedURL = url
        tab.loadErrorMessage = nil
        tab.passkeyRequestURL = nil
        if let webView = tab.webView {
            webView.load(URLRequest(url: url))
        } else {
            tab.url = url
            persistSession()
        }
    }

    /// The web view for a tab, created on first request in the tab's
    /// profile and started on the tab's URL.
    func webView(for tab: BrowserTab) -> WKWebView {
        if let webView = tab.webView { return webView }
        let configuration = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: configuration)
        configuration.websiteDataStore = profiles.dataStore(for: profile(for: tab))
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // A YouTube player a page embeds shows no suggestions; a popup copies
        // this configuration, rule list included.
        YouTubeDistractionFilter.attach(to: configuration.userContentController)
        if !answersPasskeys {
            // A popup copies its opener's configuration, controller included,
            // so this is the one place the script and handler are installed.
            BrowserPasskeySupport.installReporting(in: configuration.userContentController, workspace: self)
        }
        let webView = makeWebView(configuration: configuration, for: tab)
        if let url = tab.requestedURL ?? tab.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// A popup (`window.open`, `target="_blank"`) becomes a tab beside the
    /// page that opened it, in the same profile. WebKit hands over the
    /// configuration the popup must be created with — that is what ties the
    /// new page to the opener's session, which is how a "Continue with
    /// Google" popup signs the opener in.
    func openPopup(from opener: BrowserTab, configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = openTab(url: nil, profileID: opener.profileID, beside: opener, activate: true)
        return makeWebView(configuration: configuration, for: tab)
    }

    private func makeWebView(configuration: WKWebViewConfiguration, for tab: BrowserTab) -> WKWebView {
        let webView = ForeverLMWebView(frame: .zero, configuration: configuration)
        // A page's own text field keeps Ctrl+F as "move forward".
        webView.findTakesControlF = false
        // The stock WKWebView agent lacks Safari's version tokens, and Google's
        // sign-in refuses agents it takes for an embedded view.
        webView.customUserAgent = SharedWebKit.desktopSafariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        let controller = BrowserTabController(tab: tab, workspace: self)
        webView.navigationDelegate = controller
        webView.uiDelegate = controller
        controller.observe(webView)
        tab.attach(webView, controller: controller)
        return webView
    }

    // MARK: Passkeys

    /// A page in one of the tabs called `navigator.credentials` for a
    /// passkey. Marks that tab so the pane can offer the page in the default
    /// browser, where the call is answered.
    func passkeyRequested(in webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        tab.passkeyRequestURL = webView.url ?? tab.url ?? tab.requestedURL
    }

    // MARK: Session

    func persistSession() {
        guard persistsSession else { return }
        let snapshot = BrowserSessionSnapshot(
            tabs: tabs.map { .init(profileID: $0.profileID, url: $0.url ?? $0.requestedURL, title: $0.title) },
            activeIndex: tabs.firstIndex { $0.id == activeTabID }
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.sessionKey)
        }
    }

    private func restore(_ snapshot: BrowserSessionSnapshot) {
        let known = Set(profiles.profiles.map(\.id))
        tabs = snapshot.tabs.map { saved in
            let tab = BrowserTab(
                profileID: known.contains(saved.profileID) ? saved.profileID : BrowserProfile.libraryID,
                requestedURL: saved.url
            )
            tab.title = saved.title
            return tab
        }
        if let index = snapshot.activeIndex, tabs.indices.contains(index) {
            activeTabID = tabs[index].id
        } else {
            activeTabID = tabs.first?.id
        }
    }

    // MARK: Addresses

    /// What the address bar means. A scheme is taken as typed; a bare host
    /// or path becomes https; anything with a space, or with no dot and no
    /// port, is a search.
    static func resolveAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil,
           let url = URL(string: trimmed) {
            return url
        }
        if trimmed.lowercased().hasPrefix("about:"), let url = URL(string: trimmed) {
            return url
        }
        if trimmed.contains(" ") {
            return searchURL(for: trimmed)
        }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let looksLikeHost = hostPart == "localhost"
            || hostPart.hasPrefix("localhost:")
            || hostPart.contains(".")
            || hostPart.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?$"#, options: .regularExpression) != nil
        if looksLikeHost, let url = URL(string: "https://\(trimmed)"), url.host != nil {
            return url
        }
        return searchURL(for: trimmed)
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// The address bar's text for a page: the scheme is dropped for https,
    /// which is the default, and kept for anything else, so the learner sees
    /// an http page for what it is.
    static func displayAddress(for url: URL?) -> String {
        guard let url else { return "" }
        var text = url.absoluteString
        if url.scheme?.lowercased() == "https" {
            text = String(text.dropFirst("https://".count))
        }
        if text.hasSuffix("/"), url.path == "/" || url.path.isEmpty, url.query == nil, url.fragment == nil {
            text.removeLast()
        }
        return text
    }
}

// MARK: - Page policy

/// What a click and a response become, in every ForeverLM web view: a Browser
/// tab and a source's reader follow the same rules, which are a browser's.
///
/// A page is shown whatever its address looks like. The reader used to guess
/// from the address that a link was a PDF and save whatever came back; SSRN's
/// Download This Paper (`Delivery.cfm/….pdf`) answers with a page first — a
/// Cloudflare check, a sign-in — and the saved page read "That link opened a
/// page, not a PDF" where any browser would have run it and received the file
/// (2026-09-23). Only the response decides: a PDF on a paper's page is caught
/// and attached to the paper, another file goes to Downloads, a page is shown.
enum WebPagePolicy {
    enum ActionDecision: Equatable {
        case allow
        case download
        /// `mailto:`, `zoommtg:` and the like belong to another app.
        case openInOtherApp
        case cancel
        /// A YouTube video the page would leave for: it plays in the Reader's
        /// one-video player instead (`YouTubeContainment`).
        case openYouTubeVideo(URL)
        /// A page of YouTube's own that is not a video — the home feed, a
        /// channel, search: it does not open inside ForeverLM.
        case refuseYouTubePage
    }

    enum ResponseDecision: Equatable {
        case show
        /// A file to save to Downloads.
        case download
        /// A PDF the web view's paper is waiting for.
        case capturePDF
    }

    /// Schemes a web view renders itself.
    static func isWebScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme)
    }

    static func action(
        for url: URL?,
        isLinkActivated: Bool,
        isMainFrame: Bool,
        shouldPerformDownload: Bool
    ) -> ActionDecision {
        guard let url else { return .allow }
        if !isWebScheme(url) {
            return isLinkActivated || isMainFrame ? .openInOtherApp : .cancel
        }
        // A frame's YouTube player stays; its suggestions are hidden
        // (`YouTubeDistractionFilter`). The page itself never becomes YouTube.
        if isMainFrame {
            switch YouTubeContainment.decision(for: url) {
            case .video(let watchURL): return .openYouTubeVideo(watchURL)
            case .refused: return .refuseYouTubePage
            case .notYouTube: break
            }
        }
        return shouldPerformDownload ? .download : .allow
    }

    /// Where a YouTube video a page would have left for goes: the Reader,
    /// which plays a saved one as its source and any other in its player as a
    /// page not saved, with Add to Sources over it.
    @MainActor
    static func openYouTubeVideo(_ watchURL: URL) {
        library?.openWebCitationInReader(watchURL)
    }

    /// Why a click on one of YouTube's other pages did nothing.
    @MainActor
    static func refuseYouTubePage() {
        library?.showToast(YouTubeContainment.refusalMessage)
    }

    /// - Parameter capturesPDFs: whether this web view shows a paper still
    ///   waiting for its PDF, so a PDF it receives is that paper's.
    static func response(
        url: URL?,
        mimeType: String?,
        contentDisposition: String?,
        canShowMIMEType: Bool,
        capturesPDFs: Bool
    ) -> ResponseDecision {
        let mime = mimeType?.lowercased() ?? ""
        let disposition = contentDisposition?.lowercased() ?? ""
        let isAttachment = disposition.contains("attachment")
        if isPDF(url: url, mimeType: mime, contentDisposition: disposition) {
            if capturesPDFs { return .capturePDF }
            return isAttachment || !canShowMIMEType ? .download : .show
        }
        if !canShowMIMEType || isAttachment { return .download }
        return .show
    }

    /// A PDF by its type, or a generic binary a publisher names as one.
    static func isPDF(url: URL?, mimeType: String, contentDisposition: String) -> Bool {
        if mimeType == "application/pdf" || mimeType == "application/x-pdf" { return true }
        let genericBinary = ["application/octet-stream", "binary/octet-stream", "application/force-download", "application/download"]
        guard genericBinary.contains(mimeType) else { return false }
        return contentDisposition.contains(".pdf") || url?.pathExtension.lowercased() == "pdf"
    }

    /// The library the web views attach captured PDFs to. The Studio's view
    /// model, set by the first reader or Browser pane to appear; weak, so a
    /// torn-down model is never written to.
    @MainActor static weak var library: StudioViewModel?

    /// The paper whose page this is, while it still needs a PDF. A Browser
    /// tab uses it to catch the PDF a paper's own page hands over; the reader
    /// knows its paper already.
    @MainActor
    static func paperNeedingPDF(onPage pageURL: URL?) -> String? {
        guard let pageURL, let library,
              let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let key = SourceDiscovery.normalizedURL(pageURL.absoluteString)
        return library.articles.first {
            SourceDiscovery.normalizedURL($0.url) == key
                && (($0.sourceType == .paper
                        && $0.paperAttentionReason(hasUsablePDF: $0.cachedHasUsablePDF) == .pdfNeeded)
                    || awaitsDocumentPDF(sourceType: $0.sourceType, isUnreadable: $0.hasPaywallMarker || $0.state == .error))
        }?.id
    }

    /// The paper a source's reader gives the PDFs its pages lead to: the
    /// source itself, and only when it is a paper. An article or a post links
    /// to papers as its references; a PDF one of those links opens is that
    /// other paper, and taking it as the source's turned the article being
    /// read into that paper and archived the library's own copy of it.
    ///
    /// The one exception is an article the app could not read — a publisher
    /// check or a paywall answered its fetch — which is waiting for the
    /// learner to hand it its document. Its reader is where the learner gets
    /// past the check, so the PDF they download there is the article's
    /// (`attachDocumentPDF`); it stays an article, never becoming a paper.
    static func readerPaperID(sourceID: String, sourceType: StudioSourceType?, isUnreadable: Bool = false) -> String? {
        if sourceType == .paper { return sourceID }
        return awaitsDocumentPDF(sourceType: sourceType, isUnreadable: isUnreadable) ? sourceID : nil
    }

    /// An article the app could not read (`isUnreadable`: an error state or a
    /// paywall marker), which takes a PDF the learner brings as its document.
    static func awaitsDocumentPDF(sourceType: StudioSourceType?, isUnreadable: Bool) -> Bool {
        (sourceType == .article || sourceType == .unclassified) && isUnreadable
    }

    /// A free path in `directory`, since `WKDownload` refuses a destination
    /// that already exists.
    static func uniqueDestination(in directory: URL, suggestedFilename: String) -> URL {
        let sanitized = suggestedFilename.replacingOccurrences(of: "/", with: "-")
        let name = sanitized.isEmpty ? "download" : sanitized
        var candidate = directory.appendingPathComponent(name)
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    /// Moves a finished file into Downloads and returns where it landed.
    static func moveToDownloads(_ file: URL, named name: String? = nil) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let destination = uniqueDestination(in: downloads, suggestedFilename: name ?? file.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

// MARK: - Page panels

/// The JavaScript panels and file chooser a page asks its UI delegate for,
/// answered the same way in a Browser tab and in the reader. Publisher and
/// sign-in flows use these before continuing a link, so each is a sheet on the
/// page's window, as in a browser window. Never a modal run loop: a page with
/// no window — a chat's tab rendering in its hidden host — gets the answer a
/// dismissed panel gives, so the main thread is never held.
@MainActor
enum WebPagePanels {
    static func alert(
        _ message: String,
        from frame: WKFrameInfo,
        in webView: WKWebView,
        completion: @escaping () -> Void
    ) {
        guard let window = webView.window else {
            completion()
            return
        }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completion() }
    }

    static func confirm(
        _ message: String,
        from frame: WKFrameInfo,
        in webView: WKWebView,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window = webView.window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    static func prompt(
        _ prompt: String,
        defaultText: String?,
        from frame: WKFrameInfo,
        in webView: WKWebView,
        completion: @escaping (String?) -> Void
    ) {
        guard let window = webView.window else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.messageText = frame.request.url?.host ?? "This page"
        alert.informativeText = prompt
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// The file chooser behind an HTML file input, through the app's shared
    /// asynchronous panel.
    static func chooseFiles(
        _ parameters: WKOpenPanelParameters,
        completion: @escaping ([URL]?) -> Void
    ) {
        Task { @MainActor in
            let urls = await FilePanel.open { panel in
                panel.allowsMultipleSelection = parameters.allowsMultipleSelection
                panel.canChooseDirectories = parameters.allowsDirectories
            }
            completion(urls.isEmpty ? nil : urls)
        }
    }
}

// MARK: - Page downloads

/// Downloads for every ForeverLM web view: a Browser tab and a source's reader
/// hand each `WKDownload` here, and a finished file is decided the same way in
/// both. A PDF for a paper waiting for one attaches to it, after which the page
/// goes back to where the learner clicked; a supplementary PDF, or any other
/// file, goes to Downloads; a "download" the server answered with a page — a
/// check, a sign-in — is shown, as a browser would show it.
///
/// The reader knows its paper; a Browser tab asks `WebPagePolicy.paperNeedingPDF`
/// for the page the download came from. That is the only difference.
@MainActor
final class WebPageDownloads: NSObject {
    /// What a download is for, decided by the response that started it.
    enum Kind: Equatable {
        /// A PDF response on a paper's page: the paper's, to attach.
        case paperPDF
        /// Some other file, for Downloads.
        case file
        /// Started before any response (a `download` link, the reader's
        /// Download PDF): the finished file says which it is.
        case undecided
    }

    private struct Pending {
        let download: WKDownload
        var kind: Kind
        /// The paper a PDF from this download attaches to; nil keeps every
        /// file in Downloads.
        var paperID: String?
        /// The page the learner was reading when they clicked.
        var returnItem: WKBackForwardListItem?
        var file: URL?
        var sourceURL: URL?
        var suggestedFilename: String?
    }

    /// The paper a download started in this web view belongs to, if any.
    private let paperID: (WKWebView?) -> String?
    /// The library a PDF attaches to. Main-actor, because it reads the
    /// window's view model and the class itself is `@MainActor`.
    private let library: @MainActor () -> StudioViewModel?
    private let notify: (String) -> Void
    private var pending: [ObjectIdentifier: Pending] = [:]
    /// Set by the response policy just before it answers `.download`.
    private var nextResponseKind: Kind = .undecided
    /// Addresses whose server answered a download with a page, since shown in
    /// the web view. Each is shown once, and is not fetched again as a
    /// download when it finishes loading.
    private var pagesShownInsteadOfDownloaded = Set<String>()

    init(
        paperID: @escaping (WKWebView?) -> String?,
        library: @escaping @MainActor () -> StudioViewModel? = { @MainActor in WebPagePolicy.library },
        notify: @escaping (String) -> Void
    ) {
        self.paperID = paperID
        self.library = library
        self.notify = notify
    }

    /// Called by the response policy as it answers `.download`, so the
    /// download that follows knows what it is for.
    func expectResponseDownload(_ kind: Kind) {
        nextResponseKind = kind
    }

    /// A page shown once instead of being downloaded is shown again rather
    /// than downloaded again, unless it is now a PDF.
    func wasShownInsteadOfDownloaded(_ url: URL) -> Bool {
        pagesShownInsteadOfDownloaded.contains(url.absoluteString)
    }

    /// A navigation action became a download (a `download` link, a blob).
    func track(actionDownload download: WKDownload, returnItem: WKBackForwardListItem?) {
        track(download, kind: .undecided, returnItem: returnItem)
    }

    /// A navigation response became a download; its kind is the one the
    /// response policy just announced.
    func track(responseDownload download: WKDownload, returnItem: WKBackForwardListItem?) {
        track(download, kind: nextResponseKind, returnItem: returnItem)
        nextResponseKind = .undecided
    }

    /// Starts a download in the web view's session, so its cookies — an
    /// institutional sign-in — carry.
    func start(_ request: URLRequest, in webView: WKWebView, returnItem: WKBackForwardListItem? = nil) {
        webView.startDownload(using: request) { [weak self] download in
            self?.track(download, kind: .undecided, returnItem: returnItem)
        }
    }

    private func track(_ download: WKDownload, kind: Kind, returnItem: WKBackForwardListItem?) {
        download.delegate = self
        let key = ObjectIdentifier(download)
        guard pending[key] == nil else { return }
        let paper = kind == .file ? nil : paperID(download.webView)
        pending[key] = Pending(download: download, kind: kind, paperID: paper, returnItem: returnItem)
    }

    static func isPMCDownloadURL(_ url: URL) -> Bool {
        if PaperService.extractPMCID(from: url.absoluteString) != nil { return true }
        guard let host = url.host?.lowercased() else { return false }
        return host == "pmc.ncbi.nlm.nih.gov"
            || (host.hasSuffix(".ncbi.nlm.nih.gov") && url.path.lowercased().contains("/pmc/articles/"))
    }

    /// Shows a page the web view fetched as a download. False when there is
    /// no web view to show it in, or it was shown once and came back a page
    /// again.
    private func showPageInsteadOfDownload(_ url: URL, in webView: WKWebView?) -> Bool {
        let key = url.absoluteString
        guard let webView, !pagesShownInsteadOfDownloaded.contains(key) else { return false }
        pagesShownInsteadOfDownloaded.insert(key)
        webView.load(URLRequest(url: url))
        return true
    }

    /// Back to the page the learner was reading when they clicked, once the
    /// PDF that click led to has attached. A site that showed pages on the
    /// way (a check, a sign-in, a viewer) leaves them behind; the history
    /// move restores the reading position like Back does.
    private func returnToReadingSpot(_ item: WKBackForwardListItem?, in webView: WKWebView?) {
        guard let item, let webView,
              webView.backForwardList.currentItem !== item,
              webView.backForwardList.backList.contains(where: { $0 === item }) else { return }
        webView.go(to: item)
    }

    private func keepInDownloads(_ file: URL, named name: String?, message: (URL) -> String) {
        if let saved = WebPagePolicy.moveToDownloads(file, named: name) {
            notify(message(saved))
        } else {
            notify("Couldn't save \(file.lastPathComponent)")
        }
    }

    private func finish(_ item: Pending, file fileURL: URL) async {
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let webView = item.download.webView
        let name = item.suggestedFilename

        guard item.kind != .file, let paperID = item.paperID, let library = library() else {
            keepInDownloads(fileURL, named: name) { "Downloaded \($0.lastPathComponent) to Downloads" }
            return
        }

        let isPDF = SourceService.canOpenPDF(at: fileURL.path)

        // A supplementary file — Nature's Reporting Summary, Source Data —
        // downloaded from the paper's page is not the paper, and must not
        // become its PDF.
        if isPDF, let sourceURL = item.sourceURL, PaperService.isSupplementaryPDFURL(sourceURL.absoluteString) {
            keepInDownloads(fileURL, named: name) { _ in "That file is the paper's supplementary material, so it went to Downloads" }
            return
        }

        let isPaper = library.articles.first { $0.id == paperID }?.sourceType == .paper

        // PMC can answer with an interstitial that WKDownload saves as is;
        // the validated downloader handles PMC's proof of work.
        if isPaper, !isPDF, let sourceURL = item.sourceURL, Self.isPMCDownloadURL(sourceURL) {
            do {
                try await library.attachPDFFromURL(to: paperID, urlString: sourceURL.absoluteString)
                notify("Attached the PDF to the paper")
                returnToReadingSpot(item.returnItem, in: webView)
            } catch {
                notify("Couldn't attach that PDF — \(error.localizedDescription)")
            }
            return
        }

        // A download that turned out to be a page — a `download` link or an
        // attachment response answered with a check or a sign-in — is shown.
        if !isPDF,
           let text = try? String(contentsOf: fileURL, encoding: .utf8),
           PaperService.looksLikeHTMLDocument(text) {
            if let sourceURL = item.sourceURL, showPageInsteadOfDownload(sourceURL, in: webView) {
                return
            }
            notify("That link opened a page, not a PDF")
            return
        }

        // Any other file is the learner's, not the paper's.
        guard isPDF else {
            keepInDownloads(fileURL, named: name) { "Downloaded \($0.lastPathComponent) to Downloads" }
            return
        }

        do {
            if isPaper {
                try await library.attachPDF(to: paperID, pdfPath: fileURL.path)
                notify("Attached the PDF to the paper")
                returnToReadingSpot(item.returnItem, in: webView)
            } else {
                // An unreadable article's own PDF: it becomes the article's
                // document, and its reader shows the PDF from here on.
                try await library.attachDocumentPDF(to: paperID, pdfURL: fileURL)
                notify("Attached the PDF to the article")
            }
        } catch {
            keepInDownloads(fileURL, named: name) { _ in "Couldn't attach that PDF — \(error.localizedDescription). It is in Downloads" }
        }
    }
}

extension WebPageDownloads: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // A temporary folder of its own; the file moves into the library via
        // attachPDF, or into Downloads, when it finishes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebPageDownloads-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            suggestedFilename.isEmpty ? "download" : suggestedFilename.replacingOccurrences(of: "/", with: "-")
        )
        let key = ObjectIdentifier(download)
        if pending[key] == nil {
            track(download, kind: .undecided, returnItem: nil)
        }
        pending[key]?.file = destination
        pending[key]?.sourceURL = response.url
        pending[key]?.suggestedFilename = suggestedFilename
        completionHandler(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let item = pending.removeValue(forKey: ObjectIdentifier(download))
        if let folder = item?.file?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: folder)
        }
        // The page stays on screen while a download runs, so a failure that
        // says nothing reads as the click having done nothing at all.
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        notify("Couldn't download \(item?.suggestedFilename ?? "that file") — \(nsError.localizedDescription)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = pending.removeValue(forKey: ObjectIdentifier(download)),
              let file = item.file else { return }
        Task { @MainActor in
            await self.finish(item, file: file)
        }
    }
}

// MARK: - Per-tab WebKit delegate

/// Mirrors one web view into its tab, and answers WebKit's questions the way
/// a browser window does: popups become tabs, downloads land in Downloads,
/// JavaScript panels are sheets, a file chooser is an open panel, and a link
/// to another app's scheme goes to that app.
@MainActor
final class BrowserTabController: NSObject {
    private weak var tab: BrowserTab?
    private weak var workspace: BrowserWorkspace?
    private var observations: [NSKeyValueObservation] = []
    /// The page each main-frame navigation left, so a PDF it ends on can be
    /// matched to the paper that page is.
    private var navigationOriginURL: URL?
    /// The page the learner was reading when they clicked, for a PDF the
    /// click ends on to return to once it has attached.
    private var clickOriginItem: WKBackForwardListItem?
    /// The reader's download handling, with the paper found from the page.
    private lazy var downloads = WebPageDownloads(
        paperID: { [weak self] webView in self?.paperNeedingPDF(in: webView) },
        notify: { [weak self] message in self?.notify(message) }
    )

    init(tab: BrowserTab, workspace: BrowserWorkspace) {
        self.tab = tab
        self.workspace = workspace
    }

    /// The paper a PDF from this tab belongs to: the one whose page the
    /// navigation left, or the one at the page's own address.
    private func paperNeedingPDF(in webView: WKWebView?) -> String? {
        WebPagePolicy.paperNeedingPDF(onPage: navigationOriginURL)
            ?? WebPagePolicy.paperNeedingPDF(onPage: webView?.url)
    }

    func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.url = webView.url; self?.workspace?.persistSession() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.title = webView.title ?? "" }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.estimatedProgress = webView.estimatedProgress }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.tab?.hasOnlySecureContent = webView.hasOnlySecureContent }
            },
        ]
    }

    func stop() {
        observations.forEach { $0.invalidate() }
        observations = []
    }

    /// Schemes the web view renders itself. Anything else — `mailto:`,
    /// `zoommtg:`, `x-apple.systempreferences:` — belongs to another app.
    static func isWebScheme(_ url: URL) -> Bool {
        WebPagePolicy.isWebScheme(url)
    }

    private func notify(_ message: String) {
        workspace?.notice = .init(message: message)
    }
}

extension BrowserTabController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
        if isMainFrame {
            navigationOriginURL = webView.url
            if navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted {
                clickOriginItem = webView.backForwardList.currentItem
            }
        }
        switch WebPagePolicy.action(
            for: navigationAction.request.url,
            isLinkActivated: navigationAction.navigationType == .linkActivated,
            isMainFrame: isMainFrame,
            shouldPerformDownload: navigationAction.shouldPerformDownload
        ) {
        case .allow: return (.allow, preferences)
        case .download: return (.download, preferences)
        case .openInOtherApp:
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return (.cancel, preferences)
        case .cancel: return (.cancel, preferences)
        case .openYouTubeVideo(let watchURL):
            WebPagePolicy.openYouTubeVideo(watchURL)
            closeIfNothingLoaded(webView)
            return (.cancel, preferences)
        case .refuseYouTubePage:
            workspace?.notice = .init(message: YouTubeContainment.refusalMessage)
            closeIfNothingLoaded(webView)
            return (.cancel, preferences)
        }
    }

    /// A tab opened straight onto YouTube — typed into the address bar, a link
    /// handed to ForeverLM as the default browser, a popup — has nothing to
    /// show once that page is refused, so it goes rather than sit blank. After
    /// the policy has answered: WebKit is still waiting on this web view.
    private func closeIfNothingLoaded(_ webView: WKWebView) {
        guard webView.url == nil, webView.backForwardList.currentItem == nil,
              let tab, let workspace else { return }
        DispatchQueue.main.async { [weak workspace, weak tab] in
            guard let workspace, let tab else { return }
            workspace.close(tab)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        // A PDF reached from a paper's own page — or shown at the paper's own
        // address — is that paper's, as in the reader.
        let paperID = paperNeedingPDF(in: webView)
        let response = navigationResponse.response
        // A page that already came back as a download once is shown as that
        // page; only a PDF from it downloads.
        if let url = response.url,
           downloads.wasShownInsteadOfDownloaded(url),
           navigationResponse.canShowMIMEType,
           !WebPagePolicy.isPDF(url: url, mimeType: response.mimeType?.lowercased() ?? "", contentDisposition: "") {
            return .allow
        }
        switch WebPagePolicy.response(
            url: response.url,
            mimeType: response.mimeType,
            contentDisposition: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"),
            canShowMIMEType: navigationResponse.canShowMIMEType,
            capturesPDFs: paperID != nil
        ) {
        case .show:
            return .allow
        case .download:
            downloads.expectResponseDownload(.file)
            return .download
        case .capturePDF:
            downloads.expectResponseDownload(.paperPDF)
            return .download
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.loadErrorMessage = nil
        // A sign-in page that fails a passkey usually lands on another page
        // of the same site; the notice outlives that, not a move elsewhere.
        if let asked = tab?.passkeyRequestURL, asked.host?.lowercased() != webView.url?.host?.lowercased() {
            tab?.passkeyRequestURL = nil
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // A cancelled load is the learner typing a new address, or a
        // download taking the navigation over — not a failure.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }  // frame load interrupted (download)
        tab?.loadErrorMessage = nsError.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.track(actionDownload: download, returnItem: clickOriginItem)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.track(responseDownload: download, returnItem: clickOriginItem)
    }
}

extension BrowserTabController {
    static func uniqueDestination(in directory: URL, suggestedFilename: String) -> URL {
        WebPagePolicy.uniqueDestination(in: directory, suggestedFilename: suggestedFilename)
    }
}

extension BrowserTabController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let tab, let workspace else { return nil }
        if let url = navigationAction.request.url, !Self.isWebScheme(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        // WebKit loads the popup's request into the view it is handed, body
        // and headers included, and the popup keeps its opener: that is how a
        // "Continue with Google" window signs the page that opened it in.
        return workspace.openPopup(from: tab, configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, let workspace else { return }
        workspace.close(tab)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        WebPagePanels.alert(message, from: frame, in: webView, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        WebPagePanels.confirm(message, from: frame, in: webView, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        WebPagePanels.prompt(prompt, defaultText: defaultText, from: frame, in: webView, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        WebPagePanels.chooseFiles(parameters, completion: completionHandler)
    }
}

// MARK: - Passkeys

/// Passkeys in the Browser pane.
///
/// WebKit answers a page's WebAuthn call — `navigator.credentials.get` or
/// `.create` with a `publicKey` option, the passkey and security-key prompt —
/// only in an app that holds `com.apple.developer.web-browser.public-key-credential`,
/// which Apple grants on request to apps that act as a web browser
/// (`docs/browser-passkeys.md`; ForeverLM's request is filed). Without it the
/// call is refused and the page shows its own error: Amazon's "Passkey error",
/// Google's prompt that never appears. Until the entitlement ships, a user
/// script reports each such call to the workspace, which marks the tab so the
/// pane can offer the page in the default browser, where the passkey works.
/// The script only reports — the call itself runs unchanged — and nothing is
/// installed at all once the process holds the entitlement.
enum BrowserPasskeySupport {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"
    static let messageName = "foreverlmPasskeyRequest"

    /// Whether this process holds the entitlement, read once from its code
    /// signature. The Developer ID release adds the key when its profile
    /// carries it (`build_dmg.sh`); a Dev build reads its entitlements file.
    static let appAnswersPasskeys: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return isGranted(SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil))
    }()

    static func isGranted(_ entitlementValue: Any?) -> Bool {
        (entitlementValue as? Bool) == true
    }

    /// Wraps `navigator.credentials.get` and `.create` so a passkey call is
    /// reported before it runs. Password-credential calls (no `publicKey`)
    /// are left alone; the wrapper never touches the call's result.
    static let reportingScript = """
    (() => {
      const credentials = navigator.credentials;
      if (!credentials || credentials.__foreverlmPasskeyReporting) { return; }
      credentials.__foreverlmPasskeyReporting = true;
      const report = (kind, options) => {
        try {
          if (!options || !options.publicKey) { return; }
          window.webkit.messageHandlers.\(messageName).postMessage({ kind: kind });
        } catch (_) {}
      };
      for (const kind of ["get", "create"]) {
        const original = credentials[kind];
        if (typeof original !== "function") { continue; }
        credentials[kind] = function (options) {
          report(kind, options);
          return original.apply(this, arguments);
        };
      }
    })();
    """

    /// Installs the script in every frame at document start — a sign-in
    /// page may run its passkey prompt in an iframe — and the handler the
    /// script posts to. Once per content controller: a popup copies its
    /// opener's configuration and with it this controller.
    @MainActor
    static func installReporting(in controller: WKUserContentController, workspace: BrowserWorkspace) {
        controller.removeScriptMessageHandler(forName: messageName)
        controller.add(PasskeyMessageHandler(workspace: workspace), name: messageName)
        controller.addUserScript(WKUserScript(source: reportingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// The browser the notice offers: the default one for https, or Safari
    /// when ForeverLM itself is the default — it registers http and https,
    /// so handing the page to the default browser could hand it to us.
    struct ExternalBrowser: Equatable {
        let name: String
        let applicationURL: URL
    }

    static var externalBrowser: ExternalBrowser? {
        let workspace = NSWorkspace.shared
        let probe = URL(string: "https://foreverlm.com")!
        return pickExternalBrowser(
            defaultBrowser: workspace.urlForApplication(toOpen: probe),
            safari: workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
            ownBundlePath: Bundle.main.bundleURL.standardizedFileURL.path
        )
    }

    static func pickExternalBrowser(defaultBrowser: URL?, safari: URL?, ownBundlePath: String) -> ExternalBrowser? {
        let candidates = [defaultBrowser, safari].compactMap { $0 }
        guard let chosen = candidates.first(where: { $0.standardizedFileURL.path != ownBundlePath }) else { return nil }
        let localized = (try? chosen.resourceValues(forKeys: [.localizedNameKey]).localizedName)
        let name = localized.map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            ?? chosen.deletingPathExtension().lastPathComponent
        return ExternalBrowser(name: name, applicationURL: chosen)
    }

    /// Opens the page in the external browser; falls back to the system's
    /// own routing when none was found.
    @MainActor
    static func openOutside(_ url: URL) {
        if let browser = externalBrowser {
            NSWorkspace.shared.open([url], withApplicationAt: browser.applicationURL, configuration: .init()) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// WebKit retains its message handlers; the workspace must not be
    /// retained by its own tabs' content controllers.
    private final class PasskeyMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var workspace: BrowserWorkspace?

        init(workspace: BrowserWorkspace) {
            self.workspace = workspace
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == BrowserPasskeySupport.messageName, let webView = message.webView else { return }
            MainActor.assumeIsolated {
                workspace?.passkeyRequested(in: webView)
            }
        }
    }
}
