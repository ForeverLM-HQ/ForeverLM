import Foundation
import Testing
import WebKit
import SwiftUI
@testable import ForeverLM

@Suite("Linked pages")
struct LinkedPageTests {
    @Test("A Claude artifact link normalizes to its family and id")
    func claudeArtifactURLs() throws {
        let id = "a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d"
        let canonical = "https://claude.ai/code/artifact/\(id)"
        for pasted in [
            "https://claude.ai/code/artifact/\(id)",
            "https://claude.ai/code/artifact/\(id)?v=3",
            "https://claude.ai/code/artifact/\(id)#section",
            "https://claude.ai/code/artifact/\(id)/",
            "https://www.claude.ai/code/artifact/\(id.uppercased())",
            "claude.ai/code/artifact/\(id)",
        ] {
            #expect(try LinkedPage.canonicalURL(from: pasted).absoluteString == canonical, "\(pasted)")
        }
        // A chat artifact shared publicly is a different page and keeps its family.
        #expect(
            try LinkedPage.canonicalURL(from: "https://claude.ai/public/artifacts/\(id)?utm=x").absoluteString
                == "https://claude.ai/public/artifacts/\(id)"
        )
        #expect(LinkedPage.kind(ofURLString: canonical) == .claudeArtifact)
        #expect(LinkedPage.claudeArtifactID(from: URL(string: canonical)!) == id)
    }

    /// A site kept in the library is addressed by its record and served by
    /// the app itself (`LocalSiteSchemeHandler`), under a CSP sandbox.
    @Test("A site kept in the library has a foreverlm-site address the app serves from its folder")
    func localSiteAddresses() throws {
        let url = LinkedPage.localSiteURL(artifactID: "0C9A6B1E-7F7D-4A7E-9F3A-2B5C6D7E8F90")
        #expect(url.absoluteString == "foreverlm-site://0c9a6b1e-7f7d-4a7e-9f3a-2b5c6d7e8f90/")
        #expect(LinkedPage.kind(of: url) == .foreverlmSite)
        #expect(LinkedPage.kind(of: url)?.section == .sites)
        #expect(LinkedPage.localSiteID(from: url) == "0c9a6b1e-7f7d-4a7e-9f3a-2b5c6d7e8f90")
        #expect(LinkedPage.localSiteID(fromURLString: "foreverlm-site://doc_abc123/pages/two.html?embed=1") == "doc_abc123")
        #expect(LinkedPage.localSiteID(fromURLString: "https://example.com/atlas/") == nil)
        #expect(LinkedPage.localSiteID(fromURLString: "foreverlm-site://../") == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalSiteScheme_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = root.appendingPathComponent("Artifacts/site-a/Site", isDirectory: true)
        try FileManager.default.createDirectory(at: site.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try Data("<h1>Home</h1>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data("<h1>Two</h1>".utf8).write(to: site.appendingPathComponent("pages/index.html"))
        try Data((0..<100).map { UInt8($0) }).write(to: site.appendingPathComponent("clip.mp4"))

        func answer(_ address: String, range: String? = nil) -> (status: Int, headers: [AnyHashable: Any], body: Data) {
            var request = URLRequest(url: URL(string: address)!)
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let result = LocalSiteSchemeHandler.answer(for: request, contentRoot: root)
            let http = result.response as! HTTPURLResponse
            return (http.statusCode, http.allHeaderFields, result.body)
        }
        let home = answer("foreverlm-site://site-a/")
        #expect(home.status == 200)
        #expect(home.body == Data("<h1>Home</h1>".utf8))
        #expect((home.headers["Content-Type"] as? String) == "text/html; charset=utf-8")
        #expect((home.headers["Content-Security-Policy"] as? String)?.hasPrefix("sandbox allow-scripts") == true)
        #expect((home.headers["Content-Security-Policy"] as? String)?.contains("allow-same-origin") == false, "each page gets an opaque origin, as on the web host")

        // An animation on a Memory card is served under the card policy: scripts
        // run in an opaque origin, nothing loads but the animation's own files.
        let card = try #require(LocalSiteSchemeHandler.answer(
            for: URLRequest(url: URL(string: "foreverlm-site://site-a/")!),
            contentRoot: root,
            contentSecurityPolicy: LocalSiteServing.cardContentSecurityPolicy
        ).response as? HTTPURLResponse)
        let cardPolicy = try #require(card.allHeaderFields["Content-Security-Policy"] as? String)
        #expect(cardPolicy.hasPrefix("sandbox allow-scripts;"))
        #expect(!cardPolicy.contains("allow-same-origin") && !cardPolicy.contains("allow-popups") && !cardPolicy.contains("allow-forms"))
        #expect(cardPolicy.contains("default-src foreverlm-site: data: blob:"))
        #expect(!cardPolicy.contains("http"), "no network origin is named")
        #expect(cardPolicy.contains("form-action 'none'"))
        #expect(answer("foreverlm-site://site-a/pages").body == Data("<h1>Two</h1>".utf8), "a folder answers with its index.html")
        #expect(answer("foreverlm-site://site-a/pages/?embed=1&step=2").status == 200)
        #expect(answer("foreverlm-site://site-a/missing.html").status == 404)
        #expect(answer("foreverlm-site://site-a/..%2F..%2Fsecret").status == 404)
        #expect(answer("foreverlm-site://site-b/").status == 404)
        let part = answer("foreverlm-site://site-a/clip.mp4", range: "bytes=10-19")
        #expect(part.status == 206)
        #expect(part.body == Data((10..<20).map { UInt8($0) }))
        #expect((part.headers["Content-Range"] as? String) == "bytes 10-19/100")
        #expect(LocalSiteSchemeHandler.byteRange("bytes=-10", length: 100) == 90..<100)
        #expect(LocalSiteSchemeHandler.byteRange("bytes=95-", length: 100) == 95..<100)
        #expect(LocalSiteSchemeHandler.byteRange("bytes=200-", length: 100) == nil)
        #expect(LocalSiteSchemeHandler.byteRange("items=0-1", length: 100) == nil)
    }

    /// Sites are no longer put on the web (2026-10-10): a ForeverLM site is a
    /// library address, and the retired host is a website like any other.
    @Test("A ForeverLM site lives at its library address; the retired sites host is not linked")
    func foreverlmSiteKind() throws {
        #expect(LinkedPage.kind(ofURLString: "https://sites.foreverlm.com/mito-landscape/") == nil)
        #expect(throws: LinkedPageError.unsupported("sites.foreverlm.com")) {
            try LinkedPage.canonicalURL(from: "https://sites.foreverlm.com/mito-landscape/")
        }
        #expect(LinkedPageKind.foreverlmSite.section == .sites)
        #expect(LinkedPageKind.foreverlmSite.textCopySource == .renderedPage)
        #expect(LinkedPage.kind(ofURLString: "https://foreverlm.com/share/abcdefghjkmn") == nil)
        #expect(!LinkedPage.isSignInURL(URL(string: "foreverlm-site://x/"), kind: .foreverlmSite))
        #expect(LinkedPage.title(fromPageTitle: "There is no page here", kind: .foreverlmSite) == nil)
        #expect(LinkedPage.title(fromPageTitle: "Mito Landscape", kind: .foreverlmSite) == "Mito Landscape")
    }

    @Test("A Codex site link keeps its route and loses its query")
    func codexSiteURLs() throws {
        let host = "techbio-companies-landscape.learner-1234.chatgpt.site"
        #expect(try LinkedPage.canonicalURL(from: "https://\(host)").absoluteString == "https://\(host)/")
        #expect(try LinkedPage.canonicalURL(from: "\(host)/?ref=x").absoluteString == "https://\(host)/")
        #expect(
            try LinkedPage.canonicalURL(from: "http://\(host.uppercased())/companies/recursion?tab=1#top").absoluteString
                == "https://\(host)/companies/recursion"
        )
        #expect(LinkedPage.kind(ofURLString: "https://\(host)/") == .codexSite)
        #expect(LinkedPage.isCodexSiteHost("goblin-tales.openai.chatgpt.site"))
        #expect(!LinkedPage.isCodexSiteHost("chatgpt.site"))
        #expect(!LinkedPage.isCodexSiteHost("openai.chatgpt.site"))
        #expect(!LinkedPage.isCodexSiteHost("evil.chatgpt.site.example.com"))
    }

    @Test("Google Docs links still go through the Google rules")
    func googleDocsDelegates() throws {
        #expect(
            try LinkedPage.canonicalURL(from: "https://docs.google.com/document/d/1AbC/edit?usp=sharing").absoluteString
                == "https://docs.google.com/document/d/1AbC/edit"
        )
        #expect(LinkedPage.kind(ofURLString: "https://docs.google.com/document/d/1AbC/edit") == .googleDoc)
        #expect(LinkedPage.kind(ofURLString: "https://docs.google.com/spreadsheets/d/1AbC/edit") == nil)
        #expect(throws: LinkedGoogleDocError.wrongKind("Google Sheet")) {
            _ = try LinkedPage.canonicalURL(from: "https://docs.google.com/spreadsheets/d/1AbC/edit")
        }
    }

    @Test("Everything else is refused with the reason")
    func refusals() {
        #expect(throws: LinkedPageError.empty) { _ = try LinkedPage.canonicalURL(from: " \n") }
        #expect(throws: LinkedPageError.unsupported("example.com")) {
            _ = try LinkedPage.canonicalURL(from: "https://example.com/code/artifact/abcdef12")
        }
        #expect(throws: LinkedPageError.unsupported("chatgpt.com")) {
            _ = try LinkedPage.canonicalURL(from: "https://chatgpt.com/c/123")
        }
        // A site on its own domain cannot be told from any other website.
        #expect(throws: LinkedPageError.unsupported("landscape.example.org")) {
            _ = try LinkedPage.canonicalURL(from: "https://landscape.example.org/")
        }
        #expect(throws: LinkedPageError.noClaudeArtifact) {
            _ = try LinkedPage.canonicalURL(from: "https://claude.ai/code/artifacts")
        }
        #expect(throws: LinkedPageError.noClaudeArtifact) {
            _ = try LinkedPage.canonicalURL(from: "https://claude.ai/chat/abc")
        }
        #expect(throws: LinkedPageError.noClaudeArtifact) {
            _ = try LinkedPage.canonicalURL(from: "https://claude.ai/code/artifact/not-hex!")
        }
        #expect(LinkedPage.kind(ofURLString: "https://example.com/") == nil)
        for error in [LinkedPageError.empty, .notAURL, .unsupported("x"), .noClaudeArtifact] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("A record's kind follows its linked URL")
    func recordKind() {
        func record(_ url: String?) -> ArtifactRecord {
            ArtifactRecord(
                id: "a", title: "T", homeNotebookID: nil, linkedNotebookIDs: [], isDraft: false,
                linkedURL: url, createdAt: Date(), updatedAt: Date()
            )
        }
        #expect(record(nil).linkedKind == nil)
        #expect(record("https://docs.google.com/document/d/1AbC/edit").linkedKind == .googleDoc)
        #expect(record("https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d").linkedKind == .claudeArtifact)
        #expect(record("https://x.y.chatgpt.site/").linkedKind == .codexSite)
        #expect(record("https://example.com/").linkedKind == nil)
        #expect(record("https://example.com/").isLinked)
    }

    @Test("Sign-in is read from the address for Google and Claude, from the status for Codex")
    func signInSignals() {
        #expect(LinkedPage.isSignInURL(URL(string: "https://accounts.google.com/v3/signin"), kind: .googleDoc))
        #expect(LinkedPage.isSignInURL(URL(string: "https://claude.ai/login?returnTo=%2Fcode"), kind: .claudeArtifact))
        #expect(!LinkedPage.isSignInURL(URL(string: "https://claude.ai/code/artifact/abcdef12"), kind: .claudeArtifact))
        #expect(LinkedPage.isSignInURL(URL(string: "https://auth.openai.com/authorize"), kind: .codexSite))
        #expect(!LinkedPage.isSignInURL(URL(string: "https://a.b.chatgpt.site/"), kind: .codexSite))
        #expect(LinkedPage.isSignInStatus(401, kind: .codexSite))
        #expect(!LinkedPage.isSignInStatus(200, kind: .codexSite))
        #expect(!LinkedPage.isSignInStatus(401, kind: .claudeArtifact))
        #expect(!LinkedPage.isSignInStatus(nil, kind: .codexSite))
    }

    @Test("Generic titles never become the doc's name")
    func titles() {
        #expect(LinkedPage.title(fromPageTitle: "Claude Artifact", kind: .claudeArtifact) == nil)
        #expect(LinkedPage.title(fromPageTitle: "Claude", kind: .claudeArtifact) == nil)
        #expect(LinkedPage.title(fromPageTitle: "URL Shape Probe - Claude", kind: .claudeArtifact) == "URL Shape Probe")
        #expect(LinkedPage.title(fromPageTitle: "Sign in required", kind: .codexSite) == nil)
        #expect(LinkedPage.title(fromPageTitle: "Not Found", kind: .codexSite) == nil)
        #expect(LinkedPage.title(fromPageTitle: " TechBio Companies ", kind: .codexSite) == "TechBio Companies")
        #expect(LinkedPage.title(fromPageTitle: "Plan - Google Docs", kind: .googleDoc) == "Plan")
    }

    @Test("Only the frame that holds the content is a text copy")
    func frames() {
        // Observed on a live artifact: chrome, a "Loading..." wrapper, then the
        // artifact as an about:srcdoc document with no host.
        #expect(LinkedPage.frameCarriesText(host: nil, href: "about:srcdoc", isMainFrame: false, kind: .claudeArtifact))
        #expect(!LinkedPage.frameCarriesText(host: "www.claudeusercontent.com", href: "https://www.claudeusercontent.com/artifact/x", isMainFrame: false, kind: .claudeArtifact))
        #expect(!LinkedPage.frameCarriesText(host: "claude.ai", href: "https://claude.ai/code/artifact/x", isMainFrame: true, kind: .claudeArtifact))
        #expect(!LinkedPage.frameCarriesText(host: nil, href: nil, isMainFrame: true, kind: .claudeArtifact))
        #expect(LinkedPage.frameCarriesText(host: "a.b.chatgpt.site", href: "https://a.b.chatgpt.site/", isMainFrame: true, kind: .codexSite))
        #expect(!LinkedPage.frameCarriesText(host: "cdn.example.com", href: nil, isMainFrame: false, kind: .codexSite))
        #expect(!LinkedPage.frameCarriesText(host: "docs.google.com", href: nil, isMainFrame: true, kind: .googleDoc))
        #expect(LinkedPageKind.googleDoc.textCopySource == .export)
        #expect(LinkedPageKind.claudeArtifact.textCopySource == .renderedPage)
    }

    @Test("A sign-in page is known by its title where the address does not change")
    func signInTitles() {
        #expect(LinkedPage.isSignInTitle("Sign in – Claude", kind: .claudeArtifact))
        #expect(LinkedPage.isSignInTitle("Log in - Claude", kind: .claudeArtifact))
        #expect(!LinkedPage.isSignInTitle("Protein Folding Explorer – Compare Structures & Energies", kind: .claudeArtifact))
        #expect(LinkedPage.isSignInTitle("Sign in required", kind: .codexSite))
        #expect(!LinkedPage.isSignInTitle("TechBio Companies", kind: .codexSite))
        #expect(LinkedPage.isSignInTitle("Sign in - Google Accounts", kind: .googleDoc))
        #expect(!LinkedPage.isSignInTitle("Plan - Google Docs", kind: .googleDoc))
        #expect(!LinkedPage.isSignInTitle(nil, kind: .claudeArtifact))
        #expect(!LinkedPage.isSignInTitle("  ", kind: .claudeArtifact))
    }

    @Test("Reported text is folded to prose")
    func normalizedText() {
        #expect(LinkedPage.normalizedText("  Title  \n\n\n\nBody line.  \r\nNext.\n\n\n") == "Title\n\nBody line.\nNext.")
        #expect(LinkedPage.normalizedText("\n\n  \n") == "")
        // The report is Markdown: a nested list item keeps its indentation,
        // a tab counts as two spaces, and an indented sentence does not.
        #expect(LinkedPage.normalizedText("# Title\n\n- one\n  - two  \n\t1. three\n   prose") == "# Title\n\n- one\n  - two\n  1. three\nprose")
        #expect(LinkedPage.isListItem("- a"))
        #expect(LinkedPage.isListItem("12. a"))
        #expect(!LinkedPage.isListItem("-a"))
        #expect(!LinkedPage.isListItem("2026. A year"))
    }

    @Test("Each kind names itself")
    func names() {
        for kind in LinkedPageKind.allCases {
            #expect(!kind.label.isEmpty)
            #expect(!kind.productName.isEmpty)
            #expect(!kind.symbolName.isEmpty)
            #expect(kind.placeholderTitle == kind.label)
        }
        #expect(LinkedPageKind.googleDoc.label == LinkedGoogleDoc.label)
        #expect(LinkedPageKind.codexSite.rawValue == "codex_site")
    }

    @Test("A Google Doc is a Doc; a Claude artifact and a Codex site are Sites")
    func sections() {
        #expect(LinkedPageKind.googleDoc.section == .docs)
        #expect(LinkedPageKind.claudeArtifact.section == .sites)
        #expect(LinkedPageKind.codexSite.section == .sites)
        #expect(ArtifactSection.docs.linkedKinds == [.googleDoc])
        #expect(ArtifactSection.sites.linkedKinds == [.claudeArtifact, .codexSite, .foreverlmSite])

        let now = Date()
        func record(_ url: String?) -> ArtifactRecord {
            ArtifactRecord(id: UUID().uuidString, title: "t", homeNotebookID: nil, linkedNotebookIDs: [], linkedURL: url, createdAt: now, updatedAt: now)
        }
        #expect(record(nil).section == .docs)
        #expect(record("https://docs.google.com/document/d/1abcDEFghiJKLmnoPQRstuVWxyz0123456789/edit").section == .docs)
        #expect(record("https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d").section == .sites)
        #expect(record("https://techbio.learner-1234.chatgpt.site/").section == .sites)
        // A linked URL no build recognizes is still listed, as a Doc.
        #expect(record("https://example.com/page").section == .docs)
    }

    @Test("Only a Google Doc is named by its own page, so only it takes no title of ours")
    func googleDocNamesItself() {
        let now = Date()
        func record(_ url: String?) -> ArtifactRecord {
            ArtifactRecord(id: UUID().uuidString, title: "t", homeNotebookID: nil, linkedNotebookIDs: [], linkedURL: url, createdAt: now, updatedAt: now)
        }
        #expect(record("https://docs.google.com/document/d/1abcDEFghiJKLmnoPQRstuVWxyz0123456789/edit").namesItself)
        #expect(!record(nil).namesItself)
        #expect(!record("https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d").namesItself)
        #expect(!record("https://techbio.learner-1234.chatgpt.site/").namesItself)
    }

    @Test("A section's link sheet refuses the other section's links with where they go")
    func sectionScopedLinks() throws {
        let site = "https://techbio.learner-1234.chatgpt.site/"
        let artifact = "https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d"
        let googleDoc = "https://docs.google.com/document/d/1abcDEFghiJKLmnoPQRstuVWxyz0123456789/edit"

        #expect(try LinkedPage.canonicalURL(from: site, in: .sites).absoluteString == site)
        #expect(try LinkedPage.canonicalURL(from: artifact, in: .sites).absoluteString == artifact)
        #expect(try LinkedPage.canonicalURL(from: googleDoc, in: .docs).absoluteString == googleDoc)

        #expect(throws: LinkedPageError.wrongSection(kind: .codexSite, section: .docs)) {
            try LinkedPage.canonicalURL(from: site, in: .docs)
        }
        #expect(throws: LinkedPageError.wrongSection(kind: .claudeArtifact, section: .docs)) {
            try LinkedPage.canonicalURL(from: artifact, in: .docs)
        }
        #expect(throws: LinkedPageError.wrongSection(kind: .googleDoc, section: .sites)) {
            try LinkedPage.canonicalURL(from: googleDoc, in: .sites)
        }
        let message = LinkedPageError.wrongSection(kind: .codexSite, section: .docs).errorDescription ?? ""
        #expect(message.contains("Codex Site") && message.contains("Sites"))
        // A link that is none of the three is refused the same way in either section.
        #expect(throws: LinkedPageError.unsupported("example.com")) {
            try LinkedPage.canonicalURL(from: "https://example.com/x", in: .sites)
        }
    }

    @Test("WebKit's link commands on a Site's source card become Reader and window commands; an ordinary link keeps its own")
    func siteSourceCardLinkCommands() {
        typealias Disposition = ForeverLMWebView.LinkMenuDisposition
        // A source card: open here, open in a window of its own, and no download of a foreverlm:// address.
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierOpenLink", isSourceLink: true) == Disposition.openInReader)
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierOpenLinkInNewWindow", isSourceLink: true) == Disposition.openInNewWindow)
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierDownloadLinkedFile", isSourceLink: true) == Disposition.remove)
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierCopyLink", isSourceLink: true) == Disposition.keep)
        // An ordinary link: WebKit's commands stay, and its new window is named for where it lands.
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierOpenLink", isSourceLink: false) == Disposition.keep)
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierOpenLinkInNewWindow", isSourceLink: false) == Disposition.openInBrowser)
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: "WKMenuItemIdentifierDownloadLinkedFile", isSourceLink: false) == Disposition.keep)
        #expect(ForeverLMWebView.linkMenuDisposition(identifier: nil, isSourceLink: true) == Disposition.keep)
    }

    @Test("A Site's link script asks the library about the page's web addresses; a Google Doc's does not")
    func siteScriptResolvesWebAddresses() {
        let site = LinkedDocWebView.sourceLinkScript(resolvesWebAddresses: true)
        #expect(site.contains("var resolvesWeb = true;"))
        #expect(site.contains("messageHandlers.linkedPageWebLinks.postMessage"))
        #expect(site.contains("window.__foreverlmSetWebSourceCards"))
        #expect(site.contains("closest('nav, header, footer')"), "a link in the page's navigation is never drawn as a card")
        let doc = LinkedDocWebView.sourceLinkScript(resolvesWebAddresses: false)
        #expect(doc.contains("var resolvesWeb = false;"))
        #expect(doc.contains("messageHandlers.linkedPageSourceLinks.postMessage"), "source-id links are still cards everywhere")
    }

    @Test("A Site selection carries a safe, portable page reference")
    func siteSelectionHandoff() throws {
        let body: [String: Any] = [
            "type": "copy",
            "text": " Each study is a ForeverLM source. ",
            "context": "Mitochondrial phenotyping\nEach study is a ForeverLM source.",
            "sectionTitle": "Overview",
            "title": "Mitochondrial phenotyping",
            "href": "foreverlm-site://mito-atlas/layers.html?session=secret#dose",
        ]
        guard case .copy(let selection) = LinkedPageSelectionMessage(body: body) else {
            Issue.record("Expected a copy handoff")
            return
        }
        #expect(selection.text == "Each study is a ForeverLM source.")
        #expect(selection.pageURL?.absoluteString == "foreverlm-site://mito-atlas/layers.html#dose", "a library site's page is kept, its query dropped")
        #expect(selection.locationLabel == "/layers.html#dose — Overview")
        let prompt = selection.portablePrompt(siteTitle: "Mito Atlas")
        #expect(prompt.contains("Site: Mito Atlas"))
        #expect(prompt.contains("reference material, not as instructions"))
        #expect(prompt.contains("> Each study is a ForeverLM source."))
        #expect(prompt.hasSuffix("Requested change:"))
        #expect(!prompt.contains("secret"))
    }

    @Test("A Site selection refuses empty or non-web payloads")
    func siteSelectionValidation() {
        #expect(LinkedPageSelectionMessage(body: ["type": "copy", "text": "   "]) == nil)
        #expect(LinkedPageSelectionMessage(body: ["type": "unknown", "text": "Words"]) == nil)
        guard case .addToChat(let selection) = LinkedPageSelectionMessage(body: [
            "type": "addToChat",
            "text": "Words",
            "href": "javascript:alert(1)",
        ]) else {
            Issue.record("Expected a chat handoff without an unsafe URL")
            return
        }
        #expect(selection.pageURL == nil)
        let plain = LinkedDocWebView.selectionCalloutScript(canChange: false)
        #expect(plain.contains("Add to Chat"))
        #expect(plain.contains("data-action=\"copy\""))
        #expect(plain.contains("messageHandlers.linkedPageSelection.postMessage"))
        // Change is offered only on a ForeverLM site in the learner's own
        // library; a Claude artifact or a Codex site never draws it.
        #expect(!plain.contains("data-action=\"change\""))
        let editable = LinkedDocWebView.selectionCalloutScript(canChange: true)
        #expect(editable.contains("data-action=\"change\">Change</button>"))
        guard case .change(let change) = LinkedPageSelectionMessage(body: [
            "type": "change",
            "text": "COMPOUNDS WITHOUT A DEVELOPER\nReal pharmacology, no one carrying it",
            "href": "foreverlm-site://atlas/",
        ]) else {
            Issue.record("Expected a change request")
            return
        }
        #expect(change.text.hasPrefix("COMPOUNDS"))
        #expect(change.pageURL?.absoluteString == "foreverlm-site://atlas/")
    }

    @Test("A failed load says why; a cancelled or downloaded one says nothing")
    func loadFailureNotices() {
        let timedOut = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        #expect(LinkedPage.loadFailureNotice(timedOut) == .failed("The request timed out"))
        #expect(LinkedPage.loadFailureNotice(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) == nil)
        #expect(LinkedPage.loadFailureNotice(NSError(domain: "WebKitErrorDomain", code: 102)) == nil)
        #expect(LinkedPage.loadFailureNotice(NSError(domain: "WebKitErrorDomain", code: 101, userInfo: [NSLocalizedDescriptionKey: ""])) == .failed(""))

        #expect(LinkedPageLoadNotice.failed("The request timed out").text(kind: .googleDoc) == "Google Docs did not load — The request timed out")
        #expect(LinkedPageLoadNotice.failed("").text(kind: .claudeArtifact) == "Claude did not load")
        #expect(LinkedPageLoadNotice.slow.text(kind: .codexSite) == "Still waiting for ChatGPT")
        #expect(LinkedPageLoadNotice.slow.symbolName != LinkedPageLoadNotice.failed("x").symbolName)
    }

    /// An open is a read (product owner, 2026-09-20: "don't reorder these upon
    /// click"): the text a page reports as it draws fills an empty copy once,
    /// and a copy that exists — an animation's description and sources from
    /// `save_animation` — stands, undated and so unmoved in the list, until
    /// Refresh Text Copy asks for the page's text again.
    @Test("opening a linked page fills an empty text copy once and leaves an existing one undated")
    @MainActor
    func openingLinkedPageLeavesExistingTextCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedPageOpenTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let animation = try await storage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://krebs/")!, title: "The Krebs cycle",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation, sourceIDs: []
        )
        #expect(await vm.linkedArtifactTextCopyIsEmpty(animation.id))

        // The first open finds no copy: the rendering fills it and dates the record.
        #expect(await vm.adoptLinkedPageText(animation.id, text: "Step 1 of 8\n\nCitrate forms"))
        let filled = try await storage.artifactMarkdown(animation.id)
        #expect(filled.markdown == "Step 1 of 8\n\nCitrate forms")
        #expect(filled.artifact.updatedAt > animation.updatedAt)
        #expect(await !vm.linkedArtifactTextCopyIsEmpty(animation.id))

        // A later open catches the page mid-play; the copy and the date stand.
        #expect(await !vm.adoptLinkedPageText(animation.id, text: "Step 5 of 8\n\n17.5 s"))
        let kept = try await storage.artifactMarkdown(animation.id)
        #expect(kept.markdown == filled.markdown)
        #expect(kept.artifact.updatedAt == filled.artifact.updatedAt)

        // Refresh Text Copy is the ask: the page's text again, and dated.
        #expect(await vm.adoptLinkedPageText(animation.id, text: "Step 5 of 8\n\n17.5 s", replacingExistingCopy: true))
        let refreshed = try await storage.artifactMarkdown(animation.id)
        #expect(refreshed.markdown == "Step 5 of 8\n\n17.5 s")
        #expect(refreshed.artifact.updatedAt > kept.artifact.updatedAt)

        // Empty text is never a copy, asked for or not.
        #expect(await !vm.adoptLinkedPageText(animation.id, text: "  \n ", replacingExistingCopy: true))
        #expect(try await storage.artifactMarkdown(animation.id).markdown == refreshed.markdown)
    }
}

/// The web view's navigation delegate is what puts a load notice over the
/// page; these drive it as WebKit would.
@Suite("Linked page load notices")
@MainActor
struct LinkedPageLoadNoticeTests {
    private final class Reported {
        var notice: LinkedPageLoadNotice?
        var url: URL?
        var title: String?
        var status: Int?
    }

    private func makeCoordinator(_ reported: Reported, slowAfter delay: TimeInterval) -> LinkedDocWebView.Coordinator {
        let view = LinkedDocWebView(
            url: URL(string: "https://docs.google.com/document/d/abc123/edit")!,
            kind: .googleDoc,
            reloadGeneration: 0,
            zoomScale: 1,
            currentURL: Binding(get: { reported.url }, set: { reported.url = $0 }),
            pageTitle: Binding(get: { reported.title }, set: { reported.title = $0 }),
            statusCode: Binding(get: { reported.status }, set: { reported.status = $0 }),
            loadNotice: Binding(get: { reported.notice }, set: { reported.notice = $0 }),
            onText: { _ in },
            onAddSelectionToChat: { _ in },
            onCopySelection: { _ in },
            onOpenSource: { _ in },
            onOpenSourceInNewWindow: { _ in },
            sourceWindowTargets: { [] },
            sourceCardForToken: { _ in nil }
        )
        let coordinator = view.makeCoordinator()
        coordinator.slowLoadNoticeDelay = delay
        return coordinator
    }

    @Test("WebKit giving up puts the reason over the page until the next load starts")
    func failureThenRetry() {
        let reported = Reported()
        let coordinator = makeCoordinator(reported, slowAfter: 60)
        let webView = WKWebView()
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        ))
        #expect(reported.notice == .failed("The request timed out"))

        // Reload: the new load clears the old verdict.
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        #expect(reported.notice == nil)
        // A cancelled load — a reload or profile switch taking over — is not a failure.
        coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(reported.notice == nil)
        coordinator.webView(webView, didFail: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(reported.notice == nil)
        coordinator.stopObserving()
    }

    @Test("A page that has not committed after the delay says it is waiting; committing clears it")
    func slowThenCommit() async throws {
        let reported = Reported()
        let coordinator = makeCoordinator(reported, slowAfter: 0.05)
        let webView = WKWebView()
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        #expect(reported.notice == nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(reported.notice == .slow)
        coordinator.webView(webView, didCommit: nil)
        #expect(reported.notice == nil)
        coordinator.stopObserving()
    }

    @Test("A page that commits in time never says it was waiting")
    func promptCommit() async throws {
        let reported = Reported()
        let coordinator = makeCoordinator(reported, slowAfter: 0.05)
        let webView = WKWebView()
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(webView, didCommit: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(reported.notice == nil)
        coordinator.stopObserving()
    }
}
