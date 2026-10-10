import Foundation

// Its own file so the phone, which compiles an allowlist of Shared files and
// not the Mac's walkthrough record, shows a step's animation under the same
// policy the Mac does.

/// The HTML a step's animation is shown from. Whatever wrote it, the page is
/// served as one document with a policy that keeps it to itself: inline
/// styles and script, data: images, nothing fetched, no frames.
enum PaperWalkthroughAnimationDocument {
    static let contentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:;"

    static func document(for html: String) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        let injected = meta + viewport
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            var copy = html
            copy.replaceSubrange(range, with: "<head>" + injected)
            return copy
        }
        if let range = html.range(of: "<html", options: .caseInsensitive),
           let close = html[range.lowerBound...].firstIndex(of: ">") {
            var copy = html
            copy.insert(contentsOf: "<head>\(injected)</head>", at: copy.index(after: close))
            return copy
        }
        return "<!DOCTYPE html><html><head>\(injected)</head><body style=\"margin:0\">\(html)</body></html>"
    }
}
