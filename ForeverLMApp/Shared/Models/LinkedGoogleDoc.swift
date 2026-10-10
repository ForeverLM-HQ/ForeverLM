import Foundation

/// A Google Doc shown in the Docs pane as a *linked doc*.
///
/// The link is identity, so it is parsed by deterministic code: the document id
/// is the path segment after `/d/`, and every share, edit, preview or mobile
/// form of the same document normalizes to one canonical edit URL. Sheets and
/// Slides are refused here on purpose — the Docs pane holds documents, and the
/// text export the app keeps beside the link only reads as prose for a Doc.
enum LinkedGoogleDoc {
    /// What the sidebar and metadata line call one of these.
    static let label = "Google Doc"
    /// The title a linked doc carries until Google's own is fetched or the
    /// writer renames it.
    static let placeholderTitle = "Google Doc"
    /// The glyph beside a linked doc's title.
    static let symbolName = "doc.richtext"

    /// The canonical edit URL for a Google Doc link the user pasted, or the
    /// reason it is not one.
    static func canonicalEditURL(from rawString: String) throws -> URL {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LinkedGoogleDocError.empty }
        // A bare `docs.google.com/…` paste has no scheme; give it Google's.
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let host = url.host?.lowercased() else {
            throw LinkedGoogleDocError.notAURL
        }
        guard host == "docs.google.com" else {
            throw LinkedGoogleDocError.notGoogleDocs(host)
        }
        guard let resource = SourceService.googleDocsResource(from: url) else {
            throw LinkedGoogleDocError.noDocumentID
        }
        guard resource.kind == .document else {
            throw LinkedGoogleDocError.wrongKind(resource.kind.label)
        }
        return editURL(documentID: resource.id)
    }

    /// The document id of a canonical or pasted Google Docs URL; nil for
    /// anything that is not a Google Doc.
    static func documentID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return SourceService.googleDocumentID(from: url)
    }

    static func editURL(documentID: String) -> URL {
        URL(string: "https://docs.google.com/document/d/\(documentID)/edit")!
    }

    /// Google's plain-text export of the document — the same endpoint the
    /// source importer reads, so a linked doc and an imported one see the
    /// same text.
    static func exportURL(documentID: String) -> URL {
        SourceService.googleDocsExportURL(
            for: SourceService.GoogleDocsResource(kind: .document, id: documentID, gid: nil)
        )
    }

    /// Whether a page the embedded editor landed on is Google's sign-in rather
    /// than the document. Sign-in lives on its own host, so the redirect is the
    /// signal — no page text has to be read.
    static func isSignInURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
    }

    /// The document's own name from the editor page's `<title>`, which Google
    /// writes as "Name - Google Docs". Structure, not prose: the suffix is a
    /// fixed marker Google appends, and the name is whatever precedes it.
    static func title(fromPageTitle pageTitle: String) -> String? {
        var name = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Google Docs", " – Google Docs", " - Google Documenten"] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Google Docs", name != "Google Accounts" else { return nil }
        return String(name.prefix(500))
    }

    /// The `<title>` of an HTML page, with the entities Google writes in one
    /// decoded. Structural: the tag is the marker, not the words inside it.
    static func pageTitle(inHTML html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html[open.upperBound...].firstIndex(of: ">"),
              let close = html[openEnd...].range(of: "</title>", options: .caseInsensitive) else {
            return nil
        }
        let raw = String(html[html.index(after: openEnd)..<close.lowerBound])
        let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// The cookies a browser would send with a request to `url`: the domain
    /// covers the host (a leading-dot domain covers subdomains), the path is a
    /// prefix of the request path, secure cookies stay on https, and expired
    /// ones are dropped. This stands in for the cookie jar the export session
    /// does not share with the web views.
    static func cookies(_ cookies: [HTTPCookie], applicableTo url: URL) -> [HTTPCookie] {
        InAppWebSession.applicable(cookies, to: url)
    }

    /// How long an export is considered fresh: opening the same doc twice in a
    /// row does not fetch it twice.
    static let exportRefreshInterval: TimeInterval = 10 * 60
}

enum LinkedGoogleDocError: LocalizedError, Equatable {
    case empty
    case notAURL
    case notGoogleDocs(String)
    case noDocumentID
    case wrongKind(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste a Google Docs link."
        case .notAURL:
            return "That is not a web address."
        case .notGoogleDocs(let host):
            return "That link points at \(host), not docs.google.com."
        case .noDocumentID:
            return "That Google Docs link has no document in it. It should look like docs.google.com/document/d/…"
        case .wrongKind(let kind):
            return "That is a \(kind). Only Google Docs documents can be linked here."
        }
    }
}
