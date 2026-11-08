import Foundation

/// What a reference entry prints that names its paper, read by rule.
///
/// Identity is never a model's to decide. A DOI, an arXiv id, a PubMed id or a web address is
/// either printed in the entry or it is not, and the same text always gives the same answer.
enum PaperReferenceIdentity {

    /// The DOI an entry prints, lower-cased: DOIs are case-insensitive, and one form is what
    /// the library and the catalogs compare on. Nil when the entry prints none.
    static func doi(in text: String) -> String? {
        PDFReferenceEntries.doi(inReferenceEntry: text)?.lowercased()
    }

    /// The doi.org address of a DOI.
    static func url(forDOI doi: String) -> String {
        "https://doi.org/\(doi)"
    }

    /// A DOI as stored, bare, from any form an agent or a catalog hands one over in: a doi.org
    /// address, a `doi:` prefix, or the bare `10.…/…`. Nil when it is not a DOI.
    static func normalizedDOI(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.removingPercentEncoding ?? text
        if let range = text.range(of: "doi.org/", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
        }
        if text.lowercased().hasPrefix("doi:") { text = String(text.dropFirst(4)) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;)]"))
        guard text.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil else { return nil }
        return text.lowercased()
    }

    /// An address an entry prints that names its paper, with the DOI when the address is a
    /// DOI's: the DOI first, then an arXiv id, a PubMed id, then any web address.
    static func printedLink(in text: String) -> (url: String, doi: String?, origin: PaperReference.LinkOrigin)? {
        if let doi = doi(in: text) {
            return (url(forDOI: doi), doi, .printedDOI)
        }
        if let id = firstMatch(of: #"arXiv:\s*(\d{4}\.\d{4,5})(?:v\d+)?"#, in: text)
            ?? firstMatch(of: #"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})"#, in: text) {
            return ("https://arxiv.org/abs/\(id)", nil, .printedURL)
        }
        if let id = firstMatch(of: #"(?:PMID|PubMed):?\s*(\d{5,9})"#, in: text) {
            return ("https://pubmed.ncbi.nlm.nih.gov/\(id)/", nil, .printedURL)
        }
        if var address = firstMatch(of: #"(https?://[^\s<>\"]+)"#, in: text) {
            while let last = address.last, ".,;:)]".contains(last) { address.removeLast() }
            guard let parsed = URL(string: address), parsed.host != nil else { return nil }
            return (address, nil, .printedURL)
        }
        return nil
    }

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The years an entry prints: 1900 to 2099, outside any address. A reference prints the
    /// year of its issue, and a title may print another, so every one is a candidate.
    static func years(in text: String) -> [Int] {
        let withoutAddresses = text
            .replacingOccurrences(of: #"10\.\d{4,9}/\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        // A year may follow a journal's full stop with no space ("J.Immunol.1987,138"), as a
        // typesetter that drops spaces prints it; never a digit, or a digit and its point
        // ("1.2019", a section or a version).
        guard let expression = try? NSRegularExpression(pattern: #"(?<!\d)(?<!\d\.)((?:19|20)\d{2})(?![\d])"#) else { return [] }
        let range = NSRange(withoutAddresses.startIndex..., in: withoutAddresses)
        return expression.matches(in: withoutAddresses, range: range).compactMap { match in
            Range(match.range(at: 1), in: withoutAddresses).flatMap { Int(withoutAddresses[$0]) }
        }
    }

    /// The first words of an entry after its number, on letters and digits alone: what two
    /// readings of one entry share when one closed a hyphenated line up and the other did not.
    static func leadKey(of text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = body.range(of: #"^(?:\[\d{1,3}\]|\(\d{1,3}\)|\d{1,3}[.)]?)\s*"#, options: .regularExpression) {
            body.removeSubrange(number)
        }
        let key = body.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(key.prefix(48)))
    }

    /// An entry as a catalog search takes it: its number gone, the length held.
    static func searchText(of entry: String) -> String {
        var body = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = body.range(of: #"^(?:\[\d{1,3}\]|\(\d{1,3}\)|\d{1,3}[.)]?)\s*"#, options: .regularExpression) {
            body.removeSubrange(number)
        }
        return String(body.prefix(400))
    }
}

// MARK: - Which catalog record an entry names

/// Whether a catalog record is the paper a reference entry prints.
///
/// A catalog's best match for a whole entry is only a candidate: a search always returns
/// something. A record is accepted when the entry prints it — its title letter for letter, or
/// its volume and first page beside its first author — the year agrees, and the first author is
/// printed too; and only when exactly one DOI is accepted. Anything looser puts a wrong link
/// on a citation, which reads as a fact.
enum PaperReferenceCatalogMatch {

    /// The one record `entry` names among `records`, or nil.
    static func accepted(
        entry: String,
        among records: [SlideCitationService.ResolvedPaper]
    ) -> SlideCitationService.ResolvedPaper? {
        let matching = records.filter { accepts($0, entry: entry) }
        let byDOI = Dictionary(grouping: matching, by: { $0.doi.lowercased() })
        guard byDOI.count == 1 else { return nil }
        return byDOI.values.first?.first
    }

    static func accepts(_ record: SlideCitationService.ResolvedPaper, entry: String) -> Bool {
        guard yearAgrees(record, entry: entry), firstAuthorPrinted(record, entry: entry) else { return false }
        if SlideCitationService.referenceEntry(entry, printsTitle: record.title) { return true }
        // The title is not printed in full (a subtitle a list leaves out, a word a line break
        // broke): the record's volume and first page, printed beside its author and year, name
        // the paper as surely.
        guard let volume = record.volume, let page = record.firstPage,
              record.authors != nil, !PaperReferenceIdentity.years(in: entry).isEmpty else { return false }
        return printsToken(volume, in: entry) && printsToken(page, in: entry)
    }

    /// The year agrees when the entry prints one within a year of the record's (an issue year
    /// against an online-first one) or prints none to compare. A record with no year never
    /// agrees: nothing then vouches for it.
    private static func yearAgrees(_ record: SlideCitationService.ResolvedPaper, entry: String) -> Bool {
        guard let recordYear = record.year.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return false }
        let printed = PaperReferenceIdentity.years(in: entry)
        guard !printed.isEmpty else { return true }
        return printed.contains { abs($0 - recordYear) <= 1 }
    }

    /// The first author's surname is printed somewhere in the entry. A record that names no
    /// authors (a consortium) is not held to it.
    private static func firstAuthorPrinted(_ record: SlideCitationService.ResolvedPaper, entry: String) -> Bool {
        guard let surname = SlideCitationService.firstAuthorSurname(record.authors) else {
            return record.authors == nil
        }
        let key = foldedLetters(surname)
        guard key.count >= 2 else { return false }
        return foldedLetters(entry).contains(key)
    }

    private static func foldedLetters(_ value: String) -> String {
        String(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter(\.isLetter))
    }

    /// Whether `token` stands in `text` as a whole token: "5" in "2018; 5: 333-45", not in "2015".
    private static func printsToken(_ token: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token.lowercased())
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Citation markers

/// A citation as the text of a paper prints it, read into the entries it names.
enum PaperCitationMarker {

    /// The numbers a numbered marker names, in order, with ranges expanded: "5", "5–7" (5, 6, 7),
    /// "5,7", "[12]", "(3)", and the superscript digits a PDF carries ("⁵⁻⁷"). A range names every
    /// entry in it although the PDF links only the first of them. Empty for a marker with any
    /// letter in it, which is an author-year citation, and for a range that runs backwards or
    /// past 60 entries, which is a figure panel or a year span.
    static func numbers(in marker: String) -> [Int] {
        let folded = foldedDigits(marker)
        guard !folded.contains(where: \.isLetter) else { return [] }
        let tokens = folded
            .split(whereSeparator: { ",;\u{2009}\u{00A0} \t\n".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]()")) }
            .filter { !$0.isEmpty }
        var numbers: [Int] = []
        for token in tokens {
            let parts = token.split(separator: "-", omittingEmptySubsequences: true).compactMap { Int($0) }
            let hasDash = token.contains("-")
            if hasDash {
                guard parts.count == 2, parts[0] <= parts[1], parts[1] - parts[0] <= 60 else { return [] }
                numbers += Array(parts[0]...parts[1])
            } else if let number = Int(token) {
                numbers.append(number)
            } else {
                return []
            }
        }
        return numbers
    }

    /// Superscript digits, the dash forms and the comma forms a PDF's text carries, as plain.
    private static func foldedDigits(_ marker: String) -> String {
        var folded = ""
        for scalar in marker.unicodeScalars {
            switch scalar.value {
            case 0x2070: folded += "0"
            case 0x00B9: folded += "1"
            case 0x00B2: folded += "2"
            case 0x00B3: folded += "3"
            case 0x2074...0x2079: folded += String(Int(scalar.value) - 0x2070)
            case 0x2080...0x2089: folded += String(Int(scalar.value) - 0x2080)
            case 0x207B, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212: folded += "-"
            case 0x02D2, 0x201A, 0x060C: folded += ","
            default: folded.unicodeScalars.append(scalar)
            }
        }
        return folded
    }

    /// One author-year citation: the first author's surname and the year, with the letter that
    /// tells two papers of one author and year apart ("2019a").
    struct AuthorYear: Equatable, Sendable {
        let surname: String
        let year: String
        let suffix: String?

        /// Whether the entry label ("Smith 2019", "Smith 2019a") is this citation's paper.
        func matches(label: String) -> Bool {
            guard let space = label.lastIndex(of: " ") else { return false }
            let labelSurname = String(label[..<space])
            let tail = String(label[label.index(after: space)...])
            let labelYear = String(tail.prefix(4))
            let labelSuffix = tail.count > 4 ? String(tail.dropFirst(4)) : nil
            guard labelYear == year, SlideCitationService.surnamesMatch(labelSurname, surname) else { return false }
            guard let suffix else { return true }
            return labelSuffix == suffix
        }
    }

    private static let authorYearExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\p{Lu}[\p{L}'\x{2019}\-]+)(?:\s+(?:et\s+al\.?|and\s+\p{Lu}[\p{L}'\x{2019}\-]+|&\s*\p{Lu}[\p{L}'\x{2019}\-]+))?,?\s*\(?((?:19|20)\d{2})([a-z])?\)?"#
    )

    private static let followingYearExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*[,;]\s*((?:19|20)\d{2})([a-z])?"#
    )

    /// The author-year citations in a marker: "Smith et al., 2019", "Smith and Jones (2019)",
    /// "(Smith 2019; Lee 2020a)", and "Smith 2018, 2019" for two papers of one author.
    static func authorYear(in marker: String) -> [AuthorYear] {
        guard let expression = authorYearExpression, let following = followingYearExpression else { return [] }
        var citations: [AuthorYear] = []
        let range = NSRange(marker.startIndex..., in: marker)
        for match in expression.matches(in: marker, range: range) {
            guard let surnameRange = Range(match.range(at: 1), in: marker),
                  let yearRange = Range(match.range(at: 2), in: marker) else { continue }
            let surname = String(marker[surnameRange])
            let suffixRange = Range(match.range(at: 3), in: marker)
            citations.append(AuthorYear(
                surname: surname,
                year: String(marker[yearRange]),
                suffix: suffixRange.map { String(marker[$0]) }
            ))
            // "Smith 2018, 2019": the later years share the surname.
            guard let whole = Range(match.range, in: marker) else { continue }
            var rest = String(marker[whole.upperBound...])
            while let more = following.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let moreYear = Range(more.range(at: 1), in: rest),
                  let consumed = Range(more.range, in: rest) {
                let moreSuffix = Range(more.range(at: 2), in: rest)
                citations.append(AuthorYear(
                    surname: surname,
                    year: String(rest[moreYear]),
                    suffix: moreSuffix.map { String(rest[$0]) }
                ))
                rest = String(rest[consumed.upperBound...])
            }
        }
        return citations
    }
}
