// ArticleQueueManagementTests: processing lists, search, grouping and paging.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

extension ArticleQueueManagementTests {
    @Test("processing podcasts stay above the available episode list")
    func processingPodcastsArePublishedFirst() {
        let vm = makeViewModel()
        let queued = makeArticle(
            url: "apple-podcast://episode/1001",
            title: "Waiting episode",
            sourceType: .podcast,
            state: .queued
        )
        let fetching = makeArticle(
            url: "apple-podcast://episode/1002",
            title: "Active episode",
            sourceType: .podcast,
            state: .fetching
        )
        let queuedNonApple = makeArticle(
            url: "https://example.com/podcast/episode",
            title: "Queued external episode",
            sourceType: .podcast,
            state: .queued
        )
        let ready = makeArticle(
            url: "apple-podcast://episode/1003",
            title: "Ready episode",
            sourceType: .podcast,
            state: .ready
        )
        var failed = makeArticle(
            url: "apple-podcast://episode/1004",
            title: "Failed episode",
            sourceType: .podcast,
            state: .error
        )
        failed.errorMessage = "Transcript failed"

        vm.articles = [ready, failed, fetching, queuedNonApple, queued]
        vm.sidebarTab = .podcasts

        #expect(Set(vm.activeProcessingPodcasts.map(\.id)) == [fetching.id, queuedNonApple.id, queued.id])
        #expect(Set(vm.activePodcastsNotProcessing.map(\.id)) == [ready.id, failed.id])
        #expect(vm.activeProcessingPodcastsTotalCount == 3)
        #expect(Set(vm.activeTabArticles.prefix(3).map(\.id)) == [fetching.id, queuedNonApple.id, queued.id])
    }

    @Test("processing videos include queued, fetching, and formatting work")
    func processingVideosTrackTheWholeTranscriptPipeline() {
        let vm = makeViewModel()
        let queued = makeArticle(
            url: "https://www.youtube.com/watch?v=queued12345",
            title: "Waiting video",
            sourceType: .video,
            state: .queued
        )
        let fetching = makeArticle(
            url: "https://www.youtube.com/watch?v=fetching123",
            title: "Fetching video",
            sourceType: .video,
            state: .fetching
        )
        let formatting = makeArticle(
            url: "https://www.youtube.com/watch?v=format12345",
            title: "Formatting video",
            sourceType: .video,
            state: .ready
        )
        let ready = makeArticle(
            url: "https://www.youtube.com/watch?v=ready123456",
            title: "Ready video",
            sourceType: .video,
            state: .ready
        )

        vm.articles = [ready, formatting, fetching, queued]
        vm.sidebarTab = .videos
        vm.youtubeTranscriptFetchInFlight.insert(formatting.id)

        #expect(Set(vm.activeProcessingVideos.map(\.id)) == [queued.id, fetching.id, formatting.id])
        #expect(vm.activeProcessingVideosTotalCount == 3)
        #expect(!vm.activeProcessingVideos.contains(where: { $0.id == ready.id }))
    }

    @Test("filteredActiveItems respects search text")
    func filteredBySearch() {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://example.com/alpha", title: "Alpha Post", sourceType: .article)
        let a2 = makeArticle(url: "https://example.com/beta", title: "Beta Post", sourceType: .article)
        vm.articles = [a1, a2]
        vm.sidebarTab = .articles
        vm.searchText = "alpha"
        let results = vm.activeTabArticles
        #expect(results.count == 1)
        #expect(results[0].title == "Alpha Post")
    }

    @Test("pruning selection clears book chapter hidden by search")
    func pruneSelectionClearsBookChapterHiddenBySearch() {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/DNA/Chapters/02.xhtml",
            title: "2) Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "dna-book"
        )
        vm.bookTitles = ["dna-book": "DNA"]
        vm.articles = [chapter]
        vm.sidebarTab = .books
        vm.selectedArticleId = chapter.id
        vm.selectedArticleIds = [chapter.id]
        vm.searchText = "gwas"

        vm.pruneSelectionToVisibleSources()

        #expect(vm.visibleSidebarSourceIDs.isEmpty)
        #expect(vm.selectedArticleId == chapter.id)
        #expect(vm.selectedArticleIds.isEmpty)
    }

    @Test("Source search includes persisted book chapter content")
    func sourceSearchIncludesPersistedBookChapterContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BookSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var chapter = makeArticle(
            url: "Books/Aging/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            state: .ready,
            parentGroup: "aging-book"
        )
        chapter.content = "This chapter explains the free radical theory of aging in mitochondrial damage."
        try await service.saveSource(chapter)

        var displayedChapter = chapter
        displayedChapter.content = nil
        let other = makeArticle(url: "https://example.com/unrelated", title: "Unrelated", sourceType: .article)

        let vm = StudioViewModel(storageService: service)
        vm.articles = [other, displayedChapter]
        vm.sourceSearchQuery = "free radical theory of aging"

        await vm.searchSources()

        #expect(vm.sourceSearchResults.map(\.article.id).contains(displayedChapter.id))
    }

    /// The sidebar's own filter reads metadata only, so before this pass existed a
    /// term living in a transcript or a PDF body was unfindable from the one search
    /// field the app has — the learner had to already remember words from the title.
    @Test("Sidebar search surfaces a term that appears only inside a source")
    func sidebarSearchSurfacesBodyOnlyMatch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var paper = makeArticle(
            url: "https://example.com/isr",
            title: "Integrated stress response in human cells and tissues",
            sourceType: .paper
        )
        markPaperFullyReady(
            &paper,
            content: "The cytokine GDF15 rises with mitochondrial stress across human tissues."
        )
        try await service.saveSource(paper)

        var unrelated = makeArticle(
            url: "https://example.com/unrelated",
            title: "Unrelated Paper",
            sourceType: .paper
        )
        markPaperFullyReady(
            &unrelated,
            content: "A paper about protein folding kinetics and nothing else."
        )
        try await service.saveSource(unrelated)

        // The sidebar list holds metadata without bodies, exactly as it renders.
        var displayed = paper
        displayed.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.articles = [unrelated, displayed]
        vm.sidebarTab = .papers
        vm.searchText = "GDF15"

        // Synchronous pass: the term is in neither title, author, journal, nor DOI.
        #expect(!vm.filteredActiveItems.map(\.id).contains(displayed.id))

        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.filteredActiveItems.map(\.id).contains(displayed.id))
        #expect(!vm.filteredActiveItems.map(\.id).contains(unrelated.id))

        // Clearing the field drops the matches rather than stranding them, which
        // would leave the list narrowed to a search that is no longer running.
        vm.searchText = ""
        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs.isEmpty)
        #expect(Set(vm.filteredActiveItems.map(\.id)) == [displayed.id, unrelated.id])
    }

    @Test("Sidebar content search never widens to partial or merely similar matches")
    func sidebarContentSearchStrictlyMatchesEveryTerm() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarStrictSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var exact = makeArticle(
            url: "https://example.com/picard",
            title: "Mitochondrial health",
            sourceType: .podcast
        )
        exact.content = "The guest is Martin Picard, discussing mitochondrial psychobiology."
        try await service.saveSource(exact)

        var partial = makeArticle(
            url: "https://example.com/fowler",
            title: "Software architecture",
            sourceType: .podcast
        )
        partial.content = "The guest is Martin Fowler, discussing software architecture."
        try await service.saveSource(partial)

        var unrelated = makeArticle(
            url: "https://example.com/longevity",
            title: "Longevity roundtable",
            sourceType: .podcast
        )
        unrelated.content = "A conversation about nutrition, sleep, and healthy aging."
        try await service.saveSource(unrelated)

        exact.content = nil
        partial.content = nil
        unrelated.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.articles = [unrelated, partial, exact]
        vm.sidebarTab = .podcasts
        vm.searchText = "martin picard"

        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs == [exact.id])
        #expect(vm.filteredActiveItems.map(\.id) == [exact.id])
    }

    /// The metadata pass draws the list as the learner types; the body pass lands a
    /// debounce and a database query later. Sorting both by the tab's order let the
    /// second pass push hundreds of body matches above the exact title match that
    /// was already on screen. Later matches append below; what was drawn never moves.
    @Test("Sidebar body matches append below metadata matches instead of reordering them")
    func sidebarBodyMatchesAppendBelowMetadataMatches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSearchTierTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var titled = makeArticle(
            url: "https://example.com/hypermetabolism",
            title: "Context-Specific Hypermetabolism in Mitochondrial Energy Defects",
            sourceType: .paper
        )
        markPaperFullyReady(&titled, content: "Energy expenditure rises in some tissues and not others.")
        titled.dateAdded = Date(timeIntervalSince1970: 1_000_000)
        try await service.saveSource(titled)

        // Newer, so the Papers tab's own order (date added, newest first) would put
        // both of these above the title match once their bodies are found to match.
        var mention = makeArticle(
            url: "https://example.com/biomarkers",
            title: "Biomarkers of aging for longevity interventions",
            sourceType: .paper
        )
        markPaperFullyReady(&mention, content: "Clocks must be validated in a context specific manner.")
        mention.dateAdded = Date(timeIntervalSince1970: 3_000_000)
        try await service.saveSource(mention)

        var laterMention = makeArticle(
            url: "https://example.com/clocks",
            title: "Proteomic aging clocks in a clinical trial",
            sourceType: .paper
        )
        markPaperFullyReady(&laterMention, content: "Effects were context specific across the cohort.")
        laterMention.dateAdded = Date(timeIntervalSince1970: 2_000_000)
        try await service.saveSource(laterMention)

        // The sidebar list holds metadata without bodies, exactly as it renders.
        titled.content = nil
        mention.content = nil
        laterMention.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.articles = [titled, mention, laterMention]
        vm.sidebarTab = .papers
        vm.searchText = "context-specific"

        // Synchronous pass: the title match, and only it.
        #expect(vm.filteredActiveItems.map(\.id) == [titled.id])

        await vm.refreshSidebarContentSearchMatches()

        // The body matches join below it, in the tab's own order among themselves.
        #expect(vm.filteredActiveItems.map(\.id) == [titled.id, mention.id, laterMention.id])
    }

    @Test("Papers tab search matches paper author metadata")
    func papersTabSearchMatchesPaperAuthorMetadata() {
        let vm = makeViewModel()
        var picardPaper = makeArticle(
            url: "https://example.com/mitochondria",
            title: "Mitochondrial Psychobiology",
            sourceType: .paper
        )
        picardPaper.author = "Picard et al."
        let otherPaper = makeArticle(
            url: "https://example.com/other",
            title: "Unrelated Paper",
            sourceType: .paper
        )

        vm.articles = [otherPaper, picardPaper]
        vm.sidebarTab = .papers
        vm.searchText = "Martin Picard"

        #expect(vm.activeTabArticles.map(\.id) == [picardPaper.id])
    }

    @Test("Paper search does not resurrect a duplicate already ingested elsewhere in the library")
    func paperSearchKeepsLibraryWideDuplicateSuppression() async throws {
        let vm = makeViewModel()
        let tempPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        await warmLocalPathCache([tempPDF.path])

        var ingested = makeArticle(
            url: tempPDF.path,
            title: "The significance of bioelectricity on all levels of organization",
            sourceType: .paper
        )
        ingested.localFilePath = tempPDF.path
        ingested.author = "Richard Funk; Felix Scholkmann"
        ingested.doi = "10.1016/j.pbiomolbio.2022.12.002"
        markPaperFullyReady(&ingested)

        var staleDiscovery = makeArticle(
            url: "https://example.com/discovered-paper",
            title: ingested.title,
            sourceType: .paper
        )
        staleDiscovery.author = "Jane Smith; Martin Picard; Alex Doe"
        staleDiscovery.doi = "10.1101/2022.07.27.492200"

        vm.articles = [staleDiscovery, ingested]
        vm.sidebarTab = .papers
        vm.searchText = "picard"

        #expect(vm.filteredActiveItems.map(\.id) == [staleDiscovery.id])
        #expect(vm.papersNeedingPDFAttention.isEmpty)
        #expect(vm.activePapersWithoutPDF.isEmpty)
    }

    @Test("course search matches metadata")
    func courseSearchMatchesMetadata() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "Algorithms": CourseMetadata(courseCode: "6.006", title: "Introduction to Algorithms", institution: "MIT", instructors: "Erik Demaine", playlistURL: nil),
            "Machine Learning": CourseMetadata(courseCode: "CS229", title: nil, institution: "Stanford", instructors: "Andrew Ng", playlistURL: nil),
        ]

        #expect(vm.courseGroupNames(matching: "cs229") == ["Machine Learning"])
        #expect(vm.courseGroupNames(matching: "mit") == ["Algorithms"])
        #expect(vm.courseGroupNames(matching: "") == ["Algorithms", "Machine Learning"])
    }

    @Test("hidden courses are omitted from the Courses home")
    func hiddenCoursesAreOmitted() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "Visible": CourseMetadata(title: "Visible Course"),
            "Hidden": CourseMetadata(title: "Hidden Course", isHidden: true),
        ]

        #expect(vm.courseGroupNames(matching: "") == ["Visible"])
        #expect(vm.hiddenCourseGroupNames == ["Hidden"])
    }

    @Test("course groups respect manual reorder")
    func courseGroupsRespectManualReorder() {
        let vm = makeViewModel()
        vm.courseOrder = []
        vm.courseMetadata = [
            "algorithms": CourseMetadata(title: "Algorithms"),
            "biology": CourseMetadata(title: "Biology"),
            "calculus": CourseMetadata(title: "Calculus"),
        ]

        vm.reorderCourse(from: "calculus", to: "algorithms")

        #expect(vm.courseGroupNames(matching: "") == ["calculus", "algorithms", "biology"])
    }

    @Test("sortCoursesByTitle resets manual course order")
    func sortCoursesByTitleResetsManualOrder() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "algorithms": CourseMetadata(title: "Algorithms"),
            "biology": CourseMetadata(title: "Biology"),
            "calculus": CourseMetadata(title: "Calculus"),
        ]
        vm.courseOrder = ["calculus", "biology", "algorithms"]

        vm.sortCoursesByTitle()

        #expect(vm.courseGroupNames(matching: "") == ["algorithms", "biology", "calculus"])
    }

    @Test("hidden sources are omitted from source tabs")
    func hiddenSourcesAreOmittedFromTabs() {
        let vm = makeViewModel()
        var hidden = makeArticle(url: "https://example.com/hidden", title: "Hidden", sourceType: .article)
        hidden.isHidden = true
        vm.articles = [
            makeArticle(url: "https://example.com/visible", title: "Visible", sourceType: .article),
            hidden,
        ]
        vm.sidebarTab = .articles

        #expect(vm.activeTabArticles.map(\.title) == ["Visible"])
        #expect(vm.hiddenSourceArticles(for: .articles).map(\.title) == ["Hidden"])
    }

    @Test("fully hidden books are tracked as hidden book groups")
    func hiddenBookGroupsAreTracked() {
        let vm = makeViewModel()
        var chapter1 = makeArticle(url: "/books/example/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Example Book")
        var chapter2 = makeArticle(url: "/books/example/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "Example Book")
        let visibleChapter = makeArticle(url: "/books/other/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Other Book")
        chapter1.isHidden = true
        chapter2.isHidden = true
        vm.articles = [chapter1, chapter2, visibleChapter]

        #expect(vm.visibleBookGroupNames == ["Other Book"])
        #expect(vm.hiddenBookGroupNames == ["Example Book"])
        #expect(vm.hasHiddenBookItems)
        #expect(vm.hiddenBookChapterArticles.isEmpty)
    }

    @Test("A hidden book and its chapters open from Hidden Items in the Reader, and stay hidden")
    func hiddenBookOpensFromHiddenItems() async throws {
        let vm = makeViewModel()
        var chapter1 = makeArticle(url: "/books/example/ch1.pdf", title: "Chapter 1", sourceType: .book, state: .ready, parentGroup: "Example Book", sortIndex: 0)
        var chapter2 = makeArticle(url: "/books/example/ch2.pdf", title: "Chapter 2", sourceType: .book, state: .ready, parentGroup: "Example Book", sortIndex: 1)
        var stray = makeArticle(url: "/books/other/ch2.pdf", title: "A Hidden Chapter", sourceType: .book, state: .ready, parentGroup: "Other Book", sortIndex: 1)
        var shown = makeArticle(url: "/books/other/ch1.pdf", title: "Chapter 1", sourceType: .book, state: .ready, parentGroup: "Other Book", sortIndex: 0)
        chapter1.isHidden = true
        chapter2.isHidden = true
        stray.isHidden = true
        chapter1.content = "The first chapter."
        chapter2.content = "The second chapter."
        stray.content = "A chapter hidden on its own."
        shown.content = "A chapter in the list."
        vm.articles = [chapter1, chapter2, stray, shown]
        let window = StudioWindowState()

        let model = HiddenItemsModel.build(for: .books, vm: vm, in: window)
        let book = try #require(model.groups.first)
        #expect(model.groups.map(\.id) == ["Example Book"])
        #expect(book.hiddenEpisodes.map(\.id) == [chapter1.id, chapter2.id], "a hidden book lists its chapters in order")
        #expect(model.items.map(\.id) == [stray.id])
        #expect(book.unhide != nil, "Unhide is still offered")

        // The book opens as a book opens from the Books list: nothing read yet, so its first chapter.
        await book.open?()
        #expect(window.readerArticleID == chapter1.id)
        #expect(vm.selectedArticleId == chapter1.id)
        await book.hiddenEpisodes[1].open?()
        #expect(window.readerArticleID == chapter2.id)
        await model.items[0].open?()
        #expect(window.readerArticleID == stray.id)

        // Reading it changed nothing about what is hidden.
        #expect(vm.hiddenBookGroupNames == ["Example Book"])
        #expect(vm.visibleBookGroupNames == ["Other Book"])
        #expect(vm.hiddenBookChapterArticles.map(\.id) == [stray.id])
        #expect([chapter1.id, chapter2.id, stray.id].allSatisfy { id in vm.articlesById[id]?.isHidden == true })
    }

    @Test("book metadata without chapters is not shown as a book group")
    func orphanBookMetadataIsNotShownAsBookGroup() {
        let vm = makeViewModel()
        vm.bookTitles = [
            "Orphan Book": "Orphan Book",
            "Real Book": "Real Book",
        ]
        vm.bookCoverPaths = ["Orphan Book": "/books/orphan/cover.jpg"]
        vm.bookAuthors = ["Orphan Book": "Someone"]
        vm.bookKinds = ["Orphan Book": "Textbook"]
        vm.articles = [
            makeArticle(url: "/books/real/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Real Book"),
        ]

        #expect(vm.allBookGroupNames == ["Real Book"])
        #expect(vm.visibleBookGroupNames == ["Real Book"])
        #expect(vm.allBookKinds.isEmpty)
    }

    @Test("book group source IDs preserve chapter sort order")
    func bookGroupSourceIDsPreserveChapterSortOrder() {
        let vm = makeViewModel()
        let chapter3 = makeArticle(
            url: "Books/Test/Chapters/03.pdf",
            title: "Chapter 3",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 2
        )
        let chapter1 = makeArticle(
            url: "Books/Test/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 0
        )
        let chapter2 = makeArticle(
            url: "Books/Test/Chapters/02.pdf",
            title: "Chapter 2",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 1
        )
        vm.articles = [chapter3, chapter1, chapter2]

        #expect(vm.sourceIDsForGroupInOrder("book") == [chapter1.id, chapter2.id, chapter3.id])
        #expect(vm.sourceIdsForGroup("book") == Set([chapter1.id, chapter2.id, chapter3.id]))
    }

    @Test("course group source IDs include the whole outline in lecture order")
    func courseGroupSourceIDsIncludeWholeOutlineInLectureOrder() {
        let vm = makeViewModel()
        let firstLecture = CourseSession(id: "lecture-1", courseName: "course", number: 1)
        let secondLecture = CourseSession(id: "lecture-2", courseName: "course", number: 2)
        let firstVideo = makeArticle(
            title: "Lecture 1",
            sourceType: .video,
            parentGroup: "course",
            id: "video-1"
        )
        let firstSlides = makeArticle(
            title: "Lecture 1 slides",
            sourceType: .course,
            parentGroup: "course",
            id: "slides-1"
        )
        let secondVideo = makeArticle(
            title: "Lecture 2",
            sourceType: .video,
            parentGroup: "course",
            id: "video-2"
        )
        let unassignedReading = makeArticle(
            title: "Further reading",
            sourceType: .course,
            parentGroup: "course",
            id: "reading"
        )
        vm.articles = [unassignedReading, secondVideo, firstSlides, firstVideo]
        vm.courseLecturesByCourse["course"] = [secondLecture, firstLecture]
        vm.courseLectureItemsByLectureId[firstLecture.id] = [
            CourseLectureItem(
                id: "slides-item",
                lectureId: firstLecture.id,
                sourceId: firstSlides.id,
                role: .slides,
                sortIndex: 1
            ),
            CourseLectureItem(
                id: "video-1-item",
                lectureId: firstLecture.id,
                sourceId: firstVideo.id,
                role: .video,
                sortIndex: 0
            ),
        ]
        vm.courseLectureItemsByLectureId[secondLecture.id] = [
            CourseLectureItem(
                id: "video-2-item",
                lectureId: secondLecture.id,
                sourceId: secondVideo.id,
                role: .video,
                sortIndex: 0
            ),
        ]

        #expect(vm.sourceIDsForGroupInOrder("course") == [
            firstVideo.id,
            firstSlides.id,
            secondVideo.id,
            unassignedReading.id,
        ])
    }

    @Test("group drag transfer preserves source IDs and decodes legacy name-only payloads")
    func groupDragTransferPreservesSourceIDsAndDecodesLegacyNameOnlyPayloads() throws {
        let transfer = StudioGroupTransfer(groupName: "course", sourceIDs: ["lecture-1", "lecture-2"])
        let decoded = try JSONDecoder().decode(
            StudioGroupTransfer.self,
            from: JSONEncoder().encode(transfer)
        )
        let legacy = try JSONDecoder().decode(
            StudioGroupTransfer.self,
            from: Data(#"{"groupName":"course"}"#.utf8)
        )

        #expect(decoded.groupName == "course")
        #expect(decoded.sourceIDs == ["lecture-1", "lecture-2"])
        #expect(legacy.groupName == "course")
        #expect(legacy.sourceIDs == nil)
    }

    @Test("group display title names a book by its title, never by its group key")
    func groupDisplayTitleNamesGroupsByTitleNotKey() {
        let vm = makeViewModel()
        let bookID = UUID().uuidString
        vm.bookTitles = [bookID: "Thinking in Systems"]
        vm.courseMetadata = ["course-id": CourseMetadata(title: "Linear Algebra")]
        vm.videoPlaylistMetadata = [
            "playlist-id": VideoPlaylistMetadata(
                title: "3Blue1Brown",
                playlistURL: "https://www.youtube.com/playlist?list=PL"
            )
        ]

        // The drag payload carries the group key, so a book's opaque ID must
        // resolve to its title rather than reach the drop target as-is.
        #expect(vm.groupDisplayTitle(bookID) == "Thinking in Systems")
        #expect(vm.groupDisplayTitle("course-id") == "Linear Algebra")
        #expect(vm.groupDisplayTitle("playlist-id") == "3Blue1Brown")
        // A title-keyed group (an untitled folder of sources) is its own name.
        #expect(vm.groupDisplayTitle("Reading list") == "Reading list")
        // Nothing readable: nil, so callers say nothing instead of showing a UUID.
        #expect(vm.groupDisplayTitle(UUID().uuidString) == nil)
        #expect(vm.groupDisplayTitle("   ") == nil)
    }

    @Test("book display preserves stored title instead of deriving from folder path")
    func bookDisplayPreservesStoredTitleInsteadOfDerivingFromFolderPath() {
        let vm = makeViewModel()
        vm.bookTitles = ["book": "Build LLMfrom Scratch"]
        vm.bookCoverPaths = ["book": "Books/BuildLLMfromScratch/cover.jpg"]

        #expect(vm.bookDisplayName("book") == "Build LLMfrom Scratch")
    }

    @Test("book display preserves AI-provided title metadata")
    func bookDisplayPreservesTitleMetadata() {
        let vm = makeViewModel()
        vm.bookTitles = ["book": "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition"]
        vm.bookSubtitles = ["book": "Design Principles of Biological Circuits"]
        vm.bookEditions = ["book": "Second Edition"]

        #expect(vm.bookDisplayName("book") == "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition")
        #expect(StudioViewModel.cleanBookTitle(
            "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition",
            subtitle: "Design Principles of Biological Circuits",
            edition: "Second Edition"
        ) == "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition")
    }

    @Test("book display trusts AI-provided author metadata")
    func bookDisplayTrustsAuthorMetadata() {
        let vm = makeViewModel()
        vm.bookTitles = ["book": "Power Sex Suicide"]
        vm.bookAuthors = ["book": "Power, Sex, Suicide"]

        #expect(vm.bookDisplayAuthor("book") == "Power, Sex, Suicide")
    }

    @Test("book search by metadata keeps matching book chapters")
    func bookSearchByMetadataKeepsMatchingBookChapters() {
        let vm = makeViewModel()
        let powerChapter1 = makeArticle(
            url: "Books/PowerSexSuicide/Chapters/01.pdf",
            title: "Mitochondria",
            sourceType: .book,
            parentGroup: "power-book",
            sortIndex: 0
        )
        let powerChapter2 = makeArticle(
            url: "Books/PowerSexSuicide/Chapters/02.pdf",
            title: "The Meaning of Life",
            sourceType: .book,
            parentGroup: "power-book",
            sortIndex: 1
        )
        let otherChapter = makeArticle(
            url: "Books/Other/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "other-book",
            sortIndex: 0
        )
        vm.bookTitles = [
            "power-book": "Power, Sex, Suicide",
            "other-book": "Other Book",
        ]
        vm.articles = [powerChapter1, powerChapter2, otherChapter]
        vm.sidebarTab = .books
        vm.searchText = "power, sex"

        #expect(vm.filteredBookGroupNames == ["power-book"])
        #expect(vm.totalFilteredCount == 1)
        #expect(vm.activeTabArticles.map(\.id) == [powerChapter1.id, powerChapter2.id])
    }

    @Test("Books tab search reaches chapter text through the indexed content pass")
    func booksTabSearchFindsChapterBodyMatches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BooksContentSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var intro = makeArticle(
            url: "Books/Transformer/Chapters/01.pdf",
            title: "Introduction: Life itself",
            sourceType: .book,
            parentGroup: "transformer",
            sortIndex: 0
        )
        intro.content = "We cannot hope to understand what goes wrong in cancer or Alzheimer’s disease without the Krebs cycle."
        try await service.saveSource(intro)

        var carbon = makeArticle(
            url: "Books/Transformer/Chapters/03.pdf",
            title: "The path of carbon",
            sourceType: .book,
            parentGroup: "transformer",
            sortIndex: 1
        )
        carbon.content = "Carbon flows through the cycle in both directions."
        try await service.saveSource(carbon)

        var other = makeArticle(
            url: "Books/Other/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "other-book",
            sortIndex: 0
        )
        other.content = "A chapter about something else entirely."
        try await service.saveSource(other)

        // The sidebar list holds metadata without bodies, exactly as it renders.
        intro.content = nil
        carbon.content = nil
        other.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.bookTitles = ["transformer": "Transformer", "other-book": "Other Book"]
        vm.articles = [other, carbon, intro]
        vm.sidebarTab = .books
        vm.searchText = "Alzheimer"

        // The synchronous metadata pass finds nothing: the term is in a chapter body only.
        #expect(vm.filteredBookGroupNames.isEmpty)
        #expect(vm.totalFilteredCount == 0)
        #expect(vm.activeTabArticles.isEmpty)

        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs == [intro.id])
        #expect(vm.filteredBookGroupNames == ["transformer"])
        #expect(vm.totalFilteredCount == 1)
        // The whole book renders, not only the matching chapter, so the group stays coherent.
        #expect(vm.activeTabArticles.map(\.id) == [intro.id, carbon.id])

        vm.searchText = ""
        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs.isEmpty)
        #expect(Set(vm.filteredBookGroupNames) == ["other-book", "transformer"])
    }

    @Test("Books tab group list and chapters follow the category filter")
    func booksTabFollowsCategoryFilter() {
        let vm = makeViewModel()
        let biology = makeArticle(
            url: "Books/Biology/Chapters/01.pdf",
            title: "Cells",
            sourceType: .book,
            parentGroup: "biology-book",
            sortIndex: 0
        )
        let history = makeArticle(
            url: "Books/History/Chapters/01.pdf",
            title: "Empires",
            sourceType: .book,
            parentGroup: "history-book",
            sortIndex: 0
        )
        vm.bookTitles = ["biology-book": "Biology", "history-book": "History"]
        vm.bookKinds = ["biology-book": "Science", "history-book": "Humanities"]
        vm.articles = [biology, history]
        vm.sidebarTab = .books

        #expect(Set(vm.filteredBookGroupNames) == ["biology-book", "history-book"])
        #expect(vm.totalFilteredCount == 2)

        // The cached list and count must not outlive the category choice.
        vm.selectedBookKind = "Science"
        #expect(vm.filteredBookGroupNames == ["biology-book"])
        #expect(vm.totalFilteredCount == 1)
        #expect(vm.activeTabArticles.map(\.id) == [biology.id])

        vm.selectedBookKind = nil
        #expect(Set(vm.filteredBookGroupNames) == ["biology-book", "history-book"])
        #expect(vm.activeTabArticles.count == 2)
    }

    @Test("the Docs source picker finds a book's chapters by the book's title and author")
    func citationSourceSearchFindsBookMetadata() async {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/HowLifeWorks/Chapters/01.xhtml",
            title: "The Cell as an Agent",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [chapter]

        let index = await vm.artifactSourcePickerIndex()
        #expect(index.rows(matching: "how life works").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "Philip Ball").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "unrelated book").isEmpty)
    }

    @Test("a field prefix confines the search to that field")
    func sourceSearchFieldScope() {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "https://example.com/ret",
            title: "Reverse electron transport at complex I",
            sourceType: .paper
        )
        paper.author = "Martin Picard"
        paper.journal = "Nature Metabolism"
        paper.publishedYear = "2024"
        var other = makeArticle(
            url: "https://example.com/methods",
            title: "Overview of methods that determine mitochondrial function",
            sourceType: .paper
        )
        other.author = "Eashan Sharma"
        other.journal = "Reverse Transport Quarterly"
        other.publishedYear = "2025"
        vm.articles = [paper, other]

        // The bare query reads everything; the prefixed one reads titles only.
        #expect(vm.sourceMatchesSearch(other, query: "reverse transport"))
        #expect(!vm.sourceMatchesSearch(other, query: "title:reverse transport"))
        #expect(vm.sourceMatchesSearch(paper, query: "title:reverse electron transport"))
        #expect(vm.sourceMatchesSearch(paper, query: "Title: Reverse Electron"))
        #expect(vm.sourceMatchesSearch(other, query: "journal:reverse transport"))
        #expect(vm.sourceMatchesSearch(paper, query: "author:picard"))
        #expect(vm.sourceMatchesSearch(paper, query: "by: picard"))
        #expect(!vm.sourceMatchesSearch(paper, query: "title:picard"))
        #expect(vm.sourceMatchesSearch(other, query: "year:2025"))
        #expect(!vm.sourceMatchesSearch(paper, query: "year:2025"))
        #expect(vm.sourceMatchesSearch(paper, query: "site:example.com"))

        // The author's-last-name shortcut belongs to the byline, not to a title search.
        #expect(vm.sourceMatchesSearch(paper, query: "mitochondria picard"))
        #expect(!vm.sourceMatchesSearch(paper, query: "title:mitochondria picard"))

        // A prefix with nothing after it is a search still being typed.
        #expect(vm.sourceMatchesSearch(paper, query: "title:"))
        // A pasted address is an ordinary search, not a scope.
        #expect(vm.sourceMatchesSearch(paper, query: "https://example.com/ret"))
        #expect(!vm.sourceMatchesSearch(other, query: "https://example.com/ret"))

        let parsed = StudioViewModel.SidebarSearchQuery(parsing: "  Title:  Reverse  ")
        #expect(parsed.field == .title)
        #expect(parsed.text == "Reverse")
        #expect(StudioViewModel.SidebarSearchQuery(parsing: "doi:10.1038/x").field == .doi)
        #expect(StudioViewModel.SidebarSearchQuery(parsing: "https://doi.org/10.1038/x").field == nil)
        #expect(StudioViewModel.SidebarSearchQuery(parsing: "reverse").isScoped == false)
    }

    @Test("a title-scoped search reads a book's title but not its author")
    func bookSearchHonorsFieldScope() {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/HowLifeWorks/Chapters/01.xhtml",
            title: "The Cell as an Agent",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [chapter]

        vm.searchText = "philip ball"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
        vm.searchText = "author:philip ball"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
        vm.searchText = "title:philip ball"
        #expect(!vm.bookMatchesSearch("book-how-life-works"))
        vm.searchText = "title:how life"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
        // A chapter title answers for its book under the same scope.
        vm.searchText = "title:cell as an agent"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
    }

    @Test("source search reads a hyphenated term and its bare spelling as one")
    func sourceSearchIgnoresHyphenation() async {
        let vm = makeViewModel()
        var hyphenated = makeArticle(
            url: "https://example.com/gdf-15-aging",
            title: "GDF-15 as a Biomarker of Aging",
            sourceType: .paper
        )
        hyphenated.author = "Margalida Torrens-Mas"
        var bare = makeArticle(
            url: "https://example.com/mystery-hormone",
            title: "GDF15 is still a mystery hormone",
            sourceType: .paper
        )
        bare.author = "Casper M. Sigvardsen"
        vm.articles = [hyphenated, bare]

        // The direction that used to fail: nothing in the hyphenated title
        // literally contains "gdf15".
        #expect(vm.sourceMatchesSearch(hyphenated, query: "GDF15"))
        #expect(vm.sourceMatchesSearch(bare, query: "GDF-15"))
        #expect(vm.sourceMatchesSearch(hyphenated, query: "GDF15 biomarker"))
        #expect(vm.sourceMatchesSearch(hyphenated, query: "torrens mas"))
        // Folding punctuation must not fold the term itself.
        #expect(!vm.sourceMatchesSearch(hyphenated, query: "GDF16"))
        #expect(!vm.sourceMatchesSearch(bare, query: "FGF-21"))

        // The fold closes up punctuation inside a word and keeps whitespace between
        // words, so a whole-query match cannot straddle a boundary the learner typed.
        #expect(StudioViewModel.foldedSidebarSearchString("GDF-15 as a Biomarker of Aging")
            == "gdf15 as a biomarker of aging")

        // Both spellings therefore land in the Docs picker under either query.
        let index = await vm.artifactSourcePickerIndex()
        let bareQuery = Set(index.rows(matching: "GDF15").map(\.sourceID))
        let hyphenQuery = Set(index.rows(matching: "GDF-15").map(\.sourceID))
        // The last-author rule reaches the picker too, and a typo still finds nothing.
        #expect(index.rows(matching: "torrens mas").map(\.sourceID) == [hyphenated.id])
        #expect(index.rows(matching: "GDF16").isEmpty)
        #expect(bareQuery == [hyphenated.id, bare.id])
        #expect(hyphenQuery == [hyphenated.id, bare.id])
    }

    @Test("book metadata search ignores hyphenation too")
    func citationSourceSearchIgnoresBookHyphenation() async {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/CfMtDNA/Chapters/01.xhtml",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "book-cf-mtdna",
            sortIndex: 0
        )
        vm.bookTitles = ["book-cf-mtdna": "cf-mtDNA and Mitochondrial Health"]
        vm.articles = [chapter]

        let index = await vm.artifactSourcePickerIndex()
        #expect(index.rows(matching: "cfmtDNA").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "cf-mtDNA").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "mtRNA").isEmpty)
    }

    @Test("Notepad citation picker collapses a matching book and expands its reference")
    func notepadCitationPickerUsesWholeBook() async {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        let second = makeArticle(
            url: "Books/HowLifeWorks/02.xhtml",
            title: "Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 1
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [second, first]

        let index = await vm.artifactSourcePickerIndex()
        let rows = index.rows(matching: "Philip Ball")
        #expect(rows.count == 1)
        #expect(rows.first?.title == "How Life Works")
        #expect(rows.first?.sourceID == first.id)
        #expect(rows.first?.bookID == "book-how-life-works")
        #expect(index.entries.first?.sources.map(\.fields.id) == [first.id, second.id])

        let markdown = "[How Life Works](foreverlm://source/\(first.id)?book=book-how-life-works)"
        #expect(vm.sourceIDsReferencedByNotepadMarkdown(markdown) == [first.id, second.id])
    }

    @Test("A grounded passage puts its attached sources in the doc's context")
    func groundedPassageContributesItsSources() {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://example.com/a", title: "Aging as Adaptation", id: "src-a")
        let b = makeArticle(url: "https://example.com/b", title: "Energy Constraints", id: "src-b")
        let c = makeArticle(url: "https://example.com/c", title: "Cellular Senescence", id: "src-c")
        vm.articles = [a, b, c]

        // Sentence one stands on A and B; sentence two on C. A question about both
        // sentences has to arrive carrying all three, in reading order.
        let markdown = "[Sentence one.](foreverlm://grounding/src-a,src-b) [Sentence two.](foreverlm://grounding/src-c)"
        #expect(vm.sourceIDsReferencedByNotepadMarkdown(markdown) == ["src-a", "src-b", "src-c"])
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown("[Sentence two.](foreverlm://grounding/src-c)")
                == ["src-c"]
        )

        // A doc old enough to still carry a citation chip stands on both kinds.
        // The editor converts the chip to grounding when it opens the doc; until
        // then the source it named is context just the same.
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown(
                "[Named](foreverlm://source/src-a) and [attached.](foreverlm://grounding/src-c)"
            ) == ["src-a", "src-c"]
        )

        // An id the library no longer holds cannot become context.
        #expect(vm.sourceIDsReferencedByNotepadMarkdown("[Gone.](foreverlm://grounding/src-gone)").isEmpty)
    }

    @Test("A grounding address parses its whole list once")
    func groundingAddressParsesItsList() throws {
        let url = try #require(URL(string: "foreverlm://grounding/src-a,src%20b,src-a,src-c"))
        #expect(StudioViewModel.isNotepadGroundingURL(url))
        #expect(
            StudioViewModel.notepadGroundingTokens(from: url) == ["src-a", "src b", "src-c"]
        )

        let chip = try #require(URL(string: "foreverlm://source/src-a"))
        #expect(!StudioViewModel.isNotepadGroundingURL(chip))
        #expect(StudioViewModel.notepadGroundingTokens(from: chip).isEmpty)
    }

    @Test("A passage attached to a book stands on the book's current chapters")
    func groundedPassageExpandsABook() {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        let second = makeArticle(
            url: "Books/HowLifeWorks/02.xhtml",
            title: "Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 1
        )
        let paper = makeArticle(url: "https://example.com/a", title: "Aging as Adaptation", id: "src-a")
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.articles = [second, first, paper]

        // A book is one thing a passage stands on, and it expands through the
        // chapters the library holds now — not the ones it held when attached.
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown(
                "[Passage.](foreverlm://grounding/book:book-how-life-works,src-a)"
            ) == [first.id, second.id, "src-a"]
        )
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown(
                "[Passage.](foreverlm://grounding/book:book-gone)"
            ).isEmpty
        )

        // The picker commits a book row as the collection, not as the chapter
        // that happens to represent it in the list.
        #expect(
            StudioViewModel.notepadGroundingToken(sourceID: first.id, bookID: "book-how-life-works")
                == "book:book-how-life-works"
        )
        #expect(StudioViewModel.notepadGroundingToken(sourceID: "src-a", bookID: nil) == "src-a")
    }

    @Test("Docs source picker rows carry the drawn strings, not the source")
    func docsSourcePickerRowsAreFlat() async {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        let second = makeArticle(
            url: "Books/HowLifeWorks/02.xhtml",
            title: "Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 1
        )
        let article = makeArticle(
            url: "https://www.nytimes.com/chinese-peptides",
            title: "Chinese Peptides",
            sourceType: .article
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [second, first, article]

        let rows = await vm.artifactSourcePickerIndex().rows(matching: "")

        // One row per book plus one per ordinary source, and everything the row
        // draws is already a String — nothing here should have to reach back into
        // a StudioArticle while the list is being laid out.
        #expect(rows.count == 2)
        let book = rows.first { $0.bookID == "book-how-life-works" }
        #expect(book?.title == "How Life Works")
        #expect(book?.sourceID == first.id)
        #expect(book?.sourceType == StudioSourceType.book.rawValue)
        #expect(book?.subtitle == "Book · Philip Ball · 2 chapters")
        let plain = rows.first { $0.bookID == nil }
        #expect(plain?.sourceID == article.id)
        #expect(plain?.sourceType == StudioSourceType.article.rawValue)
        #expect(plain?.subtitle == "Article · www.nytimes.com")
    }

    @Test("The Docs source picker never offers a hidden source and finds a page by its own text")
    func sourcePickerSkipsHiddenAndMatchesContent() async {
        let vm = makeViewModel()
        var episode = makeArticle(
            url: "apple-podcast://episode/1000751939405",
            title: "AI Viruses, OpenAI's First Device",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts
        )
        episode.domain = "TBPN"
        var hidden = makeArticle(url: "https://example.com/hidden", title: "OpenAI hidden article", sourceType: .article)
        hidden.isHidden = true
        let shown = makeArticle(url: "https://example.com/shown", title: "OpenAI shown article", sourceType: .article)
        // An unscoped search reads the address and domain too, as the sidebar's
        // does, so this page's address names neither query.
        let byText = makeArticle(url: "https://health.example.org/public", title: "Public Data for Health", sourceType: .article)
        vm.articles = [episode, hidden, shown, byText]
        vm.hiddenPodcastShows = ["TBPN"]

        let index = await vm.artifactSourcePickerIndex()
        #expect(Set(index.rows(matching: "openai").map(\.sourceID)) == [shown.id])
        #expect(index.rows(matching: "direct data").isEmpty)
        let withContent = index.rows(matching: "direct data", contentMatchIDs: [byText.id, hidden.id])
        #expect(withContent.map(\.sourceID) == [byText.id])
    }

    @Test("Docs source type filters group unfinished URLs with articles")
    func docsSourceTypeFiltersUsePickerKinds() {
        #expect(ArtifactSourcePickerFilter.article.includes(sourceType: StudioSourceType.article.rawValue))
        #expect(ArtifactSourcePickerFilter.article.includes(sourceType: StudioSourceType.unclassified.rawValue))
        #expect(!ArtifactSourcePickerFilter.article.includes(sourceType: StudioSourceType.paper.rawValue))
        #expect(ArtifactSourcePickerFilter.link.includes(sourceType: StudioSourceType.manual.rawValue))
        #expect(ArtifactSourcePickerFilter.all.includes(sourceType: StudioSourceType.xPost.rawValue))
    }

    @Test("The Docs source picker index answers in title order and reuses unchanged analysis")
    func sourcePickerIndexIsTitleOrderedAndReused() async {
        let vm = makeViewModel()
        // Addresses that hold neither title: an unscoped search reads the address too.
        let zebra = makeArticle(url: "https://example.com/z-1", title: "Zebra", sourceType: .article)
        var apple = makeArticle(url: "https://example.com/a-2", title: "Apple", sourceType: .article)
        vm.articles = [zebra, apple]

        let first = await vm.artifactSourcePickerIndex()
        #expect(first.rows(matching: "").map(\.title) == ["Apple", "Zebra"])
        #expect(first.rows(matching: "example").map(\.title) == ["Apple", "Zebra"])

        // A renamed source is analysed afresh; the next opening finds the new title.
        apple.title = "Avocado"
        vm.articles = [zebra, apple]
        let second = await vm.artifactSourcePickerIndex()
        #expect(second.rows(matching: "avocado").map(\.sourceID) == [apple.id])
        #expect(second.rows(matching: "apple").isEmpty)
        #expect(second.rows(matching: "").map(\.title) == ["Avocado", "Zebra"])
    }

    @Test("The Docs source picker lists the title that is the query first and a source that only mentions it last")
    func sourcePickerRanksTitleMatchesFirst() async {
        let vm = makeViewModel()
        let exact = makeArticle(url: "https://example.com/1", title: "Revolution Postponed")
        let start = makeArticle(url: "https://example.com/2", title: "Revolution Postponed: Why the Genome Waited")
        let phrase = makeArticle(url: "https://example.com/3", title: "The Revolution Postponed Again")
        let terms = makeArticle(url: "https://example.com/4", title: "Postponed, a Revolution")
        // Named by its publication, not its title.
        var byDetails = makeArticle(url: "https://example.com/5", title: "Aardvark Notes")
        byDetails.domain = "Revolution Postponed Weekly"
        // Holds the words only in its own text.
        let byText = makeArticle(url: "https://example.com/6", title: "Abacus Hour")
        vm.articles = [byText, terms, byDetails, phrase, start, exact]

        let index = await vm.artifactSourcePickerIndex()
        let ranked = index.rows(matching: "revolution postponed", contentMatchIDs: [byText.id])
        #expect(ranked.map(\.sourceID) == [exact.id, start.id, phrase.id, terms.id, byDetails.id, byText.id])
        // Punctuation and case in the title do not cost it its place.
        #expect(index.rows(matching: "REVOLUTION postponed:").first?.sourceID == exact.id)
        // A query confined to the site is not ranked by the title it never asked about.
        #expect(index.rows(matching: "site:revolution postponed").map(\.sourceID) == [byDetails.id])
        // No query keeps the whole library in title order.
        #expect(index.rows(matching: "").first?.sourceID == byDetails.id)
    }

    @Test("The Docs source picker filters whole books by title and author")
    func notepadSourceSearchFiltersWholeBookMetadata() async {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [chapter]

        let index = await vm.artifactSourcePickerIndex()
        let byTitle = index.rows(matching: "life how works")
        let byAuthor = index.rows(matching: "ball philip")

        #expect(byTitle.map(\.title) == ["How Life Works"])
        #expect(byAuthor.map(\.title) == ["How Life Works"])
        #expect(byTitle.first?.sourceID == chapter.id)
        #expect(byTitle.first?.bookID == "book-how-life-works")
    }

    @Test("The Docs source picker only returns rows matching every typed term")
    func notepadSourceSearchStrictlyNarrowsResults() async {
        let vm = makeViewModel()
        var matching = makeArticle(title: "How Life Works")
        matching.author = "Philip Ball"
        var partial = makeArticle(title: "How Cells Work")
        partial.author = "Another Author"
        var unrelated = makeArticle(title: "The Gene")
        unrelated.author = "Siddhartha Mukherjee"
        vm.articles = [unrelated, partial, matching]

        let results = await vm.artifactSourcePickerIndex().rows(matching: "life ball")

        #expect(results.map(\.sourceID) == [matching.id])
    }

    @Test("partially hidden books still expose hidden chapters")
    func partiallyHiddenBooksExposeHiddenChapters() {
        let vm = makeViewModel()
        var hiddenChapter = makeArticle(url: "/books/example/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Example Book")
        let visibleChapter = makeArticle(url: "/books/example/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "Example Book")
        hiddenChapter.isHidden = true
        vm.articles = [hiddenChapter, visibleChapter]

        #expect(vm.visibleBookGroupNames == ["Example Book"])
        #expect(vm.hiddenBookGroupNames.isEmpty)
        #expect(vm.hiddenBookChapterArticles.map(\.title) == ["Chapter 1"])
    }

    @Test("hasMoreItems returns true when items exceed displayLimit")
    func hasMoreItems() {
        let vm = makeViewModel()
        var arts: [StudioArticle] = []
        for i in 0..<50 {
            arts.append(makeArticle(url: "https://example.com/\(i)", title: "Art \(i)", sourceType: .article))
        }
        vm.articles = arts
        vm.sidebarTab = .articles
        vm.displayLimit = 40
        #expect(vm.hasMoreItems)
        #expect(vm.activeTabArticles.count == 40)
    }
}
