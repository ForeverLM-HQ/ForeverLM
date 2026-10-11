import Foundation

// A site's files as they travel in an Artifact's CloudKit body package
// (`ArtifactBodyPackage`), which the phone unpacks to show a walkthrough's
// animation by reference. Kept apart from `LocalSite` so the phone compiles
// the file shape without the Mac's site tools.

/// One file of a site: its path inside the site and its bytes.
struct SiteFile: Equatable, Sendable {
    let path: String
    let data: Data

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
