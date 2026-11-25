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
        #expect(StudioRailHiddenItems.railOrder == [.home, .space, .memory, .library, .plugins])
        #expect(StudioRailItem.plugins.rawValue == "plugins")
        #expect(StudioRailItem.plugins.systemImage == "square.grid.2x2", "Codex's grid")
        // Hideable like the other rows, from Show in Sidebar.
        let hidden = StudioRailHiddenItems(storage: "plugins")
        #expect(hidden.railItems() == [.home, .space, .memory, .library])
        #expect(StudioRailHiddenItems(storage: hidden.setting(.plugins, hidden: false).storage).railItems().last == .plugins)
        // Open in Other Window names the plugin, or the place.
        #expect(StudioWindowDestination.plugins(.directory).noun == "Plugins")
        #expect(StudioWindowDestination.plugins(.plugin(.slack)).noun == "Slack")
    }

    @Test("open_settings takes the same ids, the plugins' opening the Plugins place")
    func openSettingsIDs() {
        #expect(MCPDataStore.settingsPaneIDs.map(\.id) == [
            "general", "chat", "voice", "images", "videos", "background", "api_keys", "ai_usage", "data_privacy",
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
            #expect(ChatPluginRequest.SetupNeed(plugin: plugin, kind: .signIn).destination == .settings(.aiKeys))
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

    @Test("Plugins is not Home: the card is its own, with Home's sidebar beside it")
    func notHome() {
        let restore = capturingDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.navigationRailVisible = true
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.plugins, .chat], activeTab: .plugins)])
        #expect(!window.isOnHome)
        #expect(!window.showsSpace)
        #expect(window.showsHomeSidebar)
    }

    @Test("‹ goes from a plugin's page back to the list, and › to the page again")
    func placeHistory() {
        let restore = capturingDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.plugins, .chat], activeTab: .plugins)])
        window.notePlaceSettled()
        window.pluginsLocation = .plugin(.slack)
        window.notePlaceSettled()
        #expect(window.canGoBackInPlaces, "a plugin's page is a place of its own")
        _ = window.goBackInPlaces()
        #expect(window.pluginsLocation == .directory)
        _ = window.goForwardInPlaces()
        #expect(window.pluginsLocation == .plugin(.slack))
        // Behind another pane the page is no place: moving it is no step.
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.chat, .plugins], activeTab: .chat)])
        window.notePlaceSettled()
        let before = window.currentPlace.identity
        window.pluginsLocation = .plugin(.notion)
        #expect(window.currentPlace.identity == before)
    }
}

// Lane H (docs/codex-parity-audit.md §7): the place checked against Codex's
// — Installed first, a breadcrumb and an Includes list on a plugin's page,
// Copy Link.

@Suite("The Plugins place, as Codex's")
struct PluginsPlaceCodexTests {
    @Test("A plugin's page knows its plugin; the directory has none")
    func locations() {
        let all: [PluginsPlaceLocation] = [.directory, .plugin(.slack)]
        #expect(all.map(\.pluginPage) == [nil, .slack])
    }

    @Test("Installed holds the connected plugins and those to reconnect, never an unknown state")
    func installed() {
        #expect(PluginStatus.isInstalled(.connected))
        #expect(PluginStatus.isInstalled(.needsAttention))
        #expect(!PluginStatus.isInstalled(.notConnected))
        #expect(!PluginStatus.isInstalled(nil), "a gateway that has not answered lists the plugin where it was")
    }

    @Test("A plugin's Includes names tools the registry has, each in one plugin")
    func includedToolsExist() {
        let names = Set(MCPToolRegistry(store: MCPDataStore()).tools.map(\.name))
        for page in PluginPage.allCases {
            for tool in page.includedTools {
                #expect(names.contains(tool), "\(page) includes \(tool), which is no ForeverLM tool")
            }
        }
        #expect(PluginPage.slack.includedTools.contains("read_slack_channel"))
        #expect(PluginPage.googleDrive.includedTools.isEmpty, "Drive's recordings arrive as sources; nothing to list")
        let all = PluginPage.allCases.flatMap(\.includedTools)
        #expect(Set(all).count == all.count, "a tool is listed once, under one plugin")
    }

    @Test("Copy Link writes an address the app opens again")
    func links() {
        #expect(PluginsPlaceLink.plugins(nil).url.absoluteString == "foreverlm://plugins")
        #expect(PluginsPlaceLink.plugins(.googleDrive).url.absoluteString == "foreverlm://plugins/google_drive")
        let links: [PluginsPlaceLink] = [.plugins(nil), .plugins(.slack), .plugins(.yourPlugins)]
        for link in links {
            #expect(PluginsPlaceLink.parse(link.url) == link)
        }
        let parse = { (text: String) in URL(string: text).flatMap(PluginsPlaceLink.parse) }
        #expect(parse("foreverlm://plugins/nope") == nil, "an unknown plugin is no link, not the list")
        #expect(parse("foreverlm://plugins/slack/more") == nil)
        #expect(parse("foreverlm://skills/outline") == nil, "no skills address")
        #expect(parse("foreverlm://doc/abc") == nil, "a doc link is StudioEntityLink's")
        #expect(parse("https://plugins/slack") == nil)
        #expect(parse("\(ForeverLMRuntimeIdentity.urlScheme)://plugins/notion") == .plugins(.notion), "the running build's own scheme reads too")
    }

    @Test("A row's Disconnect names what disconnect_plugin takes, and Calendar turns off")
    func disconnectTargets() {
        let workspace = PluginDisconnectTarget(plugin: "notion", accountID: "ws-1", label: "Acme Lab")
        #expect(workspace.verb == "Disconnect" && !workspace.isTurnOff)
        let other = PluginDisconnectTarget(plugin: "notion", accountID: "ws-2", label: "Acme Lab")
        #expect(workspace.id != other.id, "two workspaces of one plugin stay apart in a menu")
        let calendar = PluginDisconnectTarget(plugin: "apple_calendar", accountID: nil, label: nil)
        #expect(calendar.verb == "Turn Off" && calendar.isTurnOff)
        for target in [workspace, calendar] {
            #expect(MCPDataStore.disconnectablePlugins.contains(target.plugin))
        }
    }
}
