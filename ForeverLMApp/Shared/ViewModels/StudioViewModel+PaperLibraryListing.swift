// The Papers lists: library keys, listing facts, duplicate suppression and dedup keys.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    struct FilteredPaperItemsCacheKey: Equatable {
        let filter: SidebarFilterCacheKey
        let library: PaperLibraryKey
    }

    func filteredPaperItems(hasPDF: Bool) -> [StudioArticle] {
        // Memoized per filter revision so the whole cluster of papers-tab
        // properties (active*/hasMore*/remaining*) shares one partition per
        // render. The library's share comes from `paperLibraryIndex`, so a
        // keystroke, a tab switch or Show More filters the window's rows and
        // never re-derives the whole library.
        let key = FilteredPaperItemsCacheKey(filter: currentSidebarFilterCacheKey, library: currentPaperLibraryKey)
        if sidebarStore.filteredPaperItemsCacheKey != key
            || sidebarStore.filteredPaperItemsWithPDFCache == nil
            || sidebarStore.filteredPaperItemsWithoutPDFCache == nil {
            let base = filteredActiveItems
            sidebarStore.filteredPaperItemsWithPDFCache = paperItems(hasPDF: true, in: base)
            sidebarStore.filteredPaperItemsWithoutPDFCache = paperItems(hasPDF: false, in: base)
            sidebarStore.filteredPaperItemsCacheKey = key
        }
        return hasPDF
            ? (sidebarStore.filteredPaperItemsWithPDFCache ?? [])
            : (sidebarStore.filteredPaperItemsWithoutPDFCache ?? [])
    }

    var filteredPaywalledPapersWithoutPDF: [StudioArticle] {
        papersPartition.paywalledWithoutPDF
    }

    /// Whole-catalog candidate set for the explicit paywall recheck command.
    /// This intentionally ignores the current search query and pagination: the
    /// command promises to revisit the catalog, not only the rows on screen. It
    /// uses recorded paths rather than statting iCloud-backed files, so clicking
    /// the action cannot block the main actor while CloudDocs downloads a file.
    var paywalledPapersEligibleForRecheck: [StudioArticle] {
        let processingIDs = processingPaperIDs
        return activeArticles.filter {
            $0.sourceType == .paper
                && $0.hasPaywallMarker
                && ($0.localFilePath ?? "").isEmpty
                && !isSourceHidden($0)
                && !processingIDs.contains($0.id)
                && $0.state != .fetching
                && $0.url.hasPrefix("http")
        }
    }

    var filteredPapersWithPDF: [StudioArticle] {
        papersPartition.withPDF
    }

    func paperItems(hasPDF: Bool, in papers: [StudioArticle]) -> [StudioArticle] {
        let unavailable = unavailableRecordedPaperPDFIDs
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        // Both whole-library sets come from `paperLibraryIndex`, built once per
        // library change rather than on every call.
        let library = paperLibraryIndex
        // A preprint whose journal version is held with its PDF is listed as
        // that version (`supersededPreprintIDs`); it stays in its notebooks.
        let superseded = library.superseded
        if hasPDF {
            return papers.filter { hasUsablePDF($0) && !superseded.contains($0.id) }
        }

        // Duplicate suppression is a library invariant, not a property of the
        // current search/filter result. A search can match an older discovery
        // record by stale author metadata while excluding the already-ingested
        // canonical copy. Building this set from `papers` made that old record
        // reappear as "PDF needed" even though the library already held the same
        // titled/identified paper and its PDF. Use the whole published library;
        // availability remains cache-only so this stays safe in SwiftUI renders.
        let paperKeysWithPDF = library.keysWithPDF
        return papers.filter { paper in
            guard !hasUsablePDF(paper), !superseded.contains(paper.id) else { return false }
            return paperKeysWithPDF.isDisjoint(with: cachedPaperDedupLookupKeys(for: paper))
        }
    }

    // MARK: - The library's share of the Papers lists

    /// What the whole library's share of the Papers lists is built from: the
    /// articles (their presentation revision, which moves on any change to a
    /// field a row or these sets read) and the cached PDF availability that
    /// `cachedHasUsablePDF` reads, which moves on its own when the background
    /// path warm finds a file arrived or gone.
    struct PaperLibraryKey: Equatable {
        let articlesRevision: Int
        let resolvedPathGeneration: Int
    }

    var currentPaperLibraryKey: PaperLibraryKey {
        PaperLibraryKey(
            articlesRevision: articlesRevision,
            resolvedPathGeneration: StudioArticle.resolvedPathCacheGeneration
        )
    }

    /// The two whole-library sets every Papers list consults: which preprints
    /// a journal version with its PDF stands in for, and the identity keys of
    /// every paper with a usable PDF. Neither depends on the window, its tab,
    /// its search or its page, so a keystroke, a tab switch or Show More reuses
    /// them; only a library change (`PaperLibraryKey`) rebuilds them.
    struct PaperLibraryIndex {
        let key: PaperLibraryKey
        let superseded: Set<String>
        let keysWithPDF: Set<String>
        /// The preprints the library holds a journal version of, PDF or not
        /// (`publishedVersion(ofPreprint:)` answers the same for one paper).
        let withPublishedVersion: Set<String>
    }

    /// Built on the main actor, as before, but from `paperListingFacts(for:)`,
    /// so a rebuild after one paper changed re-parses that paper alone. One
    /// copy serves every window.
    var paperLibraryIndex: PaperLibraryIndex {
        let key = currentPaperLibraryKey
        if let cached = paperLibraryIndexCache, cached.key == key {
            return cached
        }
        let unavailable = unavailableRecordedPaperPDFIDs
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        prunePaperListingFacts()
        let library = activeArticles
        let superseded = Self.supersededPreprintIDs(
            in: library,
            hasUsablePDF: hasUsablePDF,
            versionFacts: { self.paperListingFacts(for: $0).version }
        )
        var keysWithPDF = Set<String>()
        for paper in library where paper.sourceType == .paper && hasUsablePDF(paper) {
            keysWithPDF.formUnion(paperListingFacts(for: paper).dedupKeys)
        }
        let withPublishedVersion = Self.supersededPreprintIDs(
            in: library,
            hasUsablePDF: { _ in true },
            versionFacts: { self.paperListingFacts(for: $0).version }
        )
        let index = PaperLibraryIndex(
            key: key,
            superseded: superseded,
            keysWithPDF: keysWithPDF,
            withPublishedVersion: withPublishedVersion
        )
        paperLibraryIndexCache = index
        return index
    }

    /// The fields a paper's listing facts are read from: everything
    /// `paperVersionKind`, `paperDedupDisplayKeys` and the title checks they
    /// make read. Equal inputs mean the facts kept for the paper still hold.
    struct PaperListingInputs: Equatable {
        let sourceType: StudioSourceType
        let url: String
        let title: String
        let domain: String
        let doi: String?
        let publishedDOI: String?
        let journal: String?
        // What `isPaperReadyForListenPreparation` reads, for the content key.
        let state: StudioArticleState
        let author: String?
        let publishedYear: String?
        let paperIngestionMethod: PaperIngestionMethod?
        let paperContentSHA256: String?

        init(_ paper: StudioArticle) {
            sourceType = paper.sourceType
            url = paper.url
            title = paper.title
            domain = paper.domain
            doi = paper.doi
            publishedDOI = paper.publishedDOI
            journal = paper.journal
            state = paper.state
            author = paper.author
            publishedYear = paper.publishedYear
            paperIngestionMethod = paper.paperIngestionMethod
            paperContentSHA256 = paper.paperContentSHA256
        }
    }

    /// What the Papers lists read off one paper — its versions' facts and its
    /// identity keys (`paperDedupDisplayKeys`, `paperDedupLookupKeys`) — each a
    /// parse of its address, DOI and title.
    struct PaperListingFacts {
        let inputs: PaperListingInputs
        let version: PaperVersionFacts
        let dedupKeys: [String]
        let lookupKeys: [String]
    }

    /// One paper's listing facts, kept per source id and parsed again only
    /// when a field they come from changed.
    func paperListingFacts(for paper: StudioArticle) -> PaperListingFacts {
        let inputs = PaperListingInputs(paper)
        if let known = paperListingFactsByID[paper.id], known.inputs == inputs {
            return known
        }
        let facts = PaperListingFacts(
            inputs: inputs,
            version: PaperVersionFacts(paper),
            dedupKeys: Self.paperDedupDisplayKeys(for: paper),
            lookupKeys: Self.paperDedupLookupKeys(for: paper)
        )
        paperListingFactsByID[paper.id] = facts
        return facts
    }

    /// `paperDedupLookupKeys(for:)`, read from the kept facts. Only a paper
    /// has keys, so nothing else is kept.
    func cachedPaperDedupLookupKeys(for article: StudioArticle) -> [String] {
        guard article.sourceType == .paper else { return [] }
        return paperListingFacts(for: article).lookupKeys
    }

    /// Drops the facts of sources the library no longer holds.
    private func prunePaperListingFacts() {
        let held = articlesStore.articleIDs
        guard paperListingFactsByID.keys.contains(where: { !held.contains($0) }) else { return }
        paperListingFactsByID = paperListingFactsByID.filter { held.contains($0.key) }
    }

    /// Papers that `paperItems(hasPDF:)` suppresses as duplicates: no usable PDF
    /// of their own, but dedup keys matching a copy the library already holds
    /// with one.
    func suppressedDuplicatePaperIDs() -> [String] {
        let unavailable = unavailableRecordedPaperPDFIDs
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        let papers = activeArticles.filter { $0.sourceType == .paper }
        // Hiding is durable and synced, so a twin only counts inside its own
        // library: the learner's paper never hides a team's row for every
        // member (docs/teams-design.md, decision 19).
        var keysWithPDFByLibrary: [String?: Set<String>] = [:]
        for paper in papers where hasUsablePDF(paper) {
            keysWithPDFByLibrary[paper.teamID, default: []].formUnion(Self.paperDedupDisplayKeys(for: paper))
        }
        guard !keysWithPDFByLibrary.isEmpty else { return [] }
        return papers.filter { paper in
            guard !hasUsablePDF(paper), !isSourceHidden(paper),
                  let keysWithPDF = keysWithPDFByLibrary[paper.teamID] else { return false }
            return !keysWithPDF.isDisjoint(with: Self.paperDedupLookupKeys(for: paper))
        }.map(\.id)
    }

    /// Resolve those duplicates once per launch instead of filtering them forever.
    ///
    /// Suppressing them is right as a display rule and wrong as the whole story.
    /// The row stays active, counted, embedded, and reachable by search while
    /// being invisible in every Papers partition at once: having no PDF keeps it
    /// out of the main list, and the suppression keeps it out of the attention
    /// list. Four papers sat in exactly that gap — no surface that could show
    /// them, no action that could clear them, and no count that revealed them.
    ///
    /// Hiding is the same decision made durable: reversible, still searchable,
    /// visible under the hidden filter, and synced. Only rows the suppression had
    /// already made invisible are touched, so this can never hide a paper the
    /// learner can currently see.
    func resolveSuppressedDuplicatePapers() async {
        guard !didResolveSuppressedDuplicatePapers else { return }
        didResolveSuppressedDuplicatePapers = true
        let ids = suppressedDuplicatePaperIDs()
        guard !ids.isEmpty else { return }
        for id in ids {
            do {
                try await storage.setSourceHidden(id, hidden: true)
                if let idx = articles.firstIndex(where: { $0.id == id }) {
                    articles[idx].isHidden = true
                }
            } catch {
                logger.error("Could not hide duplicate paper \(id): \(error.localizedDescription)")
            }
        }
        logger.info("Hid \(ids.count) duplicate papers the sidebar was suppressing")
    }

    /// Minimum number of recorded-but-unstattable PDFs before the library is
    /// treated as storage-degraded rather than individually stale.
    nonisolated static let unavailableRecordedPDFFloor = 10

    /// IDs of papers whose PDF the library has on record (`localFilePath` set)
    /// but whose file does not currently stat on disk — ONLY when that is true
    /// for so many papers at once that the cause must be storage-level, not
    /// per-paper. A single missing file means a stale path and the paper should
    /// re-enter the needs-attention flows (that semantic is deliberate — see
    /// `resolvedPDFPath`). Hundreds going missing simultaneously means the
    /// files' storage is unavailable: iCloud Drive rebuilding its local replica
    /// after an OS upgrade, files not yet synced to a fresh Mac, or the content
    /// root resolving to the local fallback. Re-downloading from publishers is
    /// the wrong remedy for every one of those, so above the threshold
    /// (≥ `unavailableRecordedPDFFloor` and ≥ 25% of recorded PDFs) these papers
    /// are excluded from attention, the badge, auto-fetch, and bulk downloads,
    /// and surfaced in the sidebar as waiting for their files instead. Below the
    /// threshold this returns the empty set and behavior is unchanged.
    /// `nonisolated` so the stat-heavy scan can run off the main actor over a
    /// snapshot; stats are memoized per unique path per session.
    nonisolated static func unavailableRecordedPaperPDFIDs(in articles: [StudioArticle]) -> Set<String> {
        unavailableRecordedPaperPDFIDs(in: articles) { $0.resolvedPDFPath != nil }
    }

    /// Cache-only form for SwiftUI-derived state. Unknown recorded paths count as
    /// available until the off-main warm establishes their real state, so view
    /// evaluation never performs an iCloud-backed stat or flashes a false outage.
    nonisolated static func cachedUnavailableRecordedPaperPDFIDs(in articles: [StudioArticle]) -> Set<String> {
        unavailableRecordedPaperPDFIDs(in: articles) { $0.cachedHasUsablePDF }
    }

    nonisolated private static func unavailableRecordedPaperPDFIDs(
        in articles: [StudioArticle],
        isAvailable: (StudioArticle) -> Bool
    ) -> Set<String> {
        let recorded = articles.filter {
            $0.sourceType == .paper && !($0.localFilePath ?? "").isEmpty
        }
        let missing = recorded.filter { !isAvailable($0) }
        guard missing.count >= unavailableRecordedPDFFloor,
              missing.count * 4 >= recorded.count else { return [] }
        return Set(missing.map(\.id))
    }

    /// `unavailableRecordedPaperPDFIDs` over the whole active library, memoized
    /// on what it reads: the articles and the cached path availability
    /// (`PaperLibraryKey`). The threshold is a property of the library, not of
    /// whatever subset a view is rendering, so every consumer — in every window —
    /// shares this whole-library answer.
    var unavailableRecordedPaperPDFIDs: Set<String> {
        let key = currentPaperLibraryKey
        if let cached = paperLibraryUnavailableCache, cached.key == key {
            return cached.ids
        }
        let ids = Self.cachedUnavailableRecordedPaperPDFIDs(in: activeArticles)
        paperLibraryUnavailableCache = (key, ids)
        return ids
    }

    /// Whether a source with this normalized URL (`SourceDiscovery.normalizedURL`)
    /// is in the library. One set lookup, against a table built once per
    /// articles revision.
    ///
    /// The chat's web sources footer does not answer this by scanning
    /// `articles` and normalizing every source's URL for each citation it drew,
    /// inside its SwiftUI body. Normalizing a stored file path walks the
    /// content roots, and a lazy transcript rebuilds the row every time it
    /// scrolls back into view, so one reply with web sources over a large
    /// library would turn each scroll into a second of main-thread work. The
    /// library changes rarely
    /// next to how often a row is built, so the normalization runs per revision
    /// and the row pays a hash.
    func libraryContainsSource(normalizedURL key: String) -> Bool {
        libraryIdentityKeys[key] != nil
    }

    /// Whether the page a web citation names is in the library, by address or
    /// by the paper it is. A paper is often saved under a different address
    /// than the one a web search cites — its DOI link, its PDF, a publisher
    /// page reached through a recommendation link — so the address alone said
    /// "not saved" for papers that were. The DOI the citation carries (a
    /// doi.org link, a Nature article id, a `/doi/` path, an arXiv id) is
    /// matched against every saved paper's DOI, the identity rule the Doc
    /// reference cards already apply in `activeSourceID(forReferenceURL:)`.
    func libraryContainsSource(url: String) -> Bool {
        librarySourceID(forURL: url) != nil
    }

    /// The library source a web address names, or nil when the page is not in
    /// the library. Three ways an address can name a saved source, tried in
    /// order: the address itself, the DOI written in the address, and the DOI
    /// the page declared about itself once it was loaded
    /// (`notePageDeclaredIdentity`). The third is what identifies an index
    /// page — PubMed, PMC, Semantic Scholar — whose address carries only its
    /// own record number: a chat that links a paper by its PubMed page, while
    /// the library holds it under its journal address, must not make the
    /// Reader offer Add to Sources for a paper already saved.
    func librarySourceID(forURL url: String) -> String? {
        let table = libraryIdentityKeys
        let pageKey = SourceDiscovery.normalizedURL(url)
        if let id = table[pageKey] { return id }
        if let doi = PaperService.extractDOI(from: url) ?? pageDeclaredDOIs[pageKey],
           let id = table[Self.libraryDOIKey(doi)] {
            return id
        }
        return nil
    }

    /// A page finished loading in a Reader or Browser web view and its head
    /// says which paper it is (`citation_doi`, `dc.identifier`, a DOI link).
    /// Recorded under every address the page was reached by — the one asked
    /// for and the one that answered, when a redirect made them differ — so
    /// the toolbar over that page, and a chat link to that address, can find
    /// the saved copy. The head is scanned off the main actor; a page that
    /// declares no DOI leaves no record, and a redeclaration replaces the old.
    func notePageDeclaredIdentity(pageURLs: [URL], headHTML: String) async {
        let keys = Set(pageURLs.compactMap { url -> String? in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return SourceDiscovery.normalizedURL(url.absoluteString)
        })
        guard !keys.isEmpty, !headHTML.isEmpty else { return }
        let finalURL = pageURLs.first?.absoluteString
        let doi = await Task.detached(priority: .utility) {
            PaperService.extractPaperPageMetadata(from: headHTML, url: finalURL)?.doi
        }.value
        guard let doi, !doi.isEmpty else { return }
        for key in keys where pageDeclaredDOIs[key] != doi {
            pageDeclaredDOIs[key] = doi
        }
    }

    /// Every library source's normalized URL plus, for every paper with a DOI,
    /// its `doi:` key — each mapped to the source's id — built once per
    /// articles revision. A preprint's published DOI is not a key: the journal
    /// version is its own paper (`paperDedupDisplayKeys`).
    private var libraryIdentityKeys: [String: String] {
        let revision = articlesRevision
        if sidebarStore.libraryURLKeysCacheKey == revision,
           let cached = sidebarStore.libraryURLKeysCache {
            return cached
        }
        var keys: [String: String] = [:]
        keys.reserveCapacity(articles.count * 2)
        for article in articles {
            let urlKey = SourceDiscovery.normalizedURL(article.url)
            if keys[urlKey] == nil { keys[urlKey] = article.id }
            guard article.sourceType == .paper else { continue }
            if let doi = article.doi ?? PaperService.extractDOI(from: article.url) {
                let doiKey = Self.libraryDOIKey(doi)
                if keys[doiKey] == nil { keys[doiKey] = article.id }
            }
        }
        // A saved preprint's resolved published DOI is deliberately not a key
        // here: the journal version is its own paper, and a link to it must
        // offer Add to Sources rather than answer as the preprint already held.
        sidebarStore.libraryURLKeysCache = keys
        sidebarStore.libraryURLKeysCacheKey = revision
        sidebarStore.libraryURLKeysBuilds &+= 1
        return keys
    }

    /// The key a DOI takes in `libraryIdentityKeys`: the same `doi:` namespace
    /// and normalization as the paper dedup keys, so a preprint's version
    /// suffix and a publisher's letter case never split one paper in two.
    private static func libraryDOIKey(_ doi: String) -> String {
        "doi:\(normalizeDOI(doi))"
    }

    /// Count for the Papers-tab "waiting for iCloud" indicator. Non-zero only
    /// while the storage-degraded threshold is tripped.
    var unavailableRecordedPDFCount: Int {
        unavailableRecordedPaperPDFIDs.count
    }

    /// PDF availability exactly as the paper partitions see it, for the row's own
    /// status label and recovery button.
    ///
    /// A row must not answer this from `cachedHasUsablePDF` alone. While the
    /// library is storage-degraded — a fresh Mac whose files have not arrived
    /// yet — every recorded PDF counts as present, and a row that disagreed
    /// labelled a paper "PDF needed" that the attention list had actually
    /// surfaced for its missing metadata attestation, then offered "Choose PDF"
    /// as the fix for a file sitting on the other Mac.
    func displayHasUsablePDF(_ article: StudioArticle) -> Bool {
        article.cachedHasUsablePDF || unavailableRecordedPaperPDFIDs.contains(article.id)
    }

    /// Dedup keys of every paper in `articles` that already has a resolved PDF,
    /// or whose recorded PDF is temporarily unavailable at storage level.
    /// A no-PDF paper whose keys intersect this set is a duplicate of one we
    /// already have and is hidden from the visible "needs attention" list by
    /// `paperItems(hasPDF:)`. Auto-fetch reuses this so it never counts or tries
    /// to download a paper the user can't see in that list. `nonisolated` so the
    /// stat-heavy `resolvedPDFPath` scan runs off the main actor over a snapshot.
    nonisolated static func paperDedupKeysForPapersWithPDF(in articles: [StudioArticle]) -> Set<String> {
        let unavailable = unavailableRecordedPaperPDFIDs(in: articles)
        return Set(
            articles
                .filter { $0.sourceType == .paper && ($0.resolvedPDFPath != nil || unavailable.contains($0.id)) }
                .flatMap { paperDedupDisplayKeys(for: $0) }
        )
    }

    /// Where a paper stands among its own versions: the preprint a server
    /// posted, the journal's version of record, or a paper that says neither.
    enum PaperVersionKind: Sendable {
        case preprint
        case journal
        case unknown
    }

    /// A paper's place among its versions, from what the row already records. A
    /// resolved published DOI (that is not its own) says the paper is a preprint
    /// that was published; so do a preprint server's address, venue and DOI
    /// prefix. A journal DOI or a real journal name says the version of record.
    nonisolated static func paperVersionKind(of article: StudioArticle) -> PaperVersionKind {
        guard article.sourceType == .paper else { return .unknown }
        let ownDOI = (article.doi ?? PaperService.extractDOI(from: article.url)).map(normalizeDOI)
        if let published = article.publishedDOI?.trimmingCharacters(in: .whitespacesAndNewlines),
           !published.isEmpty, normalizeDOI(published) != ownDOI {
            return .preprint
        }
        if PaperService.isPreprintPaper(url: article.url, journal: article.journal) { return .preprint }
        if let ownDOI {
            return PaperService.isPreprintDOI(ownDOI) ? .preprint : .journal
        }
        if let journal = article.normalizedJournal, journal != StudioArticle.unknownPaperJournal {
            return .journal
        }
        return .unknown
    }

    /// The keys under which two paper rows are one paper.
    ///
    /// A preprint and its journal version are two versions of one work, not one
    /// paper twice: each stays its own row, with the notebooks, highlights and
    /// chats made against its own text. So they share no key — the published DOI
    /// resolved for a preprint is a link between the rows, not an identity, and
    /// the title key is split by version so a preprint never meets the journal
    /// record. A paper that says neither (no journal, no DOI) meets both, as it
    /// always did.
    ///
    /// A title is evidence only while the DOIs do not contradict it. Two papers
    /// with different DOIs are two papers whatever they are called: a Nature
    /// Reviews Methods Primer and its one-page PrimeView share their title
    /// exactly, and the title key once archived the Primer as the PrimeView's
    /// duplicate. So the title keys are asymmetric: these are the keys a paper
    /// is found by, and `paperDedupLookupKeys(for:)` the keys it looks for. A
    /// paper with a DOI is found under `doi:<its DOI>` and `any`, and looks under
    /// `doi:<its DOI>` and `nodoi`; a paper without one is found under `nodoi`
    /// and `any`, and looks under `any`. Same DOI, or a DOI on one side only,
    /// meets; two different DOIs never do. Compare two papers with
    /// `paperDedupKeysMatch`, never by intersecting these keys with each other.
    nonisolated static func paperDedupDisplayKeys(for article: StudioArticle) -> [String] {
        paperIdentityKeys(for: article, lookingUp: false)
    }

    /// The keys a paper looks for among other papers' `paperDedupDisplayKeys`.
    nonisolated static func paperDedupLookupKeys(for article: StudioArticle) -> [String] {
        paperIdentityKeys(for: article, lookingUp: true)
    }

    /// Whether two paper rows are one paper by a deterministic identity key.
    /// Symmetric: the title keys' asymmetry cancels out across the pair.
    nonisolated static func paperDedupKeysMatch(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        !Set(paperDedupLookupKeys(for: lhs)).isDisjoint(with: paperDedupDisplayKeys(for: rhs))
    }

    /// A paper's DOI for identity, from its record or its address, normalized.
    nonisolated static func paperIdentityDOI(of article: StudioArticle) -> String? {
        let recorded = article.doi?.trimmingCharacters(in: .whitespacesAndNewlines)
        let doi = recorded?.isEmpty == false ? recorded : PaperService.extractDOI(from: article.url)
        return doi.map(normalizeDOI).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Two papers whose DOIs are both known and differ are two papers, whatever
    /// their titles say. Title-based matching everywhere asks this first.
    nonisolated static func paperDOIsContradict(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return normalizeDOI(lhs) != normalizeDOI(rhs)
    }

    private nonisolated static func paperIdentityKeys(for article: StudioArticle, lookingUp: Bool) -> [String] {
        guard article.sourceType == .paper else { return [] }
        var keys: [String] = []
        let doi = paperIdentityDOI(of: article)
        if let doi {
            keys.append("doi:\(doi)")
        }
        if let publisherKey = paperPublisherIdentityKey(for: article.url) {
            keys.append(publisherKey)
        }
        if article.isPaperReadyForListenPreparation,
           let contentSHA256 = article.paperContentSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contentSHA256.isEmpty {
            keys.append("content-sha256:\(contentSHA256.lowercased())")
        }
        let normalizedTitle = normalizedPaperTitle(article.title)
        if !normalizedTitle.isEmpty,
           !titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
            let versions: [String]
            switch paperVersionKind(of: article) {
            case .preprint: versions = ["preprint"]
            case .journal: versions = ["journal"]
            case .unknown: versions = ["preprint", "journal"]
            }
            let doiTags: [String]
            switch (doi, lookingUp) {
            case (let doi?, false): doiTags = ["doi:\(doi)", "any"]
            case (let doi?, true): doiTags = ["doi:\(doi)", "nodoi"]
            case (nil, false): doiTags = ["nodoi", "any"]
            case (nil, true): doiTags = ["any"]
            }
            for version in versions {
                for doiTag in doiTags {
                    keys.append("title:\(normalizedTitle)#\(version)#\(doiTag)")
                }
            }
        }
        return keys
    }

}
