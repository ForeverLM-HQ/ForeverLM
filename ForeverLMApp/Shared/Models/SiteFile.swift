import Foundation

// A site's files as they travel: in a publish to sites.foreverlm.com, and in
// an Artifact's CloudKit body package (`ArtifactBodyPackage`), which the
// phone unpacks to show a walkthrough's animation by reference. Kept apart
// from `SitePublishingService` so the phone compiles the file shape without
// the publishing client.

/// One file of a site as it is sent: its path inside the site and its bytes.
struct SiteFile: Equatable, Sendable {
    let path: String
    let data: Data
    /// Sent by its own streamed request after the publish rather than inline
    /// in the JSON body — a paper's PDF, a large image. The publish declares
    /// the path and size; the service stores the bytes when they arrive.
    var upload: Bool = false

    /// The wire form: text as `content` when the bytes are UTF-8 text, else
    /// `content_base64`; an upload as its declaration. The site derives the
    /// type from the extension.
    var payload: [String: Any] {
        if upload { return ["path": path, "upload": true, "bytes": data.count] }
        if let text = String(data: data, encoding: .utf8), !SiteFile.looksBinary(data) {
            return ["path": path, "content": text]
        }
        return ["path": path, "content_base64": data.base64EncodedString()]
    }

    /// A NUL in the first 8 KB is the bytes of an image, a font or an archive;
    /// text has none.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }
}

/// Where a file sits inside a site.
enum SiteFilePath {
    /// The page a site opens on.
    static let entryFile = "index.html"

    /// A file's path inside the site, as the site will store and serve it, or
    /// nil when it cannot be one. A leading `./` or `/` is forgiven.
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        while text.hasPrefix("./") || text.hasPrefix("/") { text.removeFirst(text.hasPrefix("./") ? 2 : 1) }
        guard !text.isEmpty, text.count <= 200 else { return nil }
        let segments = text.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= 20 else { return nil }
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..",
                  segment.first!.isLetter || segment.first!.isNumber,
                  segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._~-".contains($0)) }) else { return nil }
        }
        return segments.joined(separator: "/")
    }
}
