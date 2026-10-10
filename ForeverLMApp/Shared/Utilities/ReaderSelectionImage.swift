import CoreGraphics
import Foundation

/// A picture inside a Reader selection, as the page described it.
///
/// A drag over a web page takes pictures with it — a figure, an infographic,
/// a diagram — and `selection.toString()` says nothing about them, which is
/// why until 2026-09-20 a selection that was only a picture summoned no bar
/// at all (product owner, over a Waypoint Bio figure: "i want to be able to
/// highlight stuff and also have that explained"). The page now reports each
/// picture the selection covers, and the app does two things with it: Chat
/// attaches the picture to the message so the model sees the figure, and
/// Highlight anchors the mark to the picture (`ReaderImageAnchor`).
///
/// The page describes; the app fetches. Bytes cross the bridge only when the
/// app could not get them itself — a `blob:` URL lives inside the page and
/// nothing outside can read it — so a selection over a photo essay does not
/// push megabytes of base64 through a message handler on every mouse-up.
struct ReaderSelectionImage: Equatable, Sendable {
    /// How many pictures one selection hands to the chat. The chat's own
    /// picture tools return at most this many per result, and a model reads a
    /// handful of figures far better than a page of them.
    static let maximumPerSelection = 4

    /// The picture's URL as the page resolved it (`currentSrc`), absolute.
    let src: String
    let alt: String
    /// Natural size in pixels; 0 when the page did not know it.
    let width: Int
    let height: Int
    /// Where the picture was in the page's viewport, in CSS pixels, so the app
    /// can photograph it off the web view when its URL cannot be fetched.
    let viewportRect: CGRect?
    /// The picture's bytes as a `data:` URL, only for a picture the app cannot
    /// fetch by URL.
    let dataURL: String?

    init(
        src: String,
        alt: String = "",
        width: Int = 0,
        height: Int = 0,
        viewportRect: CGRect? = nil,
        dataURL: String? = nil
    ) {
        self.src = src.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alt = ReaderImageAnchor.cleanedAlt(alt)
        self.width = max(0, width)
        self.height = max(0, height)
        self.viewportRect = viewportRect
        self.dataURL = dataURL?.isEmpty == false ? dataURL : nil
    }

    /// One entry of the `images` array a reader page posts.
    init?(payload: [String: Any]) {
        guard let src = payload["src"] as? String,
              !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var rect: CGRect?
        if let left = (payload["left"] as? NSNumber)?.doubleValue,
           let top = (payload["top"] as? NSNumber)?.doubleValue,
           let right = (payload["right"] as? NSNumber)?.doubleValue,
           let bottom = (payload["bottom"] as? NSNumber)?.doubleValue,
           right > left, bottom > top {
            rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        self.init(
            src: src,
            alt: payload["alt"] as? String ?? "",
            width: (payload["width"] as? NSNumber)?.intValue ?? 0,
            height: (payload["height"] as? NSNumber)?.intValue ?? 0,
            viewportRect: rect,
            dataURL: payload["dataURL"] as? String
        )
    }

    /// A saved mark's picture, asked about again from its card or the notes
    /// list: the anchor knows the URL, and the app fetches the rest.
    init(anchor: ReaderImageAnchor) {
        self.init(src: anchor.src, alt: anchor.alt, width: anchor.width, height: anchor.height)
    }

    /// The `images` array of a reader page's message, capped and de-duplicated
    /// by URL — a responsive page can list one picture twice.
    static func list(from payload: Any?) -> [ReaderSelectionImage] {
        guard let entries = payload as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        var result: [ReaderSelectionImage] = []
        for entry in entries {
            guard let image = ReaderSelectionImage(payload: entry), seen.insert(image.src).inserted else { continue }
            result.append(image)
            if result.count >= maximumPerSelection { break }
        }
        return result
    }

    /// The durable half: what a highlight stores about this picture.
    var anchor: ReaderImageAnchor {
        ReaderImageAnchor(src: src, alt: alt, width: width, height: height)
    }

    /// The alt text, on one line, or "Picture" when the page gave none.
    var displayLabel: String { anchor.displayLabel }

    /// The name the picture is attached to a chat under, which the composer
    /// shows beneath its thumbnail and the message carries as the image
    /// line's alt text: the picture's alt text, else the file it came from,
    /// else "Picture". Kept to one short line so the chip stays a chip.
    var attachmentName: String {
        let alt = self.alt
        if !alt.isEmpty { return String(alt.prefix(80)) }
        let file = anchor.fileName
        if !file.isEmpty, file.count <= 80 { return file }
        return "Picture"
    }

    /// The URL the app fetches the picture from, when it can be fetched at all.
    /// A `blob:` URL cannot be, and a `data:` URL is decoded rather than fetched.
    var fetchURL: URL? {
        guard let url = URL(string: src), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "file": return url
        default: return nil
        }
    }

    /// The bytes of a `data:` picture — either the page's own `src`, or the
    /// `dataURL` the page handed over for a `blob:` — or nil.
    var inlineData: Data? {
        for candidate in [dataURL, src].compactMap({ $0 }) {
            if let data = Self.decodeDataURL(candidate) { return data }
        }
        return nil
    }

    /// `data:<type>;base64,<bytes>`. A `data:` URL that is not base64 (a
    /// percent-encoded SVG, say) is not a picture the chat can carry anyway.
    static func decodeDataURL(_ string: String) -> Data? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:"),
              let comma = trimmed.firstIndex(of: ",") else { return nil }
        let header = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<comma].lowercased()
        guard header.hasSuffix(";base64") else { return nil }
        let payload = trimmed[trimmed.index(after: comma)...]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: payload)
    }
}
