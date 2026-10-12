import Foundation
import Testing
@testable import ForeverLM

/// Build 210's stalls (2026-10-11) spent most of their app time rebuilding the
/// Library list's derived state on every read: the Papers lists re-parsed every
/// paper in the library (406 samples), the search re-folded every source's
/// fields (215), and the notebook lists were rebuilt for every row that asked.
/// Each is memoized now. These pin the one property that matters: what a memo
/// returns is what a fresh build returns, across the changes that must
/// invalidate it — a keystroke, a tab switch, Show More, a paper some task
/// takes up, a source edited, a PDF found missing with no source changing.
@Suite("Library list derived-state memos")
@MainActor
struct SidebarDerivedStateCacheTests {

    // MARK: - Fixtures

    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarDerivedStateCacheTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func paper(_ url: String, _ title: String, doi: String? = nil, pdf: String? = nil) -> StudioArticle {
        var paper = StudioArticle(url: url, title: title, sourceType: .paper)
        paper.state = .ready
        paper.doi = doi
        paper.localFilePath = pdf
        return paper
    }

    /// Metadata attested and text cleaned, as a paper the pipeline finished.
    private func markReady(_ paper: inout StudioArticle) {
        paper.author = paper.author ?? "Zara Holt"
        paper.journal = paper.journal ?? "Journal of Acme Lab"
        paper.publishedYear = paper.publishedYear ?? "2026"
        let clean = "Canonical text for \(paper.id)."
        let raw = "Header\n\n\(clean)\n\nReferences"
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        _ = paper.completePaperMetadataExtractionAfterLLM()
        paper.paperListenableContentReady = true
    }

    /// Stats the paths off the main actor, as the app's background warm does.
    private func warm(_ paths: [String]) async {
        await Task.detached(priority: .utility) {
            for path in paths { _ = StudioArticle.resolvedLocalPath(forRawPath: path) }
        }.value
    }

    private func makePDF() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-memo-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        return url.path
    }

    // MARK: - The Papers lists, built as they were before the memo

    struct Partition: Equatable {
        var processing: [String]
        var attention: [String]
        var withPDF: [String]
        var paywalled: [String]
    }

    /// `papersPartition` as the code before the memo computed it: the
    /// whole-library sets rebuilt from the library on the spot, the filtered
    /// list built afresh.
    private func referencePartition(_ vm: StudioViewModel) -> Partition {
        let library = vm.articles
        let unavailable = StudioViewModel.cachedUnavailableRecordedPaperPDFIDs(in: library)
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        let superseded = StudioViewModel.supersededPreprintIDs(in: library, hasUsablePDF: hasUsablePDF)
        let keysWithPDF = Set(
            library.filter { $0.sourceType == .paper && hasUsablePDF($0) }
                .flatMap { StudioViewModel.paperDedupDisplayKeys(for: $0) }
        )
        let base = vm.computeFilteredActiveItems()
        let withPDFItems = base.filter { hasUsablePDF($0) && !superseded.contains($0.id) }
        let missingItems = base.filter { paper in
            guard !hasUsablePDF(paper), !superseded.contains(paper.id) else { return false }
            return keysWithPDF.isDisjoint(with: StudioViewModel.paperDedupDisplayKeys(for: paper))
        }
        let processingIDs = vm.processingPaperIDs
        let missingIDs = Set(missingItems.map(\.id))
        let partitioned = missingIDs.union(withPDFItems.map(\.id))
        return Partition(
            processing: processingIDs.isEmpty ? [] : base.filter {
                $0.sourceType == .paper && processingIDs.contains($0.id)
            }.map(\.id),
            attention: base.filter {
                $0.sourceType == .paper
                    && !$0.hasPaywallMarker
                    && !processingIDs.contains($0.id)
                    && $0.state != .fetching
                    && partitioned.contains($0.id)
                    && (missingIDs.contains($0.id) || $0.state == .error || !$0.hasPaperIngestionAttestation)
            }.map(\.id),
            withPDF: withPDFItems.filter {
                !processingIDs.contains($0.id) && $0.state != .error && $0.hasPaperIngestionAttestation
            }.map(\.id),
            paywalled: missingItems.filter { $0.hasPaywallMarker && !processingIDs.contains($0.id) }.map(\.id)
        )
    }

    private func memoized(_ vm: StudioViewModel) -> Partition {
        Partition(
            processing: vm.filteredProcessingPapers.map(\.id),
            attention: vm.papersNeedingPDFAttention.map(\.id),
            withPDF: vm.filteredPapersWithPDF.map(\.id),
            paywalled: vm.filteredPaywalledPapersWithoutPDF.map(\.id)
        )
    }

    /// Every Papers-tab read a render makes, against the reference.
    private func expectPapersTabMatchesReference(_ vm: StudioViewModel, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let reference = referencePartition(vm)
        // Read twice: the second read is the memo's.
        #expect(memoized(vm) == reference, Comment(rawValue: step), sourceLocation: sourceLocation)
        #expect(memoized(vm) == reference, Comment(rawValue: step + " (memo)"), sourceLocation: sourceLocation)
        let rows = reference.processing
            + reference.attention.prefix(vm.papersWithoutPDFDisplayLimit)
            + reference.withPDF.prefix(vm.papersWithPDFDisplayLimit)
            + reference.paywalled.prefix(vm.paywalledPapersDisplayLimit)
        #expect(vm.activeTabArticles.map(\.id) == Array(rows), Comment(rawValue: step), sourceLocation: sourceLocation)
        #expect(vm.activeTabArticles.map(\.id) == vm.computeActiveTabArticles().map(\.id), Comment(rawValue: step), sourceLocation: sourceLocation)
        #expect(vm.visibleSidebarSourceIDs == Set(rows), Comment(rawValue: step), sourceLocation: sourceLocation)
        #expect(vm.activePapersWithoutPDFTotalCount == reference.attention.count, Comment(rawValue: step), sourceLocation: sourceLocation)
        #expect(vm.hasMorePapersWithoutPDF == (reference.attention.count > vm.papersWithoutPDFDisplayLimit), Comment(rawValue: step), sourceLocation: sourceLocation)
    }

    @Test("The Papers lists from the memo equal a fresh build across keystrokes, tabs, Show More, tasks, edits and PDFs going missing")
    func papersListsMatchAFreshBuild() async throws {
        let vm = makeViewModel()
        let journalPDF = try makePDF()
        let goingMissingPDF = try makePDF()
        let unattestedPDF = try makePDF()
        let neverThere = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-memo-missing-\(UUID().uuidString).pdf").path
        defer {
            for path in [journalPDF, goingMissingPDF, unattestedPDF] { try? FileManager.default.removeItem(atPath: path) }
        }
        await warm([journalPDF, goingMissingPDF, unattestedPDF, neverThere])

        var journal = paper("https://www.example.org/articles/fission-2026", "Mitochondrial fission in ageing muscle", doi: "10.5555/acme.2026.1", pdf: journalPDF)
        markReady(&journal)
        // Its preprint, superseded by the journal version with a PDF.
        var preprint = paper("https://www.biorxiv.org/content/10.1101/2025.01.01.000001v1", "Mitochondrial fission in ageing muscle (preprint)")
        preprint.publishedDOI = "10.5555/acme.2026.1"
        // The journal paper again, by DOI, without a PDF: suppressed as a twin.
        let twin = paper("https://doi.org/10.5555/acme.2026.1", "Mitochondrial fission in ageing muscle", doi: "10.5555/acme.2026.1")
        let missing = paper("https://www.example.org/articles/ketones", "Ketone bodies as signalling molecules")
        var paywalled = paper("https://www.example.org/articles/paywalled", "Paywalled mitochondria review")
        paywalled.isPaywalled = true
        var fetching = paper("https://www.example.org/articles/fetching", "A paper still downloading")
        fetching.state = .fetching
        var goingMissing = paper("https://www.example.org/articles/going", "Mitochondrial DNA copy number", pdf: goingMissingPDF)
        markReady(&goingMissing)
        let unattested = paper("https://www.example.org/articles/unattested", "A paper without its metadata", pdf: unattestedPDF)
        var failed = paper("https://www.example.org/articles/failed", "A paper whose PDF failed", pdf: neverThere)
        failed.state = .error
        let article = StudioArticle(url: "https://example.org/news", title: "Mitochondria in the news", sourceType: .article)
        let fillers = (0..<55).map { paper("https://www.example.org/filler/\($0)", "Filler paper \($0) on muscle") }

        vm.articles = [journal, preprint, twin, missing, paywalled, fetching, goingMissing, unattested, failed, article] + fillers
        vm.sidebarTab = .papers
        expectPapersTabMatchesReference(vm, "first render")
        #expect(vm.filteredPapersWithPDF.map(\.id).contains(journal.id))
        #expect(!vm.papersNeedingPDFAttention.map(\.id).contains(preprint.id), "the preprint is listed as its journal version")
        #expect(!vm.papersNeedingPDFAttention.map(\.id).contains(twin.id), "the twin is suppressed")

        for query in ["mito", "mitochondrial fission", "muscle", "", "title:ketone", "Zara Holt"] {
            vm.searchText = query
            expectPapersTabMatchesReference(vm, "search \(query)")
        }

        // A keystroke reuses the library's share: plant a mark in it, type,
        // and find the mark still there (unless another test moved the
        // process-wide path cache meanwhile, which rightly rebuilds it).
        let generation = StudioArticle.resolvedPathCacheGeneration
        let share = vm.paperLibraryIndex
        vm.paperLibraryIndexCache = StudioViewModel.PaperLibraryIndex(
            key: share.key, superseded: share.superseded, keysWithPDF: share.keysWithPDF.union(["mark"])
        )
        vm.searchText = "ageing"
        _ = vm.papersNeedingPDFAttention
        if StudioArticle.resolvedPathCacheGeneration == generation {
            #expect(vm.paperLibraryIndexCache?.keysWithPDF.contains("mark") == true)
        }
        vm.paperLibraryIndexCache = nil
        vm.searchText = ""

        vm.papersWithoutPDFDisplayLimit = 10
        expectPapersTabMatchesReference(vm, "Show More, smaller page")
        vm.papersWithoutPDFDisplayLimit = 50
        vm.papersWithPDFDisplayLimit = 1
        expectPapersTabMatchesReference(vm, "Show More, other section")

        vm.resolvingPaperPDFIds.insert(missing.id)
        expectPapersTabMatchesReference(vm, "a task takes a paper up")
        #expect(vm.filteredProcessingPapers.map(\.id) == [missing.id])
        vm.resolvingPaperPDFIds.remove(missing.id)
        expectPapersTabMatchesReference(vm, "the task lets it go")

        // A source edited: the preprint loses its published DOI and its title
        // no longer names the journal version, so it is listed again.
        let index = try #require(vm.articles.firstIndex { $0.id == preprint.id })
        vm.articles[index].publishedDOI = nil
        vm.articles[index].title = "An unrelated preprint"
        expectPapersTabMatchesReference(vm, "a paper edited")
        #expect(vm.papersNeedingPDFAttention.map(\.id).contains(preprint.id))

        // A PDF found missing with no source changing: the path cache alone
        // moves, as the background warm finds it.
        #expect(vm.filteredPapersWithPDF.map(\.id).contains(goingMissing.id))
        try FileManager.default.removeItem(atPath: goingMissingPDF)
        StudioArticle.invalidateResolvedPathCache(forRawPaths: [goingMissingPDF])
        await warm([goingMissingPDF])
        expectPapersTabMatchesReference(vm, "a PDF gone missing")
        #expect(vm.papersNeedingPDFAttention.map(\.id).contains(goingMissing.id))

        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.map(\.id) == vm.computeActiveTabArticles().map(\.id))
        vm.sidebarTab = .papers
        expectPapersTabMatchesReference(vm, "back from another tab")

        vm.invalidateFilteredSidebarCache()
        expectPapersTabMatchesReference(vm, "after the sidebar invalidation")

        vm.articles.removeAll { $0.id == journal.id }
        expectPapersTabMatchesReference(vm, "a paper deleted")
        #expect(vm.paperListingFactsByID[journal.id] == nil, "the deleted paper's facts are dropped")
    }

    @Test("Each tab's rows from the memo equal a fresh build across Show More, edits and the invalidation")
    func otherTabsMatchAFreshBuild() {
        let vm = makeViewModel()
        let articles = (0..<60).map {
            StudioArticle(url: "https://example.org/a/\($0)", title: "Article \($0) about sleep", sourceType: .article)
        }
        var podcasts = (0..<50).map {
            StudioArticle(url: "https://example.org/p/\($0)", title: "Episode \($0)", sourceType: .podcast)
        }
        podcasts[3].state = .fetching
        podcasts[7].state = .queued
        vm.articles = articles + podcasts

        for tab in [StudioSidebarTab.articles, .podcasts] {
            vm.sidebarTab = tab
            #expect(vm.activeTabArticles.map(\.id) == vm.computeActiveTabArticles().map(\.id), Comment(rawValue: "\(tab)"))
            vm.showMore()
            #expect(vm.activeTabArticles.map(\.id) == vm.computeActiveTabArticles().map(\.id), Comment(rawValue: "\(tab) Show More"))
            #expect(vm.visibleSidebarSourceIDs == Set(vm.computeActiveTabArticles().map(\.id)))
            vm.searchText = "1"
            #expect(vm.activeTabArticles.map(\.id) == vm.computeActiveTabArticles().map(\.id), Comment(rawValue: "\(tab) search"))
            vm.searchText = ""
        }

        vm.sidebarTab = .podcasts
        let before = vm.activeTabArticles.map(\.id)
        let index = vm.articles.firstIndex { $0.id == podcasts[3].id }!
        vm.articles[index].state = .ready
        let after = vm.activeTabArticles.map(\.id)
        #expect(after == vm.computeActiveTabArticles().map(\.id))
        #expect(after != before, "the episode leaves Processing")

        vm.invalidateFilteredSidebarCache()
        #expect(vm.sidebarStore.activeTabListingCache == nil)
        #expect(vm.activeTabArticles.map(\.id) == vm.computeActiveTabArticles().map(\.id))
    }

    // MARK: - Search

    @Test("The analysed search answers as the field-by-field search for every source and query")
    func analysedSearchMatchesFieldByField() {
        let vm = makeViewModel()
        var gdf = StudioArticle(url: "https://www.example.org/gdf15", title: "GDF-15 as a biomarker of mitochondrial disease", sourceType: .paper)
        gdf.author = "Zara Holt, Ana Ferrer Vidal"
        gdf.journal = "Acme Journal of Medicine"
        gdf.publishedYear = "2024"
        gdf.doi = "10.5555/acme.gdf15"
        var cafe = StudioArticle(url: "https://example.org/cafe", title: "Café culture and naïve résumés", sourceType: .article)
        cafe.author = "Zoë Lindqvist"
        let decomposed = StudioArticle(url: "https://example.org/decomposed", title: "Cafe\u{301} decomposed and e\u{301}lan", sourceType: .article)
        let greek = StudioArticle(url: "https://example.org/greek", title: "Το μιτοχόνδριο και ΑΤΡ", sourceType: .article)
        let lines = StudioArticle(url: "https://example.org/lines", title: "Two\r\nlines\tand   spaces", sourceType: .article)
        var chapter = StudioArticle(url: "/tmp/book/Chapters/ch1.txt", title: "Chapter 1", sourceType: .book, parentGroup: "The Living Current")
        chapter.author = "Ida Marsh"
        let emoji = StudioArticle(url: "https://example.org/emoji", title: "Cells 🧬 and flags 🇳🇱", sourceType: .article)
        let sources = [gdf, cafe, decomposed, greek, lines, chapter, emoji]
        let queries = [
            "gdf15", "GDF-15", "gdf 15", "gdf15 biomarker", "biomarker gdf", "ferrer vidal", "holt vidal", "vidal",
            "café", "cafe", "CAFÉ", "e\u{301}lan", "élan", "naive", "naïve résumé", "lindqvist", "zoë",
            "μιτοχόνδριο", "ατρ", "two lines", "lines and", "\r\n", "living current", "marsh",
            "2024", "10.5555", "example.org", "🧬", "🇳🇱", "flags 🇳🇱", "  ", "", "a", "zz",
            "title:gdf", "author:vidal", "journal:acme", "doi:gdf15", "site:example", "year:2024", "title:",
        ]
        for query in queries {
            for source in sources {
                let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                for asked in [query, lowered] {
                    #expect(
                        vm.sourceMatchesSearch(source, query: asked)
                            == StudioViewModel.sourceMatchesSearchAnalysingFields(source, query: asked),
                        Comment(rawValue: "\(source.title) / \(asked)")
                    )
                }
            }
        }

        // An edited source is analysed again: the old title stops matching.
        #expect(vm.sourceMatchesSearch(gdf, query: "biomarker"))
        var renamed = gdf
        renamed.title = "Growth differentiation factor in disease"
        #expect(!vm.sourceMatchesSearch(renamed, query: "biomarker"))
        #expect(vm.sourceMatchesSearch(renamed, query: "differentiation"))
    }

    @Test("A byte search finds what String.contains finds in plain ASCII, and is not used for anything else")
    func plainASCIIByteSearchAgreesWithContains() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abc -.\t\n")
        for _ in 0..<4_000 {
            let hay = String((0..<Int.random(in: 0...12, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let pin = String((0..<Int.random(in: 0...4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let text = StudioViewModel.SidebarSearchText(hay)
            let needle = StudioViewModel.SidebarSearchText(pin)
            #expect(text.isPlainASCII && needle.isPlainASCII)
            #expect(text.contains(needle) == hay.contains(pin), Comment(rawValue: "\(hay.debugDescription) / \(pin.debugDescription)"))
        }
        #expect(!StudioViewModel.SidebarSearchText("a\r\nb").isPlainASCII)
        #expect(!StudioViewModel.SidebarSearchText("café").isPlainASCII)
        #expect(StudioViewModel.SidebarSearchText("cafe\u{301}").contains(.init("cafe")) == "cafe\u{301}".contains("cafe"))
    }

    // MARK: - Notebooks

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func notebook(_ id: String, _ title: String, archived: Bool = false) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id, title: title, startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now, updatedAt: now,
            status: (archived ? LearningGoalStatus.archived : .active).rawValue,
            items: [], kind: LearningGoalRecord.companionKind
        )
    }

    private static func goal(_ id: String, in notebookID: String) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id, title: "Goal \(id)", startAt: now, endAt: now.addingTimeInterval(86_400 * 30),
            createdAt: now, updatedAt: now, status: LearningGoalStatus.active.rawValue,
            items: [], kind: LearningGoalRecord.companionKind, parentNotebookID: notebookID
        )
    }

    /// The notebook lists as the code before the memo computed them.
    private func referenceLists(_ vm: StudioViewModel) -> (all: [String], active: [String], archived: [String]) {
        let all = vm.learningGoals.filter { goal in
            goal.isNotebook && goal.teamID == vm.activeTeamID
                && (vm.screenRecordScope?.allowsNotebook(id: goal.id, createdAt: goal.createdAt) ?? true)
        }
        return (
            all.map(\.id),
            vm.orderedNotebooks(all.filter { !$0.isArchived }).map(\.id),
            vm.orderedNotebooks(all.filter(\.isArchived)).map(\.id)
        )
    }

    private func expectNotebookListsMatchReference(_ vm: StudioViewModel, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let reference = referenceLists(vm)
        for _ in 0..<2 {
            #expect(vm.allNotebooks.map(\.id) == reference.all, Comment(rawValue: step), sourceLocation: sourceLocation)
            #expect(vm.notebooks.map(\.id) == reference.active, Comment(rawValue: step), sourceLocation: sourceLocation)
            #expect(vm.archivedNotebooks.map(\.id) == reference.archived, Comment(rawValue: step), sourceLocation: sourceLocation)
        }
        let goalParents = vm.learningGoals.reduce(into: [String: String]()) { result, goal in
            if goal.isGoal, let parent = goal.parentNotebookID, !parent.isEmpty { result[goal.id] = parent }
        }
        #expect(vm.notebookHoldingContext.notebookIDs == Set(reference.active), Comment(rawValue: step), sourceLocation: sourceLocation)
        #expect(vm.notebookHoldingContext.goalParents == goalParents, Comment(rawValue: step), sourceLocation: sourceLocation)
    }

    @Test("The notebook lists from the memo equal a fresh build as notebooks are added, archived, renamed and reordered")
    func notebookListsMatchAFreshBuild() {
        let orderKey = "studio.projectOrder"
        let savedOrder = UserDefaults.standard.object(forKey: orderKey)
        defer {
            if let savedOrder { UserDefaults.standard.set(savedOrder, forKey: orderKey) } else { UserDefaults.standard.removeObject(forKey: orderKey) }
        }
        let vm = makeViewModel()
        vm.learningGoals = [Self.notebook("nb-a", "Ageing"), Self.notebook("nb-b", "Sleep"), Self.goal("g-1", in: "nb-a")]
        expectNotebookListsMatchReference(vm, "first read")

        vm.learningGoals.append(Self.notebook("nb-c", "Ketones"))
        expectNotebookListsMatchReference(vm, "a notebook added")

        let index = vm.learningGoals.firstIndex { $0.id == "nb-b" }!
        vm.learningGoals[index].status = LearningGoalStatus.archived.rawValue
        expectNotebookListsMatchReference(vm, "a notebook archived in place")
        #expect(vm.archivedNotebooks.map(\.id) == ["nb-b"])

        vm.learningGoals[0].title = "Ageing, renamed"
        expectNotebookListsMatchReference(vm, "a notebook renamed in place")
        #expect(vm.notebooks.first { $0.id == "nb-a" }?.title == "Ageing, renamed")

        vm.notebookOrder = ["nb-c", "nb-a", "nb-b"]
        expectNotebookListsMatchReference(vm, "reordered")
        #expect(vm.notebooks.map(\.id) == ["nb-c", "nb-a"])

        vm.learningGoals.append(Self.goal("g-2", in: "nb-c"))
        expectNotebookListsMatchReference(vm, "a goal added")

        vm.learningGoals.removeAll { $0.id == "nb-a" }
        expectNotebookListsMatchReference(vm, "a notebook deleted")
    }
}
