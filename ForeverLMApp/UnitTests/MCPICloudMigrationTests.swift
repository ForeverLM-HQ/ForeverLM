import Foundation
import Testing
@testable import ForeverLM

/// The iCloud move's controls over MCP (docs/cloudkit-schema-design.md §13; AGENTS.md: every Settings
/// control has a chat equivalent): the buttons are `run_settings_action` actions, the state is
/// `get_sync_status`, and the one control that needs the learner's own confirmation says so.
@Suite("MCP iCloud migration")
struct MCPICloudMigrationTests {
    private static let moveActions = [
        "confirm_this_mac_holds_my_library", "upload_library_to_icloud_again", "apply_old_library_removals", "keep_old_library_removals",
    ]

    @Test("The move's buttons are actions of run_settings_action, listed by get_app_settings and in its schema")
    func actionsAreRegistered() throws {
        let listed = MCPDataStore.settingsActionIDs.compactMap { $0["action"] }
        for action in Self.moveActions { #expect(listed.contains(action), "\(action)") }
        let tool = try #require(MCPToolRegistry.settingsParityToolDefs.first { $0.name == "run_settings_action" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let schema = try #require(properties["action"] as? [String: Any])
        let enumeration = try #require(schema["enum"] as? [String])
        for action in Self.moveActions { #expect(enumeration.contains(action), "\(action) is in the tool's schema") }
        for action in Self.moveActions {
            #expect(MCPDataStore.settingsActionIDs.first { $0["action"] == action }?["pane"] == "Data & Privacy › iCloud")
        }
        #expect(tool.description.contains("confirm_this_mac_holds_my_library"))
    }

    @Test("Remove old iCloud data stays in the Settings window, with its reason, and open_settings points at the pane")
    func removalNeedsTheLearner() throws {
        let entry = try #require(MCPDataStore.settingsOnlyInTheWindow.first { $0["control"] == "Remove old iCloud data" })
        #expect(entry["open_settings"] == "data_privacy")
        #expect(MCPDataStore.settingsPaneIDs.contains { $0.id == "data_privacy" })
        #expect(!MCPDataStore.settingsActionIDs.contains { ($0["action"] ?? "").contains("remove_old") }, "no chat action deletes the old container")
    }

    @Test("A move action under generation 1 is refused: there is no new iCloud store")
    func refusedUnderGeneration1() async throws {
        guard ForeverLMRuntimeIdentity.syncGeneration == .one else { return }
        let store = MCPDataStore()
        await #expect(throws: MCPError.self) { _ = try await store.runSettingsAction(action: "confirm_this_mac_holds_my_library") }
    }
}
