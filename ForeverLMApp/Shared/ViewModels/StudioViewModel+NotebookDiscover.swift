import Foundation
import Observation

// MARK: - Discover, in a notebook's Add sources
//
// Two searches list works a notebook is missing, to tick and import:
// - Web: one web search with the notebook as context (`WebSourceDiscovery`,
//   the `source_discovery` task on the chat's model). Paid, so Return runs
//   it, never a keystroke.
// - Papers: PubMed through `LiteratureSearch`, with no model and no cost.
// Whether the library or the notebook already holds a work is read off the
// library's own lookups (`librarySourceID(forURL:)`: address, then DOI), never
// off the model. Importing goes through one seam, `importDiscovered`, onto the
// library's one import (`addArticle`: a paper needs its PDF, and one behind a
// paywall lands as PDF needed) and the notebook's one membership write
// (`addSourcesToNotebookContext`), and ends with one toast for the lot. A list
// lives in memory only, one per notebook, so it survives the sheet closing: ↗
// opens a page in the window and the learner comes back to the same list.
// Nothing is saved but imports.

/// What Discover's import did with one address.
enum DiscoveredImport: Equatable, Sendable {
    /// New to the library, and now in the notebook.
    case added(sourceID: String)
    /// The library held it already; now the notebook does too.
    case filed(sourceID: String)
    /// The notebook held it already.
    case alreadyInNotebook(sourceID: String)
    /// Nothing was written: the address is never a source here
    /// (`WebSourceDiscovery.setAsideReason`), the notebook cannot take it, or
    /// the import failed. Discover never lists a page ForeverLM links rather
    /// than imports, so there is no linked outcome.
    case failed(String)

    var sourceID: String? {
        switch self {
        case .added(let id), .filed(let id), .alreadyInNotebook(let id): return id
        case .failed: return nil
        }
    }

    /// The notebook holds the work now.
    var landed: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// One work Discover lists, from the web or from PubMed.
struct NotebookDiscoveryRow: Identifiable, Equatable, Sendable {
    /// Where the library and the notebook stand on the work.
    enum Holding: Equatable, Sendable {
        case new
        case inLibrary(sourceID: String)
        case inNotebook(sourceID: String)

        var sourceID: String? {
            switch self {
            case .new: return nil
            case .inLibrary(let id), .inNotebook(let id): return id
            }
        }
    }

    enum ImportState: Equatable, Sendable {
        /// Ticked and waiting its turn in the import under way.
        case waiting
        case importing
        case done(DiscoveredImport)
    }

    /// The normalized address: one row per page.
    let id: String
    let url: String
    var title: String
    let kind: VideoCitedPaper.Kind
    /// How a web row's address was confirmed; nil for a PubMed row. A row
    /// Crossref named keeps Crossref's title, and one whose page was opened
    /// already carries the page's own; a cited row takes the page's title
    /// from its preview.
    var confirmedBy: WebSourceCandidate.Confirmation?
    /// The host without `www.`.
    let site: String
    /// When the work appeared, as the page gives it (web rows).
    var published: String?
    /// "Authors · Journal · Year" (PubMed rows).
    var byline: String?
    /// One line on why it fits the notebook (web rows).
    var why: String?
    /// PubMed's abstract, drawn clamped (PubMed rows). Nothing is stored.
    var abstract: String?
    var isReview = false
    var isPreprint = false
    var isFreeFullText = false
    var holding: Holding = .new
    var importState: ImportState?

    /// Whether the row has a box to tick: a work the notebook does not hold
    /// yet and that is not being imported or already in.
    var isTickable: Bool {
        if case .inNotebook = holding { return false }
        switch importState {
        case nil: return true
        case .waiting, .importing: return false
        case .done(let outcome): return !outcome.landed
        }
    }
}

/// Everything Discover reaches outside itself — the chat route's config, the
/// web search, PubMed and the usage ledger — so tests stand in for the
/// network, the model and the ledger. The sheet's session and the MCP tool
/// share it.
struct SourceDiscoveryServices: Sendable {
    /// The chat route's config for Source Discovery; nil when nothing can
    /// run or pay for it.
    var resolveConfig: @MainActor @Sendable () -> AITaskConfig?
    var web: WebSourceDiscovery.Dependencies
    var papers: @Sendable (_ query: String, _ limit: Int) async throws -> LiteratureSearch.Result
    /// What the calls recorded under a run id cost; nil before the ledger
    /// holds any of them.
    var runCost: @Sendable (_ runID: String) async -> Double?

    static func live(aiService: AIService, storage: StorageService) -> SourceDiscoveryServices {
        SourceDiscoveryServices(
            resolveConfig: { KeychainService.resolveConfig(for: .sourceDiscovery) },
            web: .live(aiService: aiService),
            papers: { query, limit in try await LiteratureSearch.search(query: query, limit: limit) },
            runCost: { runID in
                // The usage event is written as the response completes, a
                // moment after the run returns; asked a few times, never polled.
                for attempt in 0..<4 {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
                    if let cost = try? await storage.aiUsageCost(sessionID: runID, before: Date()),
                       cost.eventCount > 0 {
                        return cost.totalUSD
                    }
                }
                return nil
            }
        )
    }
}

/// One notebook's Discover lists, Web and Papers, kept apart so switching
/// between them never throws away a paid search.
@MainActor @Observable
final class NotebookDiscoverySession {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case web
        case papers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .web: return "Web"
            case .papers: return "Papers"
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case searching
        case results
        /// The route cannot search the web (a model whose search ForeverLM
        /// cannot bill): nothing was sent.
        case refused(String)
        case failed(String)
    }

    /// One mode's list.
    struct Listing: Equatable, Sendable {
        var phase: Phase = .idle
        /// What the rows answer: the learner's words, or the notebook's title.
        var query: String?
        /// One sentence on what the works cover together (web).
        var summary: String?
        var rows: [NotebookDiscoveryRow] = []
        var selected: Set<String> = []
        /// Listed by the model but neither cited, known to Crossref, nor
        /// answering, so not shown (web).
        var leftOut = 0
        /// What the search cost, once the ledger has it (web).
        var costUSD: Double?
        /// PubMed's count of every match, beyond the page shown (papers).
        var totalMatches: Int?
    }

    /// Works a Papers search lists.
    static let papersLimit = 20

    let notebookID: String
    var mode: Mode
    var query = ""
    private(set) var listings: [Mode: Listing] = [.web: Listing(), .papers: Listing()]
    private(set) var isImporting = false
    let services: SourceDiscoveryServices
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The list `searchTask` is filling, so stopping it puts that list's
    /// phase back, not the one on screen.
    @ObservationIgnored private var searchTaskMode: Mode?
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(notebookID: String, services: SourceDiscoveryServices, mode: Mode = .web) {
        self.notebookID = notebookID
        self.services = services
        self.mode = mode
    }

    // MARK: One session per notebook

    private static var sessions: [String: NotebookDiscoverySession] = [:]

    /// The notebook's session for the life of the app, made on first use.
    static func session(forNotebook notebookID: String, vm: StudioViewModel) -> NotebookDiscoverySession {
        if let existing = sessions[notebookID] { return existing }
        let session = NotebookDiscoverySession(
            notebookID: notebookID,
            services: .live(aiService: vm.aiService, storage: vm.storage)
        )
        sessions[notebookID] = session
        return session
    }

    // MARK: Reading the list

    var listing: Listing { listings[mode] ?? Listing() }

    var isSearching: Bool { listing.phase == .searching }

    var tickableRows: [NotebookDiscoveryRow] { listing.rows.filter(\.isTickable) }

    /// The ticked rows, in the list's order.
    var selectedRows: [NotebookDiscoveryRow] {
        listing.rows.filter { $0.isTickable && listing.selected.contains($0.id) }
    }

    var selectedCount: Int { selectedRows.count }

    var allTickableSelected: Bool {
        let tickable = tickableRows
        return !tickable.isEmpty && tickable.allSatisfy { listing.selected.contains($0.id) }
    }

    func isSelected(_ row: NotebookDiscoveryRow) -> Bool {
        row.isTickable && listing.selected.contains(row.id)
    }

    // MARK: Ticking

    func setSelected(_ selected: Bool, rowID: String) {
        guard !isImporting else { return }
        update(mode) { listing in
            if selected { listing.selected.insert(rowID) } else { listing.selected.remove(rowID) }
        }
    }

    /// Ticks every row that has a box, or unticks them all when all are ticked.
    func toggleSelectAll() {
        guard !isImporting else { return }
        let ids = Set(tickableRows.map(\.id))
        let tickAll = !allTickableSelected
        update(mode) { listing in
            listing.selected = tickAll ? ids : []
        }
    }

    // MARK: Searching

    /// Runs the current mode's search for `query` (the notebook's own subject
    /// when empty), replacing that mode's list. A search under way is
    /// cancelled first.
    func search(vm: StudioViewModel) {
        guard let notebook = vm.notebook(id: notebookID) else { return }
        stopSearchTask()
        let mode = self.mode
        let rawQuery = query
        let context = vm.discoveryContext(for: notebook)
        update(mode) { $0.phase = .searching }
        searchTaskMode = mode
        searchTask = Task { [weak self] in
            switch mode {
            case .web:
                await self?.runWebSearch(rawQuery, context: context, vm: vm)
            case .papers:
                await self?.runPapersSearch(rawQuery, context: context, vm: vm)
            }
        }
    }

    /// Stops the search under way; the list it would have replaced stays.
    func cancelSearch() {
        stopSearchTask()
    }

    /// Stops the search under way, whichever list it fills, and puts that
    /// list back as it stood: nothing searched, or the results it had.
    private func stopSearchTask() {
        searchTask?.cancel()
        searchTask = nil
        guard let running = searchTaskMode else { return }
        searchTaskMode = nil
        update(running) { listing in
            guard listing.phase == .searching else { return }
            listing.phase = listing.query == nil ? .idle : .results
        }
    }

    /// The web search, refused before any request on a route that cannot
    /// search the web.
    func runWebSearch(_ rawQuery: String, context: NotebookDiscoveryContext, vm: StudioViewModel) async {
        guard let config = services.resolveConfig() else {
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .sourceDiscovery)
                ?? "Discover has no available AI model, or nothing to pay for it. Check your OpenRouter key in Settings › AI Usage."
            update(.web) { $0.phase = .failed(reason) }
            return
        }
        do {
            let result = try await WebSourceDiscovery.run(
                query: rawQuery,
                context: context,
                config: config,
                dependencies: services.web
            )
            guard !Task.isCancelled else { return }
            let rows = result.candidates.map(Self.row(for:))
            update(.web) { listing in
                listing = Listing(
                    phase: .results,
                    query: result.query,
                    summary: result.summary.isEmpty ? nil : result.summary,
                    rows: rows,
                    leftOut: result.leftOut
                )
            }
            refreshHoldings(vm: vm, modes: [.web])
            // Web rows the notebook lacks start ticked: the model chose them for it.
            update(.web) { listing in
                listing.selected = Set(listing.rows.filter(\.isTickable).map(\.id))
            }
            let runID = result.runID
            let cost = await services.runCost(runID)
            update(.web) { listing in
                guard listing.query == result.query else { return }
                listing.costUSD = cost
            }
        } catch let refusal as WebSourceDiscoveryError where refusal.isRefusal {
            update(.web) { $0.phase = .refused(refusal.localizedDescription) }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            update(.web) { $0.phase = .failed(error.localizedDescription) }
        }
    }

    /// PubMed: free. Its failures read as they are, so
    /// "found nothing" and "could not search" stay apart.
    func runPapersSearch(_ rawQuery: String, context: NotebookDiscoveryContext, vm: StudioViewModel) async {
        let query = WebSourceDiscovery.searchQuery(rawQuery, context: context)
        do {
            let result = try await services.papers(query, Self.papersLimit)
            guard !Task.isCancelled else { return }
            let rows = result.works.map(Self.row(for:))
            update(.papers) { listing in
                // PubMed's ranking is raw relevance, not a list chosen for the
                // notebook, so nothing starts ticked.
                listing = Listing(phase: .results, query: query, rows: Self.uniqued(rows), totalMatches: result.hitCount)
            }
            refreshHoldings(vm: vm, modes: [.papers])
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            update(.papers) { $0.phase = .failed(error.localizedDescription) }
        }
    }

    /// Puts the current mode's list away: the search under way stops and the
    /// list goes back to nothing searched, as Gemini's Delete does to its
    /// results card. An import under way is left to finish.
    func dismissListing() {
        guard !isImporting else { return }
        if searchTaskMode == mode {
            searchTask?.cancel()
            searchTask = nil
            searchTaskMode = nil
        }
        update(mode) { $0 = Listing() }
    }

    /// Switches to Papers and searches there with the same words: the way on
    /// from a refused web search.
    func searchPapersInstead(vm: StudioViewModel) {
        mode = .papers
        search(vm: vm)
    }

    // MARK: Marks

    /// Re-reads where the library and the notebook stand on every row. A row
    /// the notebook now holds loses its box and its tick.
    func refreshHoldings(vm: StudioViewModel, modes: [Mode] = Mode.allCases) {
        guard let notebook = vm.notebook(id: notebookID) else { return }
        for mode in modes {
            update(mode) { listing in
                for index in listing.rows.indices {
                    listing.rows[index].holding = vm.discoveryHolding(forURL: listing.rows[index].url, in: notebook)
                }
                let tickable = Set(listing.rows.filter(\.isTickable).map(\.id))
                listing.selected.formIntersection(tickable)
            }
        }
    }

    // MARK: Importing

    /// Imports the ticked rows one at a time, in the list's order, through
    /// `importDiscovered`; each row shows how its own import went, and one
    /// toast sums them up. One at a time because each import's duplicate
    /// checks read the library the one before may just have added to.
    func importSelected(vm: StudioViewModel) {
        guard !isImporting, let notebook = vm.notebook(id: notebookID) else { return }
        let mode = self.mode
        let picked = selectedRows
        guard !picked.isEmpty else { return }
        let notebookID = self.notebookID
        isImporting = true
        update(mode) { listing in
            for index in listing.rows.indices where picked.contains(where: { $0.id == listing.rows[index].id }) {
                listing.rows[index].importState = .waiting
            }
        }
        importTask = Task { [weak self] in
            var outcomes: [DiscoveredImport] = []
            for row in picked {
                if Task.isCancelled { break }
                self?.setImportState(.importing, rowID: row.id, mode: mode)
                let outcome = await vm.importDiscovered(row.url, intoNotebook: notebookID)
                outcomes.append(outcome)
                self?.setImportState(.done(outcome), rowID: row.id, mode: mode)
            }
            guard let self else { return }
            // Rows a cancel left waiting go back to their boxes.
            self.update(mode) { listing in
                for index in listing.rows.indices where listing.rows[index].importState == .waiting {
                    listing.rows[index].importState = nil
                }
            }
            self.isImporting = false
            self.importTask = nil
            self.refreshHoldings(vm: vm)
            vm.showToast(Self.importSummary(outcomes, notebookTitle: notebook.title))
        }
    }

    /// Stops after the row being imported; what landed stays.
    func cancelImport() {
        importTask?.cancel()
    }

    private func setImportState(_ state: NotebookDiscoveryRow.ImportState, rowID: String, mode: Mode) {
        update(mode) { listing in
            guard let index = listing.rows.firstIndex(where: { $0.id == rowID }) else { return }
            listing.rows[index].importState = state
            if case .done(let outcome) = state, outcome.landed {
                listing.selected.remove(rowID)
            }
        }
    }

    /// The one toast an import ends with.
    nonisolated static func importSummary(_ outcomes: [DiscoveredImport], notebookTitle: String) -> String {
        let notebook = "\u{201C}\(notebookTitle)\u{201D}"
        var added = 0
        var already = 0
        var failures: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .added, .filed: added += 1
            case .alreadyInNotebook: already += 1
            case .failed(let reason): failures.append(reason)
            }
        }
        if added == 0, already == 0, failures.count == 1 { return failures[0] }
        var parts: [String] = []
        if added > 0 {
            parts.append("Added \(added) \(added == 1 ? "source" : "sources") to \(notebook)")
        } else if already == 0 {
            parts.append("Nothing was added to \(notebook)")
        }
        if already > 0 {
            parts.append(added == 0
                ? "\(already == 1 ? "It was" : "All \(already) were") already in \(notebook)"
                : "\(already) already there")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) could not be added")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: Rows

    static func row(for candidate: WebSourceCandidate) -> NotebookDiscoveryRow {
        NotebookDiscoveryRow(
            id: candidate.identity,
            url: candidate.url,
            title: candidate.title,
            kind: candidate.kind,
            confirmedBy: candidate.confirmedBy,
            site: candidate.site,
            published: candidate.published,
            why: candidate.why.isEmpty ? nil : candidate.why
        )
    }

    static func row(for work: LiteratureSearch.Work) -> NotebookDiscoveryRow {
        let url = work.url
        let host = URL(string: url)?.host?.lowercased() ?? ""
        let byline = [work.authors, work.journal, work.year.map(String.init)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return NotebookDiscoveryRow(
            id: URLNormalizer.normalize(url),
            url: url,
            title: work.title,
            kind: WebSourceDiscovery.kind(of: url),
            site: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
            byline: byline.isEmpty ? nil : byline,
            abstract: work.abstract,
            isReview: work.isReview,
            isPreprint: work.isPreprint,
            isFreeFullText: work.isFreeFullText
        )
    }

    /// One row per address, first kept.
    private static func uniqued(_ rows: [NotebookDiscoveryRow]) -> [NotebookDiscoveryRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private func update(_ mode: Mode, _ change: (inout Listing) -> Void) {
        var listing = listings[mode] ?? Listing()
        change(&listing)
        listings[mode] = listing
    }
}

extension WebSourceDiscoveryError {
    /// Refused before anything was sent, rather than failed on the way.
    var isRefusal: Bool {
        if case .webSearchOff = self { return true }
        return false
    }
}

// MARK: - The view model's half

extension StudioViewModel {
    /// What Discover's search reads about a notebook: its title, Instructions,
    /// research questions, and one line per source it works from.
    func discoveryContext(for notebook: LearningGoalRecord) -> NotebookDiscoveryContext {
        let lines = discoverySourceIDs(notebook).compactMap { articlesById[$0] }.map { article in
            WebSourceDiscovery.contextLine(
                title: article.title,
                author: article.author,
                kind: Self.discoveryKindWord(article.sourceType),
                year: article.publishedYear
            )
        }
        return NotebookDiscoveryContext(
            // A placeholder ("New notebook 2") says nothing to search for.
            title: NotebookNaming.isPlaceholder(notebook.title) ? "" : notebook.title,
            instructions: notebook.description,
            researchQuestions: notebook.researchQuestions ?? [],
            sources: lines
        )
    }

    /// The sources Discover names as the notebook's: the ticked ones of its
    /// own, as this Mac holds them — the sources every Studio tile works from
    /// (`notebookStudioSourceIDs`), never a related notebook's.
    func discoverySourceIDs(_ notebook: LearningGoalRecord) -> [String] {
        notebookStudioSourceIDs(notebook.id)
    }

    /// Where the library and the notebook stand on an address: by the address
    /// itself, the DOI in it, or the DOI its page declared
    /// (`librarySourceID(forURL:)`). A team notebook holds the team's copies,
    /// which name the learner's own rows (`canonicalSourceID`).
    func discoveryHolding(forURL url: String, in notebook: LearningGoalRecord) -> NotebookDiscoveryRow.Holding {
        guard let sourceID = librarySourceID(forURL: url) else { return .new }
        let canonical = canonicalSourceID(sourceID)
        if notebook.approvedSourceIDs.contains(where: { canonicalSourceID($0) == canonical }) {
            return .inNotebook(sourceID: sourceID)
        }
        return .inLibrary(sourceID: sourceID)
    }

    /// Whether the notebook takes imports from this account: a live notebook
    /// whose team, if it has one, this account may edit.
    func discoveryCanImport(into notebook: LearningGoalRecord) -> Bool {
        guard !notebook.isArchived else { return false }
        if let teamID = notebook.teamID { return team(id: teamID)?.canEdit == true }
        return !isActiveLibraryReadOnly
    }

    /// Discover's one import: an address into the library and the notebook.
    ///
    /// The seam the imports slice's `importLink(_:intoNotebook:)` replaces
    /// once it lands, mapping its `NotebookImportOutcome` onto
    /// `DiscoveredImport`. Until then it takes the same two canonical steps:
    /// the library's import (`addArticle`, which gives a paper the PDF
    /// pipeline, so one behind a paywall lands as PDF needed and is never
    /// read off its page) unless the library holds the address already, by
    /// URL or DOI; then the notebook's membership write, which says nothing:
    /// the import ends with one toast for every row (`importSummary`).
    ///
    /// An address Discover never lists (`WebSourceDiscovery.setAsideReason`)
    /// is refused before anything is written, so this seam never links a
    /// page, imports a whole notebook or playlist, or adds a home page.
    func importDiscovered(_ url: String, intoNotebook notebookID: String) async -> DiscoveredImport {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .failed("There is no address to add.") }
        if let reason = WebSourceDiscovery.setAsideReason(for: address) { return .failed(reason) }
        guard let target = notebook(id: notebookID), !target.isArchived else {
            return .failed("That notebook is no longer here.")
        }
        guard discoveryCanImport(into: target) else {
            return .failed("This notebook is read-only for you.")
        }
        let sourceID: String
        var isNew = false
        if let held = librarySourceID(forURL: address) {
            sourceID = held
        } else {
            let previousError = errorMessage
            do {
                try await addArticle(
                    url: address,
                    revealInReader: false,
                    waitForInitialPaperProcessing: false,
                    reviveArchivedSourceIfNeeded: true
                )
            } catch {
                return .failed(error.localizedDescription)
            }
            // `addArticle` reports a refusal or a duplicate through
            // `errorMessage` rather than throwing, so the library is asked
            // what it holds now.
            let reported = errorMessage != previousError ? errorMessage : nil
            guard let id = librarySourceID(forURL: address)
                ?? existingArticleIndex(matchingSourceURL: address).map({ articles[$0].id }) else {
                return .failed(reported ?? "It could not be added to Sources.")
            }
            sourceID = id
            isNew = !(reported?.localizedCaseInsensitiveContains("already") ?? false)
        }
        let canonical = canonicalSourceID(sourceID)
        if let current = notebook(id: notebookID),
           current.approvedSourceIDs.contains(where: { canonicalSourceID($0) == canonical }) {
            return .alreadyInNotebook(sourceID: sourceID)
        }
        guard await addSourcesToNotebookContext([sourceID], notebookID: notebookID, announce: false) != nil else {
            return .failed("It is in Sources, but could not be added to \u{201C}\(target.title)\u{201D}.")
        }
        return isNew ? .added(sourceID: sourceID) : .filed(sourceID: sourceID)
    }

    /// The word a source's line in Discover's request calls its kind.
    nonisolated static func discoveryKindWord(_ type: StudioSourceType) -> String {
        switch type {
        case .paper: return "paper"
        case .book: return "book"
        case .podcast: return "podcast"
        case .video: return "video"
        case .meeting: return "meeting"
        case .course: return "course"
        case .xPost: return "post"
        case .article, .manual, .unclassified: return "article"
        }
    }
}
