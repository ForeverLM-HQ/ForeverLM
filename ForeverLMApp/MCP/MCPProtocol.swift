import Foundation
import OSLog

#if os(macOS)

/// MCP (Model Context Protocol) JSON-RPC handler.
/// Implements the Streamable HTTP transport: POST /mcp with JSON-RPC body.
final class MCPProtocolHandler: @unchecked Sendable {
    static let shared = MCPProtocolHandler()

    private let logger = Logger(subsystem: "ForeverLM", category: "MCPProtocol")
    private let tools = MCPToolRegistry.shared

    // Sessions are created on `initialize` and touched by concurrent per-request
    // Tasks, so all access is guarded by `sessionsLock`. Each entry tracks its
    // last-seen time so stale sessions expire instead of accumulating forever.
    private let sessionsLock = NSLock()
    private var sessions: [String: Date] = [:]
    private let sessionTTL: TimeInterval = 24 * 60 * 60

    private func registerSession(_ id: String) {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        expireStaleSessionsLocked()
        sessions[id] = Date()
    }

    /// Validate an incoming Mcp-Session-Id against known sessions, refreshing its
    /// last-seen time on a hit. Unknown or expired IDs return false.
    private func isKnownSession(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        expireStaleSessionsLocked()
        guard sessions[id] != nil else { return false }
        sessions[id] = Date()
        return true
    }

    private func expireStaleSessionsLocked() {
        let cutoff = Date().addingTimeInterval(-sessionTTL)
        sessions = sessions.filter { $0.value > cutoff }
    }

    private let serverInfo: [String: Any] = [
        "name": "ForeverLM",
        "version": "1.0.0",
    ]

    private let capabilities: [String: Any] = [
        "tools": [:] as [String: Any],
    ]

    /// Server instructions sent to the LLM on initialize.
    private let instructions = Prompts.mcpServerInstructions

    /// Instructions returned to ingest-scoped plugin clients instead: the
    /// assistant instructions describe a tool surface such a client cannot
    /// call, so they would only mislead it.
    private static let ingestInstructions = """
        This ForeverLM connection is ingest-only (scope mcp:ingest). Available \
        tools: add_source, add_sources (batch), update_source_content (only \
        for sources this plugin added), get_connector_inbox, \
        import_connector_paper, and get_mcp_status. Push ordinary sources \
        with stable canonical URLs so repeated runs deduplicate cleanly, and \
        set update_existing when re-pushing to refresh content in place. Stage \
        local paper PDFs only in the directory returned by get_connector_inbox, \
        then import them with import_connector_paper so the mandatory Paper \
        Metadata and Source Content Cleanup steps run. All \
        other ForeverLM tools require a connection authorized with the full \
        scope (mcp:tools).
        """

    // MARK: - Handle MCP Request

    /// Handle a POST /mcp request. `access` is the validated OAuth context for
    /// this request; tool visibility and dispatch are both filtered by its
    /// scope, and it is re-derived from the bearer token on every request —
    /// session IDs only mark protocol liveness, never authority.
    func handleRequest(_ request: HTTPRequest, access: MCPAccessContext) async -> HTTPResponse {
        // Validate session for non-initialize requests
        let sessionID = request.headers["mcp-session-id"]

        guard let body = request.bodyJSON else {
            return jsonRPCError(nil, code: -32700, message: "Parse error")
        }

        let method = body["method"] as? String ?? ""
        let id = body["id"] // Can be Int or String or nil (notification)
        let params = body["params"] as? [String: Any] ?? [:]

        logger.info("MCP request: \(method)")

        switch method {
        case "initialize":
            return handleInitialize(id: id, params: params, access: access)

        case "notifications/initialized":
            // Streamable HTTP requires notification-only POSTs to receive an
            // accepted response with no JSON body.
            return HTTPResponse(status: 202, statusText: "Accepted", headers: [:], body: Data())

        case "tools/list":
            guard isKnownSession(sessionID) else {
                return invalidSessionResponse(id: id, sessionID: sessionID)
            }
            return handleToolsList(id: id, access: access)

        case "resources/list":
            guard isKnownSession(sessionID) else {
                return invalidSessionResponse(id: id, sessionID: sessionID)
            }
            return jsonRPCResult(id, result: ["resources": []])

        case "resources/templates/list":
            guard isKnownSession(sessionID) else {
                return invalidSessionResponse(id: id, sessionID: sessionID)
            }
            return jsonRPCResult(id, result: ["resourceTemplates": []])

        case "tools/call":
            guard isKnownSession(sessionID) else {
                return invalidSessionResponse(id: id, sessionID: sessionID)
            }
            return await handleToolsCall(id: id, params: params, access: access)

        case "ping":
            return jsonRPCResult(id, result: [:] as [String: Any])

        default:
            return jsonRPCError(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private func handleInitialize(id: Any?, params: [String: Any], access: MCPAccessContext) -> HTTPResponse {
        let sessionID = UUID().uuidString
        registerSession(sessionID)

        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities,
            "serverInfo": serverInfo,
            "instructions": access.scope == .ingest ? Self.ingestInstructions : instructions,
        ]

        var response = jsonRPCResult(id, result: result)
        response.headers["Mcp-Session-Id"] = sessionID
        return response
    }

    // MARK: - Tools List

    private func handleToolsList(id: Any?, access: MCPAccessContext) -> HTTPResponse {
        let toolDefs: [[String: Any]] = tools.tools
            .filter { MCPToolRegistry.isToolAllowed($0.name, scope: access.scope) }
            .map { tool in
                [
                    "name": tool.name,
                    "title": MCPToolRegistry.title(for: tool.name),
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                    "annotations": MCPToolRegistry.annotations(for: tool.name),
                ]
            }

        return jsonRPCResult(id, result: ["tools": toolDefs])
    }

    // MARK: - Tools Call

    private func handleToolsCall(id: Any?, params: [String: Any], access: MCPAccessContext) async -> HTTPResponse {
        guard let toolName = params["name"] as? String else {
            return jsonRPCError(id, code: -32602, message: "Missing tool name")
        }

        // Scope gate. callTool repeats the check as defense in depth for any
        // future non-HTTP call path.
        guard MCPToolRegistry.isToolAllowed(toolName, scope: access.scope) else {
            return jsonRPCError(id, code: -32001, message: MCPToolRegistry.scopeRefusalMessage(toolName: toolName))
        }
        // A beta feature's tool on a Mac that does not show it is refused by
        // callToolDetailed, as a tool error the assistant reads out.

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let outcome = await tools.callToolDetailed(name: toolName, arguments: arguments, access: access)

        // Tool execution errors are successful JSON-RPC exchanges whose MCP
        // CallToolResult carries isError=true. Flattening them into ordinary text
        // makes clients treat refused writes and missing records as success.
        return jsonRPCResult(id, result: [
            "content": Self.contentParts(for: outcome),
            "isError": outcome.isError,
        ])
    }

    /// The MCP content parts of a tool result: the text first, then one
    /// `image` part per picture the tool attached, base64 with its media type
    /// as the MCP specification has it. The gateway relays a Mac's tool result
    /// body unchanged, so the parts reach the client as written here.
    static func contentParts(for outcome: MCPToolRegistry.ToolCallOutcome) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": outcome.text]]
        for image in outcome.images {
            content.append([
                "type": "image",
                "data": image.data.base64EncodedString(),
                "mimeType": image.mimeType,
            ])
        }
        return content
    }

    // MARK: - JSON-RPC Helpers

    private func jsonRPCResult(_ id: Any?, result: [String: Any]) -> HTTPResponse {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { response["id"] = id }
        return .json(response)
    }

    private func jsonRPCError(_ id: Any?, code: Int, message: String) -> HTTPResponse {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { response["id"] = id }
        let status = (code == -32700 || code == -32600) ? 400 : 200
        return .json(response, status: status)
    }

    /// Streamable HTTP clients use a 404 response to detect an expired session
    /// and repeat the initialize handshake. This matters whenever ForeverLM
    /// relaunches: protocol sessions are intentionally in-memory, while the MCP
    /// client may continue holding the old session ID.
    private func invalidSessionResponse(id: Any?, sessionID: String?) -> HTTPResponse {
        let hasSessionID = sessionID?.isEmpty == false
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": -32600,
                "message": hasSessionID
                    ? "Mcp-Session-Id is no longer valid; initialize a new session."
                    : "Missing Mcp-Session-Id header",
            ],
        ]
        if let id { response["id"] = id }
        return .json(response, status: hasSessionID ? 404 : 400)
    }
}

#endif
