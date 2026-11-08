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
        #expect(StudioWindowDestination.plugins(.skills).noun == "Skills")
        #expect(StudioWindowDestination.plugins(.skill("s1")).noun == "skill")
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

    @Test("‹ steps from a skill's page to the Skills list and from there to the plugins")
    func skillsHistory() {
        let restore = capturingDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.plugins], activeTab: .plugins)])
        window.notePlaceSettled()
        window.pluginsLocation = .skills
        window.notePlaceSettled()
        window.pluginsLocation = .skill("s1")
        window.notePlaceSettled()
        _ = window.goBackInPlaces()
        #expect(window.pluginsLocation == .skills)
        _ = window.goBackInPlaces()
        #expect(window.pluginsLocation == .directory)
        _ = window.goForwardInPlaces()
        _ = window.goForwardInPlaces()
        #expect(window.pluginsLocation == .skill("s1"))
    }
}

// Lane H (docs/codex-parity-audit.md §7): the place checked against Codex's
// — Plugins | Skills under one head, Installed first, a breadcrumb and an
// Includes list on a plugin's page, Copy Link — and the Skills list and
// editor beside the plugins.

@Suite("The Plugins place, as Codex's")
struct PluginsPlaceCodexTests {
    @Test("Two tabs under one head, in Codex's words")
    func tabs() {
        #expect(PluginsPlaceTab.allCases.map(\.title) == ["Plugins", "Skills"])
        #expect(PluginsPlaceTab.plugins.subtitle == "Connect plugins to let ForeverLM work across your tools.")
        #expect(PluginsPlaceTab.skills.subtitle == "Extend ForeverLM with task-specific skills.")
        #expect(PluginsPlaceTab.plugins.location == .directory)
        #expect(PluginsPlaceTab.skills.location == .skills)
    }

    @Test("Each place in the place knows its tab and the list it goes back to")
    func locations() {
        let all: [PluginsPlaceLocation] = [.directory, .plugin(.slack), .skills, .skill("s1"), .newSkill]
        #expect(all.map(\.tab) == [.plugins, .plugins, .skills, .skills, .skills])
        #expect(all.map(\.list) == [.directory, .directory, .skills, .skills, .skills])
        #expect(all.map(\.isList) == [true, false, true, false, false])
        #expect(all.map(\.pluginPage) == [nil, .slack, nil, nil, nil])
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
        #expect(PluginsPlaceLink.skills(name: nil).url.absoluteString == "foreverlm://skills")
        #expect(PluginsPlaceLink.skills(name: "Paper Walkthrough").url.absoluteString == "foreverlm://skills/paper-walkthrough")
        let links: [PluginsPlaceLink] = [.plugins(nil), .plugins(.slack), .plugins(.yourPlugins), .skills(name: nil), .skills(name: "outline")]
        for link in links {
            #expect(PluginsPlaceLink.parse(link.url) == link)
        }
        let parse = { (text: String) in URL(string: text).flatMap(PluginsPlaceLink.parse) }
        #expect(parse("foreverlm://plugins/nope") == nil, "an unknown plugin is no link, not the list")
        #expect(parse("foreverlm://plugins/slack/more") == nil)
        #expect(parse("foreverlm://skills/!!!") == nil)
        #expect(parse("foreverlm://doc/abc") == nil, "a doc link is StudioEntityLink's")
        #expect(parse("https://plugins/slack") == nil)
        #expect(parse("\(ForeverLMRuntimeIdentity.urlScheme)://plugins/notion") == .plugins(.notion), "the running build's own scheme reads too")
    }
}

@Suite("The Skills list and a skill's page")
struct SkillsDirectoryTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func skill(_ name: String, _ description: String, edited offset: TimeInterval = 0, id: String? = nil) -> SkillRecord {
        SkillRecord(id: id ?? name, name: name, description: description, instructions: "Do it.", createdAt: day, updatedAt: day + offset)
    }

    @Test("The list is by name; the search reads names and descriptions, / and $ read past")
    func rows() {
        let skills = [
            skill("outline", "Turn notes into headings"),
            skill("paper-walkthrough", "Walk through a paper with cards"),
            skill("glossary", "Define every term in a source"),
        ]
        #expect(SkillsDirectory.rows(skills, query: "").map(\.name) == ["glossary", "outline", "paper-walkthrough"])
        #expect(SkillsDirectory.rows(skills, query: "cards").map(\.name) == ["paper-walkthrough"])
        #expect(SkillsDirectory.rows(skills, query: "/outline").map(\.name) == ["outline"])
        #expect(SkillsDirectory.rows(skills, query: "$gloss term").map(\.name) == ["glossary"])
        #expect(SkillsDirectory.rows(skills, query: "PAPER").map(\.name) == ["paper-walkthrough"])
        #expect(SkillsDirectory.rows(skills, query: "headings cards").isEmpty, "every word must match")
        #expect(SkillsDirectory.rows(skills, query: "  /  ").count == 3)
    }

    @Test("Two skills of one name (two Macs wrote each) list newest first")
    func sameName() {
        let skills = [skill("outline", "Older", edited: 0, id: "a"), skill("outline", "Newer", edited: 60, id: "b")]
        #expect(SkillsDirectory.rows(skills, query: "").map(\.id) == ["b", "a"])
    }

    @Test("A draft says what stops it saving, a taken name included")
    func draftProblems() {
        let skills = [skill("outline", "Headings", id: "o")]
        #expect(SkillDraft().problem(among: skills, editing: nil) != nil)
        let fresh = SkillDraft(name: "Glossary Builder", description: "Define terms", instructions: "List them.")
        #expect(fresh.command == "glossary-builder")
        #expect(fresh.problem(among: skills, editing: nil) == nil)
        let taken = SkillDraft(name: "Outline", description: "Mine", instructions: "Mine.")
        #expect(taken.problem(among: skills, editing: nil) == "Another skill is already called /outline. Pick another name.")
        #expect(taken.problem(among: skills, editing: "o") == nil, "a skill keeps its own name")
        #expect(SkillDraft(name: "review", description: "x", instructions: "y").problem(among: [], editing: nil)?.contains("/review") == true)
    }

    @Test("Leaving asks only when the draft holds something new")
    func changes() {
        let saved = skill("outline", "Headings")
        #expect(!SkillDraft().hasChanges(from: nil))
        #expect(!SkillDraft(name: "  ").hasChanges(from: nil))
        #expect(SkillDraft(name: "x").hasChanges(from: nil))
        #expect(!SkillDraft(saved).hasChanges(from: saved))
        var edited = SkillDraft(saved)
        edited.instructions += " Then stop."
        #expect(edited.hasChanges(from: saved))
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

    @Test("Import SKILL.md fills the fields the file has and keeps the rest")
    func importMarkdown() {
        let typed = SkillDraft(name: "mine", description: "Typed", instructions: "")
        let file = "---\nname: Paper Walkthrough\ndescription: Walk a paper\n---\n\n# Steps\n\nOne card a point.\n"
        #expect(typed.filled(fromSkillMarkdown: file) == SkillDraft(name: "Paper Walkthrough", description: "Walk a paper", instructions: "# Steps\n\nOne card a point."))
        let nameless = "---\ndescription: Only this\n---\nBody"
        #expect(typed.filled(fromSkillMarkdown: nameless)?.name == "mine")
        #expect(typed.filled(fromSkillMarkdown: "# Just markdown") == nil, "no frontmatter, no SKILL.md")
        // What Copy Markdown writes, Import reads back.
        let saved = SkillRecord(name: "outline", description: "Headings: from notes", instructions: "Make them.")
        #expect(SkillDraft().filled(fromSkillMarkdown: saved.skillMarkdown) == SkillDraft(saved))
    }
}
