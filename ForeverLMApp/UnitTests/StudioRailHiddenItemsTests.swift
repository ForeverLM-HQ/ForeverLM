import Foundation
import Testing
@testable import ForeverLM

@Suite("Navigation rail hidden items")
struct StudioRailHiddenItemsTests {
    @Test("Nothing is hidden until the learner hides something")
    func emptyStorageHidesNothing() {
        let hidden = StudioRailHiddenItems(storage: "")
        #expect(hidden.items.isEmpty)
        #expect(hidden.visibleTopItems == [.newChat, .memory, .space, .browser, .library])
        #expect(!hidden.contains(.memory))
    }

    @Test("The rail's rows: New chat, Memory, Spaces, Browser and Library are its top rows")
    func topRowsSinceShellStage4() {
        // Shell stage 4 (2026-10-01): Activity is reached from the Now chip,
        // Courses and Artifacts from the Space. Spaces sits beside Memory.
        // The Canvas row (2026-10-05) left on 2026-10-07: a canvas is an item
        // in the Space. The Home row (2026-10-07) left on 2026-10-09, with
        // the Notebooks home it opened: the Space lists every notebook.
        #expect(StudioRailItem.allCases == [.newChat, .memory, .space, .browser, .library])
        let rows = StudioRailHiddenItems().visibleTopItems.map(\.rawValue)
        #expect(!rows.contains("activity"))
        #expect(!rows.contains("courses"))
        #expect(!rows.contains("artifacts"))
    }

    @Test("A stored hidden Activity, Courses or Artifacts falls out of the set, as earlier retirements did")
    func retiredRowsFallOut() {
        let stale = StudioRailHiddenItems(storage: "activity,artifacts,browser,courses")
        #expect(stale.items == [.browser], "the retired rows are dropped; Browser stays hidden")
        #expect(stale.storage == "browser")
        #expect(stale.visibleTopItems == [.newChat, .memory, .space, .library])

        let allRetired = StudioRailHiddenItems(storage: "activity,courses,artifacts")
        #expect(allRetired.items.isEmpty)
        #expect(allRetired.storage.isEmpty, "the next write leaves no trace of them")
        #expect(allRetired.visibleTopItems == [.newChat, .memory, .space, .browser, .library])
    }

    @Test("Hiding and showing a row round-trips through its stored form")
    func roundTrip() {
        let hidden = StudioRailHiddenItems()
            .setting(.memory, hidden: true)
            .setting(.browser, hidden: true)
        #expect(hidden.storage == "browser,memory")
        let decoded = StudioRailHiddenItems(storage: hidden.storage)
        #expect(decoded == hidden)
        #expect(decoded.visibleTopItems == [.newChat, .space, .library])

        let shownAgain = decoded.setting(.memory, hidden: false)
        #expect(shownAgain.visibleTopItems == [.newChat, .memory, .space, .library])
        #expect(shownAgain.toggling(.browser).items.isEmpty)
    }

    @Test("The retired kind rows of 2026-09-17 to 09-20 fall out of the stored set")
    func kindRowsFallOut() {
        // Docs, Sites, Videos and Animations were rows folded beneath
        // Artifacts, so a hidden set saved then may still name them. They
        // are the Artifacts index's kind chips now.
        let stale = StudioRailHiddenItems(storage: "sites,docs,videos,animations")
        #expect(stale.items.isEmpty, "the retired kind rows are dropped")
        #expect(stale.storage.isEmpty)
        #expect(stale.visibleTopItems == [.newChat, .memory, .space, .browser, .library])
    }

    @Test("Goals, Ideas and Planner are off the rail; a stored one falls out of the set")
    func earlierRetirements() {
        let stale = StudioRailHiddenItems(storage: "goals,ideas,planner,library")
        #expect(stale.items == [.library])
        #expect(stale.storage == "library")
        #expect(stale.visibleTopItems == [.newChat, .memory, .space, .browser])
    }

    @Test("A hidden row comes back in its own place")
    func hiddenRowComesBackInPlace() {
        let bothHidden = StudioRailHiddenItems()
            .setting(.memory, hidden: true)
            .setting(.newChat, hidden: true)
        #expect(bothHidden.visibleTopItems == [.space, .browser, .library])
        #expect(StudioRailHiddenItems(storage: bothHidden.storage) == bothHidden)

        let memoryBack = bothHidden.toggling(.memory)
        #expect(memoryBack.visibleTopItems == [.memory, .space, .browser, .library], "Memory comes back in its own place, not where New chat was")
    }

    @Test("The Home row is off the rail since the Notebooks home went; a stored hidden one falls out of the set, and Library closes the top block")
    func homeRowRetired() {
        // The Notebooks home (the `notebooks` row, "All notebooks" before
        // 2026-10-07) went on 2026-10-09: the Space leads the rail.
        #expect(StudioRailItem(rawValue: "notebooks") == nil)
        let stale = StudioRailHiddenItems(storage: "browser,notebooks,memory")
        #expect(stale.items == [.browser, .memory], "the retired name is dropped; the other rows stay hidden")
        #expect(stale.storage == "browser,memory", "the learner's next change leaves it out")
        #expect(StudioRailHiddenItems().visibleTopItems.last == .library)
        #expect(StudioRailHiddenItems.railOrder == [.space, .memory, .library], "the Space is the rail's first row")
        let libraryHidden = StudioRailHiddenItems().setting(.library, hidden: true)
        #expect(libraryHidden.visibleTopItems.last == .browser)
    }

    @Test("The Canvas row is off the rail since canvases are Space items; a stored hidden one falls out of the set")
    func canvasRowRetired() {
        let stale = StudioRailHiddenItems(storage: "knowledgeMap,memory")
        #expect(stale.items == [.memory])
        #expect(stale.storage == "memory")
        #expect(!StudioRailItem.allCases.map(\.rawValue).contains("knowledgeMap"))
        #expect(!StudioRailHiddenItems.railOrder.map(\.rawValue).contains("knowledgeMap"))
    }

    @Test("A name this build does not know is dropped, and stray spaces are tolerated")
    func unknownNamesAreDropped() {
        let hidden = StudioRailHiddenItems(storage: "memory, schedule ,browser")
        #expect(hidden.items == [.memory, .browser])
        #expect(hidden.storage == "browser,memory")
    }

    @Test("Every hideable row has a title and an icon")
    func everyItemIsLabelled() {
        for item in StudioRailItem.allCases {
            #expect(!item.title.isEmpty)
            #expect(!item.systemImage.isEmpty)
        }
    }

    @Test("set_app_setting's window.rail_hidden_items is a JSON array of row ids, stored in the form the rail reads")
    func mcpSettingRoundTrips() throws {
        let stored = try MCPDataStore.railHiddenItemsStorage(fromJSON: #"["memory","browser"]"#)
        #expect(stored == "browser,memory")
        #expect(StudioRailHiddenItems(storage: stored).items == [.memory, .browser], "the rail hides what the assistant hid")
        #expect(try MCPDataStore.railHiddenItemsStorage(fromJSON: "[]").isEmpty)
        #expect(MCPDataStore.railHiddenItemsJSON("browser,courses,memory") == #"["browser","memory"]"#, "a retired row is not read back")
        #expect(MCPDataStore.railHiddenItemsJSON("") == "[]")
        #expect(throws: MCPError.self) { try MCPDataStore.railHiddenItemsStorage(fromJSON: #"["courses"]"#) }
        #expect(throws: MCPError.self) { try MCPDataStore.railHiddenItemsStorage(fromJSON: "memory") }
    }
}

/// The Canvas and the Atlas are beta features (`BetaFeatures`, the product owner
/// 2026-10-06): production shows neither, a Mac signed up for beta releases
/// and the Dev build show both. These tests run in a Dev build, so they ask
/// each rule about a production Mac by passing `showsCanvas` themselves.
@Suite("Beta features: the Canvas and the Atlas")
struct BetaFeaturesCanvasGateTests {
    @Test("The Canvas shows where the learner signed up for betas, and in the Dev build, and nowhere else")
    func rule() {
        #expect(!BetaFeatures.showsCanvas(signedUpForBetas: false, inDevBuild: false), "a production Mac")
        #expect(BetaFeatures.showsCanvas(signedUpForBetas: true, inDevBuild: false), "a Mac signed up for betas")
        #expect(BetaFeatures.showsCanvas(signedUpForBetas: false, inDevBuild: true), "ForeverLM Dev")
        #expect(BetaFeatures.canvasCenterTabs == [.knowledgeMap, .atlas])
    }

    @Test("A production Mac's Space lists no Canvases place; a beta Mac's lists it after Sites")
    func spacePlace() {
        #expect(!SpaceDestination.places(listsCanvases: false).contains(.canvases))
        #expect(SpaceDestination.places(listsCanvases: true) == [.all, .notebooks, .chats, .pages, .sites, .canvases, .images, .drive])
    }

    @Test("A layout showing the Canvas or the Atlas shows another tab instead, the Space first, and nothing else moves")
    func layoutSteersAway() {
        let unoffered = BetaFeatures.canvasCenterTabs
        let onCanvas = StudioCenterTabGroups.reconciled(StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .artifacts, .knowledgeMap, .reader], activeTab: .knowledgeMap),
        ]))
        let steered = onCanvas.withoutShowing(unoffered)
        #expect(steered.groups.count == 1)
        #expect(steered.groups[0].activeTab == .artifacts)
        #expect(steered.groups[0].tabs == onCanvas.groups[0].tabs, "the tabs keep their places")

        // Missing permanent tabs join the last pane, so the Space is in the first.
        let atlasBeside = StudioCenterTabGroups.reconciled(StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat], activeTab: .chat),
            .init(tabs: [.atlas, .tasks], activeTab: .atlas),
        ]))
        let atlasSteered = atlasBeside.withoutShowing(unoffered)
        #expect(atlasSteered.groups.map(\.activeTab) == [.chat, .tasks], "no Space in the pane: its first other tab")

        // Nothing changes for a layout showing neither, or where they show.
        #expect(StudioCenterTabGroups.defaultLayout.withoutShowing(unoffered) == StudioCenterTabGroups.defaultLayout)
        #expect(onCanvas.withoutShowing([]) == onCanvas)
    }

    @Test("A pane holding only the Canvas closes, and the Canvas waits behind the other pane")
    func lonePaneCloses() {
        // Missing permanent tabs join the last pane, so the lone one is first.
        let beside = StudioCenterTabGroups.reconciled(StudioCenterTabGroups(groups: [
            .init(tabs: [.knowledgeMap], activeTab: .knowledgeMap),
            .init(tabs: [.artifacts, .chat, .reader], activeTab: .chat),
        ]))
        #expect(beside.groups.count == 2 && beside.groups[0].tabs == [.knowledgeMap])
        let steered = beside.withoutShowing(BetaFeatures.canvasCenterTabs)
        #expect(steered.groups.count == 1)
        #expect(steered.groups[0].activeTab == .chat)
        #expect(steered.groups[0].tabs.contains(.knowledgeMap), "a permanent tab is never dropped, only taken off screen")
        #expect(steered == StudioCenterTabGroups.reconciled(steered))
    }

    @Test("Every Canvas and Atlas tool is in the registry, and no MCP tool is gated behind the beta sign-up")
    func mcpTools() {
        let names = Set(MCPToolRegistry().tools.map(\.name))
        // The Canvas's screens are beta; its tools are not (product owner, 2026-10-09: "nothing in the MCP
        // should be gated behind beta status"). A connector lists and calls them on any Mac.
        let canvasTools = MCPToolRegistry.knowledgeMapToolNames
            .union(MCPToolRegistry.canvasCatalogToolNames)
            .union(MCPToolRegistry.canvasAskToolNames)
            .union(MCPToolRegistry.canvasMemoryToolNames)
            .union(MCPToolRegistry.atlasToolNames)
        #expect(canvasTools.count == 27 + 1 + 4 + 3, "the 27 before build_canvas, build_canvas, the parity build's four (update_canvas_card, arrange_on_canvas, lint_canvas, screenshot_canvas) and the three that list, keep and restore a canvas's versions")
        #expect(canvasTools.isSubset(of: names))
        #expect(canvasTools.contains("build_canvas"))
        #expect(MCPToolRegistry.canvasVersionToolNames.isSubset(of: canvasTools))
        #expect(canvasTools.contains("make_atlas"))
        #expect(!canvasTools.contains("get_source_levels"), "Reader Levels is not the Canvas's")
    }
}

@Suite("Icon strip shortcuts")
struct StudioRailShortcutsTests {
    @Test("None until the learner keeps one; kept ones come back in the order kept")
    func keptInOrder() {
        #expect(StudioRailShortcuts(storage: "").items.isEmpty)
        let kept = StudioRailShortcuts()
            .setting(.place(.pages), shown: true)
            .setting(.courses, shown: true)
            .setting(.place(.canvases), shown: true)
        #expect(kept.storage == "pages,courses,canvases")
        #expect(StudioRailShortcuts(storage: kept.storage) == kept)
        let removed = kept.setting(.courses, shown: false)
        #expect(removed.items == [.place(.pages), .place(.canvases)])
        // Kept again, it goes to the end, never twice.
        #expect(removed.setting(.place(.pages), shown: true).items == [.place(.canvases), .place(.pages)])
    }

    @Test("A key that names no shortcut — All, Trash, a team's place, a retired one — is dropped, and repeats too")
    func unknownKeysFallOut() {
        let stored = StudioRailShortcuts(storage: "all,trash,team:t-1,space:psp-1,ideas,pages,pages, sites")
        #expect(stored.items == [.place(.pages), .place(.sites)])
        #expect(stored.storage == "pages,sites")
    }

    @Test("The places offered follow the Space sidebar: Notebooks, Chats, Courses, then the rest; Canvases only where listed")
    func offeredPlaces() {
        #expect(StudioRailShortcut.offered(listsCanvases: true).map(\.key)
            == ["notebooks", "chats", "courses", "pages", "sites", "canvases", "images", "drive"])
        #expect(!StudioRailShortcut.offered(listsCanvases: false).contains(.place(.canvases)))
        let kept = StudioRailShortcuts([.place(.canvases), .place(.images)])
        #expect(kept.shown(listsCanvases: false) == [.place(.images)], "a kept Canvases waits where canvases are not listed")
        #expect(kept.shown(listsCanvases: true) == [.place(.canvases), .place(.images)])
    }

    @Test("Over MCP the shortcuts are a JSON array of place ids, refused when one is unknown")
    @MainActor
    func mcpRoundTrip() throws {
        let storage = try MCPDataStore.railShortcutsStorage(fromJSON: #"["courses","pages"]"#)
        #expect(storage == "courses,pages")
        #expect(MCPDataStore.railShortcutsJSON(storage) == #"["courses","pages"]"#)
        #expect(throws: (any Error).self) { try MCPDataStore.railShortcutsStorage(fromJSON: #"["trash"]"#) }
        #expect(throws: (any Error).self) { try MCPDataStore.railShortcutsStorage(fromJSON: "pages") }
    }
}
