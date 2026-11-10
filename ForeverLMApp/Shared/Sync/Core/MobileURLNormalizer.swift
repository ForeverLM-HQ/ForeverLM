import Foundation

/// The web-URL subset of the Mac's URLNormalizer that the iPhone has minted source ids with
/// (`MobileCloudMutationService.sourceID(forNormalizedURL:)`). Local filesystem paths are not
/// accepted by mobile capture, so this can stay independent of StorageService.
///
/// Frozen with the ids it minted: the Mac reads it too, to record a source's historical iPhone form as
/// an extra `url:` work key (docs/cloudkit-schema-design.md §4.1), so a source the phone minted under
/// its own form is still found before a second one is minted. Generation 2 replaces its uses on the
/// iPhone with the core `URLNormalizer`; this copy stays the record of what the phone did.
enum MobileURLNormalizer {
    private static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
        "ref", "source", "fbclid", "gclid",
    ]

    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.host != nil else {
            return trimmed
        }
        if let videoID = youtubeVideoID(components) {
            return "youtube.com/watch?v=\(videoID)"
        }
        components.scheme = nil
        if let host = components.host?.lowercased() {
            components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if components.path.hasSuffix("/") && components.path.count > 1 {
            components.path.removeLast()
        }

        if let host = components.host,
           host == "arxiv.org" || host == "export.arxiv.org" {
            components.host = "arxiv.org"
            for prefix in ["/pdf/", "/html/", "/abs/"] where components.path.hasPrefix(prefix) {
                let id = String(components.path.dropFirst(prefix.count))
                    .replacingOccurrences(of: ".pdf", with: "")
                components.path = "/abs/\(id)"
                break
            }
            if let version = components.path.range(of: "v\\d+$", options: .regularExpression) {
                components.path.removeSubrange(version)
            }
            components.queryItems = nil
        }

        if let host = components.host,
           host.hasSuffix("biorxiv.org") || host.hasSuffix("medrxiv.org"),
           let version = components.path.range(of: "\\.\\d+v\\d+$", options: .regularExpression) {
            components.path.removeSubrange(version)
        }

        if let host = components.host, host.hasSuffix("sciencedirect.com") {
            let parts = components.path.split(separator: "/").map(String.init)
            if let marker = parts.firstIndex(where: { $0.lowercased() == "pii" }),
               parts.indices.contains(marker + 1) {
                let raw = parts[marker + 1]
                let pii = (raw.removingPercentEncoding ?? raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pii.isEmpty {
                    components.path = "/science/article/pii/\(pii)"
                    components.queryItems = nil
                }
            }
        }

        if let host = components.host, host.hasSuffix("cell.com"),
           let pii = cellPressPII(components) {
            components.path = "/pii/\(pii)"
            components.queryItems = nil
        }
        components.fragment = nil
        if let queryItems = components.queryItems {
            let filtered = queryItems.filter { !trackingParameters.contains($0.name.lowercased()) }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        guard let result = components.string else { return trimmed }
        return result.hasPrefix("//") ? String(result.dropFirst(2)) : result
    }

    private static func youtubeVideoID(_ components: URLComponents) -> String? {
        let host = components.host?.lowercased() ?? ""
        if host == "youtu.be" || host == "www.youtu.be" {
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com",
           components.path == "/watch" {
            return components.queryItems?.first(where: { $0.name == "v" })?.value
        }
        return nil
    }

    private static func cellPressPII(_ components: URLComponents) -> String? {
        if let value = components.queryItems?.first(where: { $0.name.lowercased() == "pii" })?.value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        for marker in ["fulltext", "abstract", "pdf"] {
            guard let index = parts.firstIndex(where: { $0.lowercased() == marker }),
                  parts.indices.contains(index + 1) else { continue }
            let raw = parts[index + 1]
            let pii = (raw.removingPercentEncoding ?? raw)
                .replacingOccurrences(of: ".pdf", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pii.isEmpty { return pii }
        }
        return nil
    }
}
