import Foundation

/// What a source's author field may hold: a name, or a list of names.
///
/// Every author reaches the library from something that read a page, a PDF,
/// a feed or a catalog record, and every reader can misread in the same few
/// ways. On the production library two articles carried the head of their
/// page as their author — 1,290 and 1,772 characters of `<meta …><link …>`
/// that a meta reader captured across tags — and eleven carried a web address,
/// the Open Graph `article:author` profile link read as a byline. None of those
/// is a name, and fixing one reader does not stop the next from making the
/// same mistake, so the field turns them away wherever a value enters it:
/// `StudioArticle.author`, the store's source and book writers, and the MCP
/// tools, which refuse one out loud.
///
/// The judgement is structural and deliberately narrow — markup, a web
/// address, or one "name" longer than any name — and never about whether the
/// words are a person's name: that is reading, and it belongs to the metadata
/// model, not here.
enum SourceAuthor {
    /// The longest one name in an author list may be. Lists are separated by
    /// `;` or `,`, so a consortium paper's thousands of authors pass; a run of
    /// this many characters with no separator is prose or code.
    static let maximumNameLength = 256

    /// Whether `value` can be a source's author. A blank value is not judged
    /// here: every caller already reads an empty author as no author.
    static func isPlausible(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if containsMarkup(trimmed) { return false }
        if isWebAddress(trimmed) { return false }
        let names = trimmed.split(whereSeparator: { $0 == ";" || $0 == "," })
        return !names.contains { $0.count > maximumNameLength }
    }

    /// `value` when it can be an author; nil when it is some other field read
    /// as one.
    static func storable(_ value: String?) -> String? {
        guard let value else { return nil }
        return isPlausible(value) ? value : nil
    }

    /// A tag (`<link `, `<title>`, `</meta>`, `<br/>`) or an attribute
    /// assignment (`name="viewport"`). A name never holds either; an address
    /// in angle brackets (`Jane Doe <jane@example.com>`) and a `<` as text
    /// (`Alan <> Zara`) are neither.
    static func containsMarkup(_ value: String) -> Bool {
        value.range(of: #"</?[A-Za-z][-A-Za-z0-9:]*(?:\s|/?>)"#, options: .regularExpression) != nil
            || value.range(of: #"[A-Za-z_:][-A-Za-z0-9_:.]*\s*=\s*["']"#, options: .regularExpression) != nil
    }

    /// The whole value is one web address: a profile link, not a byline.
    static func isWebAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.")
    }
}
