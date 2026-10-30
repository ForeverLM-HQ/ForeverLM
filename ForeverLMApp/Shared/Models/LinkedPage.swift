import Foundation

/// The kinds of page the library can hold as a *linked doc*: a page whose
/// canonical text lives somewhere else and is shown here in its own web view,
/// with a read-only text copy kept beside the link for chat and review.
///
/// The kind is a pure function of the linked URL's host and path, so nothing
/// is stored for it and a record made by an older build — always a Google Doc,
/// the only kind there was — reads the same on every device.
enum LinkedPageKind: String, CaseIterable, Sendable {
    /// A Google Doc at `docs.google.com/document/d/<id>/edit`.
    case googleDoc = "google_doc"
    /// A Claude artifact at `claude.ai/code/artifact/<uuid>`, or a chat
    /// artifact shared at `claude.ai/public/artifacts/<uuid>`.
    case claudeArtifact = "claude_artifact"
    /// A Codex (ChatGPT) site at `<site>.<workspace>.chatgpt.site`. A site on
    /// its own domain cannot be told from any other website and is not one.
    case codexSite = "codex_site"
    /// A site made in ForeverLM itself — HTML the learner (or a chat) wrote,
    /// kept in the library at `foreverlm-site://<id>/` (`save_site`;
    /// docs/docs-design.md → Sites) and served as written from its own files.
    case foreverlmSite = "foreverlm_site"

    /// What the list row, the metadata caption and the menus call one of these.
    var label: String {
        switch self {
        case .googleDoc: return LinkedGoogleDoc.label
        case .claudeArtifact: return "Claude Artifact"
        case .codexSite: return "Codex Site"
        case .foreverlmSite: return "ForeverLM Site"
        }
    }

    /// The product a linked doc is unlinked *from* and signed in *to*.
    var productName: String {
        switch self {
        case .googleDoc: return "Google Docs"
        case .claudeArtifact: return "Claude"
        case .codexSite: return "ChatGPT"
        case .foreverlmSite: return "ForeverLM"
        }
    }

    /// The title a linked doc carries until the page's own is read or the
    /// writer renames it.
    var placeholderTitle: String { label }

    /// The glyph beside a linked doc's title in menus and sheets, where AppKit
    /// sizes the symbol. Rows, cards and headers draw the product's own mark
    /// instead (`LinkedPageIcon`).
    var symbolName: String {
        switch self {
        case .googleDoc: return LinkedGoogleDoc.symbolName
        case .claudeArtifact: return "sparkles.rectangle.stack"
        case .codexSite: return "globe"
        case .foreverlmSite: return "globe.badge.chevron.backward"
        }
    }

    /// Where the read-only text copy comes from.
    var textCopySource: LinkedPageTextCopySource {
        switch self {
        case .googleDoc: return .export
        case .claudeArtifact, .codexSite, .foreverlmSite: return .renderedPage
        }
    }
}

/// How a linked doc's text copy is taken.
enum LinkedPageTextCopySource: Sendable {
    /// A plain-text export endpoint the app fetches with the browser's cookies.
    /// Google's editor draws on a canvas, so only its export reads as prose.
    case export
    /// The visible text of the page once it has rendered in the doc's web view.
    /// Neither Claude nor Codex exposes an export; a bare fetch of a Claude
    /// artifact returns an application shell, and a Codex site may be a
    /// script-rendered page or answer a signed-out request with a sign-in.
    case renderedPage
}

/// Which of the three library sections a doc record belongs to. The product owner's
/// decision of 2026-09-08 ("make sure you do a split within the app between
/// sites and docs"): **Docs** holds what is written here — Markdown docs — and
/// documents that live in an editor, which is a linked Google Doc; **Sites**
/// holds pages that live on the web and render here as themselves — a Claude
/// artifact, a Codex site, a ForeverLM site. A Markdown doc is a Doc whether
/// or not it has a published page (product owner, 2026-09-10). **Animations**
/// (2026-09-17) holds moving explanations of the library's sources, hosted
/// the way a ForeverLM site is and told apart by the record's own kind
/// (docs/animations-design.md). Docs and Sites are derived from the link,
/// never stored, so nothing syncs for them; the animation kind rides the
/// record's payload, and a build that predates it lists the record under
/// Sites, which is what it is on the wire.
enum ArtifactSection: String, CaseIterable, Sendable {
    case docs
    case sites
    case animations

    /// The rail row, the pane title and the home's heading.
    var title: String {
        switch self {
        case .docs: return "Pages"
        case .sites: return "Sites"
        case .animations: return "Animations"
        }
    }

    /// One entry, as the empty states and the "Select a …" placeholder call it.
    var noun: String {
        switch self {
        case .docs: return "page"
        case .sites: return "site"
        case .animations: return "animation"
        }
    }

    var pluralNoun: String {
        switch self {
        case .docs: return "pages"
        case .sites: return "sites"
        case .animations: return "animations"
        }
    }

    /// The linked kinds a section holds; a Markdown doc is a Doc without a
    /// kind, and an animation is a ForeverLM site by its link, held apart by
    /// its record kind rather than by a linked kind of its own.
    var linkedKinds: [LinkedPageKind] {
        LinkedPageKind.allCases.filter { $0.section == self }
    }

    /// What the section's one prominent button is called. Docs links one
    /// product's documents and says so; Sites links two products' pages;
    /// nothing is linked into Animations — one is made, in a chat.
    var linkActionTitle: String {
        switch self {
        case .docs: return "Link a Google Doc…"
        case .sites: return "Link a Site…"
        case .animations: return "Animate a Source…"
        }
    }
}

extension LinkedPageKind {
    /// Where a linked page of this kind is listed. A Google Doc is a document
    /// in an editor and stays beside the Markdown docs; the other two are pages.
    var section: ArtifactSection {
        switch self {
        case .googleDoc: return .docs
        case .claudeArtifact, .codexSite, .foreverlmSite: return .sites
        }
    }
}

/// Link parsing for every kind of linked page. The link is identity, so it is
/// handled by deterministic code: each family of URL normalizes to one
/// canonical form, and anything outside the three families is refused with
/// the reason.
/// What a linked page's load has to say over the page: nothing while it is
/// coming in, that it is late once `LinkedPage.slowLoadNoticeDelay` has passed
/// without a commit, and why once WebKit has given up. Each comes with the
/// header's Reload beside it.
enum LinkedPageLoadNotice: Equatable, Sendable {
    /// The page has not answered yet.
    case slow
    /// WebKit gave up, with its reason; empty when it gave none.
    case failed(String)

    func text(kind: LinkedPageKind) -> String {
        switch self {
        case .slow:
            return "Still waiting for \(kind.productName)"
        case .failed(let reason):
            return reason.isEmpty
                ? "\(kind.productName) did not load"
                : "\(kind.productName) did not load — \(reason)"
        }
    }

    var symbolName: String {
        switch self {
        case .slow: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

enum LinkedPage {
    /// The canonical URL for a link the user pasted, or the reason it is not
    /// a page Docs can hold. Google Docs links keep their own, more specific
    /// refusals (Sheets, Slides, published snapshots).
    static func canonicalURL(from rawString: String) throws -> URL {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LinkedPageError.empty }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let host = url.host?.lowercased() else {
            throw LinkedPageError.notAURL
        }
        if host == "docs.google.com" {
            return try LinkedGoogleDoc.canonicalEditURL(from: trimmed)
        }
        if host == "claude.ai" || host == "www.claude.ai" {
            guard let canonical = claudeArtifactURL(from: url) else {
                throw LinkedPageError.noClaudeArtifact
            }
            return canonical
        }
        if isCodexSiteHost(host) {
            return codexSiteURL(from: url, host: host)
        }
        throw LinkedPageError.unsupported(host)
    }

    /// The same, from one section's link sheet: a link that belongs to the
    /// other section is refused with where it goes, so a Codex site pasted
    /// into Docs is not silently filed under Sites, and a Google Doc pasted
    /// into Sites is not made a site.
    static func canonicalURL(from rawString: String, in section: ArtifactSection) throws -> URL {
        let url = try canonicalURL(from: rawString)
        let kind = kind(of: url) ?? .googleDoc
        guard kind.section == section else {
            throw LinkedPageError.wrongSection(kind: kind, section: section)
        }
        return url
    }

    /// The kind of a linked URL; nil for a URL that is none of the three.
    static func kind(of url: URL) -> LinkedPageKind? {
        if localSiteID(from: url) != nil { return .foreverlmSite }
        guard let host = url.host?.lowercased() else { return nil }
        if host == "docs.google.com" {
            return SourceService.googleDocumentID(from: url) == nil ? nil : .googleDoc
        }
        if host == "claude.ai" || host == "www.claude.ai" {
            return claudeArtifactID(from: url) == nil ? nil : .claudeArtifact
        }
        if isCodexSiteHost(host) { return .codexSite }
        return nil
    }

    static func kind(ofURLString string: String) -> LinkedPageKind? {
        URL(string: string).flatMap(kind(of:))
    }

    // MARK: Claude artifacts

    /// The artifact id of a claude.ai link: the segment after `code/artifact`
    /// or `public/artifacts`. Anything else on claude.ai — a chat, the gallery,
    /// settings — is not an artifact.
    static func claudeArtifactID(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3 else { return nil }
        let family = (parts[0].lowercased(), parts[1].lowercased())
        guard family == ("code", "artifact") || family == ("public", "artifacts") else { return nil }
        let id = parts[2].lowercased()
        guard id.count >= 8, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return id
    }

    /// One artifact, one URL: the family it was shared under is kept (a public
    /// share and a code artifact are different pages), and query, fragment and
    /// anything after the id are dropped.
    static func claudeArtifactURL(from url: URL) -> URL? {
        guard let id = claudeArtifactID(from: url) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let family = parts[1].lowercased() == "artifact" ? "code/artifact" : "public/artifacts"
        return URL(string: "https://claude.ai/\(family)/\(id)")
    }

    // MARK: Codex sites

    /// `<site>.<workspace>.chatgpt.site`; the bare domain and a single label
    /// under it are OpenAI's, not a site.
    static func isCodexSiteHost(_ host: String) -> Bool {
        guard host.hasSuffix(".chatgpt.site") else { return false }
        let labels = host.split(separator: ".")
        return labels.count >= 4 && labels.allSatisfy { !$0.isEmpty }
    }

    /// The page's own address, made canonical: https, the host lowercased,
    /// the path kept (a site may have several routes, and each is its own
    /// page), query and fragment dropped, an empty path written as `/`.
    static func codexSiteURL(from url: URL, host: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        let path = url.path
        components.path = path.isEmpty ? "/" : path
        return components.url ?? URL(string: "https://\(host)/")!
    }

    // MARK: Sites kept in the library

    /// A ForeverLM site or animation lives in the learner's own library: its
    /// files sit under the record's folder in the content root and travel
    /// between devices inside the Artifact's CloudKit body asset. Its address
    /// is `foreverlm-site://<artifact-id>/`, which the app's web views serve
    /// from that folder (`LocalSiteSchemeHandler`) — each record its own
    /// origin, and nothing is put on the web. The product owner (2026-09-22):
    /// "data should stay in the user's icloud in general".
    static let localSiteScheme = LocalSiteServing.scheme

    static func localSiteURL(artifactID: String) -> URL {
        URL(string: "\(localSiteScheme)://\(artifactID.lowercased())/")!
    }

    /// The record a local site address names, lowercased as WebKit hands a
    /// host back; nil for any other address.
    static func localSiteID(from url: URL) -> String? {
        LocalSiteServing.siteID(from: url)
    }

    static func localSiteID(fromURLString string: String?) -> String? {
        string.flatMap(URL.init(string:)).flatMap(localSiteID(from:))
    }

    // MARK: What the page reports

    /// Whether a page the web view landed on is the product's sign-in rather
    /// than the page. Google and Claude move to a sign-in address; a
    /// workspace-shared Codex site answers 401 in place, which the view reads
    /// from the response instead, and only its sign-in button leaves for
    /// OpenAI's auth host.
    static func isSignInURL(_ url: URL?, kind: LinkedPageKind) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        switch kind {
        case .googleDoc:
            return LinkedGoogleDoc.isSignInURL(url)
        case .claudeArtifact:
            return (host == "claude.ai" || host == "www.claude.ai")
                && (url.path.lowercased().hasPrefix("/login") || url.path.lowercased().hasPrefix("/magic-link"))
        case .codexSite:
            return host == "auth.openai.com" || host.hasSuffix(".auth.openai.com")
                || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
        case .foreverlmSite:
            // A ForeverLM site is served from the library; nothing to sign in to.
            return false
        }
    }

    /// Whether an HTTP status the page answered with means "sign in first".
    static func isSignInStatus(_ status: Int?, kind: LinkedPageKind) -> Bool {
        guard let status else { return false }
        switch kind {
        case .googleDoc, .claudeArtifact, .foreverlmSite: return false
        case .codexSite: return status == 401 || status == 403
        }
    }

    /// The page's own name from a document title, or nil when the title is the
    /// product's generic one — a shell that has not rendered, a sign-in, a
    /// not-found — which must never become the doc's title.
    static func title(fromPageTitle pageTitle: String, kind: LinkedPageKind) -> String? {
        switch kind {
        case .googleDoc:
            return LinkedGoogleDoc.title(fromPageTitle: pageTitle)
        case .claudeArtifact:
            var name = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [" - Claude", " – Claude", " | Claude"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let generic: Set<String> = ["", "claude", "claude artifact", "artifact", "artifacts", "claude code", "sign in", "log in", "login"]
            guard !generic.contains(name.lowercased()) else { return nil }
            return String(name.prefix(500))
        case .codexSite:
            let name = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let generic: Set<String> = ["", "sign in required", "not found", "404", "chatgpt", "sign in", "log in", "login"]
            guard !generic.contains(name.lowercased()) else { return nil }
            return String(name.prefix(500))
        case .foreverlmSite:
            let name = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let generic: Set<String> = ["", "there is no page here", "foreverlm sites", "not found", "404"]
            guard !generic.contains(name.lowercased()) else { return nil }
            return String(name.prefix(500))
        }
    }

    /// Whether the text a frame of the page reports is the page's content.
    ///
    /// A Claude artifact is three documents deep, observed 2026-09-08: the top
    /// frame is claude.ai's chrome ("Content is user-generated and unverified",
    /// Copy), inside it a `www.claudeusercontent.com` wrapper whose whole text
    /// is "Loading...", and inside that the artifact itself as an
    /// `about:srcdoc` document — a frame with no host. Only the last is the
    /// page. A Codex site is its top frame; a Google Doc's frames carry no
    /// prose at all (the editor draws on a canvas).
    static func frameCarriesText(host: String?, href: String?, isMainFrame: Bool, kind: LinkedPageKind) -> Bool {
        switch kind {
        case .googleDoc:
            return false
        case .claudeArtifact:
            guard !isMainFrame else { return false }
            if let host, !host.isEmpty { return false }
            return href == nil || href?.lowercased().hasPrefix("about:") == true
        case .codexSite, .foreverlmSite:
            return isMainFrame
        }
    }

    /// Whether a document title is the product's sign-in rather than the page.
    /// Claude does not redirect a signed-out visitor: the artifact's own URL
    /// answers with a page titled "Sign in – Claude" whose text is "Sign in to
    /// view this page", so the title is the signal there. A Codex site's 401
    /// page is titled "Sign in required".
    static func isSignInTitle(_ title: String?, kind: LinkedPageKind) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !title.isEmpty else {
            return false
        }
        switch kind {
        case .googleDoc:
            return title.hasSuffix("google accounts")
        case .claudeArtifact:
            return title.hasPrefix("sign in") || title.hasPrefix("log in")
        case .codexSite:
            return title == "sign in required"
        case .foreverlmSite:
            return false
        }
    }

    /// How long a page may go without answering before the pane says it is
    /// waiting. WebKit's own main-frame timeout is 60 seconds; a Google Doc
    /// whose request sat on a dead pooled connection (2026-09-13) was a white
    /// pane for all of it. Eight seconds is the reader's stall threshold.
    static let slowLoadNoticeDelay: TimeInterval = 8

    /// The notice a failed load leaves over the page, or nil when the failure
    /// is not one to mention: a cancelled load is a reload or a profile switch
    /// taking over, and WebKit's "frame load interrupted" is a navigation a
    /// download took. The reason is WebKit's own, without its full stop, so
    /// the notice can carry it after a dash.
    static func loadFailureNotice(_ error: Error) -> LinkedPageLoadNotice? {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return nil }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return nil }
        var reason = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while reason.hasSuffix(".") { reason.removeLast() }
        return .failed(reason)
    }

    /// The text a page reported, made storable: runs of blank lines folded to
    /// one, surrounding spaces dropped, nothing when there is nothing. A list
    /// item keeps the spaces before its marker, because the report is Markdown
    /// and that indentation is the nesting.
    static func normalizedText(_ raw: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                if isListItem(trimmed) {
                    let leading = line.prefix(while: { $0 == " " || $0 == "\t" }).replacingOccurrences(of: "\t", with: "  ")
                    lines.append(leading + trimmed)
                } else {
                    lines.append(trimmed)
                }
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A Markdown list item: `- `, `* `, `+ ` or `1. ` after any indentation.
    static func isListItem(_ trimmedLine: String) -> Bool {
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") { return true }
        let digits = trimmedLine.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count < 4 else { return false }
        return trimmedLine.dropFirst(digits.count).hasPrefix(". ")
    }
}

enum LinkedPageError: LocalizedError, Equatable {
    case empty
    case notAURL
    case unsupported(String)
    case noClaudeArtifact
    /// A recognized link pasted into the section that does not hold its kind.
    case wrongSection(kind: LinkedPageKind, section: ArtifactSection)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste a link."
        case .notAURL:
            return "That is not a web address."
        case .unsupported(let host):
            return "That link points at \(host). ForeverLM can link a Google Doc (docs.google.com) in Pages, and a Claude artifact (claude.ai/code/artifact/…) or a Codex site (….chatgpt.site) in Sites."
        case .noClaudeArtifact:
            return "That claude.ai link is not an artifact. It should look like claude.ai/code/artifact/…"
        case .wrongSection(let kind, let section):
            return "That is a \(kind.label). Link it from \(kind.section.title), not \(section.title)."
        }
    }
}

extension ArtifactRecord {
    /// What kind of page a linked doc points at; nil for a Markdown doc, and
    /// for a linked URL no build recognizes.
    var linkedKind: LinkedPageKind? {
        linkedURL.flatMap(LinkedPage.kind(ofURLString:))
    }

    /// Whether the page's own title is the title: a linked Google Doc is named
    /// in Google Docs, so ForeverLM keeps no title of its own for it, draws no
    /// title beside it and offers no rename (product owner, 2026-10-30: "for
    /// google docs; don't maintain a separate title etc"). The stored title
    /// only mirrors Google's for the lists, search and chat.
    var namesItself: Bool { linkedKind == .googleDoc }

    /// Docs, Sites or Animations. The record's own kind answers first: an
    /// animation is kept as a ForeverLM site and would otherwise read as
    /// one. Then the link alone: a Markdown doc — published or not — a linked
    /// Google Doc, and a linked URL no build recognizes are Docs; a Claude
    /// artifact, a Codex site or a ForeverLM site is a Site. An audio
    /// overview is Markdown and stays under Docs here, so rename and trash
    /// read it as a doc; the Docs list itself leaves it out, since it is
    /// listed and played in its notebook.
    var section: ArtifactSection {
        if kind == .animation { return .animations }
        return linkedKind?.section ?? .docs
    }

    /// What the row, the card caption and the pickers call a linked record:
    /// the kind's label, or "Animation" for one whose kind outranks its link.
    /// Nil for a Markdown doc.
    var kindLabel: String? {
        if kind == .animation { return ArtifactKind.animation.label }
        if kind == .audioOverview { return ArtifactKind.audioOverview.label }
        if kind == .mnemonicReading { return ArtifactKind.mnemonicReading.label }
        return linkedKind?.label
    }
}
