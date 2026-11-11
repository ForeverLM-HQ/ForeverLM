import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// A meeting folder's sidebar image over MCP: the same choice "Set Folder Image…"
/// makes in the meetings context menu, reachable by an assistant.
///
/// The write itself goes through `PreferenceStore`, which reaches `UserDefaults`,
/// `user_preferences`, and the CloudKit outbox — side effects belonging to the
/// running app, not to a test process. So what is covered here is everything that
/// decides *whether* to write: registration, the address rules, and the group
/// lookup that refuses an id no folder has. Reporting is covered against
/// `UserDefaults` directly, the same way the sidebar reads it.
@Suite("MCP meeting folder image")
struct MCPMeetingFolderImageTests {

    private func decodeObject(_ text: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    private func protocolRequest(
        method: String,
        headers: [String: String] = [:],
        params: [String: Any] = [:],
        id: Int = 1
    ) throws -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            path: "/mcp",
            queryString: "",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            ] as [String: Any])
        )
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    private func seedGroup(
        in store: MCPDataStore,
        id: String,
        title: String
    ) throws -> String {
        try store.knowledgeStore().saveMeetingGroup(
            name: id,
            metadata: MeetingMetadata(title: title)
        )
        return id
    }

    // MARK: Registration

    @Test("The folder-image tool is registered as a non-destructive local write")
    func toolIsRegistered() throws {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("set_meeting_folder_image"))

        let annotations = MCPToolRegistry.annotations(for: "set_meeting_folder_image")
        #expect(annotations["readOnlyHint"] as? Bool == false)
        // Clearing a picture restores the default icon; nothing of the learner's
        // is thrown away, so this is not a destructive call.
        #expect(annotations["destructiveHint"] as? Bool == false)
        // Storing an address is not fetching from it.
        #expect(annotations["openWorldHint"] as? Bool == false)

        // Reads next to it keep their read-only hint.
        #expect(MCPToolRegistry.annotations(for: "list_meeting_groups")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "get_meeting_group")["readOnlyHint"] as? Bool == true)

        let schema = try #require(
            MCPToolRegistry.shared.tools.first { $0.name == "set_meeting_folder_image" }?.inputSchema
        )
        #expect((schema["required"] as? [String]) == ["group_id"])
    }

    // MARK: Address rules

    @Test("An empty address means clear the choice")
    func emptyAddressClears() throws {
        #expect(try MCPDataStore.resolvedMeetingFolderImage(nil) == nil)
        #expect(try MCPDataStore.resolvedMeetingFolderImage("") == nil)
        #expect(try MCPDataStore.resolvedMeetingFolderImage("   \n ") == nil)
    }

    @Test("A web address is kept as given")
    func webAddressPassesThrough() throws {
        #expect(
            try MCPDataStore.resolvedMeetingFolderImage("https://example.com/logo.png")
                == "https://example.com/logo.png"
        )
        #expect(
            try MCPDataStore.resolvedMeetingFolderImage("  http://example.com/logo.png  ")
                == "http://example.com/logo.png"
        )
    }

    @Test("A path to a file that exists becomes a file URL")
    func localPathBecomesFileURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_meeting_image_file_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("logo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)

        let resolved = try #require(try MCPDataStore.resolvedMeetingFolderImage(file.path))
        #expect(resolved.hasPrefix("file://"))
        #expect(URL(string: resolved)?.path == file.path)
    }

    @Test("A path to nothing is refused rather than stored")
    func missingLocalFileIsRefused() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_such_folder_image_\(UUID().uuidString).png").path
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.resolvedMeetingFolderImage(missing)
        }
    }

    @Test("Addresses the tile cannot draw are refused with the reason")
    func unusableAddressesAreRefused() {
        // No scheme at all.
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.resolvedMeetingFolderImage("examplefellowship.org/logo.png")
        }
        // A scheme nothing fetches an image over.
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.resolvedMeetingFolderImage("data:image/png;base64,iVBORw0KGgo=")
        }
        // http(s) with no host.
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.resolvedMeetingFolderImage("https://")
        }
    }

    // MARK: Group lookup

    @Test("An id no meeting folder has is refused, and says where ids come from")
    func unknownGroupIsRefused() throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        try seedGroup(in: store, id: "group-a", title: "[EF] Comp Bio Reading Group")

        // Passing the *title* is the mistake this message has to answer.
        do {
            _ = try store.setMeetingFolderImage(
                groupID: "[EF] Comp Bio Reading Group",
                imageURL: "https://example.com/logo.png"
            )
            Issue.record("Expected an unknown group id to be refused.")
        } catch let error as MCPError {
            #expect("\(error)".contains("list_meeting_groups"))
        }
    }

    @Test("Getting an unknown group is a real tool error")
    func unknownGroupReadIsRefused() throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }

        #expect(throws: MCPError.self) {
            _ = try store.getMeetingGroup("missing-group")
        }
    }

    @Test("The MCP protocol preserves tool execution errors")
    func protocolPreservesToolErrors() async throws {
        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try protocolRequest(method: "initialize"),
            access: .internalFullAccess
        )
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let missingID = "missing-meeting-group-\(UUID().uuidString)"
        let response = await MCPProtocolHandler.shared.handleRequest(
            try protocolRequest(
                method: "tools/call",
                headers: ["mcp-session-id": sessionID],
                params: [
                    "name": "get_meeting_group",
                    "arguments": ["group_id": missingID],
                ],
                id: 2
            ),
            access: .internalFullAccess
        )
        let envelope = try #require(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains(missingID) == true)
    }

    @Test("group_id is required")
    func emptyGroupIsRefused() throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        #expect(throws: MCPError.self) {
            _ = try store.setMeetingFolderImage(groupID: "  ", imageURL: nil)
        }
    }

    // MARK: Reporting

    @Test("The chosen image is reported back by both meeting reads")
    func readsReportTheChosenImage() throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        let groupID = "image-report-\(UUID().uuidString)"
        try seedGroup(in: store, id: groupID, title: "[EF] Aging Biology Study Group")

        let key = MeetingMetadata.folderImagePreferenceKey(for: groupID)
        let address = "https://example.com/fellowship-square-logo.png"
        UserDefaults.standard.set(address, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let list = try decodeObject(store.listMeetingGroups())
        let groups = try #require(list["meeting_groups"] as? [[String: Any]])
        let listed = try #require(groups.first { $0["group_id"] as? String == groupID })
        #expect(listed["image_url"] as? String == address)

        let group = try decodeObject(store.getMeetingGroup(groupID))
        #expect(group["group_id"] as? String == groupID)
        #expect(group["image_url"] as? String == address)
        #expect(group["sessions"] as? [[String: Any]] != nil)
    }

    @Test("A folder with no image of its own reports none")
    func readsStaySilentWithoutAnImage() throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        let groupID = "no-image-\(UUID().uuidString)"
        try seedGroup(in: store, id: groupID, title: "[EF] Biostasis Working Group Sync")

        let list = try decodeObject(store.listMeetingGroups())
        let groups = try #require(list["meeting_groups"] as? [[String: Any]])
        let listed = try #require(groups.first { $0["group_id"] as? String == groupID })
        #expect(listed["image_url"] == nil)

        let group = try decodeObject(store.getMeetingGroup(groupID))
        #expect(group["image_url"] == nil)
    }
}

#endif
