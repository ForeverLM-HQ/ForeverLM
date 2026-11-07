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
