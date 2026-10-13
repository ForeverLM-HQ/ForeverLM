import Foundation
import Testing
@testable import ForeverLM

// Plugins is a place, as in Codex (docs/codex-shell-plan.md, Track 2): the
// strip's row under the Library opens a directory of every plugin, a plugin's
// page opens inside it, and Settings has no Plugins. Every way that opened a
// plugin's Settings pane — open_settings, a chat's connect card, the web's
// links into the Mac — opens the place instead, by the same ids.

@Suite("The Plugins place")
struct PluginsPlaceTests {
    @Test("A plugin's page keeps the id open_settings always took for it")
    func pageIDsAreTheOpenSettingsIDs() {
        #expect(PluginPage.allCases.map(\.rawValue) == [
            "x", "youtube", "google_drive", "apple_calendar", "slack", "linear", "github", "notion", "build_your_own_plugin",
        ])
        #expect(PluginPage.builtIn == [.x, .youtube, .googleDrive, .appleCalendar, .slack, .linear, .github, .notion])
        for page in PluginPage.allCases {
            #expect(!page.title.isEmpty)
            #expect(page.about.hasSuffix("."), "\(page)'s line is a sentence")
        }
        #expect(PluginPage.appleCalendar.title == "Calendar")
        #expect(PluginPage.yourPlugins.title == "Build Your Own")
    }

    @Test("Plugins is a shell place of its own, on the strip under the Library")
    @MainActor
    func placeAndRow() {
        let place = ShellPlaces.descriptor(for: .plugins)
        #expect(place.module == .plugins && place.module.isShell)
        #expect(place.sidebar == nil)
        #expect(StudioCenterTab.plugins.rawValue == "plugins", "stored layouts name it so")
        #expect(StudioCenterTab.permanentTabs.contains(.plugins))
        #expect(StudioRailHiddenItems.railOrder == [.newChat, .space, .memory, .library, .plugins])
        #expect(StudioRailItem.plugins.rawValue == "plugins")
        #expect(StudioRailItem.plugins.systemImage == "square.grid.2x2", "Codex's grid")
        // Hideable like the other rows, from Show in Sidebar.
        let hidden = StudioRailHiddenItems(storage: "plugins")
        #expect(hidden.railItems() == [.newChat, .space, .memory, .library])
        #expect(StudioRailHiddenItems(storage: hidden.setting(.plugins, hidden: false).storage).railItems().last == .plugins)
        // It leaves a notebook, as the Library does.
        #expect(NotebookWorkspace.route(.plugins, coursePageID: nil) == .leave)
        // Open in Other Window names the plugin, or the place.
        #expect(StudioWindowDestination.plugins(nil).noun == "Plugins")
        #expect(StudioWindowDestination.plugins(.slack).noun == "Slack")
    }

    @Test("open_settings takes the same ids, the plugins' opening the Plugins place")
    func openSettingsIDs() {
        #expect(MCPDataStore.settingsPaneIDs.map(\.id) == [
            "general", "chat", "voice", "images", "videos", "background", "billing", "ai_usage", "data_privacy",
            "team_general", "team_members", "sources", "plugins", "mcp", "mcp_pairing", "x", "youtube",
            "google_drive", "apple_calendar", "slack", "linear", "github", "notion", "build_your_own_plugin",
        ], "the tool's enum is a published contract")
        let target = { (id: String) in MCPDataStore.settingsPaneIDs.first { $0.id == id }?.target }
        #expect(target("plugins") == .plugins(nil))
        for page in PluginPage.allCases {
            #expect(target(page.rawValue) == .plugins(page))
        }
        #expect(target("mcp") == .pane(.mcp))
        #expect(target("sources") == .pane(.sources))
        #expect(MCPDataStore.openInAppKinds.contains("plugins"))
    }

    @Test("A chat's connect card opens the plugin's page; signing in still opens Settings")
    func chatSetupCardGoesToThePlace() {
        for plugin in ChatPlugin.allCases {
            let connect = ChatPluginRequest.SetupNeed(plugin: plugin, kind: .connect)
            #expect(connect.destination == .plugin(plugin.pluginPage))
            #expect(connect.body.contains("Plugins › \(plugin.title)"))
            #expect(!connect.body.contains("Settings"))
            #expect(ChatPluginRequest.SetupNeed(plugin: plugin, kind: .signIn).destination == .settings(.aiBilling))
        }
        #expect(ChatPlugin.github.pluginPage == .github)
    }
}

@Suite("The Plugins place in a window")
@MainActor
struct PluginsPlaceWindowTests {
    private func capturingDefaults() -> () -> Void {
        let keys = ["studio.centerTabGroups.v1", "studio.navigationRailVisible"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        return {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    @Test("Plugins is not Home: the card is its own, with no Home sidebar")
    func notHome() {
        let restore = capturingDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.navigationRailVisible = true
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.plugins, .chat], activeTab: .plugins)])
        #expect(!window.isOnHome)
        #expect(!window.showsSpace)
        #expect(!window.showsHomeSidebar)
    }

    @Test("‹ goes from a plugin's page back to the list, and › to the page again")
    func placeHistory() {
        let restore = capturingDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.plugins, .chat], activeTab: .plugins)])
        window.notePlaceSettled()
        window.pluginPage = .slack
        window.notePlaceSettled()
        #expect(window.canGoBackInPlaces, "a plugin's page is a place of its own")
        _ = window.goBackInPlaces()
        #expect(window.pluginPage == nil)
        _ = window.goForwardInPlaces()
        #expect(window.pluginPage == .slack)
        // Behind another pane the page is no place: moving it is no step.
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.chat, .plugins], activeTab: .chat)])
        window.notePlaceSettled()
        let before = window.currentPlace.identity
        window.pluginPage = .notion
        #expect(window.currentPlace.identity == before)
    }
}
