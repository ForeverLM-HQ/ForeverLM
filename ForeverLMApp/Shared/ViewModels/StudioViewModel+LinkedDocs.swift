import Foundation
import OSLog
import WebKit

/// What one attempt to pull a linked doc's text copy came to. Shown as a
/// single line in the doc's pane only when the copy is not what the reader
/// would assume it is.
enum LinkedDocExportOutcome: Equatable, Sendable {
    /// The copy was fetched and the stored text is current.
    case refreshed
    /// The stored copy is recent enough that nothing was fetched — or the copy
    /// comes from the rendered page and arrives when the page has drawn.
    case fresh
    /// The page answered with a sign-in or nothing readable: the doc is not
    /// shared with the account the app's web views are signed into, or no
    /// account is signed in at all. The stored copy, if any, stands.
    case unavailable
}

extension StudioViewModel {
    /// Put a page — a Google Doc, a Claude artifact or a Codex site — into the
    /// library from a pasted link. The link is normalized to its canonical
    /// URL first and refused when it is none of the three, or — when the link
    /// came from one section's sheet — when it belongs to the other section;
    /// the row appears at once under a placeholder title in the section its
    /// kind belongs to, and the title and text copy follow: in the background
    /// for a page a bare fetch can name, otherwise when the doc is opened and
    /// the page renders.
    func linkPage(
        urlString: String,
        in section: ArtifactSection? = nil,
        homeNotebookID: String?,
        linkedNotebookIDs: [String]
    ) async throws -> ArtifactRecord {
        let url = if let section {
            try LinkedPage.canonicalURL(from: urlString, in: section)
        } else {
            try LinkedPage.canonicalURL(from: urlString)
        }
        let kind = LinkedPage.kind(of: url) ?? .googleDoc
        if let existing = artifacts.first(where: { $0.linkedURL == url.absoluteString }) {
            showToast("\(existing.title) is already linked")
            return existing
        }
        let artifact = try await storage.createLinkedArtifact(
            url: url,
            title: kind.placeholderTitle,
            homeNotebookID: homeNotebookID,
            linkedNotebookIDs: linkedNotebookIDs
        )
        artifacts = try await loadScopedArtifacts()
        showToast("Linked \(kind.label)")
        Task { [weak self] in
            guard let self else { return }
            await self.adoptLinkedDocTitleIfPlaceholder(artifact.id)
            if kind.textCopySource == .export {
                _ = await self.refreshLinkedDocExport(artifact.id, force: true)
            }
        }
        return artifact
    }

    /// The kind of page a URL about to become a *source* would link to, or nil
    /// when it is an ordinary address. The product owner (2026-09-09): "codex sites
    /// should always obviously be ingested as a 'site' not as an article". A
    /// page ForeverLM links — a Codex site, a Claude artifact, a Google Doc, a
    /// ForeverLM site — is never scraped into an article: every route that
    /// makes a source from a URL asks this first, before `detectSourceType`,
    /// which does not know these hosts and would send the address to the model
    /// as an article. A Codex site read that way is its sign-in page (every one
    /// answers an anonymous fetch with 401 "Sign in required"), so the article
    /// would be worthless besides being the wrong kind. Takes what the source
    /// bar takes: a bare host without a scheme is read as https, a local file
    /// path is never a page.
    nonisolated static func linkedPageKind(forSourceURL url: String) -> LinkedPageKind? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return LinkedPage.kind(ofURLString: withScheme)
    }

    /// Why a URL about to become a *source* is refused outright, or nil when
    /// nothing stands in its way. The product owner (2026-09-12): "convoke bio results
    /// should not be ingested as a source in foreverlm". Convoke is a biopharma
    /// intelligence workspace queried live over MCP; what it returns is a query
    /// result, not a page, and the plugin that pushed two of them stamped
    /// each with a `platform.convoke.bio/mcp` address no reader can open. Every
    /// route that makes a source from a URL asks this beside `linkedPageKind`,
    /// before any classification: the source bar, browser Reading List
    /// discovery, MCP `add_source` and a plugin's `add_sources` batch. The
    /// public `insights.convoke.bio` pages are ordinary articles and pass.
    /// Takes what the source bar takes: a bare host without a scheme is read
    /// as https, a local file path is never refused here.
    nonisolated static func sourceRefusal(forSourceURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URL(string: withScheme)?.host?.lowercased() else { return nil }
        if host == "platform.convoke.bio" || host.hasSuffix(".platform.convoke.bio") {
            return "Convoke query results are not sources: Convoke is queried live over MCP, and a platform.convoke.bio address is its endpoint, not a page anyone can read. Nothing from it is added to the library."
        }
        return nil
    }

    /// Copy a Markdown doc into a new Google Doc in the user's Drive and make
    /// the doc a linked doc pointing at it. The content sent is the stored
    /// body, rendered to HTML by `MarkdownHTML`, its attached sources as
    /// numbered citations and a References list; the caller flushes any
    /// unsaved draft first so the two cannot disagree. A Mac without a
    /// `drive.file` grant is sent through Google's consent in the browser by
    /// `GoogleDriveService` before the create. On success the doc keeps its
    /// id, Notebooks and Markdown body and opens in Google's editor like any
    /// linked doc; on failure nothing about it changes.
    func convertDocToGoogleDoc(_ artifactID: String) async throws -> ArtifactRecord {
        let snapshot = try await storage.artifactMarkdown(artifactID)
        guard !snapshot.artifact.isLinked else {
            throw ArtifactError.alreadyLinked(snapshot.artifact.title)
        }
        let html = MarkdownHTML.document(
            title: snapshot.artifact.title,
            markdown: snapshot.markdown,
            references: citationReferences(in: snapshot.markdown)
        )
        let documentID = try await GoogleDriveService.shared.createGoogleDoc(
            title: snapshot.artifact.title,
            html: html
        )
        let url = LinkedGoogleDoc.editURL(documentID: documentID)
        let linked = try await storage.linkArtifactToGoogleDoc(artifactID: artifactID, url: url)
        artifacts = try await loadScopedArtifacts()
        showToast("Converted to \(LinkedGoogleDoc.label)")
        return linked
    }

    /// What each source a Doc's body attaches to a passage or links reads as
    /// in a reference list, by the token its address carries. A book attached
    /// whole (`book:<id>`) is one reference, the book; a source or book the
    /// library no longer holds is left out, so its passages cite nothing.
    func citationReferences(in markdown: String) -> [String: MarkdownHTML.Reference] {
        var references: [String: MarkdownHTML.Reference] = [:]
        for token in StorageService.groundingTokens(in: markdown) where references[token] == nil {
            if token.hasPrefix(Self.notepadGroundingBookPrefix) {
                let bookID = String(token.dropFirst(Self.notepadGroundingBookPrefix.count))
                let chapters = bookChapterArticlesInOrder(for: bookID)
                guard let first = chapters.first else { continue }
                references[token] = Self.citationReference(
                    book: groupDisplayTitle(bookID) ?? first.title,
                    chapters: chapters
                )
            } else if let source = articlesById[token] {
                references[token] = Self.citationReference(for: source, groupTitle: sourceGroupTitle(for: source))
            }
        }
        return references
    }

    /// One source as a reference list prints it. A paper names its journal
    /// and links its DOI; a chapter, an episode or a lecture names the book,
    /// show or course it is part of (`groupTitle`); a web page names its site.
    /// The placeholders a paper carries while its metadata is unread ("Unknown
    /// authors") are left out, and so is a meeting's address: a recording's
    /// link is private, and a document is for sharing.
    nonisolated static func citationReference(for source: StudioArticle, groupTitle: String?) -> MarkdownHTML.Reference {
        var reference = MarkdownHTML.Reference(title: source.title)
        reference.authors = citationAuthors(source.author)
        if let year = source.normalizedPublishedYear, year != StudioArticle.unknownPaperYear {
            reference.year = year
        } else if source.sourceType == .video, let published = source.videoPublishedAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            reference.year = String(calendar.component(.year, from: published))
        }
        switch source.sourceType {
        case .paper:
            if let journal = source.normalizedJournal, journal != StudioArticle.unknownPaperJournal {
                reference.container = journal
            }
        case .article, .manual, .unclassified, .xPost:
            reference.container = source.displayDomain
        case .book, .course, .podcast, .video, .meeting:
            let group = groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let group, !group.isEmpty, group != source.title { reference.container = group }
        }
        guard source.sourceType != .meeting else { return reference }
        if let doi = PaperWalkthroughCitation.normalizedDOI(source.doi) {
            reference.url = "https://doi.org/" + doi
        } else {
            reference.url = [source.publicURL, source.url, source.podcastWebPageURL]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { candidate in
                    let lowered = candidate.lowercased()
                    return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
                }
        }
        return reference
    }

    /// A book attached whole: its title, and the author and year its chapters
    /// carry. No address: a book in the library is a file on this Mac.
    nonisolated static func citationReference(book title: String, chapters: [StudioArticle]) -> MarkdownHTML.Reference {
        var reference = MarkdownHTML.Reference(title: title)
        reference.authors = chapters.lazy.map { citationAuthors($0.author) }.first { !$0.isEmpty } ?? []
        reference.year = chapters.lazy.compactMap(\.normalizedPublishedYear).first
        return reference
    }

    /// The names an author field holds. Paper metadata separates them with a
    /// semicolon; any other field is one entry, since a name is not parsed.
    nonisolated static func citationAuthors(_ author: String?) -> [String] {
        guard let raw = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != StudioArticle.unknownPaperAuthor else { return [] }
        var seen = Set<String>()
        return raw
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Make a linked doc an editable Markdown doc again, keeping the text
    /// ForeverLM holds for it as the body. The page itself is not touched.
    func unlinkDoc(_ artifactID: String) async {
        let kind = artifacts.first(where: { $0.id == artifactID })?.linkedKind
        do {
            _ = try await storage.unlinkArtifact(artifactID: artifactID)
            artifacts = try await loadScopedArtifacts()
            // A site's text copy becomes a Markdown doc, which is a Doc: it
            // leaves Sites, and the toast says where it went.
            showToast(kind?.section == .sites
                ? "Unlinked from \(kind?.productName ?? "the page") — now a page in Pages"
                : "Unlinked from \(kind?.productName ?? "the page")")
        } catch {
            logger.error("Unlinking a doc failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// A linked page as ForeverLM's own: unlinked into a Markdown doc and
    /// published on foreverlm.com in one step, so the chat, Claude and Codex
    /// edit it from then on (the MCP twin is `adopt_page`). The sign-in is
    /// checked first, so a signed-out Mac changes nothing; a publish that
    /// fails after the unlink leaves an ordinary doc, which the error says.
    /// The page stays in Sites: it has a page on foreverlm.com now.
    func adoptLinkedPage(_ artifactID: String) async {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }),
              let kind = artifact.linkedKind else { return }
        guard ManagedAI.isSignedIn else {
            errorMessage = DocPublishingError.signedOut.localizedDescription
            return
        }
        do {
            _ = try await storage.unlinkArtifact(artifactID: artifactID)
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Making a linked page a ForeverLM page failed at unlinking: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }
        do {
            let status = try await publishDoc(artifactID)
            publishedDocStatuses[artifactID] = status
        } catch {
            logger.error("Making a linked page a ForeverLM page failed at publishing: \(error.localizedDescription)")
            errorMessage = "‘\(artifact.title)’ is a page of your own now, unlinked from \(kind.productName), but it was not published: \(error.localizedDescription)"
        }
    }

    /// Pull a Google Doc's plain-text export into its body, rate-limited so an
    /// open costs at most one fetch per interval. The browser's Google cookies
    /// ride along, so a doc shared with the signed-in account exports too; one
    /// that still answers with a sign-in page leaves the stored copy alone.
    /// A page whose copy comes from its rendering has nothing to fetch here
    /// and answers `.fresh`: `adoptLinkedPageText` takes that copy when the
    /// page reports it.
    @discardableResult
    func refreshLinkedDocExport(_ artifactID: String, force: Bool = false) async -> LinkedDocExportOutcome {
        var artifact = artifacts.first(where: { $0.id == artifactID })
        if artifact == nil {
            let stored = try? await storage.loadArtifacts()
            artifact = stored?.first(where: { $0.id == artifactID })
        }
        guard let artifact, let kind = artifact.linkedKind, let linkedURL = artifact.linkedURL else {
            return .unavailable
        }
        guard kind.textCopySource == .export else { return .fresh }
        guard let documentID = LinkedGoogleDoc.documentID(from: linkedURL) else {
            return .unavailable
        }
        if !force, await !storage.linkedArtifactExportIsDue(artifactID) {
            return .fresh
        }
        await storage.noteLinkedArtifactExportAttempt(artifactID)
        let cookies = await Self.linkedPageCookies(for: LinkedGoogleDoc.exportURL(documentID: documentID))
        do {
            let text = try await SourceService.shared.googleDocumentPlainText(
                documentID: documentID,
                cookies: cookies
            )
            let before = artifact.updatedAt
            let snapshot = try await storage.replaceLinkedArtifactExport(artifactID: artifactID, text: text)
            if snapshot.artifact.updatedAt != before {
                artifacts = try await loadScopedArtifacts()
            }
            return .refreshed
        } catch {
            logger.info("Linked doc export unavailable for \(artifactID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// Store a Google Doc's text export that the signed-in page fetched for
    /// itself: the route that works when `refreshLinkedDocExport`'s own
    /// request is answered with a sign-in page. The same checks as that
    /// export apply, so Docs' "enable JavaScript" shell is never a copy.
    /// Returns the stored copy's length, or nil when nothing was stored.
    func adoptLinkedGoogleDocExport(_ artifactID: String, text rawText: String) async -> Int? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        guard !text.isEmpty,
              !lowered.hasPrefix("<!doctype html"),
              !lowered.hasPrefix("<html"),
              !SourceService.isGoogleDocsInterfaceContent(text) else { return nil }
        var artifact = artifacts.first(where: { $0.id == artifactID })
        if artifact == nil {
            let stored = try? await storage.loadArtifacts()
            artifact = stored?.first(where: { $0.id == artifactID })
        }
        guard let artifact, artifact.linkedKind == .googleDoc else { return nil }
        await storage.noteLinkedArtifactExportAttempt(artifactID)
        do {
            let before = artifact.updatedAt
            let snapshot = try await storage.replaceLinkedArtifactExport(artifactID: artifactID, text: text)
            if snapshot.artifact.updatedAt != before {
                artifacts = try await loadScopedArtifacts()
            }
            return snapshot.markdown.count
        } catch {
            logger.info("Linked doc page export not stored for \(artifactID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether a linked record still has no text copy. What the open of a
    /// page that reports its own text asks first: only an empty copy is
    /// filled by an open. A copy that cannot be read (a body still coming
    /// down from iCloud) is not empty: nothing is written over what an open
    /// could not see.
    func linkedArtifactTextCopyIsEmpty(_ artifactID: String) async -> Bool {
        guard let stored = try? await storage.artifactMarkdown(artifactID) else { return false }
        return stored.markdown.isEmpty
    }

    /// Take the visible text a linked page reported from its web view as the
    /// doc's text copy. Only for the kinds whose copy comes from the rendered
    /// page; a Google Doc keeps its export. Empty text is not a copy — a shell
    /// that has not drawn yet, a sign-in — and leaves the stored text alone.
    ///
    /// An open is a read. The page's visible text at the moment it is taken is
    /// a rendering — an animation's caption and clock differ every time the
    /// page draws — so unless `replacingExistingCopy` says the learner asked
    /// (Refresh Text Copy), a copy that exists stands, and only an empty copy
    /// is filled. Otherwise each click in the list wrote the record, dated it,
    /// and moved it to the top (product owner, 2026-09-20: "don't reorder these upon
    /// click"); for an animation it also replaced the description and the
    /// sources' names `save_animation` wrote with a mid-play frame.
    /// Returns whether a copy was stored (or was already this text).
    @discardableResult
    func adoptLinkedPageText(
        _ artifactID: String,
        text rawText: String,
        replacingExistingCopy: Bool = false
    ) async -> Bool {
        let text = LinkedPage.normalizedText(rawText)
        guard !text.isEmpty else { return false }
        var artifact = artifacts.first(where: { $0.id == artifactID })
        if artifact == nil {
            let stored = try? await storage.loadArtifacts()
            artifact = stored?.first(where: { $0.id == artifactID })
        }
        guard let artifact, let kind = artifact.linkedKind, kind.textCopySource == .renderedPage else {
            return false
        }
        if !replacingExistingCopy {
            guard await linkedArtifactTextCopyIsEmpty(artifactID) else { return false }
        }
        await storage.noteLinkedArtifactExportAttempt(artifactID)
        do {
            let before = artifact.updatedAt
            let snapshot = try await storage.replaceLinkedArtifactExport(artifactID: artifactID, text: text)
            if snapshot.artifact.updatedAt != before {
                artifacts = try await loadScopedArtifacts()
            }
            return true
        } catch {
            logger.info("Linked page text copy not stored for \(artifactID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Give a linked doc the page's own name while it still carries the
    /// placeholder. Best effort: a page that wants a sign-in, or one whose
    /// bare fetch is an application shell (a Claude artifact), keeps the
    /// placeholder until the doc is opened, where the title is read from the
    /// web view instead.
    func adoptLinkedDocTitleIfPlaceholder(_ artifactID: String) async {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }),
              let kind = artifact.linkedKind,
              artifact.title == kind.placeholderTitle,
              let linkedURL = artifact.linkedURL,
              let url = URL(string: linkedURL) else { return }
        let cookies = await Self.linkedPageCookies(for: url)
        guard let pageTitle = await Self.fetchPageTitle(url, cookies: cookies, kind: kind),
              let title = LinkedPage.title(fromPageTitle: pageTitle, kind: kind) else { return }
        await adoptLinkedDocTitle(artifactID, title: title)
    }

    /// Rename a linked doc from a title its web view reported. A Google Doc
    /// always follows Google's own name, so a rename made there shows here;
    /// any other kind only while the stored title is still the placeholder —
    /// a name the writer chose wins.
    func adoptLinkedDocTitle(_ artifactID: String, title: String) async {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }),
              let kind = artifact.linkedKind,
              artifact.namesItself || artifact.title == kind.placeholderTitle,
              title != artifact.title else { return }
        await updateArtifact(artifactID: artifactID, title: title)
    }

    /// The cookies the app's web views hold for a request to `url`. Read from
    /// the shared default store, which every in-app web view uses, so a
    /// sign-in done in any of them serves the fetch too.
    static func linkedPageCookies(for url: URL) async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return LinkedGoogleDoc.cookies(all, applicableTo: url)
    }

    private static func fetchPageTitle(_ url: URL, cookies: [HTTPCookie], kind: LinkedPageKind) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(SharedWebKit.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        if !cookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.httpShouldHandleCookies = false
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              // A redirect into sign-in answers with the sign-in page's title,
              // which is not the document's; the final URL says which it was.
              !LinkedPage.isSignInURL(http.url, kind: kind),
              let html = String(data: data.prefix(256 * 1_024), encoding: .utf8) else {
            return nil
        }
        return LinkedGoogleDoc.pageTitle(inHTML: html)
    }
}
