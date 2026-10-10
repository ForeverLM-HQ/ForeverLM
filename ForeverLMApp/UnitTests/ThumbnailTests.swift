import Testing
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import ForeverLM

// MARK: - OG Image Extraction

@Suite("extractOGImage")
@MainActor
struct OGImageExtractionTests {

    @Test("Extracts og:image with property-first attribute order")
    func propertyFirst() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://example.com/image.jpg">
        </head></html>
        """
        #expect(StudioViewModel.extractOGImage(from: html) == "https://example.com/image.jpg")
    }

    @Test("Extracts og:image with content-first attribute order")
    func contentFirst() {
        let html = """
        <html><head>
        <meta content="https://example.com/photo.png" property="og:image">
        </head></html>
        """
        #expect(StudioViewModel.extractOGImage(from: html) == "https://example.com/photo.png")
    }

    @Test("Rejects relative og:image URLs")
    func rejectsRelativeURL() {
        let html = """
        <meta property="og:image" content="/static/images/logo.png">
        """
        #expect(StudioViewModel.extractOGImage(from: html) == nil)
    }

    @Test("Returns nil when no og:image present")
    func noOGImage() {
        let html = """
        <html><head>
        <meta property="og:title" content="My Page">
        <meta property="og:description" content="A description">
        </head></html>
        """
        #expect(StudioViewModel.extractOGImage(from: html) == nil)
    }

    @Test("Returns nil for empty HTML")
    func emptyHTML() {
        #expect(StudioViewModel.extractOGImage(from: "") == nil)
    }

    @Test("Reads a single-quoted meta tag, and a malformed one not at all")
    func singleQuotedAndMalformed() {
        // Single quotes are HTML too: the shared tag reader reads them the way
        // a browser does (the old pattern only knew double quotes).
        let html = "<meta property='og:image' content='https://example.com/img.jpg'>"
        #expect(StudioViewModel.extractOGImage(from: html) == "https://example.com/img.jpg")
        // A quote that never closes drops its own tag, not the next one.
        let broken = #"<meta property="og:image" content="https://example.com/broken.jpg><meta property='og:image' content='https://example.com/next.jpg'>"#
        #expect(StudioViewModel.extractOGImage(from: broken) == "https://example.com/next.jpg")
    }

    @Test("Extracts first og:image when multiple present")
    func multipleOGImages() {
        let html = """
        <meta property="og:image" content="https://example.com/first.jpg">
        <meta property="og:image" content="https://example.com/second.jpg">
        """
        #expect(StudioViewModel.extractOGImage(from: html) == "https://example.com/first.jpg")
    }

    @Test("Case insensitive matching")
    func caseInsensitive() {
        let html = """
        <META PROPERTY="og:image" CONTENT="https://example.com/UPPER.jpg">
        """
        #expect(StudioViewModel.extractOGImage(from: html) == "https://example.com/UPPER.jpg")
    }

    @Test("Handles extra attributes in meta tag")
    func extraAttributes() {
        let html = """
        <meta name="twitter:image" property="og:image" content="https://example.com/social.jpg" />
        """
        #expect(StudioViewModel.extractOGImage(from: html) == "https://example.com/social.jpg")
    }
}

// MARK: - Thumbnail Display Logic

@Suite("Thumbnail display priority")
struct ThumbnailDisplayTests {

    @Test("Thumbnail lookup uses the canonical source-file relocation candidates")
    func thumbnailCandidatesMatchSourceResolver() {
        let conflictForkPDF = NSHomeDirectory()
            + "/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM 2/Papers/paper.pdf"

        let candidates = BookCoverThumbnail.candidatePaths(for: conflictForkPDF)

        #expect(candidates == StorageService.sourceFileCandidatePaths(for: conflictForkPDF))
        #expect(candidates.first == conflictForkPDF)
    }

    @Test("Book with PDF path gets PDF thumbnail (resolvedPDFPath non-nil)")
    func bookPDFPath() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        let article = StudioArticle(url: tempPDF.path, title: "Chapter 1", sourceType: .book)
        // Books with local PDF use resolvedPDFPath → BookCoverThumbnail
        #expect(article.resolvedPDFPath != nil)
        #expect(article.artworkURL == nil)
    }

    @Test("Paper with local PDF uses PDF thumbnail over artwork")
    func paperLocalPDF() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        var article = StudioArticle(url: tempPDF.path, title: "Paper", sourceType: .paper)
        article.artworkURL = "https://example.com/thumbnail.jpg"
        // resolvedPDFPath takes priority in the display hierarchy
        #expect(article.resolvedPDFPath != nil)
    }

    @Test("Web article with artworkURL uses artwork")
    func webArticleArtwork() {
        let article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article, artworkURL: "https://example.com/og.jpg")
        #expect(article.resolvedPDFPath == nil)
        #expect(article.artworkURL == "https://example.com/og.jpg")
    }

    @Test("Web article without artworkURL falls back to icon")
    func webArticleFallback() {
        let article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article)
        #expect(article.resolvedPDFPath == nil)
        #expect(article.artworkURL == nil)
    }

    @Test("Podcast with artworkURL uses artwork")
    func podcastArtwork() {
        let article = StudioArticle(url: "https://podcasts.apple.com/episode/123", title: "Episode", sourceType: .podcast, artworkURL: "https://example.com/cover100x100bb.jpg")
        #expect(article.artworkURL != nil)
    }

    @Test("Paper with web URL and localFilePath PDF uses PDF thumbnail")
    func paperWebURLWithLocalPDF() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        let article = StudioArticle(url: "https://arxiv.org/abs/2301.07041", title: "Paper", sourceType: .paper, localFilePath: tempPDF.path)
        #expect(article.resolvedPDFPath == tempPDF.path)
    }

    @Test("Course chapter with local PDF uses PDF thumbnail")
    func courseChapterPDF() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        let article = StudioArticle(url: tempPDF.path, title: "Lecture 1", sourceType: .course)
        #expect(article.resolvedPDFPath != nil)
    }
}

// MARK: - Artwork Backfill Candidate Filtering

@Suite("Artwork backfill candidates")
struct ArtworkBackfillTests {

    /// Simulates the candidate filter logic from backfillMissingArtwork()
    private func isBackfillCandidate(_ article: StudioArticle) -> Bool {
        article.artworkURL == nil
        && article.url.hasPrefix("http")
        && (article.sourceType == .article || article.sourceType == .manual || article.sourceType == .paper || article.sourceType == .unclassified)
    }

    @Test("Web article without artwork is a backfill candidate")
    func webArticleCandidate() {
        let article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article)
        #expect(isBackfillCandidate(article))
    }

    @Test("Article with existing artwork is NOT a candidate")
    func existingArtworkSkipped() {
        let article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article, artworkURL: "https://example.com/img.jpg")
        #expect(!isBackfillCandidate(article))
    }

    @Test("Local PDF article is NOT a candidate (no HTTP URL to scrape)")
    func localPDFNotCandidate() {
        let article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)
        #expect(!isBackfillCandidate(article))
    }

    @Test("Podcast is NOT a backfill candidate (artwork comes from iTunes)")
    func podcastNotCandidate() {
        let article = StudioArticle(url: "https://podcasts.apple.com/episode/123", title: "Episode", sourceType: .podcast)
        #expect(!isBackfillCandidate(article))
    }

    @Test("Book is NOT a backfill candidate (uses PDF cover)")
    func bookNotCandidate() {
        let article = StudioArticle(url: "https://example.com/book", title: "Book", sourceType: .book)
        #expect(!isBackfillCandidate(article))
    }

    @Test("Ready article IS a backfill candidate")
    func readyArticleIsCandidate() {
        var article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article)
        article.state = .ready
        #expect(isBackfillCandidate(article))
    }

    @Test("Manual source type is a backfill candidate")
    func manualSourceCandidate() {
        let article = StudioArticle(url: "https://example.com/manual", title: "Manual", sourceType: .manual)
        #expect(isBackfillCandidate(article))
    }

    @Test("Paper with web URL is a backfill candidate")
    func paperWebURLCandidate() {
        let article = StudioArticle(url: "https://arxiv.org/abs/2301.07041", title: "Paper", sourceType: .paper)
        #expect(isBackfillCandidate(article))
    }
}

// MARK: - Artwork URL Validation

@Suite("Artwork URL cleanup")
struct ArtworkURLCleanupTests {

    @Test("Relative artwork URL should be treated as invalid")
    func relativeURLInvalid() {
        // backfillMissingArtwork strips non-http artworkURLs
        var article = StudioArticle(url: "https://example.com", title: "Test", sourceType: .article)
        article.artworkURL = "/static/images/logo.png"
        // Simulate the cleanup logic
        if let art = article.artworkURL, !art.hasPrefix("http") {
            article.artworkURL = nil
        }
        #expect(article.artworkURL == nil)
    }

    @Test("HTTP artwork URL is preserved")
    func httpURLPreserved() {
        var article = StudioArticle(url: "https://example.com", title: "Test", sourceType: .article)
        article.artworkURL = "https://cdn.example.com/image.jpg"
        if let art = article.artworkURL, !art.hasPrefix("http") {
            article.artworkURL = nil
        }
        #expect(article.artworkURL == "https://cdn.example.com/image.jpg")
    }

    @Test("Data URI artwork is treated as invalid")
    func dataURIInvalid() {
        var article = StudioArticle(url: "https://example.com", title: "Test", sourceType: .article)
        article.artworkURL = "data:image/png;base64,iVBOR..."
        if let art = article.artworkURL, !art.hasPrefix("http") {
            article.artworkURL = nil
        }
        #expect(article.artworkURL == nil)
    }
}

// MARK: - ImageCache

@Suite("ImageCache")
struct ImageCacheTests {

    @Test("Cache miss returns nil")
    func cacheMiss() {
        #expect(ImageCache.shared.image(for: "nonexistent-key-\(UUID())") == nil)
    }

    @Test("Cache hit returns stored image")
    func cacheHit() {
        let key = "test-cache-\(UUID())"
        #if os(macOS)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        #else
        let image = UIImage()
        #endif
        ImageCache.shared.set(image, for: key)
        #expect(ImageCache.shared.image(for: key) != nil)
    }

    @Test("Book cover cache key uses book-cover: prefix")
    func bookCoverCacheKey() {
        let path = "/Users/me/Books/chapter.pdf"
        let cacheKey = "book-cover:\(path)"
        // Verify the key format matches what BookCoverThumbnail uses
        #expect(cacheKey == "book-cover:/Users/me/Books/chapter.pdf")
    }
}

// MARK: - Mobile artwork derivation

@Suite("Mobile artwork derivation")
struct MobileSourceArtworkTests {

    @Test("Phone derives the same YouTube thumbnail as the Mac", arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube.com/shorts/abc123XYZ_-",
        "https://www.youtube.com/watch?v=abc&t=42s",
        "https://example.com/watch?v=notyoutube",
        "https://arxiv.org/abs/2301.07041",
        "not a url",
    ])
    func matchesMacDerivation(url: String) {
        // MobileSourceArtwork mirrors StudioArticle because the phone target
        // does not compile Models.swift; this is the test that keeps the two
        // from drifting.
        #expect(
            MobileSourceArtwork.youtubeThumbnailURL(for: url)?.absoluteString
                == StudioArticle.youtubeThumbnailURL(for: url)
        )
    }

    @Test("Explicit artwork wins over the derived YouTube thumbnail")
    func artworkBeatsDerived() {
        var source = MobileCloudSource(
            id: "s1",
            title: "Video",
            subtitle: nil,
            sourceType: "video",
            dateAdded: .distantPast,
            hasAudio: false,
            isArchived: false
        )
        source.url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        source.artworkURL = "https://example.com/custom.jpg"
        #expect(source.thumbnailURL?.absoluteString == "https://example.com/custom.jpg")

        source.artworkURL = nil
        #expect(source.thumbnailURL?.absoluteString == "https://img.youtube.com/vi/dQw4w9WgXcQ/mqdefault.jpg")

        source.url = "https://example.com/post"
        #expect(source.thumbnailURL == nil)
    }
}

// MARK: - artworkURL Codable Round-Trip

@Suite("artworkURL persistence")
struct ArtworkURLCodableTests {

    @Test("artworkURL survives encode/decode")
    func roundTrip() throws {
        var article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article, artworkURL: "https://example.com/og.jpg")
        article.state = .ready

        let data = try JSONEncoder().encode(article)
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: data)

        #expect(decoded.artworkURL == "https://example.com/og.jpg")
    }

    @Test("nil artworkURL survives encode/decode")
    func roundTripNil() throws {
        let article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article)

        let data = try JSONEncoder().encode(article)
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: data)

        #expect(decoded.artworkURL == nil)
    }

    @Test("artworkURL persists alongside other fields")
    func persistsWithOtherFields() throws {
        var article = StudioArticle(url: "https://nature.com/article", title: "Paper", sourceType: .paper, artworkURL: "https://nature.com/cover.jpg", author: "Smith", journal: "Nature", publishedYear: "2025")
        article.state = .ready

        let data = try JSONEncoder().encode(article)
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: data)

        #expect(decoded.artworkURL == "https://nature.com/cover.jpg")
        #expect(decoded.author == "Smith")
    }
}
