import Foundation

/// A textbook cited on a slide, matched to a book the library holds.
///
/// Lectures cite their textbook the way they cite a paper — "Nicholls et al.,
/// Bioenergetics" in a corner, "Bioenergetics 4" under a figure — and the citation
/// pipeline only ever knew papers: Crossref, OpenAlex and a web search, each of which
/// answers with a DOI a book does not have. So the course's own textbook came back
/// "No matching record" beside the papers (product owner, 2026-09-27). This is the pass the
/// catalogs cannot make: the printed name against the books on the shelf.
enum CitedTextbookMatch {
    /// A book as the matcher sees it: the `books` row, plus where a matched row points.
    struct Book: Equatable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let edition: String?
        let author: String?
        /// The chapter an "Already in your library" row opens. Nil for a book whose
        /// chapters are not on this Mac; the row is still marked held.
        let openingChapterID: String?

        init(
            id: String,
            title: String,
            subtitle: String? = nil,
            edition: String? = nil,
            author: String? = nil,
            openingChapterID: String? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.edition = edition
            self.author = author
            self.openingChapterID = openingChapterID
        }
    }

    /// The book `candidate` cites, if the library holds it.
    ///
    /// A course's own textbooks match on the printed name alone: a lecture that says
    /// "Bioenergetics" means the book assigned with it. Any other book in the library needs
    /// the first author to agree as well — one word of a title is not much to hang an
    /// identity on across a whole shelf. A printed author that disagrees refuses the match
    /// either way, since it names a different book. A candidate that resolved to a DOI or a
    /// URL is a paper, never a book.
    static func book(
        for candidate: VideoCitedPaper,
        courseTextbooks: [Book],
        libraryBooks: [Book]
    ) -> Book? {
        guard candidate.kind == .paper,
              blankToNil(candidate.doi) == nil,
              blankToNil(candidate.url) == nil else { return nil }
        let names = printedNameKeys(of: candidate)
        guard !names.isEmpty else { return nil }
        let surname = SlideCitationService.firstAuthorSurname(candidate.authors)

        if let match = courseTextbooks.first(where: { book in
            nameAgrees(names, with: book) && (surname.map { authorAgrees($0, with: book) } ?? true)
        }) {
            return match
        }
        guard let surname else { return nil }
        return libraryBooks.first { book in
            nameAgrees(names, with: book) && authorAgrees(surname, with: book)
        }
    }

    /// The row for a citation that names a book the library holds: held, and pointing at
    /// the book's opening chapter so the reader can open it. Everything read off the slide
    /// stays as it was read, which is also what a rescan pairs the row by.
    static func held(_ candidate: VideoCitedPaper, in book: Book) -> VideoCitedPaper {
        var updated = candidate
        updated.status = .imported
        updated.importedSourceID = book.openingChapterID
        return updated
    }

    // MARK: - Names

    /// What the slide printed that could be the book's name: the venue of an attribution
    /// ("Nicholls et al., Bioenergetics" stores "Bioenergetics" as its journal), and the
    /// title when the slide printed one. The stand-in label of an attribution is not a
    /// printed name.
    static func printedNameKeys(of candidate: VideoCitedPaper) -> [String] {
        var names: [String] = []
        if let journal = blankToNil(candidate.journal) { names.append(journal) }
        if !candidate.isAttributionOnly { names.append(candidate.title) }
        return names.map(nameKey).filter { !$0.isEmpty }
    }

    static func nameAgrees(_ names: [String], with book: Book) -> Bool {
        let key = nameKey(book.title)
        guard !key.isEmpty else { return false }
        return names.contains(key)
    }

    /// A name reduced to what identifies the book: lowercase letters and digits, with the
    /// edition a slide tacks on dropped — "Bioenergetics 4", "Bioenergetics, 4th ed.",
    /// "Bioenergetics Fourth Edition" all key to "bioenergetics", as does a library title
    /// that carries its edition the same way.
    static func nameKey(_ value: String) -> String {
        var tokens = value
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        while tokens.count > 1, let last = tokens.last, isEditionToken(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        "tenth", "eleventh", "twelfth",
    ]

    /// "4", "4th", "ed", "edn", "edition", "fourth" — the tail a citation adds to a title
    /// to say which printing it means.
    static func isEditionToken(_ token: String) -> Bool {
        if ["ed", "edn", "edition"].contains(token) { return true }
        if ordinalWords.contains(token) { return true }
        return token.range(of: #"^\d{1,2}(st|nd|rd|th)?$"#, options: .regularExpression) != nil
    }

    // MARK: - Authors

    /// Whether the slide's first author is one of the book's. A book's author line is
    /// written for a cover — "David G. Nicholls & Stuart J. Ferguson", "Bruce Alberts,
    /// Rebecca Heald, …" — so every name on it is a candidate, not just the first.
    static func authorAgrees(_ surname: String, with book: Book) -> Bool {
        bookAuthorSurnames(book.author).contains { SlideCitationService.surnamesMatch(surname, $0) }
    }

    static func bookAuthorSurnames(_ author: String?) -> [String] {
        guard let author = blankToNil(author) else { return [] }
        return author
            .replacingOccurrences(of: " and ", with: ";", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: "&;,"))
            .compactMap { SlideCitationService.surname(inAuthorEntry: $0) }
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
