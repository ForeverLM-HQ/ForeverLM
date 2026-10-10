import Foundation

// The rules behind a notebook's Add sources sheet on the phone
// (docs/notebooks-design.md, "iPhone"): the links in what was pasted, and the
// name pages captured on the phone are filed under. Foundation-only, so the
// Mac unit tests compile them.

// MARK: - Links pasted together

/// The links in what was pasted into Add sources' field: at most ten
/// (Recall's limit), each once, in the order pasted. A link is what the Mac's
/// field takes (`StudioViewModel.importableLink`): an http(s) address whose
/// host has a dot, or a DOI, which becomes its doi.org address. Links may be
/// apart by spaces, new lines or commas, or run together where a paste lost
/// its line breaks; anything else in the text is not a link and is passed
/// over.
enum MobileNotebookPastedLinks {
    /// How many links one paste adds.
    static let limit = 10

    struct Reading: Equatable {
        /// The links to add, in the order pasted, at most `limit`.
        let links: [String]
        /// Distinct links past the limit, which are not added.
        let leftOut: Int

        static let none = Reading(links: [], leftOut: 0)
    }

    /// The links in `text`. `sameSource` maps a link to what makes two links
    /// one source (the phone passes its capture's URL normalizer, so a link
    /// pasted twice in two spellings is added once); by default only the
    /// same text is the same link.
    static func read(_ text: String, sameSource: (String) -> String = { $0 }) -> Reading {
        var seen = Set<String>()
        var links: [String] = []
        for token in tokens(in: text) {
            guard let link = link(in: token), seen.insert(sameSource(link)).inserted else { continue }
            links.append(link)
        }
        guard links.count > limit else { return Reading(links: links, leftOut: 0) }
        return Reading(links: Array(links.prefix(limit)), leftOut: links.count - limit)
    }

    /// The Mac's rule for one address (`StudioViewModel.importableLink`):
    /// a DOI, bare or after "doi:", becomes its doi.org address; an http(s)
    /// address whose host has a dot is taken as it stands.
    static func link(in token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if trimmed.lowercased().hasPrefix("doi:") {
            let doi = String(trimmed.dropFirst(4))
            return doi.hasPrefix("10.") && doi.contains("/") ? "https://doi.org/\(doi)" : nil
        }
        if trimmed.hasPrefix("10."), trimmed.contains("/") {
            return "https://doi.org/\(trimmed)"
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.contains(".") else { return nil }
        return trimmed
    }

    /// The candidate addresses in `text`, in order: split at white space,
    /// at a comma that a new address follows, and where a new http(s)
    /// address starts straight after a letter, digit, bracket or quote (a
    /// paste that lost its line breaks, a Markdown link), with the quotes,
    /// brackets and sentence marks around an address taken off. A comma
    /// inside an address (a map's "@lat,long") and an address inside one (a
    /// redirect's "?url=https://…") stay whole.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .flatMap { splitAtCommas(String($0)) }
            .flatMap { splitAtRunTogetherAddresses($0) }
            .map(trimmingWrapping)
            .filter { !$0.isEmpty }
    }

    /// "Add link" for one, as on the Mac; "Add 3 links" for more.
    static func addTitle(count: Int) -> String {
        count == 1 ? "Add link" : "Add \(count) links"
    }

    // MARK: Splitting

    private static func splitAtCommas(_ chunk: String) -> [String] {
        let pieces = chunk.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var tokens: [String] = []
        for piece in pieces {
            if let last = tokens.last, !last.isEmpty, !startsAddress(trimmingWrapping(piece)) {
                tokens[tokens.count - 1] = last + "," + piece
            } else {
                tokens.append(piece)
            }
        }
        return tokens
    }

    private static func splitAtRunTogetherAddresses(_ token: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var index = token.startIndex
        while index < token.endIndex {
            if !current.isEmpty,
               let previous = current.last,
               previous.isLetter || previous.isNumber || Self.markBeforeRunTogetherAddress.contains(previous),
               startsHTTPAddress(token[index...]) {
                tokens.append(current)
                current = ""
            }
            current.append(token[index])
            index = token.index(after: index)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Marks a new address can follow straight on: closing ones (the end of
    /// a line that lost its break) and opening ones (Markdown's "[title](").
    /// What an address holds inside it — "/", "=", "?", "&", "%" — never
    /// starts a new one, so a redirect's address stays in it.
    private static let markBeforeRunTogetherAddress: Set<Character> = [
        ")", "]", "}", ">", "\"", "'", "”", "’", "(", "[", "<",
    ]

    private static func startsHTTPAddress(_ text: Substring) -> Bool {
        let head = text.prefix(8).lowercased()
        return head.hasPrefix("http://") || head.hasPrefix("https://")
    }

    private static func startsAddress(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return startsHTTPAddress(Substring(lowered)) || lowered.hasPrefix("doi:") || lowered.hasPrefix("10.")
    }

    private static let openingMarks: Set<Character> = ["\"", "'", "“", "‘", "<", "(", "[", "{", "«"]
    private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ">", ".", ",", ";", ":", "!", "?", "»"]
    private static let closingBrackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// Quotes and brackets around an address, and the sentence mark after
    /// it, are not part of it. A closing bracket stays when the address
    /// opened it (a Wikipedia title's "(biology)").
    private static func trimmingWrapping(_ token: String) -> String {
        var text = Substring(token)
        while let first = text.first, openingMarks.contains(first) {
            text = text.dropFirst()
        }
        while let last = text.last {
            if closingMarks.contains(last) {
                text = text.dropLast()
            } else if let opening = closingBrackets[last],
                      text.filter({ $0 == opening }).count < text.filter({ $0 == last }).count {
                text = text.dropLast()
            } else {
                break
            }
        }
        return String(text)
    }
}

/// Where one pasted link is in Add sources.
enum MobileNotebookLinkProgress: Equatable {
    case adding
    case added
    case failed(String)
}

// MARK: - Pages captured on the phone

/// Pages scanned with the camera or picked from Photos, filed as one PDF.
/// They are named for what they are and when they were added — nothing is
/// read into the name. The Mac reads the pages' own title when it files the
/// PDF, as it does for every PDF the phone adds.
enum MobileCapturedPages {
    enum Kind: Sendable {
        case scan
        case photos

        var word: String {
            switch self {
            case .scan: return "Scan"
            case .photos: return "Photos"
            }
        }
    }

    /// "Scan · 2 October 2026 at 14:05", in the learner's own date format.
    static func title(
        kind: Kind,
        madeAt date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(
            date: .long,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        return "\(kind.word) · \(date.formatted(style))"
    }

    /// The PDF's file name: its title with the characters a path cannot
    /// hold replaced (a time's ":" as Finder writes it, "."), and every kind
    /// of space a plain one.
    static func fileName(forTitle title: String) -> String {
        let cleaned = String(title.map { character -> Character in
            switch character {
            case ":": return "."
            case "/", "\\": return "-"
            default: return character.isWhitespace ? " " : character
            }
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Pages" : cleaned) + ".pdf"
    }

    /// "1 page", "4 pages".
    static func countLine(_ count: Int) -> String {
        count == 1 ? "1 page" : "\(count) pages"
    }
}
