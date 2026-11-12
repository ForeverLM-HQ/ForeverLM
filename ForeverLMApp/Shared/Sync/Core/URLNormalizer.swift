import Foundation

/// URL normalization v1 (§4.1): the key every web source's id is minted from
/// (`SyncIdentity.sourceID(normalizedURL:)`, the Mac's `SourceIdentity.stableID`) and the `url:`
/// work key. v1 is frozen: an existing id is never re-derived, and
/// `schema/vectors/url-normalize.json` pins every branch, so an edit here that changes one of its
/// outputs is a bug; a better rule is a v2 for new keys only. The JS port
/// (`schema/js/url-normalize-v1.js`) is pinned by the same vectors.
enum URLNormalizer {

    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
        "ref", "source", "fbclid", "gclid"
    ]

    /// Pure, deterministic URL normalization.
    /// Returns a canonical string suitable for use as a unique key.
    ///
    /// A local file path (one starting with `/`) normalizes through `localPath`. Only the Mac holds
    /// local paths: it passes its content roots (`StorageService.relativeSourcePath`, through
    /// `URLNormalizer.normalize(_:)` in Mac code), which strip the absolute iCloud prefix so the
    /// same file on two Macs maps to one key. Clients without local paths use `normalizeRemote`.
    static func normalize(_ urlString: String, localPath: (String) -> String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Local file paths: strip absolute iCloud prefix to a relative path so the
        // same file on different Macs (different usernames) maps to the same key.
        if trimmed.hasPrefix("/") {
            return localPath(trimmed)
        }

        if let canonicalApplePodcastURL = canonicalApplePodcastEpisodeURL(trimmed) {
            return canonicalApplePodcastURL
        }

        // YouTube shortlinks: expand youtu.be and m.youtube.com first
        if let youtubeId = extractYouTubeVideoId(trimmed) {
            return "youtube.com/watch?v=\(youtubeId)"
        }

        guard var components = URLComponents(string: trimmed),
              components.host != nil else {
            return trimmed
        }

        // Strip scheme (URLComponents.string will produce "//host/path" after this;
        // we strip the leading "//" below before returning)
        components.scheme = nil

        // Lowercase and strip www.
        if let host = components.host?.lowercased() {
            components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        // Strip trailing slash
        if components.path.hasSuffix("/") && components.path.count > 1 {
            components.path = String(components.path.dropLast())
        }

        // Normalize arXiv URLs: /abs/, /pdf/, /html/ → canonical /abs/ form
        if let host = components.host,
           host == "arxiv.org" || host == "export.arxiv.org" {
            components.host = "arxiv.org"
            var path = components.path
            for prefix in ["/pdf/", "/html/", "/abs/"] {
                if path.hasPrefix(prefix) {
                    let id = String(path.dropFirst(prefix.count))
                        .replacingOccurrences(of: ".pdf", with: "")
                    path = "/abs/\(id)"
                    break
                }
            }
            // Strip version suffix (e.g., 2503.09427v2 → 2503.09427)
            if let dotRange = path.range(of: "v\\d+$", options: .regularExpression) {
                path.removeSubrange(dotRange)
            }
            components.path = path
            components.queryItems = nil
        }

        // Normalize bioRxiv/medRxiv: strip version suffixes
        if let host = components.host,
           host.hasSuffix("biorxiv.org") || host.hasSuffix("medrxiv.org") {
            if let vRange = components.path.range(of: "\\.\\d+v\\d+$", options: .regularExpression) {
                components.path.removeSubrange(vRange)
            }
        }

        // ScienceDirect exposes the same paper under both:
        // /science/article/pii/<PII> and /science/article/abs/pii/<PII>?via%3Dihub.
        // Canonicalize to the PII form so reading-list discovery and later PDF
        // attachment do not create sibling records for the same paper.
        if let host = components.host,
           host.hasSuffix("sciencedirect.com") {
            let pathParts = components.path.split(separator: "/").map(String.init)
            if let piiIndex = pathParts.firstIndex(where: { $0.lowercased() == "pii" }),
               pathParts.indices.contains(piiIndex + 1) {
                let pii = pathParts[piiIndex + 1]
                    .removingPercentEncoding?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? pathParts[piiIndex + 1]
                if !pii.isEmpty {
                    components.path = "/science/article/pii/\(pii)"
                    components.queryItems = nil
                }
            }
        }

        // Cell Press exposes the same paper under journal paths such as
        // /molecular-cell/fulltext/<PII> and direct PDF endpoints like
        // /action/showPdf?pii=<PII>. Canonicalize on the PII so Reading List
        // discovery, PDF attachment, and tracking-parameter variants stay one row.
        if let host = components.host,
           host.hasSuffix("cell.com"),
           let pii = cellPressPII(from: components) {
            components.path = "/pii/\(pii)"
            components.queryItems = nil
        }

        // Springer Nature exposes one article under /articles/<id>, its PDF
        // under /articles/<id>.pdf, and reaches the page through recommendation
        // links that carry `?fromPaywallRec=false`. Canonicalize on the article
        // id so a paper saved from a recommendation link and the bare address
        // a web search cites are one key: otherwise the chat's web sources
        // footer offers Add to Sources for a Nature paper already in the
        // library because the stored URL kept that query string.
        if let host = components.host,
           host == "nature.com" || host.hasSuffix(".nature.com"),
           let articleID = springerNatureArticleID(fromPath: components.path) {
            components.host = "nature.com"
            components.path = "/articles/\(articleID)"
            components.queryItems = nil
        }

        // Strip fragment
        components.fragment = nil

        // Strip tracking query parameters
        if let queryItems = components.queryItems {
            let cleaned = queryItems.filter { !trackingParams.contains($0.name.lowercased()) }
            components.queryItems = cleaned.isEmpty ? nil : cleaned
        }

        // For YouTube watch URLs, keep only the v= parameter
        if let host = components.host,
           (host == "youtube.com" || host == "m.youtube.com"),
           components.path == "/watch",
           let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return "youtube.com/watch?v=\(videoId)"
        }

        guard let result = components.string else { return trimmed }
        // URLComponents renders scheme-less URLs with a leading "//"; strip it
        return result.hasPrefix("//") ? String(result.dropFirst(2)) : result
    }

    /// v1 on a client that holds no local files (the iPhone, the web, the hosted MCP): nil for a
    /// local path, which only the Mac can normalize.
    static func normalizeRemote(_ urlString: String) -> String? {
        if urlString.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { return nil }
        return normalize(urlString, localPath: { $0 })
    }

    /// Compiled once: `normalize` runs over every source in the library when a
    /// chat checks whether a web citation is already saved, and a podcast-heavy
    /// library was compiling this pattern per episode per check.
    private static let applePodcastEpisodePattern = try! NSRegularExpression(
        pattern: #"(?i)^apple-podcast:/+episode/([A-Za-z0-9._/-]+)$"#
    )

    private static func canonicalApplePodcastEpisodeURL(_ urlString: String) -> String? {
        guard urlString.lowercased().hasPrefix("apple-podcast:") else { return nil }
        let regex = applePodcastEpisodePattern
        guard let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              match.numberOfRanges == 2,
              let idRange = Range(match.range(at: 1), in: urlString)
        else {
            return urlString
        }
        return "apple-podcast://episode/\(urlString[idRange])"
    }

    private static func extractYouTubeVideoId(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        let host = components.host?.lowercased() ?? ""

        // youtu.be/VIDEO_ID
        if host == "youtu.be" || host == "www.youtu.be" {
            let path = components.path
            let videoId = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return videoId.isEmpty ? nil : videoId
        }

        // m.youtube.com/watch?v=VIDEO_ID -> canonical youtube.com
        if host == "m.youtube.com",
           components.path == "/watch",
           let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return videoId
        }

        // youtube.com/shorts/ID, /embed/ID, /v/ID, /live/ID — the same video
        // the watch page shows. Kept apart, a Short saved from Brave and the
        // same video shared as a watch link would be two sources, two
        // transcripts and two AI runs; the classifier
        // (Models.swift) and the transcript service already read them as one.
        if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" {
            let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, ["shorts", "embed", "v", "live"].contains(parts[0]) {
                let candidate = parts[1]
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
                if candidate.count == 11, candidate.unicodeScalars.allSatisfy(allowed.contains) {
                    return candidate
                }
            }
        }

        return nil
    }

    /// The article id in a Springer Nature path — `/articles/s42003-022-04303-x`
    /// or `/articles/s42003-022-04303-x.pdf` — with nothing else. Nil for every
    /// other nature.com page (a journal home, a search, a news item), which keep
    /// their own address.
    private static func springerNatureArticleID(fromPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, parts[0] == "articles" else { return nil }
        var id = parts[1]
        if id.lowercased().hasSuffix(".pdf") { id = String(id.dropLast(4)) }
        return id.isEmpty ? nil : id
    }

    private static func cellPressPII(from components: URLComponents) -> String? {
        if let queryPII = components.queryItems?.first(where: { $0.name.lowercased() == "pii" })?.value,
           !queryPII.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return queryPII.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        for marker in ["fulltext", "abstract", "pdf"] {
            guard let markerIndex = pathParts.firstIndex(where: { $0.lowercased() == marker }),
                  pathParts.indices.contains(markerIndex + 1) else { continue }
            let rawPII = pathParts[markerIndex + 1]
            let pii = (rawPII.removingPercentEncoding ?? rawPII)
                .replacingOccurrences(of: ".pdf", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pii.isEmpty {
                return pii
            }
        }

        return nil
    }
}
