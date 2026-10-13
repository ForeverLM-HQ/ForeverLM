#if os(macOS)
import AppKit
import MediaPlayer
import PDFKit

/// The picture the system's Now Playing surfaces (the menu bar widget, Control
/// Center, AirPlay receivers, and CarPlay via a paired iPhone) show beside a
/// narration. Text-to-speech never handed one over, so every listener saw text
/// alone. A book chapter shows its book's cover, a paper its first page, an
/// article or meeting the artwork the library already has, and anything
/// without an image falls back to the ForeverLM mark rather than to nothing.
enum NowPlayingArtwork {
    /// Longest side of the rendered image. Now Playing tiles are small; a full
    /// page render for every chapter would be wasted work on the main thread's
    /// behalf.
    static let renderSize = CGSize(width: 600, height: 600)

    /// Resolves the image for a source, off the main actor. `bookCoverPath` is
    /// the book's cover when the source is a chapter and Studio knows it.
    nonisolated static func image(
        for article: StudioArticle,
        bookCoverPath: String?
    ) async -> NSImage {
        if let bookCoverPath, let cover = renderLocal(path: bookCoverPath) {
            return cover
        }
        if let pdfPath = article.cachedResolvedPDFPath,
           let page = renderLocal(path: SourcePDFPages.stored(path: pdfPath, pages: article.bookPages)) {
            return page
        }
        if let artworkURL = article.artworkURL {
            if let localPath = MeetingIconService.localArtworkPath(for: artworkURL),
               let icon = NSImage(contentsOfFile: localPath) {
                return icon
            }
            if let url = URL(string: artworkURL), url.scheme?.hasPrefix("http") == true,
               let remote = await download(url) {
                return remote
            }
        }
        return fallback
    }

    nonisolated static var fallback: NSImage {
        NSImage(named: "BrandMark") ?? NSApp.applicationIconImage
    }

    nonisolated static func artwork(from image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// An image file as-is, or the first page of a PDF rendered to `renderSize`.
    /// Relative paths are the library's; the same candidate walk the sidebar
    /// thumbnails use finds a file iCloud has moved between roots.
    private nonisolated static func renderLocal(path: String) -> NSImage? {
        // A book chapter's path names its pages of the book's file; its picture is the first.
        let location = SourcePDFPages(stored: path)
        let candidates = StorageService.sourceFileCandidatePaths(for: location.path)
        guard let filePath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        let lower = filePath.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") {
            return NSImage(contentsOfFile: filePath)
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: filePath)),
              let page = document.page(at: location.pages?.lowerBound ?? 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(renderSize.width / bounds.width, renderSize.height / bounds.height)
        return page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        )
    }

    private nonisolated static func download(_ url: URL) async -> NSImage? {
        let key = "now-playing-artwork:\(url.absoluteString)"
        if let cached = ImageCache.shared.image(for: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        ImageCache.shared.set(image, for: key)
        return image
    }
}
#endif
