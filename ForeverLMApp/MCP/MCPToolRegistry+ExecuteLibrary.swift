// MCPToolRegistry: runs the library, source and meeting tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the library, source and meeting tools; nil for any other name.
    func executeLibraryTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
        case "get_mcp_status": return try await store.getMCPStatus(toolCount: tools.count)
        case "report_connector_status":
            guard access.scope == .ingest else {
                return "Error: report_connector_status is only available to an ingest-only plugin."
            }
            guard let rawState = arguments["state"] as? String,
                  let state = MCPOAuthProvider.UserPluginHealthState(rawValue: rawState) else {
                return "Error: state must be healthy, syncing, needs_reconnect, or error."
            }
            let oauthProvider = await MCPOAuthProvider.sharedProvider()
            guard await oauthProvider.reportPluginStatus(
                clientID: access.clientID,
                state: state,
                detail: MCPDataStore.nilIfBlank(arguments["detail"] as? String ?? "")
            ) else {
                return "Error: this plugin registration no longer exists. Reconnect it in ForeverLM."
            }
            return "Plugin status recorded: \(state.rawValue)"
        case "get_sync_status": return try await store.getSyncStatus()
        case "get_connector_inbox":
            guard access.scope == .ingest else {
                return "Error: get_connector_inbox is only available to an ingest-only plugin."
            }
            return try store.getConnectorInbox(connectorLabel: access.connectorLabel)
        case "list_sources": return try store.listSources()
        case "list_courses": return try store.listCourses(notebookID: arguments["notebook_id"] as? String)
        case "get_course": return try store.getCourse(courseIdentifier: arguments["course_id"] as? String ?? "")
        case "get_lecture_papers":
            return try store.getLecturePapers(lectureID: arguments["lecture_id"] as? String ?? "")
        case "get_source_content":
            return try await store.getSourceContent(
                arguments["source_id"] as? String ?? "",
                recordChatActivity: true
            )
        case "save_source_review_guide":
            return try store.saveSourceReviewGuide(
                sourceID: arguments["source_id"] as? String ?? "",
                expectedContentSHA256: arguments["content_sha256"] as? String ?? "",
                guide: arguments["guide"] as? String ?? ""
            )
        case "list_source_actions": return try store.listSourceActions(arguments["source_id"] as? String ?? "")
        case "list_source_highlights":
            return try store.listSourceHighlights(sourceID: arguments["source_id"] as? String ?? "")
        case "search_source_highlights":
            return try store.searchSourceHighlights(
                query: arguments["query"] as? String,
                limit: arguments["limit"] as? Int,
                color: arguments["color"] as? String
            )
        case "create_source_highlight":
            return try store.createSourceHighlight(
                sourceID: arguments["source_id"] as? String ?? "",
                quote: arguments["quote"] as? String ?? "",
                note: arguments["note"] as? String,
                color: arguments["color"] as? String,
                imageURL: arguments["image_url"] as? String,
                imageAlt: arguments["image_alt"] as? String,
                sessionID: arguments["session_id"] as? String,
                hostSessionID: hostSessionID,
                references: arguments["references"],
                publicationUpdate: arguments["publication_update"] as? String
            )
        case "update_source_highlight":
            return try store.updateSourceHighlight(
                highlightID: arguments["highlight_id"] as? String ?? "",
                note: arguments["note"] as? String,
                color: arguments["color"] as? String,
                sessionID: arguments["session_id"] as? String,
                references: arguments["references"],
                publicationUpdate: arguments["publication_update"] as? String
            )
        case "delete_source_highlight":
            return try store.deleteSourceHighlight(
                highlightID: arguments["highlight_id"] as? String ?? ""
            )
        case "list_meeting_groups": return try store.listMeetingGroups()
        case "get_meeting_group": return try store.getMeetingGroup(arguments["group_id"] as? String ?? "")
        case "set_meeting_folder_image":
            return try store.setMeetingFolderImage(
                groupID: arguments["group_id"] as? String ?? "",
                imageURL: arguments["image_url"] as? String
            )
        case "set_meeting_schedule":
            return try await store.setMeetingSchedule(
                groupID: arguments["group_id"] as? String ?? "",
                weekdays: (arguments["weekdays"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") },
                start: arguments["start"] as? String,
                durationMinutes: try MCPDataStore.intArgument(arguments, "duration_minutes"),
                timezone: arguments["timezone"] as? String,
                clear: arguments["clear"] as? Bool ?? false
            )
        case "list_meeting_action_items":
            return try await store.listMeetingActionItems(
                groupID: arguments["group_id"] as? String,
                sourceID: arguments["source_id"] as? String,
                latestOnly: arguments["latest_only"] as? Bool ?? false
            )
        case "set_meeting_action_item_done":
            return try await store.setMeetingActionItemDone(
                itemID: arguments["item_id"] as? String ?? "",
                done: arguments["done"] as? Bool ?? true
            )
        case "merge_meeting_groups":
            return try store.mergeMeetingGroups(
                sourceGroupID: arguments["source_group_id"] as? String ?? "",
                targetGroupID: arguments["target_group_id"] as? String ?? ""
            )
        case "merge_meeting_sessions":
            return try await store.mergeMeetingSessions(
                groupID: arguments["group_id"] as? String,
                date: arguments["date"] as? String,
                sourceIDs: arguments["source_ids"] as? [String]
            )
        case "delete_meeting_group":
            return try await store.deleteMeetingGroup(groupID: arguments["group_id"] as? String ?? "")
        default:
            return nil
        }
    }
}
