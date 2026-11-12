import Foundation
import OSLog

/// A Substack post has two kinds of address. Its own is on the publication's
/// site: `<publication>.substack.com/p/<slug>`, or the same path on the
/// publication's own domain. Substack's reader and app hand out a second kind,
/// on substack.com itself: `/home/post/p-<id>`, `/inbox/post/<id>`,
/// `/@<handle>/p-<id>` and `open.substack.com/pub/<publication>/p/<slug>`.
///
/// Nothing in the text of an app link says which post address it names, so a
/// post saved once from the reader and once from the publication's site was
/// two sources (the product owner, 2026-11-12: "ingested twice as a duplicate.
/// That shouldn't be possible"). Substack itself says which: asked without a
/// sign-in, an app link answers with a redirect to the post's own address.
/// A source is filed under that address, and holds the app link as one more
/// work key, so either address finds it.
enum SubstackAppLink {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")

    /// Whether `address` is one of the links Substack's reader and app give a
    /// post. A note (`/@handle/note/c-<id>`), a profile and a publication's
    /// home are not posts and keep their own address.
    static func isAppLink(_ address: String) -> Bool {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = bareHost(components.host) else { return false }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch host {
        case "substack.com":
            if parts.count == 3, parts[1] == "post" {
                if parts[0] == "home" { return isPostID(parts[2], prefixed: true) }
                if parts[0] == "inbox" { return isPostID(parts[2], prefixed: false) }
            }
            if parts.count == 2, parts[0].hasPrefix("@"), parts[0].count > 1 {
                return isPostID(parts[1], prefixed: true)
            }
            return false
        case "open.substack.com":
            return parts.count == 4 && parts[0] == "pub" && parts[2] == "p"
        default:
            return false
        }
    }

    /// The post's own address, from the address that answered an app link:
    /// `https://<host>/p/<slug>`, without the query Substack adds on the way
    /// (`?triedRedirect=true`). Nil when the answer is not a post on a
    /// publication's site: Substack kept the request on its own pages, or sent
    /// it somewhere that is not a post.
    static func postAddress(answering finalURL: URL) -> String? {
        guard let components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let bare = bareHost(host), bare != "substack.com", bare != "open.substack.com" else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, parts[0] == "p", !parts[1].isEmpty else { return nil }
        return "https://\(host)/p/\(parts[1])"
    }

    /// The post's own address from the page `open.substack.com` answers with
    /// when it does not redirect: a few lines that send the browser on, by a
    /// `<meta http-equiv="refresh">` naming the post. Nil for any other page.
    static func postAddress(inForwardingPage html: String) -> String? {
        guard let match = html.range(
            of: #"http-equiv="refresh"\s+content="\d+;\s*url=[^"]+""#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let tag = html[match]
        guard let start = tag.range(of: "url=", options: .caseInsensitive)?.upperBound,
              let target = URL(string: String(tag[start...].dropLast())) else { return nil }
        return postAddress(answering: target)
    }

    /// Asks Substack which post an app link names. The request carries no
    /// cookies: signed in, Substack answers an app link with its reader instead
    /// of sending the browser to the post. Asked for the headers alone, it
    /// answers with a redirect; `open.substack.com` sometimes answers with a
    /// page that forwards instead, which is then read. Nil when `appLink` is no
    /// app link, or Substack could not be reached or did not name a post.
    static func resolvePostAddress(_ appLink: String) async -> String? {
        guard isAppLink(appLink), let url = URL(string: appLink.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.setValue(SharedWebKit.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await signedOutSession.data(for: request)
            if let answered = response.url, let address = postAddress(answering: answered) { return address }
            request.httpMethod = "GET"
            let (page, _) = try await signedOutSession.data(for: request)
            return postAddress(inForwardingPage: String(decoding: page.prefix(4096), as: UTF8.self))
        } catch {
            logger.error("Substack did not say which post an app link names: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let signedOutSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static func bareHost(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A post id is digits, after `p-` where the link writes it that way.
    private static func isPostID(_ part: String, prefixed: Bool) -> Bool {
        var digits = Substring(part)
        if prefixed {
            guard digits.hasPrefix("p-") else { return false }
            digits = digits.dropFirst(2)
        }
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

extension StudioArticle {
    /// A source that is not yet saved, filed under another address: a new id
    /// minted from it, with everything a discovered or typed link carries. A
    /// title that was only the old address or its host becomes the new host.
    func readdressed(to address: String) -> StudioArticle {
        let host = URL(string: address)?.host ?? address
        let oldHost = URL(string: url)?.host ?? url
        let placeholderTitles = [url, oldHost, domain]
        var moved = StudioArticle(
            url: address,
            title: placeholderTitles.contains(title) ? host : title,
            sourceType: sourceType,
            artworkURL: artworkURL,
            discoveryOrigin: discoveryOrigin,
            parentGroup: parentGroup,
            author: author
        )
        moved.domain = host
        moved.teamID = teamID
        moved.dateAdded = dateAdded
        moved.readAt = readAt
        return moved
    }
}
