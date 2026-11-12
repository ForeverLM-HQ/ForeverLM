// Sidebar search: the query, matcher and the notepad grounding helpers.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit

extension StudioViewModel {

    /// A sidebar search as typed, split into the field it is scoped to and the
    /// words to find.
    ///
    /// `title:reverse electron transport` reads titles and nothing else — not the
    /// journal, not the abstract the indexed pass would otherwise reach — because a
    /// learner who remembers a phrase from a title does not want every paper whose
    /// body happens to use it. A bare query keeps searching everywhere. The prefix
    /// is recognised only at the very start of the query, so a DOI or a URL pasted
    /// into the field still behaves as an ordinary search.
    struct SidebarSearchQuery: Equatable {
        enum Field: String, CaseIterable {
            case title, author, journal, year, doi, site

            /// Every spelling a learner might type before the colon.
            static func named(_ name: String) -> Field? {
                switch name.lowercased() {
                case "title", "titles", "name": return .title
                case "author", "authors", "by": return .author
                case "journal", "journals", "venue", "publisher": return .journal
                case "year", "published": return .year
                case "doi": return .doi
                case "site", "domain", "url", "host": return .site
                default: return nil
                }
            }

            /// The chip the search row shows while the query is scoped.
            var label: String {
                switch self {
                case .title: return "Title"
                case .author: return "Author"
                case .journal: return "Journal"
                case .year: return "Year"
                case .doi: return "DOI"
                case .site: return "Site"
                }
            }
        }

        /// The field the search is confined to, or nil for an ordinary search.
        let field: Field?
        /// The words to find, trimmed, with any field prefix removed.
        let text: String

        init(parsing raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let colon = trimmed.firstIndex(of: ":"),
               let field = Field.named(String(trimmed[..<colon])) {
                self.field = field
                self.text = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                self.field = nil
                self.text = trimmed
            }
        }

        var isScoped: Bool { field != nil }
        var isEmpty: Bool { text.isEmpty }

        /// The metadata a scoped search reads on one source. An unscoped search reads
        /// all of it; `title:` reads the title alone, `site:` the host and address.
        func searchableValues(of article: StudioArticle) -> [String] {
            searchableValues(
                title: article.title,
                domain: article.domain,
                author: article.author,
                journal: article.journal,
                year: article.publishedYear,
                doi: article.doi,
                url: article.url,
                parentGroup: article.parentGroup
            )
        }

        /// The same choice over values copied out of a source, for the Docs source
        /// picker's index, which reads them off the main actor.
        func searchableValues(
            title: String,
            domain: String,
            author: String?,
            journal: String?,
            year: String?,
            doi: String?,
            url: String,
            parentGroup: String?
        ) -> [String] {
            switch field {
            case nil:
                return [title, domain, author, journal, year, doi, url, parentGroup].compactMap { $0 }
            case .title: return [title]
            case .author: return [author].compactMap { $0 }
            case .journal: return [journal].compactMap { $0 }
            case .year: return [year].compactMap { $0 }
            case .doi: return [doi].compactMap { $0 }
            case .site: return [domain, url]
            }
        }
    }

    /// The current window's search field, parsed.
    var sidebarSearchQuery: SidebarSearchQuery {
        SidebarSearchQuery(parsing: searchText)
    }

    /// Whether a group row (a book, a course, a meeting series, a playlist) answers
    /// a search on its own metadata. `metadata` is what an unscoped search reads;
    /// `titles` is what `title:` reads and `authors` what `author:` reads. Other
    /// scopes have no group-level answer and leave the decision to the group's rows,
    /// which the callers test with `sourceMatchesSearch`.
    static func sidebarGroupMatchesSearch(
        _ query: SidebarSearchQuery,
        metadata: [String],
        titles: [String],
        authors: [String] = []
    ) -> Bool {
        let normalizedQuery = normalizedSidebarSearchString(query.text)
        guard !normalizedQuery.isEmpty else { return true }
        let candidates: [String]
        switch query.field {
        case nil: candidates = metadata
        case .title: candidates = titles
        case .author: candidates = authors
        case .journal, .year, .doi, .site: candidates = []
        }
        let normalized = candidates.map(normalizedSidebarSearchString).filter { !$0.isEmpty }
        if normalized.contains(where: { $0.contains(normalizedQuery) }) {
            return true
        }
        // A shelf named "cf-mtDNA and Mitochondrial Health" answers to "cfmtDNA"
        // too, the same way a source does — see `sourceMatchesSearch`.
        let foldedQuery = foldedSidebarSearchString(normalizedQuery)
        guard !foldedQuery.isEmpty else { return false }
        return normalized.contains { foldedSidebarSearchString($0).contains(foldedQuery) }
    }

    /// Whether a source answers a sidebar search: the whole query in one of its
    /// fields, then its fold, then every term, then every folded term, then a
    /// paper's last author (`sourceMatchesSearchAnalysingFields` spells the
    /// steps out).
    ///
    /// A search pass asks this of every source in the tab, and analysing a
    /// source's fields — ICU folding, a regex and the catenated fold of each —
    /// is what made a pass over a large library take a third of a second on
    /// the main thread. So an
    /// unscoped query compares against each source's analysis, made once per
    /// change to its fields (`sidebarSearchAnalysis(of:)`), and the query is
    /// analysed once per pass (`sidebarSearchMatcher(for:)`). The steps and the
    /// strings compared are the same; only plain ASCII on both sides is
    /// compared as bytes, where a byte search finds exactly what
    /// `String.contains` finds. A field-scoped query (`title:`) reads one or two
    /// fields and is rare; it is analysed per source as before.
    func sourceMatchesSearch(_ article: StudioArticle, query: String) -> Bool {
        let matcher = sidebarSearchMatcher(for: query)
        guard matcher.parsed.field == nil else {
            return Self.sourceMatchesSearchAnalysingFields(article, query: query)
        }
        if matcher.normalizedQuery.value.isEmpty { return true }
        return matcher.matches(sidebarSearchAnalysis(of: article))
    }

    /// How well a source answers a sidebar search, or nil when it does not
    /// (`SidebarSearchMatcher.strength`). A field-scoped query has one
    /// strength: the field holds what was typed or it does not.
    func sourceSearchStrength(_ article: StudioArticle, query: String) -> Int? {
        let matcher = sidebarSearchMatcher(for: query)
        guard matcher.parsed.field == nil else {
            return Self.sourceMatchesSearchAnalysingFields(article, query: query)
                ? SidebarSearchMatcher.fullStrength : nil
        }
        if matcher.normalizedQuery.value.isEmpty { return SidebarSearchMatcher.fullStrength }
        return matcher.strength(sidebarSearchAnalysis(of: article))
    }

    /// `sourceMatchesSearch` computed from scratch: every field normalized and
    /// folded on the spot. The scoped path, and what the analysed path must
    /// always agree with.
    nonisolated static func sourceMatchesSearchAnalysingFields(_ article: StudioArticle, query: String) -> Bool {
        let parsed = SidebarSearchQuery(parsing: query)
        let normalizedQuery = Self.normalizedSidebarSearchString(parsed.text)
        guard !normalizedQuery.isEmpty else { return true }

        let searchableFields = parsed.searchableValues(of: article)
            .map(Self.normalizedSidebarSearchString)
            .filter { !$0.isEmpty }

        if searchableFields.contains(where: { $0.contains(normalizedQuery) }) {
            return true
        }

        // "GDF15" and "GDF-15" are one term written two ways, and a learner types
        // whichever spelling they last read. Folding both sides the same way makes the
        // two directions symmetric — literal containment finds the hyphenated title
        // from a hyphenated query and never the reverse, because splitting "GDF-15"
        // leaves two fragments a bare title still contains while "GDF15" stays one.
        // Per field rather than over the joined text, so a match cannot straddle a
        // title's end and an author's start.
        let foldedQuery = Self.foldedSidebarSearchString(normalizedQuery)
        if !foldedQuery.isEmpty,
           searchableFields.contains(where: {
               Self.foldedSidebarSearchString($0).contains(foldedQuery)
           }) {
            return true
        }

        let queryTerms = Self.sidebarSearchTerms(in: normalizedQuery)
        guard !queryTerms.isEmpty else { return false }

        let searchableText = searchableFields.joined(separator: " ")
        if queryTerms.allSatisfy({ searchableText.contains($0) }) {
            return true
        }

        // Terms are already punctuation-free, so the same fold lets one term of a
        // longer query ("gdf15 biomarker") reach a hyphenated field.
        let foldedText = Self.foldedSidebarSearchString(searchableText)
        if queryTerms.allSatisfy({ foldedText.contains($0) }) {
            return true
        }

        // "torrens mas" finds the paper by its last author term. Only where the
        // author is in scope: a `title:` search must not reach the byline.
        if article.sourceType == .paper, queryTerms.count > 1,
           parsed.field == nil || parsed.field == .author,
           let author = article.author.map(Self.normalizedSidebarSearchString) {
            let authorTerms = Set(Self.sidebarSearchTerms(in: author))
            if let lastName = queryTerms.last, authorTerms.contains(lastName) {
                return true
            }
        }

        return false
    }

    /// A string a sidebar search compares, with whether it is plain ASCII.
    ///
    /// Between two plain-ASCII strings — no byte above 0x7F, no carriage
    /// return, so every character is one byte and one grapheme — a byte search
    /// (`memmem`) finds exactly what `String.contains` finds, at the speed of a
    /// scan rather than Foundation's grapheme-aware search. Anything else is
    /// compared by `String.contains` itself, so the answer never depends on
    /// which path ran.
    struct SidebarSearchText {
        let value: String
        let isPlainASCII: Bool

        init(_ value: String) {
            var contiguous = value
            contiguous.makeContiguousUTF8()
            self.value = contiguous
            isPlainASCII = contiguous.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
        }

        func contains(_ needle: SidebarSearchText) -> Bool {
            if isPlainASCII, needle.isPlainASCII,
               let found = Self.bytes(of: value, contain: needle.value) {
                return found
            }
            return value.contains(needle.value)
        }

        /// Nil when either side has no contiguous UTF-8 to scan.
        private static func bytes(of haystack: String, contain needle: String) -> Bool? {
            haystack.utf8.withContiguousStorageIfAvailable { hay -> Bool? in
                needle.utf8.withContiguousStorageIfAvailable { pin -> Bool in
                    // `String.contains` finds no empty string.
                    guard !pin.isEmpty, hay.count >= pin.count,
                          let hayStart = hay.baseAddress, let pinStart = pin.baseAddress else { return false }
                    return memmem(hayStart, hay.count, pinStart, pin.count) != nil
                }
            } ?? nil
        }
    }

    /// One source's fields as an unscoped sidebar search reads them, analysed
    /// once: the very strings `sourceMatchesSearchAnalysingFields` builds on
    /// every call, kept until one of the fields changes.
    struct SidebarSearchAnalysis {
        /// The fields the analysis was made from.
        let fields: ArtifactSourcePickerIndex.SourceFields
        /// Every field an unscoped search reads, normalized, empties dropped.
        let normalizedFields: [SidebarSearchText]
        /// Each of `normalizedFields` folded (`foldedSidebarSearchString`).
        let foldedFields: [SidebarSearchText]
        /// `normalizedFields` joined by spaces, and that folded.
        let text: SidebarSearchText
        let foldedText: SidebarSearchText
        /// A paper's author terms; nil for any other source and for a paper
        /// without an author.
        let authorTerms: Set<String>?
        /// Every word of `text`, which is what a surname-only match is ranked
        /// by (`SidebarSearchMatcher.strength`).
        let words: Set<String>

        init(_ fields: ArtifactSourcePickerIndex.SourceFields) {
            self.fields = fields
            let normalized = fields.values(in: SidebarSearchQuery(parsing: ""))
                .map(StudioViewModel.normalizedSidebarSearchString)
                .filter { !$0.isEmpty }
            normalizedFields = normalized.map(SidebarSearchText.init)
            foldedFields = normalized.map { SidebarSearchText(StudioViewModel.foldedSidebarSearchString($0)) }
            let joined = normalized.joined(separator: " ")
            text = SidebarSearchText(joined)
            words = Set(StudioViewModel.sidebarSearchTerms(in: joined))
            foldedText = SidebarSearchText(StudioViewModel.foldedSidebarSearchString(joined))
            if fields.sourceType == .paper, let author = fields.author {
                authorTerms = Set(StudioViewModel.sidebarSearchTerms(
                    in: StudioViewModel.normalizedSidebarSearchString(author)
                ))
            } else {
                authorTerms = nil
            }
        }
    }

    /// A sidebar query analysed once for a whole pass.
    struct SidebarSearchMatcher {
        /// The query as the caller passed it, which is what the memo matches on.
        let query: String
        /// The locale the normalization folded under (`normalizedSidebarSearchString`).
        let localeIdentifier: String
        let parsed: SidebarSearchQuery
        let normalizedQuery: SidebarSearchText
        let foldedQuery: SidebarSearchText
        let terms: [SidebarSearchText]

        init(_ query: String, localeIdentifier: String) {
            self.query = query
            self.localeIdentifier = localeIdentifier
            parsed = SidebarSearchQuery(parsing: query)
            let normalized = StudioViewModel.normalizedSidebarSearchString(parsed.text)
            normalizedQuery = SidebarSearchText(normalized)
            foldedQuery = SidebarSearchText(StudioViewModel.foldedSidebarSearchString(normalized))
            terms = StudioViewModel.sidebarSearchTerms(in: normalized).map(SidebarSearchText.init)
        }

        /// `sourceMatchesSearchAnalysingFields` for an unscoped query, step for
        /// step, over a source's analysis. The caller has answered an empty
        /// query already.
        func matches(_ source: SidebarSearchAnalysis) -> Bool {
            strength(source) != nil
        }

        /// A source that holds the whole query or every term of it.
        static let fullStrength = Int.max

        /// How well a source answers, or nil when it does not: `fullStrength`
        /// when its fields hold the whole query or every term, and otherwise,
        /// for a paper found by an author's surname alone, the number of typed
        /// terms that are words of its fields.
        ///
        /// The surname step lets "torrens mas" find a paper, and it also lets
        /// "RET mirela lu" find every paper with an author named Lu. Only a
        /// few of those are by Mirela Lu, and they hold two of the typed
        /// words where the rest hold one, so the list leads with them
        /// (`computeFilteredActiveItems`) (product owner, 2026-11-12: "why
        /// are those not showing up early?").
        func strength(_ source: SidebarSearchAnalysis) -> Int? {
            if source.normalizedFields.contains(where: { $0.contains(normalizedQuery) }) {
                return Self.fullStrength
            }
            if !foldedQuery.value.isEmpty,
               source.foldedFields.contains(where: { $0.contains(foldedQuery) }) {
                return Self.fullStrength
            }
            guard !terms.isEmpty else { return nil }
            if terms.allSatisfy({ source.text.contains($0) }) {
                return Self.fullStrength
            }
            if terms.allSatisfy({ source.foldedText.contains($0) }) {
                return Self.fullStrength
            }
            if let authorTerms = source.authorTerms, terms.count > 1,
               let lastName = terms.last, authorTerms.contains(lastName.value) {
                return Set(terms.map(\.value)).intersection(source.words).count
            }
            return nil
        }
    }

    /// The analysed query for `query`, kept while the same query is asked of
    /// source after source. A new query under a new locale drops every source
    /// analysis, since normalization folds under the current locale.
    func sidebarSearchMatcher(for query: String) -> SidebarSearchMatcher {
        if let memo = sidebarSearchMatcherMemo, memo.query == query {
            return memo
        }
        let localeIdentifier = Locale.current.identifier
        if sidebarSearchMatcherMemo?.localeIdentifier != localeIdentifier {
            sidebarSearchAnalyses.removeAll()
        } else if sidebarSearchAnalyses.count > articlesStore.articleIDs.count {
            // Sources removed since they were analysed.
            let held = articlesStore.articleIDs
            sidebarSearchAnalyses = sidebarSearchAnalyses.filter { held.contains($0.key) }
        }
        let matcher = SidebarSearchMatcher(query, localeIdentifier: localeIdentifier)
        sidebarSearchMatcherMemo = matcher
        return matcher
    }

    /// A source's analysis, made again only when a field it reads changed.
    func sidebarSearchAnalysis(of article: StudioArticle) -> SidebarSearchAnalysis {
        let fields = ArtifactSourcePickerIndex.SourceFields(article)
        if let known = sidebarSearchAnalyses[article.id], known.fields == fields {
            return known
        }
        let analysis = SidebarSearchAnalysis(fields)
        sidebarSearchAnalyses[article.id] = analysis
        return analysis
    }

    /// Every source address in a note, in document order.
    ///
    /// Two kinds share the scheme. `foreverlm://grounding/<id>,<id>` is a
    /// grounded passage: sources attached to the prose and invisible in it, which
    /// is why one address carries a list rather than a single id.
    /// `foreverlm://source/<id>` is the retired citation chip — a source the
    /// sentence named, drawn as a titled card. Nothing writes one now; a doc that
    /// still holds one is converted to grounding when the editor opens it, and
    /// until then it counts towards what the note stands on just the same.
    ///
    /// A regex is right here where it would be wrong over prose: these addresses
    /// are written by the editor, not by a person, so identity stays deterministic.
    private static func notepadSourceURLs(in markdown: String) -> [URL] {
        guard let expression = try? NSRegularExpression(
            pattern: #"foreverlm://(?:source|grounding)/[^\)\s\]]+"#
        ) else { return [] }

        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return expression.matches(in: markdown, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: markdown) else { return nil }
            return URL(string: String(markdown[matchRange]))
        }
    }

    /// Whether an address is a grounded passage rather than a titled chip.
    static func isNotepadGroundingURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "grounding"
    }

    /// What a grounded passage carries, in the order it was attached.
    ///
    /// Each entry is either a source id or `book:<book-id>`. A book is one thing a
    /// passage stands on, not thirty chapters, and writing the chapter list into
    /// the address would both bloat the doc and freeze the book as it was the day
    /// it was attached — the same reason a chip carries `?book=` rather than an
    /// expanded list. `expandedGroundingSourceIDs` resolves them against the
    /// library as it is now.
    static func notepadGroundingTokens(from url: URL) -> [String] {
        guard isNotepadGroundingURL(url) else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()
        for part in url.path.dropFirst().split(separator: ",", omittingEmptySubsequences: true) {
            let raw = String(part)
            let token = (raw.removingPercentEncoding ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            ordered.append(token)
        }
        return ordered
    }

    static let notepadGroundingBookPrefix = "book:"

    /// Resolve grounding references into live source ids, dropping anything the
    /// library no longer holds. A book expands through its current chapters, so a
    /// chapter imported after the passage was written joins what it stands on.
    func expandedGroundingSourceIDs(_ tokens: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for token in tokens {
            let resolved: [String]
            if token.hasPrefix(Self.notepadGroundingBookPrefix) {
                let bookID = String(token.dropFirst(Self.notepadGroundingBookPrefix.count))
                resolved = sourceIDsForGroupInOrder(bookID)
            } else {
                resolved = [token]
            }
            for id in resolved where articlesById[id] != nil && seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    /// Resolve Notepad references into live source IDs. A book-level reference
    /// expands through the current book relationship, so later chapter imports
    /// join the context without rewriting the note.
    func sourceIDsReferencedByNotepadMarkdown(_ markdown: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for url in Self.notepadSourceURLs(in: markdown) {
            // A grounded passage names no source in the prose, but the note stands
            // on what is attached to it just as much as on what it cites, so both
            // reach the shelf and the chat context.
            if Self.isNotepadGroundingURL(url) {
                for id in expandedGroundingSourceIDs(Self.notepadGroundingTokens(from: url))
                where seen.insert(id).inserted {
                    ordered.append(id)
                }
                continue
            }
            guard let sourceID = ChatMarkdownView.sourceID(from: url) else { continue }
            let bookID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "book" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedIDs: [String]
            if let bookID, !bookID.isEmpty {
                let chapterIDs = sourceIDsForGroupInOrder(bookID)
                resolvedIDs = chapterIDs.isEmpty ? [sourceID] : chapterIDs
            } else {
                resolvedIDs = [sourceID]
            }
            for id in resolvedIDs where articlesById[id] != nil && seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    nonisolated static func normalizedSidebarSearchString(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// A normalized string with the punctuation inside each word closed up, so a term
    /// written both ways — "GDF15" and "GDF-15" — reduces to one spelling. Whitespace
    /// between words survives, so a query still cannot match across a boundary it never
    /// crossed.
    ///
    /// This is the analysis the full-text index side runs on the same text
    /// (`SourceSearchEngine.catenatedFold`), shared rather than reimplemented: one
    /// definition of "the same term" for the list filters and for retrieval, or a
    /// learner gets one answer when the term is in a title and another when it is only
    /// in a body. Searches consult it only after literal containment misses, so it
    /// widens what a query finds and never narrows it.
    nonisolated static func foldedSidebarSearchString(_ value: String) -> String {
        SourceSearchEngine.catenatedFold(value)
    }

    nonisolated static func sidebarSearchTerms(in value: String) -> [String] {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

}
