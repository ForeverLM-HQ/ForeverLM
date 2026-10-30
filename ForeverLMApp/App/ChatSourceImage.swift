import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture the chat transcript shows for a `foreverlm://image/…` reference.
///
/// The web view only ever sees the `data:` URL — a chat message is a sandboxed
/// page with no file access, and the reference itself deliberately names no
/// path. The bytes stay here so the Copy button and a drag out of the transcript
/// put the very same image on the pasteboard.
struct ChatSourceImage: Encodable, Sendable {
    let data: Data
    let mediaType: String
    /// The captured frame a slide picture was drawn from, which is what ties it
    /// to the papers "Extract papers" read off that slide. Nil for every other
    /// kind of picture. Not sent to the page; `citedPapers` is.
    var slideFrame: SlideFrame? = nil
    /// The papers read off this slide that there is something to do with: one
    /// in the library opens in the Reader, one still on offer can be added.
    /// Filled per lookup rather than cached with the bytes, because adding a
    /// paper changes it and the picture does not.
    var citedPapers: [CitedPaper] = []
    /// For a picture from the image store, the version shown and what made
    /// it, for the right-click menu's model line and Redraw With. Not sent
    /// to the page.
    var generatedListing: GeneratedImageStore.Listing? = nil

    struct SlideFrame: Equatable, Sendable {
        let sourceID: String
        let imagePath: String
        let timeSeconds: Double?
    }

    /// A paper as the list under a slide shows it.
    struct CitedPaper: Encodable, Equatable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        /// The library source it was added as; nil while it is still on offer.
        let sourceID: String?
        let canAdd: Bool

        init(_ paper: VideoCitedPaper) {
            id = paper.id
            title = paper.title
            subtitle = paper.displaySubtitle
            sourceID = paper.status == .imported ? paper.importedSourceID : nil
            canAdd = paper.status == .pending && !(paper.url ?? "").isEmpty
        }
    }

    /// Whether `paper` was read off `frame`. The stored frame path is the tie;
    /// a row saved before paths were kept falls back to the slide's timestamp,
    /// the way the transcript places it (`VideoCitedPaperWindow`). A paper that
    /// names another frame never matches on time, since two slides can round
    /// onto the same storyboard tile.
    static func paper(_ paper: VideoCitedPaper, isFrom frame: SlideFrame) -> Bool {
        guard paper.sourceID == frame.sourceID else { return false }
        if let path = paper.slideImagePath { return path == frame.imagePath }
        guard let seconds = paper.slideTimeSeconds, let slideSeconds = frame.timeSeconds else { return false }
        return abs(slideSeconds - seconds) < 0.5
    }

    /// The papers of `frame` worth listing under it, in the order the source's
    /// candidates came: waved-off ones and ones that resolved to nothing offer
    /// nothing to click, so they stay in the reader's Papers list.
    static func citedPapers(from papers: [VideoCitedPaper], on frame: SlideFrame) -> [CitedPaper] {
        papers
            .filter { paper($0, isFrom: frame) }
            .map(CitedPaper.init)
            .filter { $0.sourceID != nil || $0.canAdd }
    }

    var dataURL: String { "data:\(mediaType);base64,\(data.base64EncodedString())" }

    enum CodingKeys: String, CodingKey {
        case dataURL
        case mediaType
        case citedPapers
        case redrawable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dataURL, forKey: .dataURL)
        try container.encode(mediaType, forKey: .mediaType)
        if !citedPapers.isEmpty {
            try container.encode(citedPapers, forKey: .citedPapers)
        }
        // The picture carries a Redraw button only when it can be drawn again.
        if let generatedListing, GeneratedImageRedraw.canRedraw(generatedListing.details) {
            try container.encode(true, forKey: .redrawable)
        }
    }

    /// Places the picture on the general pasteboard as an image other apps
    /// paste (TIFF/PNG through `NSImage`), plus the original bytes under their
    /// own type so an SVG or GIF survives a paste into an app that keeps them.
    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        var wroteSomething = false
        if let type = UTType(mimeType: mediaType) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            wroteSomething = true
        }
        if let image = NSImage(data: data) {
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
                wroteSomething = true
                if mediaType != "image/png",
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    item.setData(png, forType: .png)
                }
            }
        }
        guard wroteSomething else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    // MARK: - Resolution

    /// Rendered pictures, keyed by reference URL. A transcript re-renders its
    /// rows as the learner scrolls, and a rebuilt row must not re-rasterize a
    /// PDF page every time; the cost limit keeps a long illustrated chat from
    /// holding hundreds of megabytes of page renders.
    private static let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private final class CacheEntry {
        let image: ChatSourceImage
        init(_ image: ChatSourceImage) { self.image = image }
    }

    /// Drops the store's pictures a redraw replaced, so a line that names
    /// one looks it up again and shows the redraw.
    static func forgetGenerated(ids: [String]) {
        for id in ids {
            guard let reference = GeneratedImageReference(id: id) else { continue }
            cache.removeObject(forKey: reference.urlString as NSString)
        }
    }

    /// Renders listed slides into the cache before any reply shows them. A
    /// quiz over a talk lists its slides once and deals them out one question
    /// at a time; rendered here in the background, each draws the moment its
    /// question arrives. A slide already cached is skipped.
    @MainActor
    static func prewarmSlides(_ references: [SourceImageReference], content: String) {
        let pending = references.filter { reference in
            guard case .slide = reference.location else { return false }
            return cache.object(forKey: reference.urlString as NSString) == nil
        }
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            for reference in pending {
                let rendered = await Task.detached(priority: .utility) {
                    Self.renderedSlide(reference, content: content)
                }.value
                guard let rendered else { continue }
                let key = reference.urlString as NSString
                guard cache.object(forKey: key) == nil else { continue }
                cache.setObject(CacheEntry(rendered), forKey: key, cost: rendered.data.count)
            }
        }
    }

    /// Resolves a reference through the article that owns it. Nil when the URL
    /// is not an image reference, the source is unknown, its file is not on
    /// this device, or the location does not exist in the file.
    ///
    /// File and PDF work runs detached; nothing here touches the main actor
    /// except the lookups the caller supplies.
    ///
    /// A slide is named by its video's stored content, which the sidebar's
    /// catalog rows do not carry: `contentForSourceID` reads it from storage
    /// when the article came without it. Without that read every slide of a
    /// library video drew as "picture unavailable" (2026-09-25).
    ///
    /// A slide comes back with the papers `citedPapersForSource` holds for its
    /// video that were read off that frame.
    @MainActor
    static func resolved(
        token: String,
        articleForSourceID: @MainActor (String) async -> StudioArticle?,
        contentForSourceID: @MainActor (String) async -> String? = { _ in nil },
        citedPapersForSource: @MainActor (String) async -> [VideoCitedPaper] = { _ in [] }
    ) async -> ChatSourceImage? {
        guard var image = await resolvedPicture(
            token: token,
            articleForSourceID: articleForSourceID,
            contentForSourceID: contentForSourceID
        ) else { return nil }
        if let frame = image.slideFrame {
            image.citedPapers = citedPapers(from: await citedPapersForSource(frame.sourceID), on: frame)
        }
        return image
    }

    /// A slide frame rendered from its video's stored block, carrying the frame
    /// it was drawn from.
    private static func renderedSlide(_ reference: SourceImageReference, content: String) -> ChatSourceImage? {
        guard let frame = SourceImageCatalog.slideFrame(for: reference, in: content),
              let rendered = SourceImageCatalog.renderSlideFrame(frame, crop: reference.crop) else { return nil }
        return ChatSourceImage(
            data: rendered.data,
            mediaType: rendered.mediaType,
            slideFrame: SlideFrame(sourceID: reference.sourceID, imagePath: frame.imagePath, timeSeconds: frame.timeSeconds)
        )
    }

    @MainActor
    private static func resolvedPicture(
        token: String,
        articleForSourceID: @MainActor (String) async -> StudioArticle?,
        contentForSourceID: @MainActor (String) async -> String?
    ) async -> ChatSourceImage? {
        func slideContent(of article: StudioArticle) async -> String? {
            if let content = article.content, SlideFrameExtraction.containsSlideSection(content) { return content }
            return await contentForSourceID(article.id) ?? article.content
        }
        // A slide whose frame is not on this Mac: the deck was captured on the
        // other one and only its listing synced, so the frame is taken again
        // from the video (`SlideFrameRestorer`) and drawn from that.
        func restoredSlide(_ reference: SourceImageReference, of article: StudioArticle, content: String) async -> ChatSourceImage? {
            let frame = await Task.detached(priority: .userInitiated) {
                SourceImageCatalog.slideFrame(for: reference, in: content)
            }.value
            guard let frame, await SlideFrameRestorer.shared.restore([frame], of: article, storage: nil) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                Self.renderedSlide(reference, content: content)
            }.value
        }
        // A picture the learner attached lives in this device's own store —
        // in memory from the moment it was dropped, on disk once written — and
        // needs no article to resolve through. Not cached here: the store is
        // its own cache, and a just-staged picture must never be shadowed by
        // an earlier miss.
        if let attached = AttachedImageReference(urlString: token) {
            let stored = await Task.detached(priority: .userInitiated) {
                AttachedImageStore.read(id: attached.id)
            }.value
            guard let stored else { return nil }
            return ChatSourceImage(data: stored.data, mediaType: stored.mediaType)
        }
        // A picture the chat drew lives in this device's own store and needs no
        // article to resolve through; it is checked first because its URL
        // shares the scheme and host with source references.
        if let generated = GeneratedImageReference(urlString: token) {
            let key = generated.urlString as NSString
            if let cached = cache.object(forKey: key) { return cached.image }
            // The version the line names, or the picture it was redrawn as.
            let stored = await Task.detached(priority: .userInitiated) {
                GeneratedImageStore.readShown(id: generated.id)
            }.value
            guard let stored else { return nil }
            var image = ChatSourceImage(data: stored.image.data, mediaType: stored.image.mediaType)
            image.generatedListing = stored.listing
            cache.setObject(CacheEntry(image), forKey: key, cost: stored.image.data.count)
            return image
        }
        // A slide named by its frame file — the path a model copied out of a
        // transcript's slide block — resolves through the video's stored block
        // to the frame it names, so a transcript kept before such a path was
        // rewritten into a `slide/<n>` reference still shows the slide.
        if let framePath = SourceImageReference.SlideFramePath(pathOrURL: token) {
            guard let article = await articleForSourceID(framePath.sourceID),
                  let content = await slideContent(of: article),
                  let index = SourceImageCatalog.slideFrameIndex(for: framePath, in: content) else { return nil }
            let reference = SourceImageReference(sourceID: article.id, location: .slide(index))
            let key = reference.urlString as NSString
            if let cached = cache.object(forKey: key) { return cached.image }
            var rendered = await Task.detached(priority: .userInitiated) {
                Self.renderedSlide(reference, content: content)
            }.value
            if rendered == nil {
                rendered = await restoredSlide(reference, of: article, content: content)
            }
            guard let rendered else { return nil }
            cache.setObject(CacheEntry(rendered), forKey: key, cost: rendered.data.count)
            return rendered
        }
        guard let reference = SourceImageReference(urlString: token) else { return nil }
        let key = reference.urlString as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let article = await articleForSourceID(reference.sourceID) else { return nil }
        // A moment is the frame the chat captured at a time the learner named.
        // This Mac may not hold it — it was captured on the other one and has
        // not synced down — so a YouTube video's frame is captured again from
        // the stream rather than drawn as unavailable.
        if case .moment(let seconds) = reference.location {
            let moment = SourceImageReference(sourceID: article.id, location: reference.location, crop: reference.crop)
            var rendered = await Task.detached(priority: .userInitiated) {
                SourceImageCatalog.renderMoment(moment)
            }.value
            if rendered == nil, YouTubeTranscriptService.isYouTubeURL(article.url) {
                _ = try? await YouTubeSlideExtractionService.shared.captureMoment(
                    videoURL: article.url,
                    sourceID: article.id,
                    seconds: seconds
                )
                rendered = await Task.detached(priority: .userInitiated) {
                    SourceImageCatalog.renderMoment(moment)
                }.value
            }
            guard let rendered else { return nil }
            let image = ChatSourceImage(data: rendered.data, mediaType: rendered.mediaType)
            cache.setObject(CacheEntry(image), forKey: key, cost: rendered.data.count)
            return image
        }
        // A slide frame is named by the video's stored content, not held in a
        // file of the source's own; everything else is inside that file. The
        // slide is drawn under the article's own id, which the token may only
        // have linked to, so its frame is tied to that video's papers.
        if case .slide = reference.location {
            guard let content = await slideContent(of: article) else { return nil }
            let slide = SourceImageReference(sourceID: article.id, location: reference.location, crop: reference.crop)
            var rendered = await Task.detached(priority: .userInitiated) {
                Self.renderedSlide(slide, content: content)
            }.value
            if rendered == nil {
                rendered = await restoredSlide(slide, of: article, content: content)
            }
            guard let rendered else { return nil }
            cache.setObject(CacheEntry(rendered), forKey: key, cost: rendered.data.count)
            return rendered
        }
        let rendered = await Task.detached(priority: .userInitiated) { () -> SourceImageCatalog.RenderedImage? in
            guard let path = article.resolvedFileLocation else { return nil }
            return SourceImageCatalog.render(reference, filePath: path)
        }.value
        guard let rendered else { return nil }
        let image = ChatSourceImage(data: rendered.data, mediaType: rendered.mediaType)
        cache.setObject(CacheEntry(image), forKey: key, cost: rendered.data.count)
        return image
    }
}

// MARK: - A card's picture for the iPhone

extension ChatSourceImage {
    /// The longest side of a card picture sent to the iPhone: a phone card is narrower than this, and a slide's
    /// words stay legible at it.
    static let cardPictureMaxPixels = 1_600

    /// A card picture as the JPEG its Card record carries for the iPhone (`CardPicturePublisher`): drawn the
    /// way a card on this Mac draws it, then scaled to at most `cardPictureMaxPixels` on its longest side.
    /// Nil when this Mac cannot draw it.
    @MainActor
    static func cardPictureJPEG(_ target: String, storage: StorageService) async -> Data? {
        guard let image = await resolved(
            token: target,
            articleForSourceID: { sourceID in try? await storage.loadSourceWithoutContent(sourceID) },
            contentForSourceID: { sourceID in await storage.loadSourceContent(sourceID) }
        ) else { return nil }
        let data = image.data
        return await Task.detached(priority: .utility) { jpeg(data, maxPixels: cardPictureMaxPixels) }.value
    }

    /// `data` decoded and written again as a JPEG no larger than `maxPixels` on its longest side.
    nonisolated static func jpeg(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

