import Foundation

/// One entry of a paper's reference list, with the address of the paper it names.
///
/// Read from the paper's own PDF at ingest (`PaperReferenceParser`) and kept in the local
/// `paper_references` table (schema 174), so a citation in the text resolves to its entry and
/// the entry to a link whether or not the PDF carries link annotations from its superscripts
/// to the list. Nothing here is decided by a model: the identity of an entry (its DOI, its
/// address) is printed in it, or comes from a catalog record that agrees with what it prints
/// (`PaperReferenceCatalogMatch`), or was authored and saved by the learner's own assistant
/// (`save_paper_references`).
struct PaperReference: Identifiable, Equatable, Sendable {
    /// How the entry came by its link, which says how far to trust it.
    enum LinkOrigin: String, Sendable, CaseIterable {
        /// A DOI the entry prints itself.
        case printedDOI = "printed_doi"
        /// An arXiv id, a PubMed id or a web address the entry prints itself.
        case printedURL = "printed_url"
        /// A Crossref or OpenAlex record whose title, year and authors the entry prints.
        case catalog
        /// Written by an assistant through `save_paper_references`.
        case agent
        /// No link: nothing the entry prints or a catalog vouches for names a paper.
        case none
    }

    var id: String { "\(sourceID)#\(ordinal)" }
    let sourceID: String
    /// The entry's place in the list, from 1. A citation number is the ordinal; an
    /// author-year list is numbered in the order it prints.
    let ordinal: Int
    /// What a citation calls the entry: "12" for a numbered list, "Smith 2019" for an
    /// author-year one.
    var label: String
    /// The entry as the paper prints it, hyphenation closed up.
    var text: String
    var title: String?
    var authors: String?
    var journal: String?
    var year: String?
    var doi: String?
    /// The resolved link: the DOI's resolver address, else a landing or PDF address.
    var url: String?
    var origin: LinkOrigin
    /// When a catalog last answered about this entry. Nil means no answer yet (never asked, or
    /// every request failed), so the entry is asked again; an answer of "no match" is dated too,
    /// so it is not asked again until the parser changes.
    var catalogCheckedAt: Date?
    var updatedAt: Date

    init(
        sourceID: String,
        ordinal: Int,
        label: String,
        text: String,
        title: String? = nil,
        authors: String? = nil,
        journal: String? = nil,
        year: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        origin: LinkOrigin = .none,
        catalogCheckedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.label = label
        self.text = text
        self.title = title
        self.authors = authors
        self.journal = journal
        self.year = year
        self.doi = doi
        self.url = url
        self.origin = origin
        self.catalogCheckedAt = catalogCheckedAt
        self.updatedAt = updatedAt
    }

    /// The address a click on the entry opens.
    var linkURL: URL? {
        guard let url, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
            return nil
        }
        return parsed
    }

    var isLinked: Bool { linkURL != nil }
}

/// A paper's stored reference list, read once and queried synchronously: the seam the
/// citation popover reads a link through. Built by `StudioViewModel.paperReferenceIndex(forSource:)`.
struct PaperReferenceIndex: Sendable {
    let sourceID: String
    /// Ascending by ordinal.
    let references: [PaperReference]

    static func empty(sourceID: String) -> PaperReferenceIndex {
        PaperReferenceIndex(sourceID: sourceID, references: [])
    }

    var isEmpty: Bool { references.isEmpty }

    /// The entry of citation number `number`.
    func reference(forNumber number: Int) -> PaperReference? {
        references.first { $0.ordinal == number }
    }

    /// The link of citation number `number`, nil when the list has no such entry or the entry
    /// names no paper.
    func link(forNumber number: Int) -> URL? {
        reference(forNumber: number)?.linkURL
    }

    /// The entries a citation marker names, in the order it names them: "5", "5–7", "5,7",
    /// "[12]" or superscript digits for a numbered list; "Smith et al., 2019" or
    /// "(Smith 2019; Lee 2020a)" for an author-year one. A number past the end of the list, or a
    /// marker that is neither, names nothing.
    func references(forMarker marker: String) -> [PaperReference] {
        let numbers = PaperCitationMarker.numbers(in: marker)
        if !numbers.isEmpty {
            var seen = Set<Int>()
            return numbers.compactMap { number in
                guard seen.insert(number).inserted else { return nil }
                return reference(forNumber: number)
            }
        }
        var found: [PaperReference] = []
        var seen = Set<Int>()
        for citation in PaperCitationMarker.authorYear(in: marker) {
            for reference in references where citation.matches(label: reference.label) && seen.insert(reference.ordinal).inserted {
                found.append(reference)
            }
        }
        return found
    }

    /// The stored entry a piece of entry text names, for a popover that read the text off the
    /// PDF's own links: the text's DOI when it prints one, otherwise the leading words after its
    /// number. Compared on letters and digits alone, so the two readings of one page (a line
    /// break closed up or not) still agree.
    func reference(matchingEntryText text: String) -> PaperReference? {
        if let doi = PaperReferenceIdentity.doi(in: text) {
            if let byDOI = references.first(where: { $0.doi == doi }) { return byDOI }
        }
        let key = PaperReferenceIdentity.leadKey(of: text)
        guard key.count >= 16 else { return nil }
        return references.first { reference in
            let own = PaperReferenceIdentity.leadKey(of: reference.text)
            return own.count >= 16 && (own.hasPrefix(key) || key.hasPrefix(own))
        }
    }

    /// The link of the entry a piece of entry text names.
    func link(forEntryText text: String) -> URL? {
        reference(matchingEntryText: text)?.linkURL
    }
}

/// One entry of a paper's reference list as the `references` satellite (`Source.derived.references`) carries it:
/// a gzip JSON array in list order. What syncs is the entry's words and the link it resolved to, with how it came
/// by it, so a link an assistant found by hand (`origin` "agent") reaches every Mac. Another Mac merges the entries
/// by their words (`InboundSourceFiles.mergeReferences`), never by `ordinal`.
struct SyncedPaperReference: Codable, Equatable, Sendable {
    var ordinal: Int
    var label: String
    var text: String
    var title: String?
    var authors: String?
    var journal: String?
    var year: String?
    var doi: String?
    var url: String?
    /// `PaperReference.LinkOrigin`'s raw value.
    var origin: String
    var catalogCheckedAt: Date?
}

/// A reference entry in a few words, as a citation card shows it: its first author (with
/// "et al." when there are more), its year and its title, rather than every author the list
/// prints (product owner, 2026-11-08: "no need to show SO many authors; can just do first author
/// and then a title and link"). Read from the stored entry's catalog record when it has one,
/// otherwise from the words the entry prints. Pure.
struct PaperReferenceSummary: Equatable, Sendable {
    /// "Hsu et al., 2013", "Vyas et al., 2016", "Brenner, 1999".
    let byline: String?
    let title: String?

    init(byline: String?, title: String?) {
        self.byline = byline
        self.title = title
    }

    init(entryText text: String, stored: PaperReference?) {
        let authors = stored?.authors.map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            .flatMap { $0.isEmpty ? nil : $0 }
        let surname = authors?.first.flatMap { $0.split(separator: " ").last.map(String.init) }
            ?? Self.firstSurname(in: text)
        let several = authors.map { $0.count > 1 } ?? Self.printsSeveralAuthors(text)
        let year = Self.nonBlank(stored?.year) ?? PaperReferenceIdentity.years(in: text).first.map(String.init)
        var byline = surname.map { several ? "\($0) et al." : $0 }
        if let year { byline = byline.map { "\($0), \(year)" } ?? year }
        self.byline = byline
        self.title = Self.nonBlank(stored?.title) ?? Self.printedTitle(in: text)
    }

    static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The first author's surname: before the first comma ("Hsu, P.", "Vyas S, …",
    /// "J. Abramson, …", "Justas Dauparas, …"), less a leading entry number.
    static func firstSurname(in text: String) -> String? {
        guard let head = firstAuthorHead(in: text).map(PaperReferenceSummary.firstName(in:)),
              head.count <= 60, let surname = SlideCitationService.surname(inAuthorEntry: head),
              surname.first?.isLetter == true else { return nil }
        return surname
    }

    /// The words that open an entry up to where its first author's name ends, less a leading
    /// entry number: up to the first comma, or, for a lone author printed with no comma, up to
    /// the initials, when they come first ("Wenz T. PGC-1α activation …"; "Schmidt-Nielsen K.
    /// 1970. Energy metabolism, body size, …", whose first comma falls inside the title). Nil
    /// when the entry prints neither.
    static func firstAuthorHead(in text: String) -> String? {
        let head = text.replacingOccurrences(of: #"^\s*[\[(]?\d{1,4}[.\])]?\s*"#, with: "", options: .regularExpression)
        let comma = head.firstIndex(of: ",")
        if let stop = head.range(of: #"\p{L}{2,}\s\p{Lu}{1,3}\.\s"#, options: .regularExpression),
           comma.map({ stop.upperBound <= $0 }) ?? true {
            return String(head[..<head.index(before: stop.upperBound)])
        }
        return comma.map { String(head[..<$0]) }
    }

    /// The first of names a list joins with "and" or "&" before any comma ("C. D. Allis and
    /// T. Jenuwein").
    static func firstName(in head: String) -> String {
        guard let joint = head.range(of: #"\s+(?:and|&)\s+"#, options: .regularExpression) else { return head }
        return String(head[..<joint.lowerBound])
    }

    /// Whether the author list names more than one: a second name before the title.
    private static func printsSeveralAuthors(_ text: String) -> Bool {
        guard let authorsEnd = authorListEnd(in: text) else { return text.contains(" et al") }
        let authors = text[..<authorsEnd]
        return authors.contains(" et al") || authors.contains(" and ") || authors.contains(" & ")
            || authors.filter({ $0 == "," }).count >= 2
    }

    /// Where the author list ends and what follows it begins, tried in turn:
    /// - authors set initials first (Science, ML papers): the first comma-separated part that is
    ///   not a name ("M. Lazarou et al., The ubiquitin …", "… J. A. Kolberg, Single-copy …");
    /// - a year in brackets straight after the authors ("… Qu, C.K. (2013). ", "… et al (2003) ");
    /// - the last author, after "&" or "and", with initials ("… & Li, H. The atomic …");
    /// - "et al." ("Chen, P.-M. et al. CD38 …");
    /// - a surname and initials followed by a word that is no surname ("Wyss-Coray, T. Ageing …");
    /// - the first full stop after a surname ("… Jenuwein. ") or after the initials that follow
    ///   one ("… Haigis MC. ", "… Wenz T. "), or after a year standing alone ("… Schwarz. 2013. ").
    static func authorListEnd(in text: String) -> String.Index? {
        authorListEnds(in: text).first
    }

    /// Every place the rules above say the author list may end, in the order they are tried.
    static func authorListEnds(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        let head = text.replacingOccurrences(of: #"^\s*[\[(]?\d{1,4}[.\])]?\s*"#, with: "", options: .regularExpression)
        let offset = text.count - head.count
        func inText(_ index: String.Index) -> String.Index {
            text.index(text.startIndex, offsetBy: offset + head.distance(from: head.startIndex, to: index))
        }
        if head.range(of: #"^\p{Lu}\.\s?"#, options: .regularExpression) != nil, let end = initialsFirstAuthorsEnd(in: head) {
            ends.append(inText(end))
        }
        let early = head.index(head.startIndex, offsetBy: min(head.count, 600))
        for pattern in [
            // Not a year after the title ("… Mitochondria and cancer. Cell (2016) 166:…"): no
            // sentence stands before it.
            #"^(?:(?!\.\s+\p{Lu}\p{Ll}+\s+\p{Ll})[^()]){3,}?\((?:19|20)\d{2}[a-z]?\)[.:,]?\s+(?=["“\p{L}\d])"#,
            #"^.*?(?:&|\band\b)\s+(?:(?:de|van|von|der|den|la|le|del|di|da|du)\s)*\p{Lu}[\p{L}'’\-]+(?:\s\p{Lu}[\p{L}'’\-]+)?,?\s+\p{Lu}\.(?:\s?-?\p{Lu}\.)*\s+(?=["“\p{Lu}\d])"#,
            #"^.*?\bet al\.?,?\s+(?=["“\p{Lu}\d])"#,
            // "Wyss-Coray, T. Ageing …", "… Lin, J. Recent Advances …": a surname and its initials,
            // then a word that is no surname (it is not followed by a comma).
            #"^.*?\p{Lu}[\p{L}'’\-]+,\s?\p{Lu}\.(?:\s?-?\p{Lu}\.)*\s+(?=["“]?(?:\p{Lu}[\p{Ll}\d\-]+|\d|\p{Lu}{2,})(?:[\s:\-]|$))(?![\p{L}'’\-]+,)"#,
        ] {
            if let match = head.range(of: pattern, options: .regularExpression), match.upperBound <= early {
                ends.append(inText(match.upperBound))
            }
        }
        let ns = head as NSString
        guard let stop = try? NSRegularExpression(pattern: #"(\S+)\.\s+(?=["“\p{Lu}\d(\[])"#) else { return ends }
        for match in stop.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let tokenRange = match.range(at: 1)
            let token = ns.substring(with: tokenRange)
            let before = tokenRange.location > 0 ? ns.substring(with: NSRange(location: tokenRange.location - 1, length: 1)) : ""
            let isYear = token.range(of: #"^\(?(?:19|20)\d{2}[a-z]?\)?$"#, options: .regularExpression) != nil
            let letters = token.filter(\.isLetter)
            let isWord = letters.count >= 2 && token.contains(where: \.isLowercase) && !token.contains(".")
            let isInitialsAfterSurname = before == " " && !letters.isEmpty && letters.count <= 3
                && token.allSatisfy({ $0.isUppercase || $0 == "-" })
                && ns.substring(to: tokenRange.location).trimmingCharacters(in: .whitespaces).last?.isLetter == true
            if isYear || isWord || isInitialsAfterSurname, let end = Range(NSRange(location: NSMaxRange(match.range), length: 0), in: head) {
                ends.append(inText(end.lowerBound))
                break
            }
        }
        return ends
    }

    /// Initials-first authors: names are "J. Abramson", "A. N. Player", "Y.-M. Ma", "and S. Weinbach",
    /// each closed by a comma; the first part after a comma that is not one starts the title.
    private static func initialsFirstAuthorsEnd(in head: String) -> String.Index? {
        let name = #"^(?:and\s+)?(?:\p{Lu}\.\s?-?)+\s?(?:(?:de|van|von|der|den|la|le|del|di|da|du)\s)*\p{Lu}[\p{L}'’\-]+(?:\s+et al\.?)?$"#
        var position = head.startIndex
        var sawName = false
        while position < head.endIndex {
            let rest = head[position...]
            let comma = rest.range(of: ", ")
            let partEnd = comma?.lowerBound ?? rest.endIndex
            let part = rest[..<partEnd].trimmingCharacters(in: .whitespaces)
            if part.range(of: name, options: .regularExpression) != nil {
                sawName = true
                guard let comma else { return nil }
                position = comma.upperBound
                continue
            }
            // "…, J. Dunger, et al. Accurate …".
            if sawName, let etAl = part.range(of: #"^et al\.?\s+"#, options: .regularExpression) {
                return head.index(position, offsetBy: part.distance(from: part.startIndex, to: etAl.upperBound))
            }
            // "… C. D. Allis and T. Jenuwein. The molecular …": the last name ends with a full stop.
            if let stop = part.range(of: #"^(?:and\s+)?(?:\p{Lu}\.\s?-?)+\s?\p{Lu}[\p{L}'’\-]+(?:\s+and\s+(?:\p{Lu}\.\s?-?)+\s?\p{Lu}[\p{L}'’\-]+)?\.\s+"#, options: .regularExpression) {
                return head.index(position, offsetBy: part.distance(from: part.startIndex, to: stop.upperBound))
            }
            return sawName ? position : nil
        }
        return nil
    }

    /// The title an entry prints: the sentence after its author list (and after the year,
    /// when the year stands between them), up to its closing full stop.
    static func printedTitle(in text: String) -> String? {
        for start in authorListEnds(in: text) {
            if let title = title(in: text, from: start) { return title }
        }
        return nil
    }

    private static func title(in text: String, from authorsEnd: String.Index) -> String? {
        var start = authorsEnd
        var rest = text[start...]
        // "… Schwarz. 2013. The pathways …": the year stands alone after the authors.
        if let year = rest.range(of: #"^\(?(?:19|20)\d{2}[a-z]?\)?[.,]?\s+"#, options: .regularExpression) {
            start = year.upperBound
            rest = text[start...]
        }
        guard let end = rest.range(of: #"[.?!](?=\s|$)"#, options: .regularExpression) else { return nil }
        let title = rest[..<end.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \"“”"))
        let closing = rest[end.lowerBound] == "." ? "" : String(rest[end.lowerBound])
        guard title.count >= 12, title.count <= 300, title.split(separator: " ").count >= 2 else { return nil }
        return title + closing
    }
}
