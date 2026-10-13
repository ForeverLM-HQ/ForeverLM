import SwiftUI
import Foundation
import AppKit
import PDFKit

struct SourceThumbnail: View {
    let source: StudioArticle
    var size: CGFloat = 42
    /// The book's own cover, for a row that stands for the whole book rather
    /// than the chapter that represents it. A chapter's file is one XHTML page,
    /// so `source` alone would draw the first picture inside that chapter — a
    /// figure, not the cover. Keyed off `StudioViewModel.bookCoverPaths` by the
    /// caller; nil means the row is about `source` itself.
    var bookCoverPath: String? = nil

    // Resolved off-main in `.task`: resolvedPDFPath/resolvedLocalPath stat the filesystem,
    // and this view renders per-row inside non-lazy ForEach lists, so probing during body
    // would block the main actor (documented Library-beachball hazard).
    @State private var localDocumentThumbnailPath: String?

    /// A paper's first page is mostly white, and beside covers it reads as a
    /// picture that failed to load: a filmed row draws the paper icon instead
    /// (screen record mode).
    private var drawsPaperAsIcon: Bool {
        source.sourceType == .paper && ScreenRecordMode.isEffective
    }

    private var artworkURL: URL? {
        SourceArtwork.remoteURL(for: source)
    }

    var body: some View {
        Group {
            if let bookCoverPath {
                BookCoverThumbnail(
                    pdfPath: bookCoverPath,
                    size: CGSize(width: size, height: size),
                    placeholderSystemImage: "book.closed",
                    tint: sourceTypeColor(.book)
                )
            } else if let thumbnailPath = localDocumentThumbnailPath, !drawsPaperAsIcon {
                BookCoverThumbnail(
                    pdfPath: thumbnailPath,
                    size: CGSize(width: size, height: size),
                    placeholderSystemImage: sourceTypeIcon(source.sourceType),
                    tint: sourceTypeColor(source.sourceType)
                )
            } else if let artworkURL {
                CachedAsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        sourceTypeIconView
                    default:
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.quaternary)
                    }
                }
            } else {
                sourceTypeIconView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: source.id) {
            localDocumentThumbnailPath = await Self.resolveLocalDocumentThumbnailPath(for: source)
        }
    }

    private static func resolveLocalDocumentThumbnailPath(for source: StudioArticle) async -> String? {
        // A captured or drawn meeting icon is a file this app wrote, not a URL
        // to fetch, so it renders through the file-backed thumbnail rather than
        // the async image loader above — the same choice `SourceArtwork` makes
        // for the web-view surfaces.
        await Task.detached(priority: .utility) {
            SourceArtwork.filePath(for: source)
        }.value
    }

    @ViewBuilder
    private var sourceTypeIconView: some View {
        if source.sourceType == .xPost {
            XLogoShape()
                .fill(sourceTypeColor(source.sourceType), style: FillStyle(eoFill: true))
                .frame(width: size * 0.40, height: size * 0.40)
                .frame(width: size, height: size)
                .background(sourceTypeColor(source.sourceType).opacity(0.10))
        } else {
            Image(systemName: sourceTypeIcon(source.sourceType))
                .zoomedSystemFont(size: max(12, size * 0.42))
                .foregroundStyle(sourceTypeColor(source.sourceType))
                .frame(width: size, height: size)
                .background(sourceTypeColor(source.sourceType).opacity(0.10))
        }
    }

    private func sourceTypeIcon(_ type: StudioSourceType) -> String {
        switch type {
        case .article, .unclassified: return "doc.richtext"
        case .paper: return "doc.text.magnifyingglass"
        case .podcast: return "headphones"
        case .book: return "book.closed"
        case .course: return "graduationcap"
        case .meeting: return "person.2.wave.2"
        case .video: return "play.rectangle"
        case .xPost: return "bubble.left"
        case .manual: return "link"
        }
    }

    private func sourceTypeColor(_ type: StudioSourceType) -> Color {
        switch type {
        case .article, .unclassified: return .blue
        case .paper: return .purple
        case .podcast: return .orange
        case .book: return .green
        case .course: return .indigo
        case .meeting: return .teal
        case .video: return .red
        case .xPost: return .primary
        case .manual: return .secondary
        }
    }
}

/// Where a source's picture comes from.
///
/// `artworkURL` is not always a URL to load. A podcast cover and a YouTube
/// still live at `https://…`, but a meeting icon this app captured or drew is
/// a file under the content root, referenced by the same relative-path
/// convention as every other source file — and a paper or an EPUB chapter
/// carries no artwork at all, only a document whose first page is the picture.
/// Every surface that shows a source has to make that distinction, so it is
/// made once here: the two web-view surfaces had each written their own rule,
/// and both read a stored icon path as a URL to fetch, which is why a meeting
/// with a perfectly good icon on disk rendered the letter fallback.
enum SourceArtwork {
    enum Origin: Sendable, Equatable {
        /// A path under the content root, or an absolute one. Rendering covers
        /// PDFs, EPUB chapters, and stored images alike.
        case file(String)
        case remote(URL)

        var cacheKey: String {
            switch self {
            case .file(let path): return "file:\(path)"
            case .remote(let url): return "url:\(url.absoluteString)"
            }
        }
    }

    static func origin(for article: StudioArticle) -> Origin? {
        if let path = filePath(for: article) { return .file(path) }
        if let url = remoteURL(for: article) { return .remote(url) }
        return nil
    }

    /// The picture a source carries as a file, or nil when it has none.
    ///
    /// Off the main actor this stats the filesystem; on it, `StudioArticle`'s
    /// accessors answer from their memoization tables instead, so a render path
    /// can call this without risking a cold iCloud stat.
    static func filePath(for article: StudioArticle) -> String? {
        // A book chapter's picture is its first page of the book's file.
        if let pdfPath = article.resolvedPDFPath { return SourcePDFPages.stored(path: pdfPath, pages: article.bookPages) }
        if article.isEPUBChapter, let path = article.resolvedLocalPath { return path }
        // Only a bare relative path names stored content. Anything carrying a
        // scheme is a URL, and a `file:` one is not this app's to open on a
        // source's say-so.
        guard let artwork = nonempty(article.artworkURL), !artwork.contains("://") else { return nil }
        return MeetingIconService.localArtworkPath(for: artwork)
    }

    /// The picture a source carries as a URL to load. Stored artwork wins, but
    /// artwork stored as a *file* is not a URL: those sources fall through to
    /// the YouTube still rather than to nothing.
    static func remoteURL(for article: StudioArticle) -> URL? {
        loadableURL(article.artworkURL) ?? loadableURL(article.youtubeThumbnailURL)
    }

    /// A web view is handed this address verbatim, so only the two schemes that
    /// mean "fetch this over the network" are allowed through.
    static func loadableURL(_ value: String?) -> URL? {
        guard let value = nonempty(value),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Rendering

    /// A picture no larger than `maxPixelSize` on either side, for the surfaces
    /// that cannot render `SourceThumbnail` itself — a web view can only be
    /// given the bytes. Nothing here runs on a render path: every filesystem
    /// probe, decode, and download happens off the main actor, and the result
    /// is cached in memory and on disk under a key that includes the size.
    static func thumbnail(for origin: Origin, maxPixelSize: CGFloat) async -> NSImage? {
        let key = cacheKey(for: origin, maxPixelSize: maxPixelSize)
        if let cached = ImageCache.shared.image(for: key) { return cached }

        if let rendered = await Task.detached(priority: .utility, operation: {
            renderedImage(for: origin, key: key, maxPixelSize: maxPixelSize)
        }).value {
            ImageCache.shared.set(rendered, for: key, toDisk: true)
            return rendered
        }
        // Only a download is left, and that cannot happen inside the detached
        // render above.
        guard case .remote(let url) = origin,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let downloaded = scaled(NSImage(data: data), maxPixelSize: maxPixelSize) else { return nil }
        ImageCache.shared.set(downloaded, for: key, toDisk: true)
        return downloaded
    }

    static func cacheKey(for origin: Origin, maxPixelSize: CGFloat) -> String {
        "source-artwork:\(origin.cacheKey):\(Int(maxPixelSize))"
    }

    /// Everything that can be answered without the network. A missing file is
    /// simply no picture: pulling a source back out of iCloud to draw a
    /// citation chip would not be worth the wait.
    nonisolated private static func renderedImage(
        for origin: Origin,
        key: String,
        maxPixelSize: CGFloat
    ) -> NSImage? {
        if let cached = ThumbnailDiskCache.shared.cachedImage(for: key) { return cached }
        guard case .file(let stored) = origin else { return nil }
        let location = SourcePDFPages(stored: stored)
        guard let filePath = BookCoverThumbnail.candidatePaths(for: location.path)
            .first(where: { EPUBBookFiles.exists(atPath: $0) }) else { return nil }

        let lower = filePath.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".png") || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") {
            return scaled(NSImage(contentsOfFile: filePath), maxPixelSize: maxPixelSize)
        }
        if lower.hasSuffix(".htm") || lower.hasSuffix(".html") || lower.hasSuffix(".xhtml") {
            guard let imagePath = EPUBParser.firstImagePath(inXHTMLAt: filePath) else { return nil }
            return scaled(EPUBBookFiles.contents(atPath: imagePath).flatMap(NSImage.init(data:)), maxPixelSize: maxPixelSize)
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: filePath)),
              let page = document.page(at: location.pages?.lowerBound ?? 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxPixelSize / bounds.width, maxPixelSize / bounds.height)
        return page.thumbnail(
            of: CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)),
            for: .mediaBox
        )
    }

    /// Fits a picture inside `maxPixelSize` without `NSImage.lockFocus`, which
    /// is not safe to reach for off the main actor.
    nonisolated private static func scaled(_ image: NSImage?, maxPixelSize: CGFloat) -> NSImage? {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(maxPixelSize / width, maxPixelSize / height)
        guard scale < 1 else { return image }

        let target = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: Int(target.width),
            height: Int(target.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: target))
        guard let output = context.makeImage() else { return image }
        return NSImage(cgImage: output, size: target)
    }

    nonisolated static func pngDataURL(from image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    nonisolated static func jpegDataURL(from image: NSImage, quality: CGFloat = 0.82) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(
                using: .jpeg,
                properties: [.compressionFactor: quality]
              ) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }
}
