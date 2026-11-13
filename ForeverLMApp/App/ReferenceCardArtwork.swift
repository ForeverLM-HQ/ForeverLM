import AppKit
import Foundation

/// The picture on a doc's reference card.
///
/// A card stands for a source, and every other surface that stands for a source
/// — the sidebar row, the References shelf, a chat citation — shows its picture,
/// so the card does too. A source in the library shows the library's own
/// artwork through `SourceArtwork`: a paper's first page, a chapter's book
/// cover, a podcast's art, a YouTube still. A reference the library does not hold has no
/// file to draw from, so it gets a link preview: the page's `og:image` when the
/// page declares one, otherwise the site's own icon, small in the tile, so a
/// nature.com card and a cellarity.com card still tell apart at a glance.
///
/// Both answers travel to the editor as strings inside `ArtifactReferenceStatus`
/// — an `https:` address the web view fetches itself, or a `data:` image for a
/// file only this Mac can read — because the editor is a web view and can only be
/// handed bytes or an address, never a native view.
enum ReferenceCardArtwork {
    /// Twice the tile's 40pt side, so the picture is crisp on Retina without the
    /// embedded string being long enough to matter across a doc of 150 cards.
    static let maxPixelSize: CGFloat = 80

    /// The cover a card draws for a book chapter, which is the book's own:
    /// `coverPaths` is `StudioViewModel.bookCoverPaths`, keyed by book id. A
    /// chapter's file is the book's PDF or one XHTML page, so the chapter alone
    /// draws a page of text or a figure from inside it. A book dropped on a page
    /// is a card on its first chapter, which is how "How Life Works" came to
    /// wear its first page in place of its cover (product owner, 2026-11-12:
    /// "The How Life Works book doesn't properly show its cover"). Nil for
    /// anything that is not a chapter, or a book with no cover.
    static func bookCoverPath(for article: StudioArticle, coverPaths: [String: String]) -> String? {
        guard article.sourceType == .book, let bookID = article.parentGroup else { return nil }
        return coverPaths[bookID]
    }

    /// The library's picture for a saved source, as the editor can show it: a
    /// small JPEG data URL rendered off-main from the file that backs the source,
    /// or the remote artwork address when the source has no file of its own.
    /// `bookCoverPath` is the book's cover for a chapter (`bookCoverPath(for:coverPaths:)`),
    /// drawn in place of the chapter's own file; a cover that will not render
    /// leaves the chapter's. Nil is a source with no picture at all; the tile
    /// then draws its glyph.
    static func libraryThumbnailURL(for article: StudioArticle, bookCoverPath: String? = nil) async -> String? {
        if let bookCoverPath,
           let image = await SourceArtwork.thumbnail(for: .file(bookCoverPath), maxPixelSize: maxPixelSize),
           let dataURL = SourceArtwork.jpegDataURL(from: image) {
            return dataURL
        }
        let path = await Task.detached(priority: .utility) {
            SourceArtwork.filePath(for: article)
        }.value
        if let path,
           let image = await SourceArtwork.thumbnail(for: .file(path), maxPixelSize: maxPixelSize),
           let dataURL = SourceArtwork.jpegDataURL(from: image) {
            return dataURL
        }
        return SourceArtwork.remoteURL(for: article)?.absoluteString
    }

    /// A footnote card's second line for a saved source, written the way the
    /// sidebar row writes it: author · venue · year for a paper, without the
    /// "Unknown …" placeholders the row has room for; the author and the site
    /// for anything else. Nil when there is nothing to say, and the card falls
    /// back to the address's domain.
    static func libraryDetail(for article: StudioArticle) -> String? {
        var parts: [String] = []
        if article.sourceType == .paper {
            parts = article.paperMetadataDisplayParts.filter {
                $0 != StudioArticle.unknownPaperAuthor
                    && $0 != StudioArticle.unknownPaperJournal
                    && $0 != StudioArticle.unknownPaperYear
            }
        } else {
            if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty,
               article.sourceType != .book {
                parts.append(author)
            }
            if let domain = article.displayDomain { parts.append(domain) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What a page says about itself, for a card whose source is not in the library.
struct ReferenceLinkPreview: Equatable, Sendable {
    /// `page` for an HTML page, `pdf` for a document the address serves directly.
    var kind: String
    /// The page's `og:image` or `twitter:image`, absolute.
    var imageURL: String?
    /// The page's declared icon, else the site's, else `/favicon.ico` on trust;
    /// the tile falls back to its glyph when even that does not load.
    var iconURL: String?
    /// The page's own title — a paper's `citation_title`, else `og:title`, else
    /// the `<title>` without its site suffix — for a footnote's card. Nil leaves
    /// the card on the words that cite it.
    var title: String?
    /// The footnote card's second line: author · venue · year from a scholarly
    /// page's citation tags, else the author, the site's name and the year the
    /// page declares. Nil leaves the card on the address's domain.
    var detail: String?
}

/// Link previews for reference cards, fetched once per address for the life of
/// the app. Fetching reads only the head of a page — the first 64 KB, over a
/// streamed connection that is dropped there — so a doc with a hundred and fifty
/// references costs a hundred and fifty small requests, not a hundred and fifty
/// page loads, and an address that serves a PDF is never downloaded at all: its
/// tile shows the site's icon, which is resolved once per site and shared.
actor ReferenceLinkPreviews {
    static let shared = ReferenceLinkPreviews()

    private var previews: [String: ReferenceLinkPreview] = [:]
    private var inFlight: [String: Task<ReferenceLinkPreview, Never>] = [:]
    private var siteIcons: [String: Task<String?, Never>] = [:]

    func preview(for href: String) async -> ReferenceLinkPreview {
        if let cached = previews[href] { return cached }
        if let running = inFlight[href] { return await running.value }
        let task = Task<ReferenceLinkPreview, Never> { await self.fetchPreview(for: href) }
        inFlight[href] = task
        let preview = await task.value
        previews[href] = preview
        inFlight[href] = nil
        return preview
    }

    private func fetchPreview(for href: String) async -> ReferenceLinkPreview {
        guard let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return ReferenceLinkPreview(kind: "page")
        }
        // An address that names a PDF is not fetched: the whole document would
        // come down for a head that holds no picture.
        let namesPDF = url.pathExtension.lowercased() == "pdf"
        let head = namesPDF ? nil : await Self.fetchHead(url)
        let isPDF = namesPDF || (head.map { !$0.isHTML } ?? false)
        var preview = ReferenceLinkPreview(kind: isPDF ? "pdf" : "page")
        preview.imageURL = head?.imageURL
        preview.iconURL = head?.iconURL
        preview.title = head?.title
        preview.detail = head?.detail
        if preview.iconURL == nil {
            preview.iconURL = await siteIcon(for: head?.finalURL ?? url)
        }
        return preview
    }

    /// The site's icon, from its front page's head — one fetch per origin,
    /// shared by every reference into that site — falling back to the
    /// conventional `/favicon.ico`.
    private func siteIcon(for url: URL) async -> String? {
        guard let host = url.host, let scheme = url.scheme else { return nil }
        let origin = "\(scheme)://\(host)"
        if let running = siteIcons[origin] { return await running.value }
        let task = Task<String?, Never> {
            if let home = URL(string: "\(origin)/"),
               let head = await Self.fetchHead(home),
               let icon = head.iconURL {
                return icon
            }
            return "\(origin)/favicon.ico"
        }
        siteIcons[origin] = task
        return await task.value
    }

    // MARK: - Fetching and parsing

    struct PageHead: Sendable {
        var finalURL: URL
        var isHTML: Bool
        var imageURL: String?
        var iconURL: String?
        var title: String?
        var detail: String?
    }

    private static let headByteLimit = 65_536

    /// The head of the page at `url`: the first 64 KB of an HTML response,
    /// parsed for its picture and icon. A non-HTML response — a PDF served
    /// directly, an image — is reported as such and not read further.
    nonisolated private static func fetchHead(_ url: URL) async -> PageHead? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (Macintosh) ForeverLM", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        let finalURL = http.url ?? url
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("html") || contentType.isEmpty else {
            return PageHead(finalURL: finalURL, isHTML: false)
        }
        var data = Data()
        data.reserveCapacity(headByteLimit)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= headByteLimit { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        let html = String(decoding: data, as: UTF8.self)
        let summary = summary(inHead: html, url: finalURL)
        return PageHead(
            finalURL: finalURL,
            isHTML: true,
            imageURL: StudioViewModel.extractOGImage(from: html, baseURL: finalURL),
            iconURL: iconURL(inHead: html, baseURL: finalURL),
            title: summary.title,
            detail: summary.detail
        )
    }

    /// What a page's head says the page is, for a footnote's card: the title, and a
    /// second line in the sidebar row's shape. A scholarly landing page carries
    /// citation tags — `citation_title`, `citation_author`, `citation_journal_title`,
    /// `citation_publication_date` — and reads as a paper: author · venue · year,
    /// the author shortened the way the library shortens it. Any other page
    /// reads as a page: its author when it names one, then the site's own name
    /// (`og:site_name`) or the host, then the year it was published when it says.
    /// Structured metadata only — the same parsers the paper importer uses; no
    /// guessing from the prose.
    nonisolated static func summary(inHead html: String, url: URL?) -> (title: String?, detail: String?) {
        let paper = PaperService.extractPaperPageMetadata(from: html)
        let page = PaperService.extractWebArticleMetadata(from: html)
        let title = [paper?.title, page?.title]
            .compactMap { $0?.decodingTitleMarkup().trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        var parts: [String] = []
        if let paper, paper.authorsDisplay != nil || paper.journal != nil || paper.year != nil {
            if let author = StudioArticle.shortAuthorDisplay(paper.authorsDisplay) { parts.append(author) }
            if let journal = clean(paper.journal) { parts.append(journal) }
            if let year = paper.year { parts.append(year) }
        } else {
            if let author = clean(page?.author) { parts.append(author) }
            if let site = clean(metaContent(inHead: html, key: "og:site_name")) {
                parts.append(site)
            } else if let host = url?.host?.lowercased() {
                parts.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
            if let published = metaContent(inHead: html, key: "article:published_time"),
               let year = published.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
                parts.append(String(published[year]))
            }
        }
        return (title, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    nonisolated private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.decodingHTMLCharacterReferences().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The `content` of the first `<meta>` whose `property` or `name` is `key`,
    /// read inside its own tag in either attribute order (`HTMLTagAttributes`).
    nonisolated static func metaContent(inHead html: String, key: String) -> String? {
        for tag in HTMLTagAttributes.tags(named: "meta", in: html) {
            let name = tag["property"] ?? tag["name"]
            guard name?.lowercased() == key.lowercased(), let content = tag["content"] else { continue }
            return content
        }
        return nil
    }

    /// The icon a page declares in its head: an `apple-touch-icon` when there is
    /// one, because it is drawn at a size that survives being shown at 20pt, else
    /// the first `icon` or `shortcut icon`. Relative addresses resolve against
    /// the page.
    nonisolated static func iconURL(inHead html: String, baseURL: URL?) -> String? {
        var touchIcon: String?
        var icon: String?
        for tag in HTMLTagAttributes.tags(named: "link", in: html) {
            guard let rel = tag["rel"]?.lowercased() else { continue }
            let rels = rel.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
            guard let href = tag["href"],
                  let resolved = resolveAddress(href, baseURL: baseURL) else { continue }
            if rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") {
                if touchIcon == nil { touchIcon = resolved }
            } else if rels.contains("icon") {
                if icon == nil { icon = resolved }
            }
        }
        return touchIcon ?? icon
    }

    /// An `https:` or `http:` address for `raw`, resolved against the page when
    /// it is relative. Anything else — a `data:` icon, a `javascript:` — is not
    /// an address the tile should be handed.
    nonisolated static func resolveAddress(_ raw: String, baseURL: URL?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), let scheme = absolute.scheme?.lowercased() {
            return scheme == "https" || scheme == "http" ? absolute.absoluteString : nil
        }
        if trimmed.hasPrefix("//"), let baseURL {
            return "\(baseURL.scheme ?? "https"):\(trimmed)"
        }
        guard let baseURL,
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return resolved.absoluteString
    }
}
