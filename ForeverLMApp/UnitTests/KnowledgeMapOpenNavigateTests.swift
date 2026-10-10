import Foundation
import Testing
@testable import ForeverLM

// Open and navigate (docs/knowledge-map-design.md, "Circling and the inspector"):
// back and forward over the canvases a window opened, the tray's Regions list,
// how a card's ref names what opens, and (below) the suggested questions, the
// two new Asks and a canvas made from sources.

@MainActor
@Suite("Canvas history: ⌘[ and ⌘]")
struct KnowledgeMapCanvasHistoryTests {
    @Test("The first canvas opened is the first step back; each opening pushes")
    func visitPushes() {
        let history = KnowledgeMapCanvasHistory()
        #expect(!history.hasHistory && !history.canGoBack && !history.canGoForward)
        history.visit("b", from: "a")
        #expect(history.stack == ["a", "b"] && history.index == 1)
        #expect(history.hasHistory && history.canGoBack && !history.canGoForward)
        history.visit("c", from: "b")
        #expect(history.stack == ["a", "b", "c"] && history.index == 2)
    }

    @Test("Back and forward move along the stack without pushing, and stop at its ends")
    func backAndForward() {
        let history = KnowledgeMapCanvasHistory()
        history.visit("b", from: "a")
        history.visit("c", from: "b")
        #expect(history.candidate(.back) == "b")
        #expect(history.index == 2, "asking who is there moves nothing")
        #expect(history.step(.back) == "b")
        #expect(history.step(.back) == "a")
        #expect(history.step(.back) == nil, "nothing before the first")
        #expect(history.index == 0 && !history.canGoBack && history.canGoForward)
        #expect(history.step(.forward) == "b")
        #expect(history.step(.forward) == "c")
        #expect(history.step(.forward) == nil)
        #expect(history.stack == ["a", "b", "c"])
    }

    @Test("Opening a canvas from the middle drops what was ahead, as a browser does")
    func openingDropsTheFuture() {
        let history = KnowledgeMapCanvasHistory()
        history.visit("b", from: "a")
        history.visit("c", from: "b")
        history.step(.back)
        history.step(.back)
        history.visit("d", from: "a")
        #expect(history.stack == ["a", "d"] && history.index == 1)
        #expect(!history.canGoForward)
    }

    @Test("The same canvas twice in a row is no new step, and a canvas opened some other way is placed first")
    func repeatsAndStrangers() {
        let history = KnowledgeMapCanvasHistory()
        history.visit("a", from: "a")
        #expect(history.stack == ["a"])
        history.visit("b", from: "a")
        history.visit("b", from: "b")
        #expect(history.stack == ["a", "b"])
        // An assistant opened "x" behind the window's back; the learner then opens "c".
        history.visit("c", from: "x")
        #expect(history.stack == ["a", "b", "x", "c"] && history.index == 3)
    }

    @Test("Forgetting a canvas keeps the place on the entry it was on, and merges neighbours that become the same")
    func forgetting() {
        let history = KnowledgeMapCanvasHistory()
        history.visit("b", from: "a")
        history.visit("c", from: "b")
        history.visit("b", from: "c")
        #expect(history.stack == ["a", "b", "c", "b"])
        history.forget("c")
        #expect(history.stack == ["a", "b"] && history.index == 1, "b, c, b is a, b once c is gone")
        history.step(.back)
        history.forget("b")
        #expect(history.stack == ["a"] && history.index == 0)
        history.forget("a")
        #expect(history.stack.isEmpty && history.index == -1 && !history.hasHistory)
    }

    @Test("Forgetting the canvas the place is on moves the place to the one before it")
    func forgettingTheCurrent() {
        let history = KnowledgeMapCanvasHistory()
        history.visit("b", from: "a")
        history.visit("c", from: "b")
        history.step(.back)
        history.forget("b")
        #expect(history.stack == ["a", "c"] && history.index == 0)
        #expect(history.candidate(.forward) == "c")
    }

    @Test("Only the newest fifty are kept")
    func capacity() {
        let history = KnowledgeMapCanvasHistory()
        history.visit("c1", from: "c0")
        for number in 2...60 { history.visit("c\(number)", from: "c\(number - 1)") }
        #expect(history.stack.count == KnowledgeMapCanvasHistory.capacity)
        #expect(history.stack.last == "c60" && history.index == KnowledgeMapCanvasHistory.capacity - 1)
        #expect(history.stack.first == "c11")
    }
}

@Suite("The tray's Regions list")
struct KnowledgeMapRegionOutlineTests {
    private func region(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> KnowledgeMapLayout.Region {
        .init(name: name, x: x, y: y, w: w, h: h, color: "#7F77DD", at: 1)
    }

    @Test("Reading order: left to right inside a row of the plane, top to bottom, each region before the ones inside it")
    func outline() {
        var layout = KnowledgeMapLayout()
        layout.setRegion("mootha", region("Mootha", 0, 0, 1200, 800))
        layout.setRegion("mtdna", region("mtDNA mutations", 100, 100, 500, 300))
        layout.setRegion("clonal", region("Clonal expansion", 650, 100, 400, 300))
        layout.setRegion("deep", region("Heteroplasmy", 120, 130, 200, 150))
        layout.setRegion("below", region("Methods", 0, 1000, 600, 300))
        layout.setRegion("right", region("Aging", 1500, 20, 600, 300))
        let rows = layout.regionOutline()
        #expect(rows.map(\.id) == ["mootha", "mtdna", "deep", "clonal", "right", "below"])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 0, 0])
    }

    @Test("No regions, no rows; two regions of one rect are both on the first level")
    func edges() {
        #expect(KnowledgeMapLayout().regionOutline().isEmpty)
        var layout = KnowledgeMapLayout()
        layout.setRegion("a", region("A", 0, 0, 300, 200))
        layout.setRegion("b", region("B", 0, 0, 300, 200))
        #expect(layout.regionOutline().map(\.depth) == [0, 0])
        #expect(layout.regionOutline().map(\.id) == ["a", "b"], "ties go by id, so the same plane lists the same way")
    }
}

@Suite("What a card's ref opens")
struct KnowledgeMapOpenRefTests {
    @Test("A canvas and a chat card are named by their prefix, whatever the ref parser knows")
    func prefixes() {
        #expect(StudioViewModel.knowledgeMapID(of: "canvas:cnv-1", prefix: "canvas:") == "cnv-1")
        #expect(StudioViewModel.knowledgeMapID(of: " chat:abc:def ", prefix: "chat:") == "abc:def")
        #expect(StudioViewModel.knowledgeMapID(of: "canvas:", prefix: "canvas:") == nil)
        #expect(StudioViewModel.knowledgeMapID(of: "source:abc", prefix: "canvas:") == nil)
    }
}

@Suite("Suggested questions for a chat opened from the Canvas")
struct KnowledgeMapSuggestedQuestionsTests {
    @Test("Three questions from the Ideas' sentences and the regions' names, no model asked")
    func three() {
        let questions = KnowledgeMapSuggestedQuestions.questions(
            ideas: ["Nobody reads absolute ΔΨm in humans", "mtDNA heteroplasmy drifts with age", "PINK1 is the sensor"],
            regions: ["Membrane potential", "Mitophagy"]
        )
        #expect(questions == [
            "What connects “Nobody reads absolute ΔΨm in humans” and “mtDNA heteroplasmy drifts with age”?",
            "What does “Membrane potential” leave open?",
            "What in my sources best supports “Nobody reads absolute ΔΨm in humans”?",
        ])
    }

    @Test("A canvas with less written on it offers what it can: an Idea alone, regions alone, or nothing")
    func lessOnTheCanvas() {
        #expect(KnowledgeMapSuggestedQuestions.questions(ideas: [], regions: []).isEmpty)
        #expect(KnowledgeMapSuggestedQuestions.questions(ideas: ["  "], regions: [""]).isEmpty, "a blank is not a title")
        #expect(KnowledgeMapSuggestedQuestions.questions(ideas: ["One claim"], regions: []) == [
            "What in my sources best supports “One claim”?",
            "Where do my sources disagree about “One claim”?",
        ])
        #expect(KnowledgeMapSuggestedQuestions.questions(ideas: [], regions: ["A", "B"]) == [
            "What does “A” leave open?",
            "How do “A” and “B” fit together?",
            "What does “B” leave open?",
        ])
    }

    @Test("Titles are one line, each once, and cut at a word when long; the same canvas asks the same way")
    func cleaning() {
        let long = "word " + String(repeating: "another ", count: 20)
        let cleaned = KnowledgeMapSuggestedQuestions.cleaned(["  two\nlines  here ", "Two lines here", long])
        #expect(cleaned.count == 2)
        #expect(cleaned[0] == "two lines here")
        #expect(cleaned[1].count <= KnowledgeMapSuggestedQuestions.titleCharacters && cleaned[1].hasSuffix("…"))
        let again = KnowledgeMapSuggestedQuestions.questions(ideas: ["a", "b"], regions: ["r"])
        #expect(again == KnowledgeMapSuggestedQuestions.questions(ideas: ["a", "b"], regions: ["r"]))
        #expect(again.count == KnowledgeMapSuggestedQuestions.limit)
    }
}

@MainActor
@Suite("A canvas's suggested questions, read from the open canvas")
struct KnowledgeMapCanvasQuestionsTests {
    @Test("The selected Ideas and the regions around them come first; sources are never asked about by name")
    func fromTheCanvas() throws {
        let suite = try #require(UserDefaults(suiteName: "KnowledgeMapCanvasQuestionsTests.\(UUID().uuidString)"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeMapCanvasQuestions_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
            let map = vm.knowledgeMap
            let ideas = [IdeaRecord(id: "a", title: "First claim"), IdeaRecord(id: "b", title: "Second claim"), IdeaRecord(id: "c", title: "Third claim")]
            let paper = StudioArticle(url: "https://example.com/p", title: "A paper", sourceType: .paper, id: "p")
            map.rebuildContent(articles: [paper], ideas: ideas, notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            map.place([
                (ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 300, y: 0), (ref: "idea:c", x: 1500, y: 0), (ref: "source:p", x: 600, y: 0),
            ])
            map.saveRegion(id: "r1", name: "Early", x: -50, y: -50, w: 800, h: 300, color: "#7F77DD")
            map.saveRegion(id: "r2", name: "Late", x: 1400, y: -50, w: 400, h: 300, color: "#1D9E75")

            let plain = vm.knowledgeMapSuggestedQuestions()
            #expect(plain == [
                "What connects “First claim” and “Second claim”?",
                "What does “Early” leave open?",
                "What in my sources best supports “First claim”?",
            ])
            let selected = vm.knowledgeMapSuggestedQuestions(selection: ["idea:c"])
            #expect(selected.first == "What connects “Third claim” and “First claim”?")
            #expect(selected.dropFirst().first == "What does “Late” leave open?", "the region around the selected card first")
            #expect(!plain.joined().contains("A paper"))
        }
    }
}

@MainActor
@Suite("Open and navigate: the view model's side")
struct KnowledgeMapOpenViewModelTests {
    private func withCanvasDefaults(_ body: (StudioViewModel) async throws -> Void) async throws {
        let suiteName = "KnowledgeMapOpenViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeMapOpenViewModel_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            try await PageSpaceRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
                try await body(StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false))
            }
        }
    }

    private func paper(_ id: String) -> StudioArticle {
        StudioArticle(url: "https://example.com/\(id)", title: "Paper \(id)", sourceType: .paper, id: id)
    }

    @Test("⌘-click: a popup for a card the Canvas holds, one at a time; none for a card it does not; opening beside closes it")
    func popup() async throws {
        try await withCanvasDefaults { vm in
            vm.knowledgeMap.rebuildContent(articles: [paper("a"), paper("b")], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            let rect = CGRect(x: 10, y: 20, width: 240, height: 120)
            vm.showKnowledgeMapPopup("source:a", near: rect)
            #expect(vm.knowledgeMap.popup?.ref == "source:a" && vm.knowledgeMap.popup?.rect == rect)
            #expect(vm.knowledgeMap.popup?.windowID == vm.activeWindowState.id, "drawn in the window it was asked for")
            vm.showKnowledgeMapPopup("source:b", near: rect)
            #expect(vm.knowledgeMap.popup?.ref == "source:b", "one at a time")
            vm.showKnowledgeMapPopup("source:missing", near: rect)
            #expect(vm.knowledgeMap.popup?.ref == "source:b", "a card the Canvas does not hold has no popup")
            let other = vm.createCanvas(named: "Other")
            await vm.openKnowledgeMapItemBeside("canvas:\(other.id)", in: vm.activeWindowState)
            #expect(vm.knowledgeMap.popup == nil, "the card was opened: its popup is done")
            vm.knowledgeMap.popup = KnowledgeMapPopup(ref: "source:a", rect: rect)
            vm.dismissKnowledgeMapPopup()
            #expect(vm.knowledgeMap.popup == nil)
        }
    }

    @Test("A canvas card opens that canvas; opening pushes it on the window's history, and ⌘[ ⌘] walk it, skipping one deleted since")
    func history() async throws {
        try await withCanvasDefaults { vm in
            let window = vm.activeWindowState
            let first = vm.createCanvas(named: "First"), second = vm.createCanvas(named: "Second"), third = vm.createCanvas(named: "Third")
            vm.openCanvas(first.id, in: window)
            vm.openCanvas(second.id, in: window)
            await vm.openKnowledgeMapItemBeside("canvas:\(third.id)", in: window)
            #expect(vm.knowledgeMap.mapID == third.id)
            #expect(window.canvasHistory.stack.suffix(3) == [first.id, second.id, third.id])
            vm.navigateCanvasHistory(.back, in: window)
            #expect(vm.knowledgeMap.mapID == second.id)
            #expect(window.canvasHistory.stack.suffix(3) == [first.id, second.id, third.id], "walking pushes nothing")
            vm.navigateCanvasHistory(.forward, in: window)
            #expect(vm.knowledgeMap.mapID == third.id)
            vm.navigateCanvasHistory(.forward, in: window)
            #expect(vm.knowledgeMap.mapID == third.id, "nothing after the last")

            vm.moveCanvasesToTrash([second.id])
            vm.deleteCanvasesForever([second.id])
            vm.navigateCanvasHistory(.back, in: window)
            #expect(vm.knowledgeMap.mapID == first.id, "the deleted canvas is skipped")
            #expect(!window.canvasHistory.stack.contains(second.id))
        }
    }

    @Test("A canvas made from sources: named for the first, the sources one block in a region, a chat beside it with the question typed and no suggested questions")
    func canvasFromSources() async throws {
        try await withCanvasDefaults { vm in
            vm.articles = [paper("a"), paper("b")]
            let canvas = try #require(vm.makeCanvasFromSources(sourceIDs: ["b", "a", "a", "missing"]))
            #expect(canvas.name == vm.displayTitle(for: paper("b")))
            #expect(vm.knowledgeMap.mapID == canvas.id, "opened")
            #expect(Set(vm.knowledgeMap.layout.placements.keys) == ["source:a", "source:b"])
            let region = try #require(vm.knowledgeMap.layout.regions.values.first)
            #expect(vm.knowledgeMap.layout.regions.count == 1 && region.name == StudioViewModel.canvasFromSourcesRegionName)
            #expect(vm.pendingReviewChatDraft == "Help me make sense of these 2 sources on my Canvas: what are the main ideas and how do they connect?")
            #expect(vm.pendingReviewChatCanvasQuestions.isEmpty)
            #expect(vm.reviewChatResetRequestID != nil, "a fresh chat")
            #expect(StudioViewModel.canvasFromSourcesDraft(count: 1).hasPrefix("Help me make sense of this source"))

            let named = try #require(vm.makeCanvasFromSources(sourceIDs: ["a"], name: "  Mitophagy  "))
            #expect(named.name == "Mitophagy")
            #expect(vm.makeCanvasFromSources(sourceIDs: ["nope"]) == nil, "nothing the library holds, no canvas")
        }
    }
}
