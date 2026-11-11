import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The assistant integrations and this Mac's MCP endpoint.
    enum MCP {
        static let assistantIntegrationsEnabled = AccountKey<Bool>("studio.assistantIntegrationsEnabled", default: true)
        static let showStatusLight = AccountKey<Bool>("studio.showMCPStatusLight", default: true)
        static let activeNotebookID = DeviceKey<String?>("studio.activeMCPNotebookID", reason: "which Notebook this Mac's own MCP endpoint serves")
        static let cloudflareTunnelURL = DeviceKey<Any?>("mcpCloudflareTunnelURL", coding: .any, reason: "per-machine tunnel")
        static let oauthPairingCode = DeviceKey<Any?>("mcp_oauth_pairing_code", coding: .any, reason: "single-use")
        static let pageSideChatDock = DeviceKey<String?>("studio.movableOverlay.pageSideChat.dock", reason: "dragged overlay positions, absolute pixels")

        static let all: [AnyPreferenceKey] = [
            assistantIntegrationsEnabled.erased,
            showStatusLight.erased,
            activeNotebookID.erased,
            cloudflareTunnelURL.erased,
            oauthPairingCode.erased,
            pageSideChatDock.erased,
        ]
    }
}
