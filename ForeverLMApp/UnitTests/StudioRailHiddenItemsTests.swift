import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ForeverLM

@Suite("Navigation rail hidden items")
struct StudioRailHiddenItemsTests {
    @Test("Nothing is hidden until the learner hides something")
    func emptyStorageHidesNothing() {
        let hidden = StudioRailHiddenItems(storage: "")
        #expect(hidden.items.isEmpty)
        #expect(hidden.visibleTopItems == [.home, .newChat, .memory, .space, .browser, .library, .plugins])
        #expect(!hidden.contains(.memory))
    }

    @Test("The rail's rows: Home, New chat, Memory, Spaces, Browser, Library and Plugins are its top rows")
    func topRowsSinceShellStage4() {
        // Shell stage 4 (2026-10-01): Activity is reached from the Now chip,
        // Courses and Artifacts from the Space. Spaces sits beside Memory.
        // The Canvas row (2026-10-05) left on 2026-10-07: a canvas is an item
        // in the Space. The Home row (2026-10-07) left on 2026-10-09, with
        // the Notebooks home it opened: the Space lists every notebook.
        // Plugins came out of Settings onto the strip on 2026-10-13.
        #expect(StudioRailItem.allCases == [.home, .newChat, .memory, .space, .browser, .library, .plugins])
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
        #expect(stale.visibleTopItems == [.home, .newChat, .memory, .space, .library, .plugins])

        let allRetired = StudioRailHiddenItems(storage: "activity,courses,artifacts")
        #expect(allRetired.items.isEmpty)
        #expect(allRetired.storage.isEmpty, "the next write leaves no trace of them")
        #expect(allRetired.visibleTopItems == [.home, .newChat, .memory, .space, .browser, .library, .plugins])
    }

    @Test("Hiding and showing a row round-trips through its stored form")
    func roundTrip() {
        let hidden = StudioRailHiddenItems()
            .setting(.memory, hidden: true)
            .setting(.browser, hidden: true)
        #expect(hidden.storage == "browser,memory")
        let decoded = StudioRailHiddenItems(storage: hidden.storage)
        #expect(decoded == hidden)
        #expect(decoded.visibleTopItems == [.home, .newChat, .space, .library, .plugins])

        let shownAgain = decoded.setting(.memory, hidden: false)
        #expect(shownAgain.visibleTopItems == [.home, .newChat, .memory, .space, .library, .plugins])
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
        #expect(stale.visibleTopItems == [.home, .newChat, .memory, .space, .browser, .library, .plugins])
    }

    @Test("Goals, Ideas and Planner are off the rail; a stored one falls out of the set")
    func earlierRetirements() {
        let stale = StudioRailHiddenItems(storage: "goals,ideas,planner,library")
        #expect(stale.items == [.library])
        #expect(stale.storage == "library")
        #expect(stale.visibleTopItems == [.home, .newChat, .memory, .space, .browser, .plugins])
    }

    @Test("A hidden row comes back in its own place")
    func hiddenRowComesBackInPlace() {
        let bothHidden = StudioRailHiddenItems()
            .setting(.memory, hidden: true)
            .setting(.newChat, hidden: true)
        #expect(bothHidden.visibleTopItems == [.home, .space, .browser, .library, .plugins])
        #expect(StudioRailHiddenItems(storage: bothHidden.storage) == bothHidden)

        let memoryBack = bothHidden.toggling(.memory)
        #expect(memoryBack.visibleTopItems == [.home, .memory, .space, .browser, .library, .plugins], "Memory comes back in its own place, not where New chat was")
    }

    @Test("The Home row is off the rail since the Notebooks home went; a stored hidden one falls out of the set, and Plugins closes the top block")
    func homeRowRetired() {
        // The Notebooks home (the `notebooks` row, "All notebooks" before
        // 2026-10-07) went on 2026-10-09: the Space leads the rail.
        #expect(StudioRailItem(rawValue: "notebooks") == nil)
        let stale = StudioRailHiddenItems(storage: "browser,notebooks,memory")
        #expect(stale.items == [.browser, .memory], "the retired name is dropped; the other rows stay hidden")
        #expect(stale.storage == "browser,memory", "the learner's next change leaves it out")
        #expect(StudioRailHiddenItems().visibleTopItems.last == .plugins)
        #expect(StudioRailHiddenItems.railOrder == [.home, .space, .memory, .library, .plugins], "Home leads and has taken the + 's place, then the Space")
        let libraryHidden = StudioRailHiddenItems().setting(.library, hidden: true).setting(.plugins, hidden: true)
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
        #expect(SpaceDestination.places(listsCanvases: true) == [.all, .notebooks, .board, .plan, .pages, .sites, .animations, .canvases, .images, .drive])
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

    @Test("The places offered follow the Space sidebar: Notebooks, Courses, then the rest; Canvases only where listed")
    func offeredPlaces() {
        #expect(StudioRailShortcut.offered(listsCanvases: true).map(\.key)
            == ["notebooks", "courses", "board", "plan", "pages", "sites", "animations", "canvases", "images", "drive"])
        #expect(!StudioRailShortcut.offered(listsCanvases: false).contains(.place(.canvases)))
        let kept = StudioRailShortcuts([.place(.canvases), .place(.images)])
        #expect(kept.shown(listsCanvases: false) == [.place(.images)], "a kept Canvases waits where canvases are not listed")
        #expect(kept.shown(listsCanvases: true) == [.place(.canvases), .place(.images)])
    }

    @Test("The strip's own order until the learner drags; a dragged icon takes the place of the one it reaches")
    func stripOrderMoves() {
        let shown = ["home", "space", "memory", "library", "plugins"]
        #expect(StudioStripOrder(storage: "").arranged(shown) == shown)
        // Down: Home past Memory lands below it. Up: Plugins to Space lands above it.
        let down = StudioStripOrder().moving("home", to: "memory", shown: shown)
        #expect(down.arranged(shown) == ["space", "memory", "home", "library", "plugins"])
        let up = down.moving("plugins", to: "space", shown: shown)
        #expect(up.arranged(shown) == ["plugins", "space", "memory", "home", "library"])
        // Onto itself, or onto an icon not shown, nothing moves.
        #expect(up.moving("home", to: "home", shown: shown) == up)
        #expect(up.moving("home", to: "voice", shown: shown) == up)
        // It round-trips through its stored form.
        #expect(StudioStripOrder(storage: up.storage) == up)
    }

    @Test("A hidden icon keeps its place, and one never placed stands after the one before it in the strip's own order")
    func stripOrderKeepsHiddenAndNewIcons() {
        let order = StudioStripOrder(["library", "home", "space", "memory", "plugins"])
        // Memory hidden, then shown again: back where it was.
        #expect(order.arranged(["home", "space", "library", "plugins"]) == ["library", "home", "space", "plugins"])
        #expect(order.arranged(["home", "space", "memory", "library", "plugins"]) == ["library", "home", "space", "memory", "plugins"])
        // A newly kept place follows the last icon before it: Plugins.
        #expect(order.arranged(["home", "space", "memory", "library", "plugins", "pages"])
            == ["library", "home", "space", "memory", "plugins", "pages"])
        // A stored name this build does not show is harmless.
        #expect(StudioStripOrder(["retired", "home"]).arranged(["home", "space"]) == ["home", "space"])
    }

    @Test("A place dragged in from the Space sidebar lands above the icon it is dropped on, or last")
    func stripOrderPlacesDroppedPlace() {
        let shown = ["home", "space", "memory", "pages"]
        let order = StudioStripOrder()
        #expect(order.placing("images", before: "space", shown: shown).arranged(shown + ["images"])
            == ["home", "images", "space", "memory", "pages"])
        #expect(order.placing("images", before: nil, shown: shown).arranged(shown + ["images"])
            == ["home", "space", "memory", "pages", "images"])
        // A kept one moves rather than repeats.
        #expect(order.placing("pages", before: "home", shown: shown).arranged(shown) == ["pages", "home", "space", "memory"])
    }

    @Test("Every strip icon has a key of its own, read back as the same icon, and the groups never share one")
    func stripEntryKeys() {
        let rows = StudioRailItem.allCases.map(StudioStripEntry.row)
        let places = StudioRailShortcut.offered(listsCanvases: true).map(StudioStripEntry.shortcut)
        let footer = StudioStripFooterItem.allCases.map(StudioStripEntry.footer)
        let all = rows + places + footer
        #expect(Set(all.map(\.key)).count == all.count)
        for entry in all { #expect(StudioStripEntry(key: entry.key) == entry) }
        let footerAreFooter = footer.allSatisfy(\.isFooter)
        let topHasFooter = (rows + places).contains(where: \.isFooter)
        #expect(footerAreFooter)
        #expect(!topHasFooter)
        #expect(StudioStripEntry(key: "trash") == nil)
    }

    @Test("A strip icon's drag is a pane drag and carries the icon")
    @MainActor
    func stripEntryDrag() {
        let visibility = StudioDragVisibility.shared
        defer { visibility.endNow() }
        StudioRailShortcut.place(.pages).beginDrag(onStrip: true)
        #expect(visibility.draggedStripEntry == .shortcut(.place(.pages)))
        StudioRailShortcut.place(.pages).beginDrag()
        #expect(visibility.draggedStripEntry == nil, "the Space sidebar's row is a place coming in, not a strip icon")
        visibility.begin(stripEntry: .footer(.account))
        #expect(visibility.isPaneDrag)
        let provider = NSItemProvider().carryingStripEntry(.footer(.account))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.studioStripEntry.identifier))
        visibility.endNow()
        #expect(visibility.draggedStripEntry == nil)
    }

    @Test("Over MCP each group's order is a JSON array of its own icon ids")
    @MainActor
    func stripOrderOverMCP() throws {
        let top = try MCPDataStore.stripOrderStorage(fromJSON: #"["memory","pages","home"]"#, footer: false, setting: "window.rail_order")
        #expect(top == "memory,pages,home")
        #expect(MCPDataStore.stripOrderJSON(top) == #"["memory","pages","home"]"#)
        let footer = try MCPDataStore.stripOrderStorage(fromJSON: #"["account","voice"]"#, footer: true, setting: "window.rail_footer_order")
        #expect(footer == "account,voice")
        #expect(throws: (any Error).self) {
            try MCPDataStore.stripOrderStorage(fromJSON: #"["voice"]"#, footer: false, setting: "window.rail_order")
        }
        #expect(throws: (any Error).self) {
            try MCPDataStore.stripOrderStorage(fromJSON: #"["home"]"#, footer: true, setting: "window.rail_footer_order")
        }
        #expect(throws: (any Error).self) {
            try MCPDataStore.stripOrderStorage(fromJSON: #"["newChat"]"#, footer: false, setting: "window.rail_order")
        }
    }

    @Test("A Space row's drag carries the place for the strip, and its pane where it has one")
    func dragCarriesPlaceAndPane() async {
        func load(_ provider: NSItemProvider) async -> StudioRailShortcut? {
            await withCheckedContinuation { continuation in
                let found = StudioRailShortcut.loadDropped(from: [provider]) { continuation.resume(returning: $0) }
                if !found { continuation.resume(returning: nil) }
            }
        }

        let pages = StudioRailShortcut.place(.pages).dragProvider()
        #expect(pages.hasItemConformingToTypeIdentifier(StudioCenterTabDragPayload.contentType.identifier), "the edge split still opens Pages beside")
        #expect(await load(pages) == .place(.pages))

        let courses = StudioRailShortcut(hub: .courses).dragProvider()
        #expect(courses.hasItemConformingToTypeIdentifier(StudioCenterTabDragPayload.contentType.identifier))
        #expect(await load(courses) == .courses)

        // Notebooks opens only in the Space: the strip is its one destination.
        let notebooks = StudioRailShortcut.place(.notebooks).dragProvider()
        #expect(!notebooks.hasItemConformingToTypeIdentifier(StudioCenterTabDragPayload.contentType.identifier))
        #expect(await load(notebooks) == .place(.notebooks))

        #expect(StudioRailShortcut.loadDropped(from: [NSItemProvider(object: "pages" as NSString)]) { _ in } == false)
    }

    @Test("A place on its way to the strip hides the content drop zones, as a pane does")
    @MainActor
    func placeDragIsPaneDrag() {
        let visibility = StudioDragVisibility.shared
        defer { visibility.endNow() }
        StudioRailShortcut.place(.images).beginDrag()
        #expect(visibility.draggedRailShortcut == .place(.images))
        #expect(visibility.draggedCenterTab == nil)
        #expect(visibility.isPaneDrag)
        StudioRailShortcut.place(.pages).beginDrag()
        #expect(visibility.draggedCenterTab == .notepad)
        visibility.endNow()
        #expect(visibility.draggedRailShortcut == nil)
    }

    @Test("Google Drive keeps its own logo on the strip; the other places their symbol")
    func driveLogo() {
        #expect(StudioRailShortcut.place(.drive).assetImage == "GoogleDriveIcon")
        #expect(StudioRailShortcut.offered(listsCanvases: true).filter { $0.assetImage != nil } == [.place(.drive)])
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

    @Test("Every bottom icon shows until the learner hides it; a hidden one round-trips through its stored form")
    func footerHiddenRoundTrip() {
        #expect(StudioStripFooterHiddenItems(storage: "").items.isEmpty)
        let hidden = StudioStripFooterHiddenItems()
            .setting(.voice, hidden: true)
            .setting(.mcp, hidden: true)
            .setting(.account, hidden: true)
        #expect(hidden.storage == "account,mcp,voice")
        #expect(StudioStripFooterHiddenItems(storage: hidden.storage) == hidden)
        #expect(hidden.setting(.mcp, hidden: false).storage == "account,voice")
        #expect(StudioStripFooterHiddenItems(storage: "voice, gone ,day").items == [.voice, .day], "an unknown name drops out")
    }

    @Test("Every bottom icon has a name and a glyph for Show in Sidebar")
    func footerItemsNamed() {
        #expect(Set(StudioStripFooterItem.allCases.map(\.title)).count == StudioStripFooterItem.allCases.count)
        #expect(StudioStripFooterItem.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    @Test("Over MCP the hidden bottom icons are a JSON array of icon ids, refused when one is unknown")
    @MainActor
    func footerHiddenMCPRoundTrip() throws {
        let storage = try MCPDataStore.stripFooterHiddenStorage(fromJSON: #"["voice","settings"]"#)
        #expect(storage == "settings,voice")
        #expect(MCPDataStore.stripFooterHiddenJSON(storage) == #"["settings","voice"]"#)
        #expect(MCPDataStore.stripFooterHiddenJSON("") == "[]")
        #expect(throws: (any Error).self) { try MCPDataStore.stripFooterHiddenStorage(fromJSON: #"["memory"]"#) }
        #expect(throws: (any Error).self) { try MCPDataStore.stripFooterHiddenStorage(fromJSON: "voice") }
    }
}
