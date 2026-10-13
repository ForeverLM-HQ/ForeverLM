import AppKit
import Foundation
import WebKit

/// Turns the pictures of a Reader selection into chat attachments.
///
/// The page describes a picture (`ReaderSelectionImage`); this fetches it.
/// Three routes, in order: the bytes the page handed over (a `data:` picture,
/// or a `blob:` the page could read back), the picture's URL fetched with the
/// in-app web session's cookies so a picture behind a publisher's sign-in
/// comes back as the page got it, and — when a page hands its pictures to
/// nothing but a browser — a photograph of the picture off the web view, at
/// the size it is drawn. The bytes then go through `ChatImagePreparation`
/// like a dropped file, so the model receives a type every vision route
/// reads, and land in the composer's tray as an ordinary attachment.
///
/// A picture no route can read is counted and reported, never dropped in
/// silence: the learner asked about a figure, and a message without it is a
/// different question.
enum ReaderSelectionImageResolver {
    struct Outcome: Sendable {
        var attachments: [ChatImageAttachment] = []
        /// Pictures the selection covered that could not be read.
        var unreadable = 0
    }

    /// Photographs a viewport rectangle (CSS pixels) off a web view, as PNG.
    typealias Snapshot = @MainActor @Sendable (CGRect) async -> Data?

    /// A picture fetch that has not answered in this long is a picture the
    /// page will not give up; the snapshot route takes over.
    static let requestTimeout: TimeInterval = 20

    @MainActor
    static func attachments(for images: [ReaderSelectionImage], snapshot: Snapshot? = nil) async -> Outcome {
        var outcome = Outcome()
        for image in images.prefix(ReaderSelectionImage.maximumPerSelection) {
            guard let data = await bytes(for: image, snapshot: snapshot) else {
                outcome.unreadable += 1
                continue
            }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ChatImagePreparation.prepare(data)
                }.value
                outcome.attachments.append(ChatImageAttachment(prepared: prepared, name: image.attachmentName))
            } catch {
                // An HTML sign-in page served with 200 is bytes, not a picture.
                outcome.unreadable += 1
            }
        }
        return outcome
    }

    @MainActor
    static func bytes(for image: ReaderSelectionImage, snapshot: Snapshot?) async -> Data? {
        if let inline = image.inlineData { return inline }
        if let url = image.fetchURL, let data = await fetch(url) { return data }
        if let rect = image.viewportRect, let snapshot { return await snapshot(rect) }
        return nil
    }

    /// The picture's bytes from its URL, as the signed-in reader would get
    /// them. A `file:` URL — an archived article's or a book chapter's own
    /// picture — reads straight from disk, and one of an EPUB book kept as one
    /// file (`EPUBBookScheme`) from the book's file.
    @MainActor
    static func fetch(_ url: URL) async -> Data? {
        if let path = EPUBBookScheme.path(of: url) {
            return await Task.detached(priority: .userInitiated) { EPUBBookScheme.response(forPath: path)?.data }.value
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        if !url.isFileURL {
            let cookies = await InAppWebSession.cookies(for: url)
            InAppWebSession.apply(cookies, to: &request)
            request.setValue("image/avif,image/webp,image/png,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    /// The snapshot route for `webView`: the picture's viewport rectangle,
    /// scaled by the reader's page zoom into view points and clipped to what
    /// is on screen. A picture scrolled mostly out of view photographs as the
    /// sliver that shows, which is still the picture the learner pointed at
    /// rather than nothing.
    @MainActor
    static func snapshotter(for webView: WKWebView) -> Snapshot {
        { cssRect in
            let zoom = webView.pageZoom
            let scaled = CGRect(
                x: cssRect.minX * zoom,
                y: cssRect.minY * zoom,
                width: cssRect.width * zoom,
                height: cssRect.height * zoom
            )
            let visible = scaled.intersection(webView.bounds)
            guard visible.width >= 16, visible.height >= 16 else { return nil }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = visible
            configuration.afterScreenUpdates = false
            do {
                return png(try await webView.takeSnapshot(configuration: configuration))
            } catch {
                return nil
            }
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
