import Foundation
import Testing
@testable import ForeverLM

/// The iCloud move's controls over MCP (docs/cloudkit-schema-design.md §13; AGENTS.md: every Settings
/// control has a chat equivalent): the buttons are `run_settings_action` actions, the state is
/// `get_sync_status`, and the one control that needs the learner's own confirmation says so.
@Suite("MCP iCloud migration")
struct MCPICloudMigrationTests {
    private static let moveActions = [
        "confirm_this_mac_holds_my_library", "upload_library_to_icloud_again", "replace_icloud_library",
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
}
