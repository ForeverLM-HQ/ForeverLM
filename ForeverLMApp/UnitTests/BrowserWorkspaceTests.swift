import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

@Suite("Browser workspace")
@MainActor
struct BrowserWorkspaceTests {
    private func makeDefaults() -> UserDefaults {
        let name = "BrowserWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Find in page

    @Test("Cmd+F reaching a tab's web view opens its find bar; Ctrl+F is the page's")
    func commandFindInBrowserWebViewShowsBar() throws {
        func keyEvent(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
                isARepeat: false, keyCode: 3
            )!
        }

        let workspace = BrowserWorkspace(profiles: BrowserProfileStore(defaults: makeDefaults()), defaults: makeDefaults())
        let tab = workspace.openTab(url: nil)
        let state = ReaderFindState()
        let webView = try #require(workspace.webView(for: tab) as? ForeverLMWebView)
        webView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        webView.findState = state

        webView.keyDown(with: keyEvent(.control))
        #expect(!state.isVisible)

        webView.keyDown(with: keyEvent(.command))
        #expect(state.isVisible)
        #expect(state.focusRevision == 1)
    }

    @Test("The host hands the pane's find state to the web view it installs")
    func hostAttachesFindState() {
        let state = ReaderFindState()
        let host = BrowserWebViewHost(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let webView = ForeverLMWebView(frame: .zero)
        host.install(webView, findState: state)
        #expect(webView.findState === state)
    }

    // MARK: Addresses

    @Test("A bare host becomes https, a scheme is kept, and words are a search")
    func addressResolution() {
        #expect(BrowserWorkspace.resolveAddress("chatgpt.com")?.absoluteString == "https://chatgpt.com")
        #expect(BrowserWorkspace.resolveAddress("  nature.com/articles/x  ")?.absoluteString == "https://nature.com/articles/x")
        #expect(BrowserWorkspace.resolveAddress("http://localhost:8788/x")?.absoluteString == "http://localhost:8788/x")
        #expect(BrowserWorkspace.resolveAddress("localhost:3000")?.absoluteString == "https://localhost:3000")
        #expect(BrowserWorkspace.resolveAddress("192.168.1.10:8080")?.host == "192.168.1.10")
        #expect(BrowserWorkspace.resolveAddress("") == nil)
        #expect(BrowserWorkspace.resolveAddress("   ") == nil)

        let search = BrowserWorkspace.resolveAddress("mitochondrial drug discovery")
        #expect(search?.host == "www.google.com")
        #expect(search?.query?.contains("q=mitochondrial") == true)
        // No dot and no port: a word, not a host.
        #expect(BrowserWorkspace.resolveAddress("foreverlm")?.host == "www.google.com")
    }

    @Test("The address bar drops https and a bare trailing slash, and keeps http")
    func displayAddress() {
        #expect(BrowserWorkspace.displayAddress(for: URL(string: "https://chatgpt.com/")) == "chatgpt.com")
        #expect(BrowserWorkspace.displayAddress(for: URL(string: "https://chatgpt.com/c/123")) == "chatgpt.com/c/123")
        #expect(BrowserWorkspace.displayAddress(for: URL(string: "https://x.com/?q=1")) == "x.com/?q=1")
        #expect(BrowserWorkspace.displayAddress(for: URL(string: "http://localhost:8788/")) == "http://localhost:8788")
        #expect(BrowserWorkspace.displayAddress(for: nil) == "")
    }

    // MARK: Profiles

    @Test("Library is always first and cannot be renamed or removed")
    func libraryProfileIsFixed() async {
        let store = BrowserProfileStore(defaults: makeDefaults())
        #expect(store.profiles.map(\.id) == [BrowserProfile.libraryID])

        store.rename(BrowserProfile.libraryID, to: "Mine")
        #expect(store.profiles.first?.name == "Library")

        await store.remove(BrowserProfile.libraryID)
        #expect(store.profiles.count == 1)
        #expect(store.dataStore(for: .library) === WKWebsiteDataStore.default())
    }

    @Test("Profiles persist, in order, and duplicate names are numbered")
    func profilesPersist() {
        let defaults = makeDefaults()
        let store = BrowserProfileStore(defaults: defaults)
        let work = store.add(name: "Work")
        let second = store.add(name: "work")
        let blank = store.add(name: "   ")
        #expect(second.name == "work 2")
        #expect(blank.name == "Profile")

        let reloaded = BrowserProfileStore(defaults: defaults)
        #expect(reloaded.profiles.map(\.id) == [BrowserProfile.libraryID, work.id, second.id, blank.id])
        #expect(reloaded.profile(id: work.id)?.name == "Work")
        #expect(reloaded.dataStore(for: work) !== WKWebsiteDataStore.default())
    }

    @Test("Another account is a profile already made before it is a new jar")
    func profilesOtherThanCurrent() {
        let store = BrowserProfileStore(defaults: makeDefaults())
        // Only Library exists: nothing to switch to, so the link makes a profile.
        #expect(store.profiles(otherThan: BrowserProfile.libraryID).isEmpty)

        let chatgpt = store.add(name: "ChatGPT account")
        // The page on Library is offered the profile that already signed in,
        // not a "ChatGPT account 2".
        #expect(store.profiles(otherThan: BrowserProfile.libraryID) == [chatgpt])
        // And from that profile, the way back to Library.
        #expect(store.profiles(otherThan: chatgpt.id) == [.library])
        #expect(store.profiles.count == 2)
    }

    @Test("A linked page opens under Library until assigned, and falls back when its profile is gone")
    func linkedPageProfiles() async {
        let defaults = makeDefaults()
        let store = BrowserProfileStore(defaults: defaults)
        let work = store.add(name: "Work")
        let pages = LinkedPageProfiles(defaults: defaults)
        #expect(pages.profile(for: "site-1", in: store) == .library)

        pages.assign(work.id, to: "site-1")
        #expect(pages.profile(for: "site-1", in: store) == work)
        #expect(LinkedPageProfiles(defaults: defaults).profile(for: "site-1", in: store) == work)

        // Assigning Library clears the entry rather than storing it.
        pages.assign(BrowserProfile.libraryID, to: "site-1")
        #expect(defaults.dictionary(forKey: LinkedPageProfiles.key)?.isEmpty == true)

        pages.assign(work.id, to: "site-2")
        await store.remove(work.id)
        #expect(pages.profile(for: "site-2", in: store) == .library)
    }

    // MARK: Tabs

    @Test("Closing the active tab moves to its right-hand neighbour, or left at the end")
    func closingSelectsNeighbour() {
        let workspace = BrowserWorkspace(profiles: BrowserProfileStore(defaults: makeDefaults()))
        let a = workspace.openTab(url: URL(string: "https://a.example"))
        let b = workspace.openTab(url: URL(string: "https://b.example"))
        let c = workspace.openTab(url: URL(string: "https://c.example"))
        #expect(workspace.activeTabID == c.id)

        workspace.select(a)
        workspace.close(a)
        #expect(workspace.activeTabID == b.id)

        workspace.select(c)
        workspace.close(c)
        #expect(workspace.activeTabID == b.id)

        workspace.close(b)
        #expect(workspace.activeTabID == nil)
        #expect(workspace.tabs.isEmpty)
    }

    @Test("Closing a background tab leaves the active one alone")
    func closingBackgroundTab() {
        let workspace = BrowserWorkspace(profiles: BrowserProfileStore(defaults: makeDefaults()))
        let a = workspace.openTab(url: URL(string: "https://a.example"))
        let b = workspace.openTab(url: URL(string: "https://b.example"), activate: false)
        #expect(workspace.activeTabID == a.id)
        workspace.close(b)
        #expect(workspace.activeTabID == a.id)
        #expect(workspace.tabs.map(\.id) == [a.id])
    }

    @Test("A tab opened beside another lands right after it, in the profile asked for")
    func openBeside() {
        let store = BrowserProfileStore(defaults: makeDefaults())
        let work = store.add(name: "Work")
        let workspace = BrowserWorkspace(profiles: store)
        let a = workspace.openTab(url: URL(string: "https://a.example"))
        _ = workspace.openTab(url: URL(string: "https://c.example"))
        let popup = workspace.openTab(url: nil, profileID: work.id, beside: a)
        #expect(workspace.tabs.firstIndex { $0.id == popup.id } == 1)
        #expect(popup.profileID == work.id)
        #expect(workspace.profile(for: popup).name == "Work")

        // An unknown profile falls back to Library rather than an orphan jar.
        let orphan = workspace.openTab(url: nil, profileID: UUID())
        #expect(orphan.profileID == BrowserProfile.libraryID)
    }

    @Test("Removing a profile closes its tabs first")
    func removingProfileClosesTabs() async {
        let store = BrowserProfileStore(defaults: makeDefaults())
        let work = store.add(name: "Work")
        let workspace = BrowserWorkspace(profiles: store)
        let keep = workspace.openTab(url: URL(string: "https://a.example"))
        _ = workspace.openTab(url: URL(string: "https://b.example"), profileID: work.id)
        _ = workspace.openTab(url: URL(string: "https://c.example"), profileID: work.id)

        await workspace.removeProfile(work.id)
        #expect(workspace.tabs.map(\.id) == [keep.id])
        #expect(store.profile(id: work.id) == nil)
        #expect(workspace.activeTabID == keep.id)
    }

    // MARK: Session

    @Test("The session comes back with its tabs, profiles and active tab")
    func sessionRoundTrip() {
        let defaults = makeDefaults()
        let store = BrowserProfileStore(defaults: defaults)
        let work = store.add(name: "Work")
        let workspace = BrowserWorkspace(profiles: store, defaults: defaults, persistSession: true)
        _ = workspace.openTab(url: URL(string: "https://a.example"))
        let b = workspace.openTab(url: URL(string: "https://chatgpt.com"), profileID: work.id)
        b.title = "ChatGPT"
        _ = workspace.openTab(url: URL(string: "https://c.example"), activate: false)
        workspace.select(b)
        workspace.persistSession()

        let restored = BrowserWorkspace(
            profiles: BrowserProfileStore(defaults: defaults),
            defaults: defaults,
            restoreSession: true
        )
        #expect(restored.tabs.count == 3)
        #expect(restored.tabs.map { $0.url?.host } == ["a.example", "chatgpt.com", "c.example"])
        #expect(restored.tabs[1].profileID == work.id)
        #expect(restored.tabs[1].title == "ChatGPT")
        #expect(restored.activeTab?.url?.host == "chatgpt.com")
        // Nothing has been shown yet, so no web process has been paid for.
        #expect(restored.tabs.allSatisfy { $0.webView == nil })
    }

    @Test("A workspace that does not own the session never writes it")
    func secondaryWorkspaceDoesNotPersist() {
        let defaults = makeDefaults()
        let workspace = BrowserWorkspace(profiles: BrowserProfileStore(defaults: defaults), defaults: defaults)
        _ = workspace.openTab(url: URL(string: "https://a.example"))
        #expect(defaults.data(forKey: BrowserWorkspace.sessionKey) == nil)
    }

    @Test("A restored tab whose profile is gone opens in Library")
    func restoredTabWithMissingProfile() {
        let defaults = makeDefaults()
        let snapshot = BrowserSessionSnapshot(
            tabs: [.init(profileID: UUID(), url: URL(string: "https://a.example"), title: "")],
            activeIndex: 0
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: BrowserWorkspace.sessionKey)
        let workspace = BrowserWorkspace(
            profiles: BrowserProfileStore(defaults: defaults),
            defaults: defaults,
            restoreSession: true
        )
        #expect(workspace.tabs.first?.profileID == BrowserProfile.libraryID)
    }

    // MARK: Web views

    @Test("A tab's web view is made once, in its profile's store, and a popup shares the opener's profile")
    func webViewsAndPopups() {
        let store = BrowserProfileStore(defaults: makeDefaults())
        let work = store.add(name: "Work")
        let workspace = BrowserWorkspace(profiles: store)
        let library = workspace.openTab(url: nil)
        let tab = workspace.openTab(url: nil, profileID: work.id)

        let libraryView = workspace.webView(for: library)
        #expect(libraryView.configuration.websiteDataStore === WKWebsiteDataStore.default())

        let first = workspace.webView(for: tab)
        #expect(workspace.webView(for: tab) === first)
        #expect(first.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(first.customUserAgent == SharedWebKit.desktopSafariUserAgent)

        let popup = workspace.openPopup(from: tab, configuration: first.configuration.copy() as! WKWebViewConfiguration)
        let popupTab = workspace.activeTab
        #expect(popupTab?.id != tab.id)
        #expect(popupTab?.profileID == work.id)
        #expect(popupTab?.webView === popup)
        #expect(workspace.tabs.firstIndex { $0.id == popupTab?.id } == 2)
    }

    // MARK: Passkeys

    @Test("Without the entitlement every tab's page reports its passkey calls; with it nothing is installed")
    func passkeyReportingFollowsTheEntitlement() {
        let store = BrowserProfileStore(defaults: makeDefaults())
        let reporting = BrowserWorkspace(profiles: store, answersPasskeys: false)
        let tab = reporting.openTab(url: URL(string: "https://www.amazon.com/ap/signin"))
        let scripts = reporting.webView(for: tab).configuration.userContentController.userScripts
        #expect(scripts.count == 1)
        #expect(scripts.first?.injectionTime == .atDocumentStart)
        #expect(scripts.first?.isForMainFrameOnly == false)
        #expect(scripts.first?.source == BrowserPasskeySupport.reportingScript)

        let entitled = BrowserWorkspace(profiles: store, answersPasskeys: true)
        let entitledTab = entitled.openTab(url: nil)
        #expect(entitled.webView(for: entitledTab).configuration.userContentController.userScripts.isEmpty)
    }

    @Test("The reporting script wraps get and create for publicKey requests only, and posts to the workspace's handler")
    func passkeyReportingScript() {
        let script = BrowserPasskeySupport.reportingScript
        #expect(script.contains("[\"get\", \"create\"]"))
        #expect(script.contains("options.publicKey"))
        #expect(script.contains("messageHandlers.\(BrowserPasskeySupport.messageName).postMessage"))
        #expect(script.contains("original.apply(this, arguments)"))
        #expect(BrowserPasskeySupport.isGranted(true))
        #expect(!BrowserPasskeySupport.isGranted(false))
        #expect(!BrowserPasskeySupport.isGranted(nil))
        #expect(!BrowserPasskeySupport.isGranted("true"))
    }

    @Test("A passkey call marks the tab that asked, a new address clears it, and a popup's call marks the popup")
    func passkeyRequestMarksTheTab() {
        let store = BrowserProfileStore(defaults: makeDefaults())
        let workspace = BrowserWorkspace(profiles: store, answersPasskeys: false)
        let signIn = URL(string: "https://www.amazon.com/ap/signin")!
        let tab = workspace.openTab(url: signIn)
        let other = workspace.openTab(url: URL(string: "https://nature.com"), activate: false)
        let webView = workspace.webView(for: tab)
        _ = workspace.webView(for: other)

        workspace.passkeyRequested(in: webView)
        #expect(tab.passkeyRequestURL == signIn)
        #expect(other.passkeyRequestURL == nil)

        workspace.load(URL(string: "https://nature.com")!, in: tab)
        #expect(tab.passkeyRequestURL == nil)

        let popup = workspace.openPopup(from: tab, configuration: webView.configuration.copy() as! WKWebViewConfiguration)
        workspace.passkeyRequested(in: popup)
        #expect(workspace.activeTab?.passkeyRequestURL == nil)  // no URL yet: nothing loaded in the popup
        #expect(tab.passkeyRequestURL == nil)

        let stranger = WKWebView(frame: .zero)
        workspace.passkeyRequested(in: stranger)
        #expect(workspace.tabs.allSatisfy { $0.passkeyRequestURL == nil })
    }

    @Test("The notice offers the default browser, and Safari when ForeverLM itself is the default")
    func passkeyExternalBrowser() {
        let brave = URL(fileURLWithPath: "/Applications/Brave Browser.app")
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let own = "/Applications/ForeverLM.app"

        let picked = BrowserPasskeySupport.pickExternalBrowser(defaultBrowser: brave, safari: safari, ownBundlePath: own)
        #expect(picked?.applicationURL == brave)
        #expect(picked?.name.hasPrefix("Brave") == true)

        let selfDefault = BrowserPasskeySupport.pickExternalBrowser(
            defaultBrowser: URL(fileURLWithPath: own), safari: safari, ownBundlePath: own)
        #expect(selfDefault?.applicationURL == safari)
        #expect(selfDefault?.name == "Safari")

        #expect(BrowserPasskeySupport.pickExternalBrowser(defaultBrowser: nil, safari: nil, ownBundlePath: own) == nil)
    }

    @Test("Only web schemes stay in the browser")
    func webSchemes() {
        #expect(BrowserTabController.isWebScheme(URL(string: "https://x.com")!))
        #expect(BrowserTabController.isWebScheme(URL(string: "http://x.com")!))
        #expect(BrowserTabController.isWebScheme(URL(string: "about:blank")!))
        #expect(!BrowserTabController.isWebScheme(URL(string: "mailto:a@b.c")!))
        #expect(!BrowserTabController.isWebScheme(URL(string: "zoommtg://zoom.us/join")!))
        #expect(!BrowserTabController.isWebScheme(URL(string: "foreverlm://doc/1")!))
    }

    @Test("A download never overwrites a file already in Downloads")
    func uniqueDownloadDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserWorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = BrowserTabController.uniqueDestination(in: directory, suggestedFilename: "paper.pdf")
        #expect(first.lastPathComponent == "paper.pdf")
        try Data().write(to: first)
        let second = BrowserTabController.uniqueDestination(in: directory, suggestedFilename: "paper.pdf")
        #expect(second.lastPathComponent == "paper 2.pdf")
        #expect(BrowserTabController.uniqueDestination(in: directory, suggestedFilename: "a/b.txt").lastPathComponent == "a-b.txt")
        #expect(BrowserTabController.uniqueDestination(in: directory, suggestedFilename: "").lastPathComponent == "download")
    }

    @Test("A PMC address is retried through the validated downloader, in a tab as in the reader")
    func pmcDownloadAddresses() {
        #expect(WebPageDownloads.isPMCDownloadURL(URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC1234567/pdf/main.pdf")!))
        #expect(WebPageDownloads.isPMCDownloadURL(URL(string: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1234567/")!))
        #expect(!WebPageDownloads.isPMCDownloadURL(URL(string: "https://www.ncbi.nlm.nih.gov/pubmed/1234567")!))
        #expect(!WebPageDownloads.isPMCDownloadURL(URL(string: "https://papers.ssrn.com/sol3/Delivery.cfm/5087321.pdf")!))
    }

    // MARK: Page policy (shared with the reader)

    @Test("A PDF-looking link is followed, not guessed into a download")
    func pdfLookingLinkIsFollowed() {
        let ssrn = URL(string: "https://papers.ssrn.com/sol3/Delivery.cfm/5087321.pdf?abstractid=5087321&mirid=1")!
        #expect(WebPagePolicy.action(for: ssrn, isLinkActivated: true, isMainFrame: true, shouldPerformDownload: false) == .allow)
        #expect(WebPagePolicy.action(for: ssrn, isLinkActivated: true, isMainFrame: true, shouldPerformDownload: true) == .download)
        let zoom = URL(string: "zoommtg://zoom.us/join")!
        #expect(WebPagePolicy.action(for: zoom, isLinkActivated: true, isMainFrame: false, shouldPerformDownload: false) == .openInOtherApp)
        #expect(WebPagePolicy.action(for: zoom, isLinkActivated: false, isMainFrame: false, shouldPerformDownload: false) == .cancel)
    }

    /// No YouTube rabbit hole inside ForeverLM (product owner, 2026-09-28): a page
    /// in a tab or a reader never becomes YouTube. A video plays in the
    /// Reader's one-video player, at its watch address; YouTube's other pages
    /// are refused; an embed in another site stays, and sign-in passes.
    @Test("A page never becomes YouTube: a video goes to the Reader's player, YouTube's other pages are refused")
    func youTubeIsContained() throws {
        func decide(_ address: String, mainFrame: Bool = true) throws -> WebPagePolicy.ActionDecision {
            WebPagePolicy.action(
                for: try #require(URL(string: address)),
                isLinkActivated: true,
                isMainFrame: mainFrame,
                shouldPerformDownload: false
            )
        }
        let watch = try #require(URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"))
        for video in [
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=RDaqz-KE-bpKQ&index=2",
            "https://youtu.be/aqz-KE-bpKQ",
            "https://m.youtube.com/watch?v=aqz-KE-bpKQ",
            "https://www.youtube.com/shorts/aqz-KE-bpKQ",
            "https://www.youtube.com/live/aqz-KE-bpKQ",
            "https://www.youtube.com/embed/aqz-KE-bpKQ",
            "https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ"
        ] {
            #expect(try decide(video) == .openYouTubeVideo(watch), "\(video)")
        }
        // The moment a link points to comes along; the Mix it hung off does not.
        #expect(try decide("https://youtu.be/aqz-KE-bpKQ?t=30") == .openYouTubeVideo(
            try #require(URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ&t=30"))
        ))
        for page in [
            "https://www.youtube.com/",
            "https://youtube.com/feed/subscriptions",
            "https://www.youtube.com/@BlenderOfficial",
            "https://www.youtube.com/results?search_query=mitochondria",
            "https://www.youtube.com/playlist?list=PLcourse",
            "https://www.youtube.com/shorts",
            "https://music.youtube.com/"
        ] {
            #expect(try decide(page) == .refuseYouTubePage, "\(page)")
        }
        // An article's embedded player loads in its frame.
        #expect(try decide("https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ", mainFrame: false) == .allow)
        // Passing through, not YouTube's pages: sign-in and consent.
        #expect(try decide("https://www.youtube.com/signin?action_handle_signin=true&next=%2Fwatch%3Fv%3Daqz-KE-bpKQ") == .allow)
        #expect(try decide("https://consent.youtube.com/m?continue=https://www.youtube.com/") == .allow)
        #expect(try decide("https://accounts.google.com/ServiceLogin?service=youtube") == .allow)
        #expect(try decide("https://www.nature.com/articles/s41586-024-00001-1") == .allow)
    }

    @Test("A saved livestream or embed is a YouTube source, so the Reader plays it rather than refusing it as a page")
    func everyContainedVideoIsAYouTubeSource() {
        for address in [
            "https://www.youtube.com/live/aqz-KE-bpKQ",
            "https://www.youtube.com/v/aqz-KE-bpKQ",
            "https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ"
        ] {
            let source = StudioArticle(url: address, title: "Talk", sourceType: .video)
            #expect(source.isYouTubeURL, "\(address)")
            #expect(YouTubeURLMetadata.watchURL(for: address)?.absoluteString == "https://www.youtube.com/watch?v=aqz-KE-bpKQ")
        }
    }

    @Test("The response decides: a page at a PDF address is shown, a PDF is caught for its paper")
    func responseDecides() {
        let ssrn = URL(string: "https://papers.ssrn.com/sol3/Delivery.cfm/5087321.pdf")!
        // SSRN's check or sign-in page at the PDF's address: shown, as a browser shows it.
        #expect(WebPagePolicy.response(url: ssrn, mimeType: "text/html", contentDisposition: nil, canShowMIMEType: true, capturesPDFs: true) == .show)
        // The PDF it ends on: the paper's.
        #expect(WebPagePolicy.response(url: ssrn, mimeType: "application/pdf", contentDisposition: nil, canShowMIMEType: true, capturesPDFs: true) == .capturePDF)
        // A publisher's generic binary named as a PDF is a PDF too.
        #expect(WebPagePolicy.response(url: ssrn, mimeType: "application/octet-stream", contentDisposition: "attachment; filename=\"paper.pdf\"", canShowMIMEType: false, capturesPDFs: true) == .capturePDF)
        // Off a paper's page, a PDF is shown inline, or saved when the site says attachment.
        #expect(WebPagePolicy.response(url: ssrn, mimeType: "application/pdf", contentDisposition: nil, canShowMIMEType: true, capturesPDFs: false) == .show)
        #expect(WebPagePolicy.response(url: ssrn, mimeType: "application/pdf", contentDisposition: "attachment", canShowMIMEType: true, capturesPDFs: false) == .download)
        // Any other file goes to Downloads, never to the paper.
        let zip = URL(string: "https://example.org/data.zip")!
        #expect(WebPagePolicy.response(url: zip, mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, capturesPDFs: true) == .download)
    }

    @Test("Only a paper's reader takes the PDFs its page leads to; an article's link to a paper's PDF stays that paper's")
    func readerTakesPDFsOnlyForAPaper() {
        #expect(WebPagePolicy.readerPaperID(sourceID: "paper", sourceType: .paper) == "paper")
        // A Substack post linking its paper's PDF became that paper when the
        // reader took the PDF as the post's own.
        for type: StudioSourceType in [.article, .manual, .unclassified, .book, .course, .video, .podcast, .meeting] {
            #expect(WebPagePolicy.readerPaperID(sourceID: "source", sourceType: type) == nil)
        }
        // A source the library no longer holds takes nothing.
        #expect(WebPagePolicy.readerPaperID(sourceID: "gone", sourceType: nil) == nil)
    }

    @Test("An article the app could not read takes the PDF its reader downloads; a readable one does not")
    func unreadableArticleTakesItsPDF() {
        // A publisher check blocked the fetch: the learner gets past it in the
        // reader, and the PDF they download there is the article's.
        for type: StudioSourceType in [.article, .unclassified] {
            #expect(WebPagePolicy.readerPaperID(sourceID: "post", sourceType: type, isUnreadable: true) == "post")
            #expect(WebPagePolicy.readerPaperID(sourceID: "post", sourceType: type, isUnreadable: false) == nil)
        }
        // Other kinds never take one, readable or not.
        for type: StudioSourceType in [.manual, .book, .course, .video, .podcast, .meeting] {
            #expect(WebPagePolicy.readerPaperID(sourceID: "source", sourceType: type, isUnreadable: true) == nil)
        }
        #expect(WebPagePolicy.readerPaperID(sourceID: "paper", sourceType: .paper, isUnreadable: false) == "paper")
    }
}
