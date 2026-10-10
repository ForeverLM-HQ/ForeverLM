import Foundation
import Testing
@testable import ForeverLM

/// The phone reads an EPUB book as one scroll: which chapters make up the book,
/// which ones are on the page and which comes next, when a chapter counts as
/// read to its end, what the page reports, and the steps that bring the page up
/// to date without moving the text above the reader mid-scroll.
@Suite("Mobile Book Reading")
struct MobileBookReadingTests {
    private func chapter(
        _ id: String,
        book: String? = "book-1",
        sortIndex: Int? = nil,
        title: String? = nil,
        type: String = "book",
        archived: Bool = false,
        localFilePath: String? = nil
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title ?? "Chapter \(id)",
            subtitle: nil,
            sourceType: type,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: archived,
            parentGroup: book,
            courseSortIndex: sortIndex,
            localFilePath: localFilePath
        )
    }

    // MARK: - The book's chapters

    @Test("A chapter is read among its book's chapters in the chapter list's order")
    func readingOrderFollowsTheBook() {
        let opened = chapter("c2", sortIndex: 1)
        let catalog = [
            chapter("c3", sortIndex: 2),
            chapter("c1", sortIndex: 0),
            opened,
            chapter("c-late", title: "Chapter 10"),
            chapter("c-early", title: "Chapter 2"),
            chapter("other", book: "book-2", sortIndex: 0),
            chapter("paper", book: "book-1", type: "paper"),
            chapter("gone", sortIndex: 3, archived: true),
        ]
        let order = MobileSourceGrouping.bookReadingOrder(for: opened, in: catalog).map(\.id)
        #expect(order == ["c1", "c2", "c3", "c-early", "c-late"])
    }

    @Test("The opened chapter stays in the book even when it is archived")
    func archivedOpenedChapterIsKept() {
        let opened = chapter("c2", sortIndex: 1, archived: true)
        let catalog = [chapter("c1", sortIndex: 0), opened, chapter("c3", sortIndex: 2)]
        #expect(MobileSourceGrouping.bookReadingOrder(for: opened, in: catalog).map(\.id) == ["c1", "c2", "c3"])
    }

    @Test("Anything but an EPUB chapter of a book with another chapter reads alone")
    func singleSourcesReadAlone() {
        let lone = chapter("only")
        #expect(MobileSourceGrouping.bookReadingOrder(for: lone, in: [lone, chapter("x", book: "book-2")]).isEmpty)

        let pdfChapter = chapter("pdf", localFilePath: "Books/Deep Learning/chapter-3.pdf")
        #expect(MobileSourceGrouping.bookReadingOrder(for: pdfChapter, in: [pdfChapter, chapter("c1")]).isEmpty)

        let article = chapter("a", type: "article")
        #expect(MobileSourceGrouping.bookReadingOrder(for: article, in: [article, chapter("c1", type: "article")]).isEmpty)

        let ungrouped = chapter("u", book: nil)
        #expect(MobileSourceGrouping.bookReadingOrder(for: ungrouped, in: [ungrouped, chapter("v", book: nil)]).isEmpty)
    }

    @Test("A PDF chapter in an EPUB book is left to its own document")
    func pdfChaptersLeaveTheScroll() {
        let opened = chapter("c1", sortIndex: 0)
        let catalog = [opened, chapter("c2", sortIndex: 1, localFilePath: "Books/B/c2.pdf"), chapter("c3", sortIndex: 2)]
        #expect(MobileSourceGrouping.bookReadingOrder(for: opened, in: catalog).map(\.id) == ["c1", "c3"])
    }

    // MARK: - The chapters on the page

    @Test("The page opens on the tapped chapter and grows a chapter at a time")
    func windowGrowsFromTheOpenedChapter() throws {
        var window = try #require(MobileBookWindow(chapterIDs: ["a", "b", "c", "d"], openingAt: "b"))
        func extend(_ edge: MobileBookEdge) -> String? { window.extend(edge) }
        #expect(window.loadedIDs == ["b"])
        #expect(window.neighbor(at: .start) == "a")
        #expect(window.neighbor(at: .end) == "c")
        #expect(!window.reachesStart && !window.reachesEnd)

        #expect(extend(.start) == "a")
        #expect(window.reachesStart && window.neighbor(at: .start) == nil)
        #expect(extend(.start) == nil)
        #expect(extend(.end) == "c")
        #expect(extend(.end) == "d")
        #expect(window.reachesEnd && window.loadedIDs == ["a", "b", "c", "d"])
        #expect(window.isBookStart("a") && !window.isBookStart("b"))
        #expect(MobileBookWindow(chapterIDs: ["a"], openingAt: "z") == nil)
    }

    @Test("Chapters far behind the reader are let go, never the one on screen or its neighbours")
    func windowLetsGoFarBehind() throws {
        let ids = (0..<10).map { "c\($0)" }
        var window = try #require(MobileBookWindow(chapterIDs: ids, openingAt: "c2"))
        func trim(keeping current: String?, after edge: MobileBookEdge) -> [String] {
            window.trim(keeping: current, after: edge)
        }
        for _ in 0..<4 { window.extend(.end) }
        #expect(window.loadedIDs == ["c2", "c3", "c4", "c5", "c6"])
        #expect(trim(keeping: "c5", after: .end).isEmpty)

        window.extend(.end)
        #expect(trim(keeping: "c6", after: .end) == ["c2"])
        #expect(window.loadedIDs == ["c3", "c4", "c5", "c6", "c7"])

        // Reading far back up: the other end goes, down to the one past the reader.
        window.extend(.start)
        #expect(trim(keeping: "c3", after: .start) == ["c7"])
        #expect(window.loadedIDs == ["c2", "c3", "c4", "c5", "c6"])

        // Nothing is let go that the reader is near, whatever the count.
        window.extend(.end)
        #expect(trim(keeping: "c3", after: .end).isEmpty)
        #expect(window.loadedIDs.count == MobileBookWindow.maximumLoadedChapters + 1)
        #expect(trim(keeping: nil, after: .end).isEmpty)
    }

    // MARK: - Reaching a chapter's end

    @Test("A chapter reaches its end by being read down to it, once")
    func endIsReachedByReadingDown() {
        var tracker = MobileBookEndTracker()
        func observe(_ chapterID: String, _ fraction: Double) -> Bool {
            tracker.observe(chapterID, fraction: fraction)
        }
        tracker.begin("opened")
        // The opened chapter counts from its start, as a single chapter does,
        // even when it opens at its saved end.
        #expect(observe("opened", 1))
        #expect(!observe("opened", 0.5))
        #expect(!observe("opened", 1))

        // Scrolling up into the chapter before shows its last lines first:
        // that is not having read it.
        #expect(!observe("before", 1))
        #expect(!observe("before", 1))
        // Reading back down through them is.
        #expect(!observe("before", 0.7))
        #expect(observe("before", 0.998))

        // Scrolling on into the next chapter enters it at its top.
        #expect(!observe("after", 0))
        #expect(!observe("after", .nan))
        #expect(observe("after", 1))
    }

    // MARK: - What the page reports

    @Test("The page's reading report is read, clamped, and anything else ignored")
    func readingReportParses() throws {
        let message: [String: Any] = [
            "type": "reading",
            "chapter": "c2",
            "fraction": NSNumber(value: 1.2),
            "visible": [
                ["chapter": "c1", "fraction": NSNumber(value: 1)],
                ["chapter": "c2", "fraction": NSNumber(value: 0.25)],
                ["chapter": "", "fraction": NSNumber(value: 0.5)],
            ],
            "first": "c1",
            "last": "c3",
            "nearStart": true,
            "nearEnd": false,
        ]
        let report = try #require(MobileBookReadingReport(message: message))
        #expect(report.chapterID == "c2")
        #expect(report.fraction == 1)
        #expect(report.visible == [
            .init(chapterID: "c1", fraction: 1),
            .init(chapterID: "c2", fraction: 0.25),
        ])
        #expect(report.firstChapterID == "c1" && report.lastChapterID == "c3")
        #expect(report.isNearStart && !report.isNearEnd)
        #expect(report.point == MobileBookReadingPoint(chapterID: "c2", fraction: 1))

        #expect(MobileBookPageEvent(message: message) == .reading(report))
        #expect(MobileBookPageEvent(message: ["type": "retry", "edge": "end"]) == .retry(.end))
        #expect(MobileBookPageEvent(message: ["type": "retry", "edge": "middle"]) == nil)
        #expect(MobileBookReadingReport(message: ["type": "reading", "fraction": 0.5, "first": "a", "last": "a"]) == nil)
        #expect(MobileBookPageEvent(message: "c2") == nil)
    }

    // MARK: - Bringing the page up to date

    private func entry(_ id: String, start: Bool = false) -> MobileBookPage.Chapter {
        MobileBookPage.Chapter(id: id, bodyHTML: "<p>\(id)</p>", isBookStart: start)
    }

    private func page(
        _ ids: [String],
        start: MobileBookEdgeState = .idle,
        end: MobileBookEdgeState = .idle,
        fontScale: Double = 1,
        scroll: MobileBookPage.ScrollRequest? = nil
    ) -> MobileBookPage {
        MobileBookPage(
            generation: 1,
            restore: MobileBookReadingPoint(chapterID: ids.first ?? "", fraction: 0.4),
            chapters: ids.map { entry($0, start: $0 == "c0") },
            startState: start,
            endState: end,
            fontScale: fontScale,
            scrollRequest: scroll
        )
    }

    private func held(_ ids: [String], start: MobileBookEdgeState = .idle, end: MobileBookEdgeState = .idle) -> MobileBookDOMState {
        MobileBookDOMState(chapterIDs: ids, startState: start, endState: end, fontScale: 1, scrollToken: nil)
    }

    @Test("A fresh page gets the opened chapter, its ends, its text size, and the saved place")
    func freshPageFills() {
        let wanted = page(["c2"], start: .idle, end: .bookEnd)
        let plan = MobileBookPageSync.plan(from: .freshShell, to: wanted, restore: wanted.restore, allowsStartChanges: true)
        #expect(plan.operations == [
            .insert(entry("c2"), at: .end),
            .edge(.end, .bookEnd),
            .fontScale(1),
            .scroll(MobileBookReadingPoint(chapterID: "c2", fraction: 0.4)),
        ])
        #expect(plan.performsRestore && !plan.deferredStartChanges && !plan.needsReload)
        #expect(plan.resultingState.chapterIDs == ["c2"])
        #expect(plan.resultingState.endState == .bookEnd && plan.resultingState.fontScale == 1)
    }

    @Test("Chapters are added at the end they belong to, nearest first")
    func chaptersGoInAtTheirEnd() {
        let plan = MobileBookPageSync.plan(
            from: held(["c2"]),
            to: page(["c0", "c1", "c2", "c3"], start: .bookEnd),
            restore: nil,
            allowsStartChanges: true
        )
        #expect(plan.operations == [
            .insert(entry("c1"), at: .start),
            .insert(entry("c0", start: true), at: .start),
            .insert(entry("c3"), at: .end),
            .edge(.start, .bookEnd),
        ])
        #expect(plan.resultingState.chapterIDs == ["c0", "c1", "c2", "c3"])
        #expect(plan.resultingState.startState == .bookEnd)
    }

    @Test("While the page scrolls, only what moves the text above the reader waits")
    func startChangesWaitForTheScrollToRest() {
        let wanted = page(["c1", "c2", "c3"], start: .loading, end: .loading)
        let plan = MobileBookPageSync.plan(from: held(["c2"]), to: wanted, restore: nil, allowsStartChanges: false)
        // The spinner at the start is the height the idle end already had.
        #expect(plan.operations == [
            .insert(entry("c3"), at: .end),
            .edge(.start, .loading),
            .edge(.end, .loading),
        ])
        #expect(plan.deferredStartChanges)
        #expect(plan.resultingState.chapterIDs == ["c2", "c3"])

        let rested = MobileBookPageSync.plan(from: plan.resultingState, to: wanted, restore: nil, allowsStartChanges: true)
        #expect(rested.operations == [.insert(entry("c1"), at: .start)])
        #expect(!rested.deferredStartChanges)

        // Collapsing the start where the book begins changes its height, so it waits too.
        let collapsing = MobileBookPageSync.plan(
            from: held(["c0", "c1"]),
            to: page(["c0", "c1"], start: .bookEnd),
            restore: nil,
            allowsStartChanges: false
        )
        #expect(collapsing.operations.isEmpty && collapsing.deferredStartChanges)
    }

    @Test("Chapters let go at either end leave the page; at the start that waits for rest")
    func chaptersLeaveThePage() {
        let wanted = page(["c2", "c3"])
        let scrolling = MobileBookPageSync.plan(from: held(["c1", "c2", "c3", "c4"]), to: wanted, restore: nil, allowsStartChanges: false)
        #expect(scrolling.operations == [.remove(chapterID: "c4", at: .end)])
        #expect(scrolling.deferredStartChanges)
        let resting = MobileBookPageSync.plan(from: scrolling.resultingState, to: wanted, restore: nil, allowsStartChanges: true)
        #expect(resting.operations == [.remove(chapterID: "c1", at: .start)])
        #expect(resting.resultingState.chapterIDs == ["c2", "c3"])
    }

    @Test("A text size is told once, and a Contents scroll is made once")
    func sizeAndScrollAreOneShot() {
        var wanted = page(["c1", "c2"], fontScale: 1.3, scroll: MobileBookPage.ScrollRequest(token: 4, chapterID: "c2"))
        let plan = MobileBookPageSync.plan(from: held(["c1", "c2"]), to: wanted, restore: nil, allowsStartChanges: false)
        #expect(plan.operations == [.fontScale(1.3), .scroll(MobileBookReadingPoint(chapterID: "c2", fraction: 0))])
        let again = MobileBookPageSync.plan(from: plan.resultingState, to: wanted, restore: nil, allowsStartChanges: true)
        #expect(again.operations.isEmpty)

        // A scroll to a chapter not on the page yet waits for it.
        wanted.scrollRequest = MobileBookPage.ScrollRequest(token: 5, chapterID: "c9")
        #expect(MobileBookPageSync.plan(from: plan.resultingState, to: wanted, restore: nil, allowsStartChanges: true).operations.isEmpty)
    }

    @Test("The saved place is restored only once its chapter is on the page")
    func restoreWaitsForItsChapter() {
        let wanted = page(["c1"])
        let plan = MobileBookPageSync.plan(
            from: held(["c1"]),
            to: wanted,
            restore: MobileBookReadingPoint(chapterID: "c7", fraction: 0.2),
            allowsStartChanges: true
        )
        #expect(plan.operations.isEmpty && !plan.performsRestore)
    }

    @Test("A page that shares no chapter with the wanted ones is rebuilt")
    func disjointPageReloads() {
        let plan = MobileBookPageSync.plan(from: held(["c1", "c2"]), to: page(["c7"]), restore: nil, allowsStartChanges: true)
        #expect(plan.needsReload && plan.operations.isEmpty)
    }

    @Test("Each step reaches the page script in the shape it reads")
    func stepPayloads() {
        let size: (Double) -> Double = { $0 * 18 }
        let insert = MobileBookPageOperation.insert(entry("c0", start: true), at: .start).payload(fontSize: size)
        #expect(insert["op"] as? String == "insert")
        #expect(insert["edge"] as? String == "start")
        #expect(insert["id"] as? String == "c0")
        #expect(insert["html"] as? String == "<p>c0</p>")
        #expect(insert["bookStart"] as? Bool == true)
        #expect(MobileBookPageOperation.remove(chapterID: "c1", at: .end).payload(fontSize: size)["op"] as? String == "remove")
        let edge = MobileBookPageOperation.edge(.end, .bookEnd).payload(fontSize: size)
        #expect(edge["state"] as? String == "end")
        #expect(MobileBookPageOperation.fontScale(1.5).payload(fontSize: size)["px"] as? Double == 27)
        let scroll = MobileBookPageOperation.scroll(MobileBookReadingPoint(chapterID: "c2", fraction: 0.3)).payload(fontSize: size)
        #expect(scroll["id"] as? String == "c2" && scroll["fraction"] as? Double == 0.3)
    }
}
