import Foundation

/// A figure a paper's running text names — "(Fig. 2a, b)", "Extended Data
/// Fig. 1c–g", "Figs. 3 and 4", "Supplementary Fig. S5" — where it is printed,
/// so the Reader can make the words a link that opens the figure (product owner,
/// 2026-11-08: "whenever e.g. 'Extended Data Fig. 1c-g' is mentioned in
/// parentheses in a paper; i can just click that and it will open that figure").
struct PrintedFigureMention: Equatable, Sendable {
    /// The printed words, in UTF-16 offsets of the text read: what
    /// `PDFPage.selection(for:)` takes.
    let range: NSRange
    /// The figure as the paper's figure index labels it ("Figure 2",
    /// "Extended Data Figure 1", "Supplementary Figure 3", "Figure S2").
    let label: String
    /// The panel letters as printed ("c–g", "a, b"); nil for the whole figure.
    let panels: String?
}

enum PrintedFigureMentions {
    /// Every figure `text` names, in reading order. A mention of several
    /// figures ("Figs. 2 and 3", "Extended Data Figs. 1c–g, 2a") is one
    /// mention a figure: the first carries the "Figs." before it, each later
    /// one its own number and panels.
    static func mentions(in text: String) -> [PrintedFigureMention] {
        guard let head = headRegex, let item = itemRegex, let separator = separatorRegex else { return [] }
        let string = text as NSString
        var found: [PrintedFigureMention] = []
        var searchFrom = 0
        while searchFrom < string.length,
              let match = head.firstMatch(
                in: text,
                range: NSRange(location: searchFrom, length: string.length - searchFrom)
              ) {
            let prefix = match.range(at: 1).location != NSNotFound ? string.substring(with: match.range(at: 1)) : nil
            let word = string.substring(with: match.range(at: 2))
            let plural = word.lowercased().hasPrefix("figs") || word.lowercased().hasPrefix("figures")
            let kind = Kind(prefix: prefix)

            var start = match.range.location
            var cursor = NSMaxRange(match.range)
            var isFirst = true
            while let itemMatch = item.firstMatch(
                in: text,
                options: .anchored,
                range: NSRange(location: cursor, length: string.length - cursor)
            ) {
                let identifier = string.substring(with: itemMatch.range(at: 1))
                let panelRange = itemMatch.range(at: 2)
                let panels = panelRange.location != NSNotFound && panelRange.length > 0
                    ? string.substring(with: panelRange) : nil
                let end = NSMaxRange(itemMatch.range)
                found.append(PrintedFigureMention(
                    range: NSRange(location: isFirst ? start : itemMatch.range.location, length: end - (isFirst ? start : itemMatch.range.location)),
                    label: kind.label(identifier: identifier),
                    panels: panels
                ))
                isFirst = false
                cursor = end
                // A further figure of the same kind: "and 3", "–4", and after
                // "Figs." a comma's "2a". "Fig. 4, 12 of 15 mice" names one.
                guard let joined = separator.firstMatch(
                    in: text,
                    options: .anchored,
                    range: NSRange(location: cursor, length: string.length - cursor)
                ) else { break }
                let joiner = string.substring(with: joined.range(at: 1))
                guard plural || ![",", ";"].contains(joiner) else { break }
                start = NSMaxRange(joined.range)
                cursor = start
            }
            searchFrom = max(cursor, NSMaxRange(match.range))
        }
        return found
    }

    /// The label among `labels` (a paper's figure index) that `label` names:
    /// the same kind of figure and the same number, however each spells it —
    /// "Fig." or "Figure", "Supplementary Figure 3" or "Figure S3". Nil when
    /// the paper indexed no such figure.
    static func matchingLabel(_ label: String, among labels: [String]) -> String? {
        guard let key = key(of: label) else { return nil }
        return labels.first { Self.key(of: $0) == key }
    }

    /// What two spellings of one figure share: its kind and its number.
    static func key(of label: String) -> String? {
        var text = label.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        var kind = Kind.main
        for (prefix, prefixKind) in [
            ("extended data ", Kind.extended), ("ed ", .extended),
            ("supplementary ", .supplementary), ("supplemental ", .supplementary), ("suppl. ", .supplementary),
        ] where text.hasPrefix(prefix) {
            kind = prefixKind
            text = String(text.dropFirst(prefix.count))
            break
        }
        guard let word = text.range(of: #"^(?:figures?|figs?\.?)\s*"#, options: .regularExpression) else { return nil }
        var identifier = String(text[word.upperBound...])
        if identifier.hasPrefix("s") {
            kind = .supplementary
            identifier.removeFirst()
        }
        // The number alone: a caption's "Figure 3B" is Figure 3, and a
        // textbook's "3–4" one figure.
        guard let number = identifier.range(of: #"^\d+(?:[.\-–]\d+)?"#, options: .regularExpression) else { return nil }
        let digits = identifier[number].replacingOccurrences(of: "–", with: "-")
        return "\(kind.rawValue):\(digits)"
    }

    private enum Kind: String {
        case main, extended, supplementary

        init(prefix: String?) {
            let prefix = (prefix ?? "").lowercased()
            if prefix.hasPrefix("ext") || prefix == "ed" {
                self = .extended
            } else if prefix.hasPrefix("suppl") {
                self = .supplementary
            } else {
                self = .main
            }
        }

        /// The label as the figure index spells it (`PaperFigureCaptionTitle.label`).
        func label(identifier: String) -> String {
            switch self {
            case .main: "Figure \(identifier)"
            case .extended: "Extended Data Figure \(identifier)"
            case .supplementary: "Supplementary Figure \(identifier)"
            }
        }
    }

    /// "Fig." and its spellings, with the kind of figure before it. Not inside
    /// a word ("configure 2"), and only before a number.
    private static let headRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:(Extended\s+Data|Supplementary|Supplemental|Suppl\.|(?-i:ED))\s+)?(Figures?|Figs?\.?)\s*(?=(?-i:S)?\d)"#,
        options: [.caseInsensitive]
    )

    /// One figure's number and its panels: "2", "S3", "1c–g", "2a, b",
    /// "3A–C", "4a and c". A panel is a single letter, set against the number
    /// or after a comma or "and", never the first letter of a word ("Fig. 2
    /// and Fig. 3", "Fig. 2, as") nor of the next figure's number (Cell's
    /// "Figures 1C, S1A"). A number that runs on ("Fig. 2017") or
    /// into a textbook's "3.4" is no mention.
    private static let itemRegex = try? NSRegularExpression(
        pattern: #"((?-i:S)?\d{1,3})(?![\d])(?!\.\d)((?-i:[a-z](?:\s*[-–—]\s*[a-z])?(?![A-Za-z0-9])(?:\s*(?:,|and|&)\s*[a-z](?:\s*[-–—]\s*[a-z])?(?![A-Za-z0-9]))*|[A-Z](?:\s*[-–—]\s*[A-Z])?(?![A-Za-z0-9])(?:\s*(?:,|and|&)\s*[A-Z](?:\s*[-–—]\s*[A-Z])?(?![A-Za-z0-9]))*))?"#,
        options: []
    )

    /// What joins two figures of one mention: "and" (", and" too), "&", "or",
    /// a dash, "to", a comma or a semicolon — always followed by the next
    /// figure's number.
    private static let separatorRegex = try? NSRegularExpression(
        pattern: #"\s*(,\s*and|,\s*&|,|;|and|&|or|to|[-–—])\s*(?=(?-i:S)?\d)"#,
        options: []
    )
}
