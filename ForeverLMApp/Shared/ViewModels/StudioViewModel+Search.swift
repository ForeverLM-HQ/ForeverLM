import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

/// One row in the Docs source picker: the strings the row draws, and nothing else.
///
/// Deliberately flat. An element that carried a whole `StudioArticle` meant thousands
/// of 49-field struct copies on the main thread whenever the list took a new set of
/// rows, which beachballed the app on a library this size. The row's source is looked
/// up by id when the row actually renders.
struct ArtifactSourcePickerRow: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let bookID: String?
    let sourceType: String
    let title: String
    let subtitle: String
}

/// The semantic source kinds the Docs picker can narrow to. Persisted source
/// types stay untouched; this only groups legacy/unclassified URLs with the
/// Article row a learner already sees in the picker.
enum ArtifactSourcePickerFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case article
    case paper
    case book
    case course
    case meeting
    case podcast
    case video
    case xPost
    case link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All sources"
        case .article: return "Articles"
        case .paper: return "Papers"
        case .book: return "Books"
        case .course: return "Courses"
        case .meeting: return "Meetings"
        case .podcast: return "Podcasts"
        case .video: return "Videos"
        case .xPost: return "X posts"
        case .link: return "Links"
        }
    }

    var activeTitle: String {
        switch self {
        case .all: return "All"
        case .article: return "Article"
        case .paper: return "Paper"
        case .book: return "Book"
        case .course: return "Course"
        case .meeting: return "Meeting"
        case .podcast: return "Podcast"
        case .video: return "Video"
        case .xPost: return "X post"
        case .link: return "Link"
        }
    }

    func includes(sourceType: String) -> Bool {
        switch self {
        case .all:
            return true
        case .article:
            return sourceType == StudioSourceType.article.rawValue
                || sourceType == StudioSourceType.unclassified.rawValue
        case .link:
            return sourceType == StudioSourceType.manual.rawValue
        default:
            return sourceType == rawValue
        }
    }
}

/// The Docs source picker's library, analysed once so that a keystroke only compares.
///
/// The picker used to rebuild its rows from `articles` on every keystroke, on the
/// main actor, through `sourceMatchesSearch` — which normalizes and folds every
/// field it reads (ICU folding and a regex each) before it compares anything. Over
/// the product owner's 4,500 sources that was half a second a pass, and a keystroke ran two
/// passes: the titles, then again with the content matches. Here each source's
/// fields are analysed once, when the picker opens, and a query is a byte search
/// over the result: a few milliseconds for the whole library, off the main actor.
///
/// The comparison is `sourceMatchesSearch`'s, step for step: the whole query, its
/// fold, every term, every folded term, then a paper's last author. A source's
/// values are joined into one string per form with a unit separator, which no
/// typed query holds, so a match cannot span two fields — the same answer as
/// comparing each field on its own.
struct ArtifactSourcePickerIndex: Sendable {
    /// What one source is searched by, copied out of its `StudioArticle` on the
    /// main actor. Equal fields mean an earlier analysis still holds.
    struct SourceFields: Sendable, Equatable {
        let id: String
        let title: String
        let domain: String
        let author: String?
        let journal: String?
        let year: String?
        let doi: String?
        let url: String
        let parentGroup: String?
        let sourceType: StudioSourceType

        init(_ source: StudioArticle) {
            id = source.id
            title = source.title
            domain = source.domain
            author = source.author
            journal = source.journal
            year = source.publishedYear
            doi = source.doi
            url = source.url
            parentGroup = source.parentGroup
            sourceType = source.sourceType
        }

        func values(in scope: StudioViewModel.SidebarSearchQuery) -> [String] {
            scope.searchableValues(
                title: title,
                domain: domain,
                author: author,
                journal: journal,
                year: year,
                doi: doi,
                url: url,
                parentGroup: parentGroup
            )
        }
    }

    /// The metadata on a book's own record, which its chapters answer to.
    struct BookFields: Sendable, Equatable {
        let id: String
        let metadata: [String]
    }

    /// A row as the main actor hands it over: what it draws, and what it is searched by.
    struct RowFields: Sendable {
        let row: ArtifactSourcePickerRow
        /// A book's chapters in reading order, or the one source.
        let sources: [SourceFields]
        let book: BookFields?
    }

    /// Searchable text in the two forms a query is compared against.
    struct SearchText: Sendable {
        let normalized: String
        let folded: String

        init(_ values: [String]) {
            let normalized = values.map(StudioViewModel.normalizedSidebarSearchString)
            self.normalized = normalized.joined(separator: "\u{1F}")
            folded = normalized.map(StudioViewModel.foldedSidebarSearchString).joined(separator: "\u{1F}")
        }
    }

    struct AnalysedSource: Sendable {
        let fields: SourceFields
        /// Every value an unscoped query reads.
        let text: SearchText
        /// A paper's author terms, so "torrens mas" finds it by the last author.
        let authorTerms: Set<String>
        let normalizedType: String

        init(_ fields: SourceFields) {
            self.fields = fields
            text = SearchText(fields.values(in: StudioViewModel.SidebarSearchQuery(parsing: "")))
            if fields.sourceType == .paper, let author = fields.author {
                authorTerms = Set(StudioViewModel.sidebarSearchTerms(
                    in: StudioViewModel.normalizedSidebarSearchString(author)
                ))
            } else {
                authorTerms = []
            }
            normalizedType = StudioViewModel.normalizedSidebarSearchString(fields.sourceType.rawValue)
        }

        func matches(_ query: Query) -> Bool {
            // `title:` alone confines the search without asking for anything.
            guard !query.normalized.isEmpty else { return true }
            let field = query.scope.field
            // A scoped query (`title:`, `author:`) is rare enough to analyse just
            // its field per keystroke rather than keep every field apart.
            let text = field == nil ? text : SearchText(fields.values(in: query.scope))
            if query.matches(text) { return true }
            if fields.sourceType == .paper, query.terms.count > 1,
               field == nil || field == .author,
               let lastName = query.terms.last {
                return authorTerms.contains(lastName)
            }
            return false
        }
    }

    struct AnalysedBook: Sendable {
        let fields: BookFields
        let text: SearchText
    }

    struct Entry: Sendable {
        let row: ArtifactSourcePickerRow
        let sources: [AnalysedSource]
        let book: AnalysedBook?
        /// The row's title in the folded form a query is ranked by.
        let foldedTitle: String
    }

    /// How closely a row answers a query, closest first. A query lists its rows by
    /// rank and then by title, so the source whose title is what was typed leads
    /// instead of waiting its turn in the alphabet behind every source that only
    /// mentions the words.
    enum Rank: Int, Comparable, Sendable {
        /// The title is the query.
        case title
        /// The title starts with the query, as it does while the title is being typed.
        case titleStart
        /// The query is a run of the title's words: "genome project" in
        /// "Why the Human Genome Project Failed".
        case titlePhrase
        /// Every term of the query is somewhere in the title.
        case titleTerms
        /// The author, address, journal or kind, or a book's chapters.
        case details
        /// Only the source's own text.
        case text

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A query, analysed once per keystroke.
    struct Query: Sendable {
        /// The field a source's search is confined to. A book's metadata has no
        /// fields, so its query is never scoped and a `title:` prefix there is
        /// only more words to find.
        let scope: StudioViewModel.SidebarSearchQuery
        let normalized: String
        let folded: String
        let terms: [String]

        init(source normalizedQuery: String) {
            let scope = StudioViewModel.SidebarSearchQuery(parsing: normalizedQuery)
            self.init(scope: scope, text: scope.text)
        }

        init(bookMetadata normalizedQuery: String) {
            self.init(scope: StudioViewModel.SidebarSearchQuery(parsing: ""), text: normalizedQuery)
        }

        private init(scope: StudioViewModel.SidebarSearchQuery, text: String) {
            self.scope = scope
            normalized = StudioViewModel.normalizedSidebarSearchString(text)
            folded = StudioViewModel.foldedSidebarSearchString(normalized)
            terms = StudioViewModel.sidebarSearchTerms(in: normalized)
        }

        func matches(_ text: SearchText) -> Bool {
            if text.normalized.containsBytes(of: normalized) { return true }
            if !folded.isEmpty, text.folded.containsBytes(of: folded) { return true }
            guard !terms.isEmpty else { return false }
            if terms.allSatisfy({ text.normalized.containsBytes(of: $0) }) { return true }
            return terms.allSatisfy { text.folded.containsBytes(of: $0) }
        }

        /// How close a folded title comes to this query, or nil when the title
        /// holds none of it. A query confined to another field (`author:`) is
        /// never ranked by title: the title is not what it asked about.
        func titleRank(_ foldedTitle: String) -> Rank? {
            guard scope.field == nil || scope.field == .title, !folded.isEmpty else { return nil }
            if foldedTitle == folded { return .title }
            if foldedTitle.hasPrefix(folded) { return .titleStart }
            if (" " + foldedTitle).containsBytes(of: " " + folded) { return .titlePhrase }
            if !terms.isEmpty, terms.allSatisfy({ foldedTitle.containsBytes(of: $0) }) { return .titleTerms }
            return nil
        }
    }

    /// Every row the picker can show, in title order.
    let entries: [Entry]

    init(_ rows: [RowFields], reusing previous: ArtifactSourcePickerIndex?) {
        var knownSources: [String: AnalysedSource] = [:]
        var knownBooks: [String: AnalysedBook] = [:]
        var knownTitles: [String: String] = [:]
        for entry in previous?.entries ?? [] {
            for source in entry.sources { knownSources[source.fields.id] = source }
            if let book = entry.book { knownBooks[book.fields.id] = book }
            knownTitles[entry.row.title] = entry.foldedTitle
        }
        entries = rows
            .map { row in
                Entry(
                    row: row.row,
                    sources: row.sources.map { fields in
                        if let known = knownSources[fields.id], known.fields == fields { return known }
                        return AnalysedSource(fields)
                    },
                    book: row.book.map { fields in
                        if let known = knownBooks[fields.id], known.fields == fields { return known }
                        return AnalysedBook(fields: fields, text: SearchText(fields.metadata))
                    },
                    foldedTitle: knownTitles[row.row.title] ?? StudioViewModel.foldedSidebarSearchString(
                        StudioViewModel.normalizedSidebarSearchString(row.row.title)
                    )
                )
            }
            .sorted { $0.row.title.localizedStandardCompare($1.row.title) == .orderedAscending }
    }

    /// The rows a query finds, closest first (`Rank`) and in title order within a
    /// rank. `contentMatchIDs` are sources whose own text holds every typed term,
    /// found by the indexed content pass the sidebar's search runs too; they join
    /// the rows the title, author and domain matched, so a page the words appear in
    /// is found here as it is there, after every row that names them.
    func rows(matching query: String, contentMatchIDs: Set<String> = []) -> [ArtifactSourcePickerRow] {
        let normalized = StudioViewModel.normalizedSidebarSearchString(query)
        guard !normalized.isEmpty else { return entries.map(\.row) }
        let sourceQuery = Query(source: normalized)
        let bookQuery = Query(bookMetadata: normalized)
        let ranked: [(rank: Rank, row: ArtifactSourcePickerRow)] = entries.compactMap { entry in
            let named: Bool
            if let book = entry.book {
                named = normalized == "book"
                    || bookQuery.matches(book.text)
                    || entry.sources.contains { $0.matches(sourceQuery) }
            } else {
                named = entry.sources.contains {
                    $0.matches(sourceQuery) || $0.normalizedType.containsBytes(of: normalized)
                }
            }
            let rank: Rank
            if named {
                rank = sourceQuery.titleRank(entry.foldedTitle) ?? .details
            } else if entry.sources.contains(where: { contentMatchIDs.contains($0.fields.id) }) {
                rank = .text
            } else {
                return nil
            }
            return (rank, entry.row)
        }
        // A stable sort keeps the entries' title order inside each rank.
        return ranked
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.row)
    }
}

private extension String {
    /// Whether this string's UTF-8 holds `needle`'s, by `memmem`. Both sides come out
    /// of the same normalization, so this finds what `contains` would — at the speed
    /// of a byte scan rather than Foundation's character-aware search, which was
    /// most of what was left once the analysis moved out of the keystroke.
    func containsBytes(of needle: String) -> Bool {
        var haystack = self
        var needle = needle
        return haystack.withUTF8 { haystack in
            needle.withUTF8 { needle in
                guard !needle.isEmpty, haystack.count >= needle.count,
                      let haystackStart = haystack.baseAddress,
                      let needleStart = needle.baseAddress else { return false }
                return memmem(haystackStart, haystack.count, needleStart, needle.count) != nil
            }
        }
    }
}

extension StudioViewModel {


    // MARK: - Knowledge Base Context Management

    /// Add a source to the chat context.
    ///
    /// `explicit` is true when the learner named this source themselves (a file
    /// dropped or uploaded into the chat, a source picked or dragged in). Asking
    /// a chat to work with one source is not ambient search, so the per-family
    /// "kept from AI" switch does not refuse it; that switch only keeps a family
    /// out of what search and discovery surface on their own.
    func addSourceToContext(_ articleId: String, explicit: Bool = false) {
        guard let article = articlesById[articleId], explicit || isSourceIncludedInKnowledge(article) else { return }
        if explicit { ChatNamedSources.shared.grant([articleId]) }
        guard !contextSourceIds.contains(articleId) else { return }
        contextSourceIds.append(articleId)
        fetchContextContentIfNeeded(for: articleId)
    }

    /// Add sources to the chat context while preserving the current context order.
    /// `explicit` as in `addSourceToContext`.
    func addSourcesToContext(_ articleIds: [String], explicit: Bool = false) {
        let ids = orderedUniqueSourceIDs(articleIds).filter { id in
            guard let article = articlesById[id] else { return false }
            return explicit || isSourceIncludedInKnowledge(article)
        }
        if explicit { ChatNamedSources.shared.grant(ids) }
        for id in ids where !contextSourceIds.contains(id) {
            contextSourceIds.append(id)
        }
        for id in ids {
            fetchContextContentIfNeeded(for: id)
        }
    }

    /// Return source IDs in the same order they currently appear in the source list.
    func sourceIDsInCurrentDisplayOrder(_ ids: Set<String>) -> [String] {
        guard !ids.isEmpty else { return [] }
        var orderedIDs: [String] = []
        var seen = Set<String>()

        for article in activeTabArticles where ids.contains(article.id) {
            orderedIDs.append(article.id)
            seen.insert(article.id)
        }

        for article in articles where ids.contains(article.id) && !seen.contains(article.id) {
            orderedIDs.append(article.id)
            seen.insert(article.id)
        }

        for id in ids where !seen.contains(id) {
            orderedIDs.append(id)
        }

        return orderedIDs
    }

    /// Replace the chat context with the provided sources.
    func setContextSources(_ articleIds: [String]) {
        let ids = orderedUniqueSourceIDs(articleIds).filter { id in
            guard let article = articlesById[id] else { return false }
            return isSourceIncludedInKnowledge(article)
        }
        contextSourceIds = ids
        for id in ids {
            fetchContextContentIfNeeded(for: id)
        }
    }

    func fetchContextContentIfNeeded(for articleId: String) {
        if let idx = articles.firstIndex(where: { $0.id == articleId }),
           articles[idx].content == nil
            && !articles[idx].cachedIsLocalDocument
            && !requiresExplicitPaperDownload(articles[idx]) {
            Task { await fetchContent(for: articleId) }
        }
    }

    /// Remove a source from the chat context.
    func removeSourceFromContext(_ articleId: String) {
        contextSourceIds.removeAll { $0 == articleId }
        ChatNamedSources.shared.revoke(articleId)
    }

    /// Toggle a source in/out of chat context.
    func toggleSourceContext(_ articleId: String) {
        if contextSourceIds.contains(articleId) {
            removeSourceFromContext(articleId)
        } else {
            addSourceToContext(articleId, explicit: true)
        }
    }

    /// Select all visible sources for context.
    func selectAllSources() {
        let visibleIds = activeTabArticles
            .filter { isSourceIncludedInKnowledge($0) }
            .map(\.id)
        for id in visibleIds where !contextSourceIds.contains(id) {
            contextSourceIds.append(id)
        }
    }

    /// Clear all source context.
    func clearSourceContext() {
        contextSourceIds = []
    }

    // MARK: - Semantic Source Search

    typealias SourceEmbeddingChunkInput = SourceEmbeddingText.ChunkInput

    /// Build chunk-level embedding inputs for a source. Delegates to the canonical
    /// `SourceEmbeddingText` so the live ingest path and the background indexer produce
    /// byte-identical chunks — positional chunk ids mean divergent boundaries would
    /// break evidence lookup.
    func embeddingChunks(for article: StudioArticle) async -> [SourceEmbeddingChunkInput] {
        let content: String?
        if article.sourceType == .paper {
            content = await storage.loadSourceContent(article.id)
        } else {
            content = article.content != nil ? article.content : await storage.loadSourceContent(article.id)
        }
        return SourceEmbeddingText.chunkInputs(
            sourceID: article.id,
            title: article.title,
            domain: article.domain,
            content: content
        )
    }

    func sourceSearchBestMatches(
        from chunkHits: [String: (chunkId: String, score: Float)],
        query: String,
        queryTerms: [String],
        articlesById: [String: StudioArticle]
    ) async -> [String: SourceSearchBestMatch] {
        var matches: [String: SourceSearchBestMatch] = [:]
        for (sourceId, hit) in chunkHits {
            guard let article = articlesById[sourceId],
                  let chunkIndex = StorageService.sourceChunkIndex(fromSourceChunkEmbeddingId: hit.chunkId) else { continue }
            let chunks = await embeddingChunks(for: article)
            guard chunkIndex < chunks.count else { continue }
            let passage = Self.normalizedSourceSearchPassage(chunks[chunkIndex].passage)
            guard !passage.isEmpty else { continue }
            matches[sourceId] = SourceSearchBestMatch(
                sourceId: sourceId,
                chunkId: hit.chunkId,
                query: query,
                excerpt: Self.sourceSearchExcerpt(from: passage, queryTerms: queryTerms),
                passage: passage,
                findQuery: Self.sourceSearchFindQuery(from: passage, queryTerms: queryTerms),
                score: hit.score
            )
        }
        return matches
    }

    static func normalizedSourceSearchPassage(_ passage: String) -> String {
        passage
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sourceSearchExcerpt(from passage: String, queryTerms: [String], maxLength: Int = 420) -> String {
        let normalized = normalizedSourceSearchPassage(passage)
        guard !normalized.isEmpty else { return "" }
        let ns = normalized as NSString
        guard ns.length > maxLength else { return normalized }

        let lower = normalized.lowercased() as NSString
        let terms = queryTerms.sorted { $0.count > $1.count }
        let matchLocation = terms
            .lazy
            .map { lower.range(of: $0.lowercased()) }
            .first { $0.location != NSNotFound }?
            .location ?? 0

        let desiredStart = max(0, matchLocation - 140)
        let start = min(desiredStart, max(0, ns.length - maxLength))
        let length = min(maxLength, ns.length - start)
        var excerpt = ns.substring(with: NSRange(location: start, length: length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { excerpt = "..." + excerpt }
        if start + length < ns.length { excerpt += "..." }
        return excerpt
    }

    static func sourceSearchFindQuery(from passage: String, queryTerms: [String]) -> String {
        let normalized = normalizedSourceSearchPassage(passage)
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "" }

        let loweredTerms = Set(queryTerms.map { $0.lowercased() })
        let matchIndex = words.firstIndex { word in
            let cleaned = word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return loweredTerms.contains(cleaned)
        } ?? 0
        let start = max(0, matchIndex - 2)
        let end = min(words.count, start + 8)
        return words[start..<end].joined(separator: " ")
    }

    /// If a source is ready, bring its search index up to date in the background, so
    /// vectors and the full-text row keep pace with newly fetched transcripts and
    /// article text instead of staying title-only.
    ///
    /// Goes through the indexer rather than embedding here: this path used to write
    /// vectors alone, so a source fetched while the app was open had no full-text row
    /// until the next launch, and the indexer then embedded it a second time because
    /// no index stamp had been recorded.
    func queueSourceEmbeddingRefreshIfReady(_ articleId: String) {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.state == .ready else { return }
        kickSourceEmbeddingIndexingSoon()
    }

    // MARK: - Sidebar content search

    /// The second pass behind the sidebar search field.
    ///
    /// `sourceMatchesSearch`, which decides what the list renders, only scans
    /// metadata: title, author, journal, year, DOI, URL, parent group. That is what
    /// keeps typing instant, but it cannot see inside a source — so a term appearing
    /// only in a transcript or a PDF body was unfindable from the one search field
    /// the app has, and a paper was only findable by remembering words from its
    /// title. This runs a strict FTS5 content pass and records sources whose canonical
    /// text contains every typed term; `computeFilteredActiveItems` unions those ids
    /// into the rendered list.
    ///
    /// Scoped to the current tab through `restrictedTo` rather than by filtering a
    /// library-wide ranking, so a small tab gets its own top results instead of
    /// whatever fragment of it survives a corpus-wide cut. Grouped tabs (courses,
    /// meetings, videos) render whole groups matched on their own group metadata,
    /// so they are left alone. Books are the exception: the pool is the tab's
    /// chapters, and `bookMatchesSearch` lets a book answer for any chapter whose
    /// text matched — a term that appears only inside one chapter of a book was
    /// otherwise unfindable from the Books tab.
    ///
    /// Takes the window explicitly because it spans an `await`, which an
    /// `inWindow` scope cannot: the search field that triggered it belongs to
    /// one window's Sources panel, and that window may not be key when the
    /// indexed lookup lands. Defaults to the window being acted in.
    func refreshSidebarContentSearchMatches(in windowState: StudioWindowState? = nil) async {
        let window = windowState ?? activeWindowState
        let store = window.sidebarStore
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = store.sidebarTab

        func clearMatches() {
            guard !store.contentSearchMatchIDs.isEmpty else { return }
            store.contentSearchMatchIDs = []
            store.contentSearchRevision &+= 1
        }

        // A field-scoped search (`title:…`) reads that field and nothing else, so
        // the pass that looks inside bodies has no say in it.
        guard !query.isEmpty, !SidebarSearchQuery(parsing: query).isScoped,
              !tab.isGrouped || tab == .books else {
            clearMatches()
            return
        }

        let pool = inWindow(window) {
            Set(activeArticles.filter { matchesCurrentTab($0) }.map(\.id))
        }
        guard !pool.isEmpty else {
            clearMatches()
            return
        }

        // Books need every matching chapter, not a top slice: the book is the
        // unit shown, and a cap would hide books whose matches sort late.
        let limit = tab == .books ? pool.count : min(max(pool.count, 40), 300)
        let matched = await storage.strictSourceContentMatchIDs(
            queryText: query,
            limit: limit,
            restrictedTo: pool
        )
        // The query or tab can move on while the indexed lookup runs.
        guard !Task.isCancelled,
              store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query,
              store.sidebarTab == tab else { return }

        guard matched != store.contentSearchMatchIDs else { return }
        store.contentSearchMatchIDs = matched
        store.contentSearchRevision &+= 1
        inWindow(window) { pruneSelectionToVisibleSources() }
    }

    /// Search sources with the shared hybrid ranking.
    ///
    /// Runs in two phases: an instant in-memory pass over already-loaded metadata so
    /// typing stays responsive, then the real ranking from `SourceSearchEngine` — the
    /// same code path the MCP `search_sources_semantic` tool runs, so asking an assistant
    /// and typing into the app return the same sources in the same order.
    func searchSources() async {
        sourceSearchGeneration += 1
        let searchGeneration = sourceSearchGeneration
        let query = sourceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            sourceSearchResults = []
            readerSearchBestMatches = [:]
            hasSearchedSources = false
            isSearchingSources = false
            pruneSelectionToVisibleSources()
            return
        }

        hasSearchedSources = true
        isSearchingSources = true
        defer {
            if searchGeneration == sourceSearchGeneration {
                isSearchingSources = false
            }
        }

        let queryTerms = SourceSearchEngine.searchTerms(for: query)
        let normalizedQuery = query.lowercased()
        let searchableArticles = articles.filter {
            isSourceIncludedInKnowledge($0) && !isSourceHidden($0)
        }
        let articlesById = Dictionary(uniqueKeysWithValues: searchableArticles.map { ($0.id, $0) })

        func isCurrentSearch() -> Bool {
            searchGeneration == sourceSearchGeneration
                && sourceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
        }

        func rankedResults(from scores: [String: Float]) -> [SourceSearchResult] {
            scores
                .compactMap { sourceId, score -> SourceSearchResult? in
                    guard let article = articlesById[sourceId] else { return nil }
                    return SourceSearchResult(article: article, score: score, bestMatch: nil)
                }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.article.title.localizedStandardCompare(rhs.article.title) == .orderedAscending
                    }
                    return lhs.score > rhs.score
                }
        }

        let metadataEntries = searchableArticles.map {
            SourceSearchMetadataEntry(
                id: $0.id,
                title: $0.title,
                domain: $0.domain,
                author: $0.author ?? "",
                parentGroup: $0.parentGroup ?? "",
                contentPrefix: $0.content.map { String($0.prefix(2000)) } ?? ""
            )
        }
        let scoredMetadata = await Task.detached(priority: .userInitiated) {
            Self.metadataSearchScores(
                entries: metadataEntries,
                normalizedQuery: normalizedQuery,
                queryTerms: queryTerms
            )
        }.value
        guard isCurrentSearch() else { return }

        // Phase 1: show what the already-loaded metadata matches, immediately. This is a
        // placeholder ordering to keep typing responsive; phase 2 replaces it wholesale.
        sourceSearchResults = Array(rankedResults(from: scoredMetadata).prefix(30))
        pruneSelectionToVisibleSources()

        // Phase 2: the shared hybrid ranking. A failed embed degrades to the lexical and
        // metadata branches rather than taking search down — the branch that actually
        // retrieves an exact term is the lexical one, so a rare-term query still works.
        var queryVector: [Float]?
        do {
            queryVector = try await aiService.embedText(query)
        } catch {
            logger.error("Query embedding failed; searching without the semantic branch: \(error.localizedDescription)")
        }
        guard isCurrentSearch() else { return }

        // Ask for more than we display: the engine ranks every active source, and hits
        // for sources not currently loaded in the list are dropped below.
        let hits = await storage.searchSources(queryText: query, queryVector: queryVector, limit: 90)
        guard isCurrentSearch() else { return }

        let visible = hits.compactMap { hit -> (hit: SourceSearchHit, article: StudioArticle)? in
            guard let article = articlesById[hit.sourceId] else { return nil }
            return (hit: hit, article: article)
        }.prefix(30)

        // Best-match excerpts are resolved only for what is actually shown — each one
        // re-derives the source's chunks, so widening this is real work per result.
        var chunkHits: [String: (chunkId: String, score: Float)] = [:]
        for entry in visible {
            guard let chunkId = entry.hit.bestChunkId, let score = entry.hit.semanticScore else { continue }
            chunkHits[entry.hit.sourceId] = (chunkId: chunkId, score: score)
        }
        let bestMatches = await sourceSearchBestMatches(
            from: chunkHits,
            query: query,
            queryTerms: queryTerms,
            articlesById: articlesById
        )
        guard isCurrentSearch() else { return }

        sourceSearchResults = visible.map { entry in
            SourceSearchResult(
                article: entry.article,
                score: entry.hit.score,
                bestMatch: bestMatches[entry.hit.sourceId]
            )
        }
        pruneSelectionToVisibleSources()
    }

    /// The Docs source picker's index of the library as it is now.
    ///
    /// The snapshot is taken here, on the main actor, because hidden sources, book
    /// grouping and the strings a row draws all read view-model state; it is a
    /// walk over `articles` with no text analysis. The analysis runs off the main
    /// actor and reuses whatever the last index analysed for a source whose
    /// searched fields have not changed, so only the first opening pays for the
    /// whole library.
    func artifactSourcePickerIndex() async -> ArtifactSourcePickerIndex {
        let snapshot = artifactSourcePickerSnapshot()
        let previous = artifactSourcePickerIndexMemo
        let index = await Task.detached(priority: .userInitiated) {
            ArtifactSourcePickerIndex(snapshot, reusing: previous)
        }.value
        artifactSourcePickerIndexMemo = index
        return index
    }

    /// One row per ordinary source and one per imported book. Books stay
    /// chapter-backed in storage, but the learner chooses the remembered book
    /// rather than having to guess which chapter holds the idea.
    private func artifactSourcePickerSnapshot() -> [ArtifactSourcePickerIndex.RowFields] {
        var emittedBookIDs = Set<String>()
        var rows: [ArtifactSourcePickerIndex.RowFields] = []
        rows.reserveCapacity(articles.count)

        for source in articles {
            // A hidden source (a hidden show's episodes, a muted channel's
            // videos, a source hidden by itself) is not in the library the
            // learner sees, so the picker never offers it (product owner, 2026-10-07:
            // TBPN episodes showed up when grounding a page passage).
            guard !isSourceHidden(source) else { continue }
            if source.sourceType == .book,
               let bookID = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bookID.isEmpty {
                guard emittedBookIDs.insert(bookID).inserted else { continue }
                let chapters = bookChapterArticlesInOrder(for: bookID)
                guard let representative = chapters.first else { continue }
                let chapterCount = chapters.count
                let subtitle = [
                    Self.sourcePickerTypeLabel(representative.sourceType),
                    bookDisplayAuthor(bookID),
                    "\(chapterCount) \(chapterCount == 1 ? "chapter" : "chapters")",
                ]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                rows.append(ArtifactSourcePickerIndex.RowFields(
                    row: ArtifactSourcePickerRow(
                        id: "book:\(bookID)",
                        sourceID: representative.id,
                        bookID: bookID,
                        sourceType: representative.sourceType.rawValue,
                        title: bookDisplayName(bookID),
                        subtitle: subtitle
                    ),
                    sources: chapters.map(ArtifactSourcePickerIndex.SourceFields.init),
                    // A learner searches for a book by the metadata on its Book
                    // record, so "How Life Works" finds chapters whose own titles
                    // are "Introduction" and "Chapter 1".
                    book: ArtifactSourcePickerIndex.BookFields(
                        id: bookID,
                        metadata: [
                            bookDisplayName(bookID),
                            bookDisplayAuthor(bookID),
                            bookDisplaySubtitle(bookID),
                            bookDisplayEdition(bookID),
                            bookDisplayKind(bookID),
                        ].compactMap { $0 }
                    )
                ))
                continue
            }

            // Who wrote it says more than where it lives, and it is the half a
            // learner scanning the picker recognizes — the domain only stands in
            // when nothing named the author.
            let type = Self.sourcePickerTypeLabel(source.sourceType)
            let attribution = (source.author ?? source.journal ?? source.domain)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(ArtifactSourcePickerIndex.RowFields(
                row: ArtifactSourcePickerRow(
                    id: "source:\(source.id)",
                    sourceID: source.id,
                    bookID: nil,
                    sourceType: source.sourceType.rawValue,
                    title: source.title,
                    subtitle: attribution.isEmpty ? type : "\(type) · \(attribution)"
                ),
                sources: [ArtifactSourcePickerIndex.SourceFields(source)],
                book: nil
            ))
        }
        return rows
    }

    static func sourcePickerTypeLabel(_ type: StudioSourceType) -> String {
        switch type {
        case .article, .unclassified: return "Article"
        case .paper: return "Paper"
        case .podcast: return "Podcast"
        case .book: return "Book"
        case .course: return "Course"
        case .meeting: return "Meeting"
        case .video: return "Video"
        case .xPost: return "X post"
        case .manual: return "Link"
        }
    }

    /// Check if a preprint has been published in a peer-reviewed venue.
    /// Tries bioRxiv `/pubs/` → Crossref `relation` → Crossref title search → OpenAlex.
}
