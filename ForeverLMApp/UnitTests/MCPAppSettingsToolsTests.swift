import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The Settings-parity tools (`MCPTools+AppSettings.swift` and its two
/// siblings): every control in the Settings window has a chat equivalent, so
/// the pane is never the only place a setting can be changed.
@Suite("MCP app settings tools", .serialized)
struct MCPAppSettingsToolsTests {

    private func payload(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    @Test("Every Settings-parity tool is registered once, and its readers are marked read-only")
    func registered() throws {
        let names = MCPToolRegistry(store: MCPDataStore()).tools.map(\.name)
        let parity = MCPToolRegistry.settingsParityToolDefs.map(\.name)
        #expect(Set(parity).count == parity.count, "a Settings-parity tool is declared twice")
        for name in parity {
            #expect(names.filter { $0 == name }.count == 1, "\(name) is registered \(names.filter { $0 == name }.count) times")
        }
        for name in MCPToolRegistry.settingsParityReadOnlyToolNames {
            #expect(parity.contains(name), "\(name) is marked read-only but not declared")
            #expect(MCPToolRegistry.annotations(for: name)["readOnlyHint"] as? Bool == true)
        }
        #expect(MCPToolRegistry.annotations(for: "set_app_setting")["readOnlyHint"] as? Bool == false)
    }

    @Test("The catalog has unique ids, and every choice's value is one of its own options")
    @MainActor
    func catalogIsConsistent() async throws {
        let entries = MCPDataStore.appSettingsCatalog()
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate setting ids: \(ids)")
        for entry in entries {
            let row = await entry.payload(includeOptions: true)
            guard row["type"] as? String == "choice", let options = row["options"] as? [[String: Any]] else { continue }
            let values = options.compactMap { $0["value"] as? String }
            #expect(!values.isEmpty, "\(entry.id) offers no options")
            if let value = row["value"] as? String, !value.isEmpty {
                #expect(values.contains(value), "\(entry.id) reads \(value), which is not one of its options \(values)")
            }
        }
    }

    @Test("get_app_settings points at every pane that has tools of its own, and names them all")
    func dedicatedToolsExist() async throws {
        let names = Set(MCPToolRegistry(store: MCPDataStore()).tools.map(\.name))
        let read = try payload(try await MCPDataStore().getAppSettings(pane: nil, settingID: nil))
        let dedicated = try #require(read["dedicated_tools"] as? [[String: String]])
        for row in dedicated {
            for field in ["read", "write"] {
                for tool in (row[field] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    #expect(names.contains(tool), "\(row["pane"] ?? "?") points at \(tool), which is not a tool")
                }
            }
        }
    }

    @Test("set_app_setting writes through the pane's setter, reports changed, and refuses what the pane would")
    @MainActor
    func setThinkingMarkSpeed() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: LoadingIndicatorSpeed.key)
        defer {
            if let prior { defaults.set(prior, forKey: LoadingIndicatorSpeed.key) } else { defaults.removeObject(forKey: LoadingIndicatorSpeed.key) }
        }
        defaults.removeObject(forKey: LoadingIndicatorSpeed.key)
        let store = MCPDataStore()

        var row = try payload(try await store.setAppSetting(settingID: "appearance.thinking_mark_speed", value: 1.5))
        #expect(row["value"] as? Double == 1.5)
        #expect(row["changed"] as? Bool == true)
        #expect(defaults.double(forKey: LoadingIndicatorSpeed.key) == 1.5)

        row = try payload(try await store.setAppSetting(settingID: "appearance.thinking_mark_speed", value: 1.5))
        #expect(row["changed"] as? Bool == false)

        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "appearance.thinking_mark_speed", value: 9)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "appearance.thinking_mark_speed", value: "fast")
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "no.such.setting", value: true)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "images.icon_style", value: "watercolour")
        }
        #expect(defaults.double(forKey: LoadingIndicatorSpeed.key) == 1.5, "a refused call writes nothing")
    }

    @Test("tasks.keep_mac_awake is this Mac's own switch for staying awake for scheduled tasks")
    @MainActor
    func keepMacAwakeForTasks() async throws {
        let defaults = UserDefaults.standard
        let key = ScheduledTaskWakePolicy.keepMacAwakeKey
        let prior = defaults.object(forKey: key)
        defer {
            ScheduledTaskRunner.shared.setKeepsMacAwake(prior as? Bool ?? false)
            if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        ScheduledTaskRunner.shared.setKeepsMacAwake(false)
        let store = MCPDataStore()

        var row = try payload(try await store.setAppSetting(settingID: "tasks.keep_mac_awake", value: true))
        #expect(row["value"] as? Bool == true)
        #expect(row["changed"] as? Bool == true)
        #expect(row["reach"] as? String == "this_mac")
        #expect(defaults.bool(forKey: key))
        #expect(ScheduledTaskRunner.shared.keepsMacAwake, "the Tasks pane's cup reads the same switch")

        row = try payload(try await store.setAppSetting(settingID: "tasks.keep_mac_awake", value: "off"))
        #expect(row["value"] as? Bool == false)
        #expect(!ScheduledTaskRunner.shared.keepsMacAwake)
        #expect(!SyncedPreferenceKeys.isSynced(key), "each Mac decides for itself")
        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "tasks.keep_mac_awake", value: "sometimes")
        }
    }

    @Test("quick_assistant.shortcut is this Mac's shortcut for the quick assistant, written as Settings records it")
    @MainActor
    func quickAssistantShortcut() async throws {
        let defaults = UserDefaults.standard
        let key = QuickAssistantShortcut.storageKey
        let prior = defaults.object(forKey: key)
        defer {
            if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
            // The test host never started the quick assistant; give back
            // whatever key the writes below registered.
            QuickAssistantHotKey.shared.apply(nil)
        }
        defaults.removeObject(forKey: key)
        let store = MCPDataStore()
        let entry = try #require(MCPDataStore.appSettingsCatalog().first { $0.id == "quick_assistant.shortcut" })
        #expect(await entry.read() as? String == QuickAssistantShortcut.default.serialized, "never chosen is the default")

        // A combination nobody uses, so the test host holds nothing that matters.
        var row = try payload(try await store.setAppSetting(settingID: "quick_assistant.shortcut", value: "⌃⇧F19"))
        #expect(row["value"] as? String == "ctrl+shift+f19")
        #expect(row["reach"] as? String == "this_mac")
        #expect(defaults.string(forKey: key) == "ctrl+shift+f19", "Settings' recorder reads the same value")

        row = try payload(try await store.setAppSetting(settingID: "quick_assistant.shortcut", value: "off"))
        #expect(row["value"] as? String == "off")
        #expect(QuickAssistantShortcut.stored() == nil)
        #expect(QuickAssistantHotKey.shared.status == .off)

        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "quick_assistant.shortcut", value: "k")
        }
        #expect(defaults.string(forKey: key) == "off", "a refused shortcut writes nothing")
        #expect(!SyncedPreferenceKeys.isSynced(key), "each Mac has its own keyboard and its own apps")
    }

    @Test("activity.layout switches the Activity pane between by source and history, and refuses anything else")
    func activityLayout() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: DayActivityLayout.storageKey)
        defer {
            if let saved { defaults.set(saved, forKey: DayActivityLayout.storageKey) } else { defaults.removeObject(forKey: DayActivityLayout.storageKey) }
        }
        defaults.removeObject(forKey: DayActivityLayout.storageKey)
        let store = MCPDataStore()

        let read = try payload(try await store.getAppSettings(pane: nil, settingID: "activity.layout"))
        let rows = try #require(read["settings"] as? [[String: Any]])
        #expect(rows.first?["value"] as? String == "by_source")
        #expect((rows.first?["options"] as? [[String: Any]])?.compactMap { $0["value"] as? String } == ["by_source", "history", "app_log"])

        let row = try payload(try await store.setAppSetting(settingID: "activity.layout", value: "history"))
        #expect(row["value"] as? String == "history")
        #expect(row["changed"] as? Bool == true)
        #expect(defaults.string(forKey: DayActivityLayout.storageKey) == DayActivityLayout.history.rawValue)
        #expect(DayActivityLayout.stored == .history)

        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "activity.layout", value: "timeline")
        }
        #expect(DayActivityLayout.stored == .history, "a refused call writes nothing")
    }

    @Test("Your name lists the name and the crown switch, and a blank or overlong name is refused without a write")
    @MainActor
    func accountNameAndCrown() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: MacAccountUser.displayNamePreferenceKey) as? NSObject
        let store = MCPDataStore()

        let read = try payload(try await store.getAppSettings(pane: "Your name", settingID: nil))
        let rows = try #require(read["settings"] as? [[String: Any]])
        #expect(rows.compactMap { $0["id"] as? String } == ["account.display_name"])
        #expect(rows.allSatisfy { $0["reach"] as? String == "account" })

        // Only refusals here: an accepted rename is a synced write to the
        // host's own profile.
        let overlong = String(repeating: "x", count: MacAccountUser.maximumDisplayNameLength + 1)
        for refused in ["", "   \n", overlong] {
            await #expect(throws: MCPError.self) {
                _ = try await store.setAppSetting(settingID: "account.display_name", value: refused)
            }
        }
        #expect(defaults.object(forKey: MacAccountUser.displayNamePreferenceKey) as? NSObject == prior, "a refused rename writes nothing")
        #expect(MacAccountUser.normalizedDisplayName("  Ada Lovelace ") == "Ada Lovelace")
    }

    @Test("memory.review_layout draws the memory review as cards or as its conversation, and refuses anything else")
    func memoryReviewLayout() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MemoryReviewLayout.storageKey)
        defer {
            if let saved { defaults.set(saved, forKey: MemoryReviewLayout.storageKey) } else { defaults.removeObject(forKey: MemoryReviewLayout.storageKey) }
        }
        defaults.removeObject(forKey: MemoryReviewLayout.storageKey)
        let store = MCPDataStore()

        let read = try payload(try await store.getAppSettings(pane: nil, settingID: "memory.review_layout"))
        let rows = try #require(read["settings"] as? [[String: Any]])
        #expect(rows.first?["value"] as? String == "cards")
        #expect((rows.first?["options"] as? [[String: Any]])?.compactMap { $0["value"] as? String } == ["cards", "conversation"])

        let row = try payload(try await store.setAppSetting(settingID: "memory.review_layout", value: "conversation"))
        #expect(row["value"] as? String == "conversation")
        #expect(row["changed"] as? Bool == true)
        #expect(MemoryReviewLayout.stored == .conversation)

        await #expect(throws: MCPError.self) {
            _ = try await store.setAppSetting(settingID: "memory.review_layout", value: "deck")
        }
        #expect(MemoryReviewLayout.stored == .conversation, "a refused call writes nothing")
    }

    @Test("open_settings names only real panes, and run_settings_action only real buttons")
    func unknownPaneAndAction() async throws {
        await #expect(throws: MCPError.self) {
            _ = try await MCPDataStore().openSettings(pane: "nowhere")
        }
        await #expect(throws: MCPError.self) {
            _ = try await MCPDataStore().runSettingsAction(action: "format_disk")
        }
        let paneIDs = MCPDataStore.settingsPaneIDs.map { $0.id }
        #expect(Set(paneIDs).count == paneIDs.count)
        // The keys and the AI spend are two places; ForeverLM is free, so
        // there is no Billing pane to open (2026-11-24).
        #expect(MCPDataStore.settingsPaneIDs.first { $0.id == "api_keys" }?.target == .pane(.aiKeys))
        #expect(MCPDataStore.settingsPaneIDs.first { $0.id == "ai_usage" }?.target == .pane(.aiUsage))
        #expect(!paneIDs.contains("billing"))
        for row in MCPDataStore.settingsOnlyInTheWindow {
            #expect(paneIDs.contains(row["open_settings"] ?? ""), "\(row["control"] ?? "?") points at an unknown pane")
        }
    }
}

#endif
