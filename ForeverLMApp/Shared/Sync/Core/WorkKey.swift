import Foundation

/// Work keys (§4.2): every identity key known for a work, normalized so two routes that import the
/// same paper, video or episode look up the same key before they mint a source. Vectors:
/// `schema/vectors/work-key.json`; the JS port is `schema/js/work-key.js`.
///
/// Normalizing returns nil for a key of a known kind whose value cannot be one (`isbn:12`,
/// `doi:abc`): the importer drops it rather than store a key that matches nothing. A kind this
/// build does not know is kept as it came, its kind lowercased, since a newer client may define it.
enum WorkKey {
    /// A work key as a client with local files computes it: a `url:` key naming a local path goes
    /// through `localPath`, the client's own roots. The Mac's `normalize(_:)` passes
    /// `StorageService.relativeSourcePath`.
    static func normalize(_ key: String, localPath: (String) -> String) -> String? {
        withoutActuallyEscaping(localPath) { normalized(key, localPath: $0) }
    }

    /// A work key as a client without local files computes it (the iPhone, the web, the hosted
    /// MCP): a `url:` key naming a local path is no work key.
    static func normalizeRemote(_ key: String) -> String? {
        normalized(key, localPath: nil)
    }

    /// The target of the member's `Mark(dismissed)` for an address (§3.5.19): `wk:` and the address's
    /// `url:` work key, or the address itself after `url:` when it has none. One form on every client,
    /// so one client's un-dismiss flips the Mark another wrote; it needs no lookup, since a suggestion
    /// is dismissed before it is a source. The JS port is `dismissalTarget` in `schema/js/work-key.js`.
    static func dismissalTarget(url: String) -> String {
        "wk:" + (normalizeRemote("url:" + url) ?? "url:" + url)
    }

    private static func normalized(_ key: String, localPath: ((String) -> String)?) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let kind = trimmed[..<colon].lowercased()
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let normalized: String?
        switch kind {
        case "doi": normalized = doi(value)
        case "arxiv": normalized = arxiv(value)
        case "pmid": normalized = pmid(value)
        case "isbn": normalized = isbn(value)
        case "podcast": normalized = podcast(value)
        case "gh": normalized = gitHub(value)
        case "x": normalized = xPost(value)
        case "file": normalized = fileHash(value)
        case "url":
            if let localPath {
                normalized = URLNormalizer.normalize(value, localPath: localPath)
            } else {
                normalized = URLNormalizer.normalizeRemote(value)
            }
        // Kept as they are, since their case is part of the identity: YouTube video ids (yt:),
        // Zoom meeting ids (zoom:), meeting session keys (meeting:), course lessons (course:),
        // native sources' own ids (native:), and kinds a newer client defines.
        default: normalized = value
        }
        guard let normalized, !normalized.isEmpty else { return nil }
        return kind + ":" + normalized
    }

    /// A DOI as `10.x/y`: resolver prefixes and a repeated `doi:` label dropped, lowercased, without
    /// trailing punctuation or a preprint's version. A version is a trailing `v<digits>` after a
    /// digit, `.` or `/` (bioRxiv and medRxiv `10.1101/2024.11.04.615786v3`, preprints.org
    /// `10.20944/preprints202301.0001.v1`, Research Square `10.21203/rs.3.rs-2581279/v1`), dropped
    /// with the `.` or `/` it leaves behind. A `v` after a letter belongs to the DOI: every 2015
    /// Oxford DOI has one (`10.1093/nar/gkv1344`), and dropping it would make one key of a whole
    /// journal's year.
    private static func doi(_ raw: String) -> String? {
        var value = raw
        let lowered = value.lowercased()
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "dx.doi.org/", "doi:"]
        where lowered.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = value.last, ".,;".contains(last) { value.removeLast() }
        if let version = value.range(of: #"(?<=[0-9./])v[0-9]+$"#, options: .regularExpression) {
            var unversioned = String(value[..<version.lowerBound])
            while let last = unversioned.last, "./".contains(last) { unversioned.removeLast() }
            // A version is never the whole suffix: `10.5555/v12` keeps its `v12`.
            if let slash = unversioned.firstIndex(of: "/"), unversioned.index(after: slash) < unversioned.endIndex {
                value = unversioned
            }
        }
        guard value.hasPrefix("10."), value.contains("/") else { return nil }
        return value
    }

    /// An arXiv id without its version: `2503.09427`, or an old-style `hep-th/9901001`.
    private static func arxiv(_ raw: String) -> String? {
        var value = raw.lowercased()
        for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "https://arxiv.org/pdf/", "http://arxiv.org/pdf/", "arxiv.org/abs/", "arxiv.org/pdf/", "arxiv:"]
        where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        if value.hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        if let version = value.range(of: #"v\d+$"#, options: .regularExpression) { value.removeSubrange(version) }
        let isModern = value.range(of: #"^\d{4}\.\d{4,5}$"#, options: .regularExpression) != nil
        let isOldStyle = value.range(of: #"^[a-z][a-z.-]*/\d{7}$"#, options: .regularExpression) != nil
        return isModern || isOldStyle ? value : nil
    }

    private static func pmid(_ raw: String) -> String? {
        var value = raw
        if value.lowercased().hasPrefix("pmid:") { value = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return value
    }

    /// 13 digits: an ISBN-10 gains the 978 prefix and a new check digit; a bad check digit is no ISBN.
    private static func isbn(_ raw: String) -> String? {
        let bytes = Array(raw.uppercased().utf8).filter { $0 != UInt8(ascii: "-") && $0 != UInt8(ascii: " ") }
        let digit: (UInt8) -> Int? = { (0x30...0x39).contains($0) ? Int($0 - 0x30) : nil }
        if bytes.count == 10 {
            let body = bytes.prefix(9).compactMap(digit)
            guard body.count == 9, let check = bytes[9] == UInt8(ascii: "X") ? 10 : digit(bytes[9]) else { return nil }
            let sum = zip(body + [check], (1...10).reversed()).reduce(0) { $0 + $1.0 * $1.1 }
            guard sum % 11 == 0 else { return nil }
            let thirteen = [9, 7, 8] + body
            return (thirteen + [isbn13CheckDigit(thirteen)]).map(String.init).joined()
        }
        let digits = bytes.compactMap(digit)
        guard bytes.count == 13, digits.count == 13, isbn13CheckDigit(Array(digits.prefix(12))) == digits[12] else { return nil }
        return digits.map(String.init).joined()
    }

    private static func isbn13CheckDigit(_ twelve: [Int]) -> Int {
        let sum = twelve.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return (10 - sum % 10) % 10
    }

    /// `<feed>#<episode GUID>`, split at the first `#`. The feed is the podcast's GUID, lowercased,
    /// or its feed URL through URLNormalizer v1, so `feed://`, `http://` and `https://` forms of one
    /// feed agree; the episode GUID is kept exactly.
    private static func podcast(_ raw: String) -> String? {
        guard let hash = raw.firstIndex(of: "#") else { return nil }
        let feed = raw[..<hash].trimmingCharacters(in: .whitespaces)
        let episode = raw[raw.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        guard !feed.isEmpty, !episode.isEmpty else { return nil }
        let normalizedFeed: String
        if feed.contains("://") || feed.contains(".") {
            guard let url = URLNormalizer.normalizeRemote(feed) else { return nil }
            normalizedFeed = url
        } else {
            normalizedFeed = feed.lowercased()
        }
        return normalizedFeed + "#" + episode
    }

    /// `owner/repo`, lowercased (GitHub's names are case-insensitive), from a bare pair or a
    /// github.com address (with or without its scheme and `www.`); `.git`, a trailing slash and
    /// deeper paths are dropped.
    private static func gitHub(_ raw: String) -> String? {
        var value = raw.lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        if value.hasPrefix("github.com/") { value = String(value.dropFirst("github.com/".count)) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return parts[0] + "/" + repo
    }

    /// A post id: its digits, from a bare id or an `x.com/<handle>/status/<id>` address.
    private static func xPost(_ raw: String) -> String? {
        let isDigits: (String) -> Bool = { !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }
        if isDigits(raw) { return raw }
        guard let status = raw.range(of: "/status/") else { return nil }
        let id = raw[status.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return isDigits(String(id)) ? String(id) : nil
    }

    /// The lowercase hex sha256 of a file's original bytes.
    private static func fileHash(_ raw: String) -> String? {
        let value = raw.lowercased()
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return value
    }
}
