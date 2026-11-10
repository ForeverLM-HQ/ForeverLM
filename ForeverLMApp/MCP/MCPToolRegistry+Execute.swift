// MCPToolRegistry: the dispatcher that runs one tool call.
import Foundation
import ImageIO
import OSLog
import PDFKit
import SQLite3

extension MCPToolRegistry {
    func executeTool(name: String, arguments: [String: Any], hostSessionID: String? = nil, access: MCPAccessContext = .internalFullAccess) async -> String {
        let hostSessionID = hostSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? hostSessionID : nil
        do {
            // The Settings-parity tools (`MCPTools+AppSettings.swift`) dispatch
            // themselves, so this switch does not grow a case per pane control.
            if let result = try await store.executeSettingsParityTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeRunningWorkTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeMnemonicReadingTool(name: name, arguments: arguments) {
                return result
            }
            // Ahead of the Canvas edits, whose names include save and restore.
            if let result = try await store.executeCanvasVersionTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeKnowledgeMapTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeCanvasCatalogTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeSpaceListTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executePaperReferenceTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeCanvasAskTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeSourceLevelsTool(name: name, arguments: arguments) {
                return result
            }
            // Memory on the Canvas (WP-B2)
            if let result = try await store.executeCanvasMemoryTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeAtlasTool(name: name, arguments: arguments) {
                return result
            }
            // A source's draft deck of cards to check is the learner's own
            // memory state, never a Doc (list_docs leaves it out): every tool
            // that takes a doc_id refuses one and names the card tools.
            // The working memory is kept in the background, never as a Doc
            // (`WorkingMemoryRecords`): the working-note tools read and change it.
            if let docID = (arguments["doc_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if MemoryCard.isDraftDeckID(docID) {
                    throw MCPError.invalidInput(MCPDataStore.cardDeckIsNoDocMessage(docID: docID, tool: name))
                }
                if WorkingMemoryRecords.contains(docID) {
                    throw MCPError.invalidInput(MCPDataStore.workingMemoryIsNoDocMessage(docID: docID, tool: name))
                }
            }
            // Notes as a graph: linked references, blocks and daily notes.
            if let result = try await store.executeNotesGraphTool(name: name, arguments: arguments) {
                return result
            }
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
            case "list_slack_channels":
                return try await store.listSlackChannels()
            case "read_slack_channel":
                return try await store.readSlackChannel(
                    channelID: arguments["channel_id"] as? String ?? "",
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days")
                )
            case "read_slack_thread":
                return try await store.readSlackThread(
                    channelID: arguments["channel_id"] as? String ?? "",
                    threadTS: (arguments["thread_ts"] as? String)
                        ?? (arguments["thread_ts"] as? Double).map { String(format: "%.6f", $0) }
                        ?? ""
                )
            case "search_slack_messages":
                return try await store.searchSlackMessages(
                    query: arguments["query"] as? String ?? "",
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    channelID: arguments["channel_id"] as? String,
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days"),
                    sort: arguments["sort"] as? String
                )
            case "get_linear_issue":
                return try await store.getLinearIssue(issue: arguments["issue"] as? String ?? "", workspace: arguments["workspace"] as? String)
            case "search_linear_issues":
                return try await store.searchLinearIssues(
                    term: arguments["term"] as? String ?? "",
                    teamKey: arguments["team_key"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "list_linear_issues":
                return try await store.listLinearIssues(
                    teamKey: arguments["team_key"] as? String,
                    stateType: arguments["state_type"] as? String,
                    assignedToMe: (arguments["assigned_to_me"] as? Bool)
                        ?? (arguments["assigned_to_me"] as? String).map { ["true", "1", "yes"].contains($0.lowercased()) },
                    updatedSinceDays: try MCPDataStore.intArgument(arguments, "updated_since_days"),
                    project: arguments["project"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "list_linear_teams":
                return try await store.listLinearTeams(workspace: arguments["workspace"] as? String)
            case "list_linear_projects":
                return try await store.listLinearProjects(
                    teamKey: arguments["team_key"] as? String,
                    statusType: arguments["status_type"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "get_linear_project":
                return try await store.getLinearProject(project: arguments["project"] as? String ?? "", workspace: arguments["workspace"] as? String)
            case "list_github_repositories":
                return try await store.listGitHubRepositories(
                    query: arguments["query"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "get_github_repository":
                return try await store.getGitHubRepository(
                    repository: arguments["repository"] as? String ?? "",
                    ref: arguments["ref"] as? String
                )
            case "list_github_files":
                return try await store.listGitHubFiles(
                    repository: arguments["repository"] as? String ?? "",
                    path: arguments["path"] as? String,
                    ref: arguments["ref"] as? String,
                    recursive: (arguments["recursive"] as? Bool)
                        ?? (arguments["recursive"] as? String).map { ["true", "1", "yes"].contains($0.lowercased()) }
                )
            case "read_github_file":
                return try await store.readGitHubFile(
                    repository: arguments["repository"] as? String ?? "",
                    path: arguments["path"] as? String ?? "",
                    ref: arguments["ref"] as? String
                )
            case "search_github_code":
                return try await store.searchGitHubCode(
                    repository: arguments["repository"] as? String ?? "",
                    query: arguments["query"] as? String ?? "",
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "list_github_issues":
                return try await store.listGitHubIssues(
                    repository: arguments["repository"] as? String ?? "",
                    state: arguments["state"] as? String,
                    labels: arguments["labels"] as? String,
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days"),
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "get_github_issue":
                return try await store.getGitHubIssue(
                    repository: arguments["repository"] as? String ?? "",
                    number: try MCPDataStore.intArgument(arguments, "number")
                )
            case "list_github_pull_requests":
                return try await store.listGitHubPullRequests(
                    repository: arguments["repository"] as? String ?? "",
                    state: arguments["state"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "get_github_pull_request":
                return try await store.getGitHubPullRequest(
                    repository: arguments["repository"] as? String ?? "",
                    number: try MCPDataStore.intArgument(arguments, "number")
                )
            case "list_github_commits":
                return try await store.listGitHubCommits(
                    repository: arguments["repository"] as? String ?? "",
                    ref: arguments["ref"] as? String,
                    path: arguments["path"] as? String,
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days"),
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "search_notion":
                return try await store.searchNotion(
                    query: arguments["query"] as? String,
                    kind: arguments["kind"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "get_notion_page":
                return try await store.getNotionPage(
                    page: arguments["page"] as? String ?? "",
                    includeContent: (arguments["include_content"] as? Bool)
                        ?? (arguments["include_content"] as? String).map { !["false", "0", "no"].contains($0.lowercased()) },
                    workspace: arguments["workspace"] as? String
                )
            case "list_notion_databases":
                return try await store.listNotionDatabases(
                    query: arguments["query"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "get_notion_database":
                return try await store.getNotionDatabase(database: arguments["database"] as? String ?? "", workspace: arguments["workspace"] as? String)
            case "query_notion_database":
                return try await store.queryNotionDatabase(
                    database: arguments["database"] as? String ?? "",
                    filter: arguments["filter"],
                    sorts: arguments["sorts"],
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    cursor: arguments["cursor"] as? String,
                    workspace: arguments["workspace"] as? String
                )
            case "create_x_post":
                let posted = try await XBookmarkService.shared.createPost(
                    text: arguments["text"] as? String ?? "",
                    replyToPostId: arguments["reply_to_post_id"] as? String,
                    account: arguments["account"] as? String
                )
                return try store.jsonString([
                    "posted": true,
                    "post_id": posted.postId,
                    "url": posted.url,
                    "posted_as": posted.account.displayLabel,
                ] as [String: Any])
            case "attach_meeting_artifact":
                return try store.attachMeetingArtifact(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String ?? "",
                    kindString: arguments["kind"] as? String
                )
            case "transcribe_meeting_recording":
                return try await store.transcribeMeetingRecording(
                    sourceID: arguments["source_id"] as? String ?? ""
                )
            case "generate_source_audio":
                return try await store.generateSourceAudio(
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    bookIDs: arguments["book_ids"] as? [String] ?? [],
                    sourceTypeNames: arguments["source_types"] as? [String] ?? [],
                    confirmCost: arguments["confirm_cost"] as? Bool ?? false,
                    allowUnsupportedLanguages: arguments["allow_unsupported_languages"] as? Bool ?? false,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                        ?? MCPRunningWork.defaultSpendLimitUSD
                )
            case "get_source_audio_status":
                return try await store.getSourceAudioStatus(
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "cancel_source_audio_generation":
                return try await store.cancelSourceAudioGeneration(
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    all: arguments["all"] as? Bool ?? false
                )
            case "get_automatic_audio_settings":
                return try await store.getAutomaticAudioSettings()
            case "set_automatic_audio_settings":
                return try await store.setAutomaticAudioSettings(
                    kind: arguments["kind"] as? String,
                    enabled: arguments["enabled"] as? Bool,
                    filter: arguments["filter"] as? String,
                    allowPaidVoices: arguments["allow_paid_voices"] as? Bool
                )
            case "import_meeting_transcript_files":
                return try await store.importMeetingTranscriptFiles(
                    groupTitle: arguments["group_title"] as? String ?? "",
                    folderPath: arguments["folder_path"] as? String ?? "",
                    source: arguments["source"] as? String
                )
            case "list_scheduled_tasks":
                return try store.listScheduledTasks(
                    includeRuns: arguments["include_runs"] as? Bool ?? false
                )
            case "get_scheduled_task":
                return try store.getScheduledTask(taskID: arguments["task_id"] as? String)
            case "create_scheduled_task":
                return try store.createScheduledTask(
                    title: arguments["title"] as? String,
                    instruction: arguments["instruction"] as? String,
                    cadence: arguments["cadence"] as? String,
                    hour: arguments["hour"] as? Int,
                    minute: arguments["minute"] as? Int,
                    weekday: arguments["weekday"] as? Int,
                    dayOfMonth: arguments["day_of_month"] as? Int,
                    date: arguments["date"] as? String,
                    timeZone: arguments["time_zone"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    enabled: arguments["enabled"] as? Bool
                )
            case "update_scheduled_task":
                return try store.updateScheduledTask(
                    taskID: arguments["task_id"] as? String,
                    title: arguments["title"] as? String,
                    instruction: arguments["instruction"] as? String,
                    cadence: arguments["cadence"] as? String,
                    hour: arguments["hour"] as? Int,
                    minute: arguments["minute"] as? Int,
                    weekday: arguments["weekday"] as? Int,
                    dayOfMonth: arguments["day_of_month"] as? Int,
                    date: arguments["date"] as? String,
                    timeZone: arguments["time_zone"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    clearNotebook: arguments["clear_notebook"] as? Bool ?? false,
                    sourceIDs: arguments["source_ids"] as? [String],
                    enabled: arguments["enabled"] as? Bool
                )
            case "run_scheduled_task_now":
                return try store.runScheduledTaskNow(taskID: arguments["task_id"] as? String)
            case "delete_scheduled_task":
                return try store.deleteScheduledTask(taskID: arguments["task_id"] as? String)
            case "get_app_context": return try store.getAppContext()
            case "list_notebooks":
                return try store.listNotebooks(includeCompleted: arguments["include_completed"] as? Bool ?? false)
            case "create_notebook":
                return try await store.createNotebook(
                    title: arguments["title"] as? String,
                    // instructions is the advertised name; description is honored for
                    // clients holding a pre-rename tool list.
                    description: (arguments["instructions"] ?? arguments["description"]) as? String,
                    summary: arguments["summary"] as? String,
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String ?? "",
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool ?? false,
                    researchQuestions: arguments["research_questions"] as? [String],
                    repository: arguments["repository"] as? String,
                    allowDuplicate: arguments["allow_duplicate"] as? Bool ?? false,
                    hostSessionID: hostSessionID
                )
            case "update_notebook":
                return try await store.updateNotebook(
                    notebookID: arguments["notebook_id"] as? String,
                    title: arguments["title"] as? String,
                    description: (arguments["instructions"] ?? arguments["description"]) as? String,
                    summary: arguments["summary"] as? String,
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String,
                    openEnded: arguments["open_ended"] as? Bool,
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool,
                    researchQuestions: arguments["research_questions"] as? [String],
                    relatedNotebookIDs: arguments["related_notebook_ids"] as? [String],
                    repository: arguments["repository"] as? String,
                    status: arguments["status"] as? String,
                    thinkFirst: arguments["think_first"] as? String
                )
            case "get_notebook":
                return try store.getNotebookDetail(notebookID: arguments["notebook_id"] as? String)
            case "delete_notebook":
                return try store.deleteNotebook(
                    notebookID: arguments["notebook_id"] as? String,
                    deleteChats: arguments["delete_chats"] as? Bool ?? false
                )
            case "add_notebook_sources":
                return try await store.addNotebookSources(
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "list_notebook_sources":
                return try store.listNotebookSources(
                    notebookID: arguments["notebook_id"] as? String
                )
            case "discover_sources":
                return try await store.discoverSources(
                    notebookID: arguments["notebook_id"] as? String,
                    query: arguments["query"] as? String,
                    count: arguments["count"] as? Int,
                    sourceIDs: arguments["source_ids"] as? [String]
                )
            case "reorder_notebook_sources":
                return try store.reorderNotebookSources(
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "set_notebook_source_selection":
                return try await store.setNotebookSourceSelection(
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    contextNotebookIDs: arguments["context_notebook_ids"] as? [String] ?? [],
                    mode: arguments["mode"] as? String ?? ""
                )
            case "list_notebook_collections":
                return try store.listNotebookCollections()
            case "update_notebook_collection":
                return try await store.updateNotebookCollection(
                    action: arguments["action"] as? String ?? "",
                    collectionID: arguments["collection_id"] as? String,
                    name: arguments["name"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String]
                )
            case "get_notebook_context":
                return try await store.getNotebookContext(
                    notebookID: arguments["notebook_id"] as? String,
                    maxSourceChars: arguments["max_source_chars"] as? Int,
                    includeEmergentState: arguments["include_emergent_state"] as? Bool,
                    includeSourceContent: arguments["include_source_content"] as? Bool
                )
            case "list_notebook_files":
                return try await store.listNotebookFiles(
                    notebookID: arguments["notebook_id"] as? String
                )
            case "list_teams":
                return try await store.listTeams()
            case "create_team":
                return try await store.createTeam(name: arguments["name"] as? String)
            case "share_with_team":
                return try await store.shareWithTeam(
                    teamID: arguments["team_id"] as? String,
                    kind: arguments["kind"] as? String,
                    ids: arguments["ids"] as? [String] ?? [],
                    includeSources: arguments["include_sources"] as? Bool,
                    includeDocs: arguments["include_docs"] as? Bool,
                    includeChats: arguments["include_chats"] as? Bool,
                    includeCitedSources: arguments["include_cited_sources"] as? Bool,
                    rightsAnswer: MCPDataStore.SharingRightsAnswer(arguments["rights_affirmed_by_learner"])
                )
            case "share_notebook":
                return try await store.shareNotebook(
                    notebookID: arguments["notebook_id"] as? String,
                    rightsAnswer: MCPDataStore.SharingRightsAnswer(arguments["rights_affirmed_by_learner"]),
                    teamID: arguments["team_id"] as? String
                )
            case "request_share":
                return try await store.requestShare(
                    teamID: arguments["team_id"] as? String,
                    url: arguments["url"] as? String,
                    title: arguments["title"] as? String,
                    docID: arguments["doc_id"] as? String
                )
            case "list_share_requests":
                return try await store.listShareRequests(
                    teamID: arguments["team_id"] as? String,
                    status: arguments["status"] as? String
                )
            case "fulfil_share_request":
                return try await store.fulfilShareRequest(
                    requestID: arguments["request_id"] as? String,
                    rightsAnswer: MCPDataStore.SharingRightsAnswer(arguments["rights_affirmed_by_learner"])
                )
            case "decline_share_request":
                return try await store.declineShareRequest(requestID: arguments["request_id"] as? String)
            case "assign_to_member":
                return try await store.assignToMember(
                    teamID: arguments["team_id"] as? String,
                    member: arguments["member"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String],
                    docID: arguments["doc_id"] as? String,
                    dueDate: arguments["due_date"] as? String,
                    notes: arguments["notes"] as? String
                )
            case "list_assignments":
                return try await store.listAssignments(
                    teamID: arguments["team_id"] as? String,
                    mine: arguments["mine"] as? Bool,
                    includeDone: arguments["include_done"] as? Bool
                )
            case "get_family_plan":
                return try await store.getFamilyPlan()
            case "set_family_plan":
                return try await store.setFamilyPlan(
                    teamID: arguments["team_id"] as? String,
                    enabled: arguments["enabled"] as? Bool
                )
            case "connect_family_member_key":
                return try await store.connectFamilyMemberKey(
                    teamID: arguments["team_id"] as? String,
                    member: arguments["member"] as? String
                )
            case "list_notebook_tasks":
                return try await store.listNotebookTasks(
                    notebookID: arguments["notebook_id"] as? String,
                    status: arguments["status"] as? String,
                    assignee: arguments["assignee"] as? String
                )
            case "create_notebook_task":
                return try await store.createNotebookTask(
                    notebookID: arguments["notebook_id"] as? String,
                    title: arguments["title"] as? String,
                    notes: arguments["notes"] as? String,
                    status: arguments["status"] as? String,
                    assigneeRecordName: arguments["assignee_record_name"] as? String,
                    dueDate: arguments["due_date"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    docID: arguments["doc_id"] as? String
                )
            case "update_notebook_task":
                return try await store.updateNotebookTask(
                    taskID: arguments["task_id"] as? String,
                    title: arguments["title"] as? String,
                    notes: arguments["notes"] as? String,
                    status: arguments["status"] as? String,
                    assigneeRecordName: arguments["assignee_record_name"] as? String,
                    dueDate: arguments["due_date"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    docID: arguments["doc_id"] as? String
                )
            case "delete_notebook_task":
                return try await store.deleteNotebookTask(taskID: arguments["task_id"] as? String)
            case "get_calendar_events":
                return try await store.getCalendarEvents(
                    date: arguments["date"] as? String,
                    days: try MCPDataStore.intArgument(arguments, "days")
                )
            case "create_calendar_event":
                return try await store.createCalendarEvent(arguments: arguments)
            case "update_calendar_event":
                return try await store.updateCalendarEvent(arguments: arguments)
            case "delete_calendar_event":
                return try await store.deleteCalendarEvent(arguments: arguments)
            case "get_day_activity":
                return try await store.getDayActivity(date: arguments["date"] as? String)
            case "delete_day_activity":
                return try await store.deleteDayActivity(activityID: arguments["activity_id"] as? String)
            case "get_learning_bout":
                return try await store.getLearningBout(date: arguments["date"] as? String)
            case "start_learning_bout":
                return try await store.startLearningBout(
                    eventID: arguments["event_id"] as? String,
                    occurrenceDate: arguments["occurrence_date"] as? String,
                    title: arguments["title"] as? String,
                    minutes: try MCPDataStore.intArgument(arguments, "minutes"),
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: MCPDataStore.sourceIDArguments(arguments)
                )
            case "end_learning_bout":
                return try await store.endLearningBout(boutID: arguments["bout_id"] as? String)
            case "write_up_learning_bout":
                return try await store.writeUpLearningBout(
                    boutID: arguments["bout_id"] as? String,
                    learned: arguments["learned"] as? String,
                    unclear: arguments["unclear"] as? String,
                    breakMinutes: try MCPDataStore.intArgument(arguments, "break_minutes")
                )
            case "set_learning_bout_break":
                return try await store.setLearningBoutBreak(
                    boutID: arguments["bout_id"] as? String,
                    running: arguments["running"] as? Bool ?? true,
                    minutes: try MCPDataStore.intArgument(arguments, "minutes")
                )
            case "abandon_learning_bout":
                return try await store.abandonLearningBout(boutID: arguments["bout_id"] as? String)
            case "list_docs":
                return try await store.listArtifacts(notebookID: arguments["notebook_id"] as? String)
            case "create_doc":
                return try await store.createArtifact(
                    title: arguments["title"] as? String ?? "",
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? [],
                    markdown: arguments["markdown"] as? String ?? "",
                    isDraft: arguments["is_draft"] as? Bool ?? false
                )
            case "read_doc":
                return try await store.readArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    start: arguments["start"] as? Int,
                    length: arguments["length"] as? Int,
                    resolveReferences: arguments["resolve_references"] as? Bool ?? false
                )
            case "list_doc_chats":
                return try await store.listArtifactChats(
                    artifactID: arguments["doc_id"] as? String ?? ""
                )
            case "link_doc_passage_to_chat":
                return try await store.linkArtifactPassageToChat(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    quote: arguments["quote"] as? String ?? "",
                    sectionTitle: arguments["section_title"] as? String ?? ""
                )
            case "unlink_doc_chat":
                return try await store.unlinkArtifactChat(
                    linkID: arguments["link_id"] as? String ?? ""
                )
            case "list_doc_comments":
                return try await store.listDocComments(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    includeResolved: arguments["include_resolved"] as? Bool ?? true
                )
            case "comment_on_doc":
                return try await store.commentOnDoc(
                    artifactID: arguments["doc_id"] as? String,
                    quote: arguments["quote"] as? String,
                    body: arguments["body"] as? String ?? "",
                    replyTo: arguments["reply_to"] as? String
                )
            case "update_doc_comment":
                return try await store.updateDocComment(
                    commentID: arguments["comment_id"] as? String ?? "",
                    body: arguments["body"] as? String,
                    resolved: arguments["resolved"] as? Bool
                )
            case "delete_doc_comment":
                return try await store.deleteDocComment(
                    commentID: arguments["comment_id"] as? String ?? "",
                    wholeThread: arguments["whole_thread"] as? Bool ?? false
                )
            case "write_doc":
                return try await store.writeArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    markdown: arguments["markdown"] as? String ?? "",
                    expectedRevision: arguments["expected_revision"] as? String ?? "",
                    publish: arguments["publish"] as? Bool ?? false
                )
            case "edit_doc":
                let rawEdits = arguments["edits"] as? [[String: Any]] ?? []
                let edits = rawEdits.map { edit in
                    MCPDataStore.ArtifactEdit(
                        find: edit["find"] as? String ?? "",
                        replace: edit["replace"] as? String ?? "",
                        replaceAll: edit["replace_all"] as? Bool ?? false
                    )
                }
                return try await store.editArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    edits: edits,
                    append: arguments["append"] as? String,
                    expectedRevision: arguments["expected_revision"] as? String ?? "",
                    publish: arguments["publish"] as? Bool ?? false
                )
            case "update_doc":
                return try await store.updateArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String],
                    isDraft: arguments["is_draft"] as? Bool,
                    isArchived: arguments["is_archived"] as? Bool,
                    isHidden: arguments["is_hidden"] as? Bool
                )
            case "delete_doc":
                return try await store.deleteArtifact(artifactID: arguments["doc_id"] as? String ?? "")
            case "list_doc_versions":
                return try await store.listDocVersions(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    versionID: arguments["version_id"] as? String,
                    start: arguments["start"] as? Int,
                    length: arguments["length"] as? Int
                )
            case "restore_doc_version":
                return try await store.restoreDocVersion(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    versionID: arguments["version_id"] as? String ?? "",
                    expectedRevision: arguments["expected_revision"] as? String,
                    publish: arguments["publish"] as? Bool ?? false
                )
            case "list_spaces":
                return try await store.listPageSpaces()
            case "update_space":
                return try await store.updatePageSpace(
                    action: arguments["action"] as? String ?? "",
                    spaceID: arguments["space_id"] as? String,
                    name: arguments["name"] as? String,
                    docIDs: arguments["doc_ids"] as? [String]
                )
            case "link_page", "link_google_doc":
                return try await store.linkPageArtifact(
                    urlString: arguments["url"] as? String ?? "",
                    title: arguments["title"] as? String,
                    text: arguments["text"] as? String,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? []
                )
            case "unlink_page", "unlink_google_doc":
                return try await store.unlinkPageArtifact(artifactID: arguments["doc_id"] as? String ?? "")
            case "adopt_page":
                return try await store.adoptPageArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    markdown: arguments["markdown"] as? String,
                    readers: arguments["readers"] as? [String],
                    slug: arguments["slug"] as? String
                )
            case "publish_doc":
                if arguments["password"] != nil {
                    throw MCPError.invalidInput("Pages are no longer shared with a password. Pass readers, a list of email addresses, instead.")
                }
                return try await store.publishArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    readers: arguments["readers"] as? [String],
                    slug: arguments["slug"] as? String
                )
            case "unpublish_doc":
                return try await store.unpublishArtifact(artifactID: arguments["doc_id"] as? String ?? "")
            case "save_site":
                return try await store.saveSite(
                    site: arguments["site"] as? String,
                    title: arguments["title"] as? String,
                    html: arguments["html"] as? String,
                    files: arguments["files"] as? [Any],
                    repository: arguments["repository"] as? String,
                    repositoryPath: arguments["repository_path"] as? String,
                    ref: arguments["ref"] as? String,
                    removeFiles: arguments["remove_files"] as? [String] ?? [],
                    replaceAll: arguments["replace_all"] as? Bool ?? false,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? []
                )
            case "read_site_file":
                return try await store.readSiteFile(
                    site: arguments["site"] as? String ?? "",
                    path: arguments["path"] as? String
                )
            case "replace_site_text":
                return try await store.replaceSiteText(
                    site: arguments["site"] as? String ?? "",
                    find: arguments["find"] as? String ?? "",
                    replace: arguments["replace"] as? String ?? "",
                    path: arguments["path"] as? String
                )
            case "save_animation":
                return try await store.saveAnimation(
                    animation: arguments["animation"] as? String,
                    title: arguments["title"] as? String,
                    description: arguments["description"] as? String,
                    html: arguments["html"] as? String,
                    files: arguments["files"] as? [Any],
                    sources: arguments["sources"] as? [String] ?? [],
                    removeFiles: arguments["remove_files"] as? [String] ?? [],
                    replaceAll: arguments["replace_all"] as? Bool ?? false,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? []
                )
            case "list_animations":
                return try await store.listAnimations(
                    sourceID: arguments["source_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "delete_animation":
                return try await store.deleteAnimation(animation: arguments["animation"] as? String ?? "")
            case "list_source_artifacts":
                return try await store.listSourceArtifacts(sourceID: arguments["source_id"] as? String ?? "")
            case "read_notebook_markdown_file":
                return try await store.readNotebookMarkdownFile(
                    notebookID: arguments["notebook_id"] as? String,
                    relativePath: arguments["path"] as? String ?? ""
                )
            case "write_notebook_markdown_file":
                return try await store.writeNotebookMarkdownFile(
                    notebookID: arguments["notebook_id"] as? String,
                    relativePath: arguments["path"] as? String ?? "",
                    markdown: arguments["markdown"] as? String ?? "",
                    expectedRevision: arguments["expected_revision"] as? String
                )
            case "list_open_questions":
                return try store.listOpenQuestions(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    includeResolved: arguments["include_resolved"] as? Bool,
                    status: arguments["status"] as? String
                )
            case "create_open_question":
                return try store.createOpenQuestion(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    summary: arguments["summary"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String,
                    severity: clampUnitInterval(optional: arguments["severity"] as? Double),
                    status: arguments["status"] as? String
                )
            case "update_open_question":
                return try store.updateOpenQuestion(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    questionID: arguments["question_id"] as? String ?? "",
                    summary: arguments["summary"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    severity: clampUnitInterval(optional: arguments["severity"] as? Double),
                    status: arguments["status"] as? String,
                    clearSourceID: arguments["clear_source_link"] as? Bool ?? false
                )
            case "update_notebook_notes", "append_notebook_notes":
                return try store.updateNotebookNotes(
                    notebookID: arguments["notebook_id"] as? String,
                    markdown: arguments["markdown"] as? String ?? arguments["notes"] as? String ?? "",
                    append: name == "append_notebook_notes"
                )
            case "split_notebook":
                return try store.splitNotebook(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    splits: arguments["splits"] as? [[String: Any]] ?? [],
                    keepParent: arguments["keep_parent"] as? Bool ?? true
                )
            case "merge_notebooks":
                return try store.mergeNotebooks(
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? [],
                    title: arguments["title"] as? String,
                    mergeNotes: arguments["merge_notes"] as? Bool ?? true
                )
            case "get_schedule":
                return try store.getSchedule(
                    goalID: arguments["goal_id"] as? String,
                    includeCompleted: arguments["include_completed"] as? Bool ?? true
                )
            case "get_today_sources":
                return try store.getTodaySources(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String,
                    dateBasis: arguments["date_basis"] as? String,
                    activityKind: arguments["activity_kind"] as? String,
                    includeCompleted: arguments["include_completed"] as? Bool ?? false,
                    maxCharsPerSource: arguments["max_chars_per_source"] as? Int
                )
            case "assign_sources_to_day":
                return try await store.assignSourcesToDay(
                    goalID: arguments["goal_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dateString: arguments["date"] as? String ?? ""
                )
            case "unschedule_sources":
                return try store.unscheduleSources(
                    goalID: arguments["goal_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "forget_source_activity":
                return try store.forgetSourceActivity(
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dateString: arguments["date"] as? String
                )
            case "clear_schedule_day":
                return try store.clearScheduleDay(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String ?? "",
                    includeCompleted: arguments["include_completed"] as? Bool ?? false
                )
            case "mark_schedule_day_done":
                return try store.markScheduleDayDone(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String ?? ""
                )
            case "set_source_completion":
                return try store.setSourceCompletion(
                    goalID: arguments["goal_id"] as? String,
                    sourceID: arguments["source_id"] as? String ?? "",
                    isCompleted: arguments["is_completed"] as? Bool ?? false
                )
            case "create_learning_goal":
                return try await store.createCompanionLearningGoal(
                    title: arguments["title"] as? String ?? "",
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String ?? "",
                    startDateString: arguments["start_date"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool ?? true,
                    notebookID: arguments["notebook_id"] as? String,
                    artifactID: arguments["artifact_id"] as? String
                )
            case "list_goals":
                return try store.listNotebookGoals(
                    notebookID: arguments["notebook_id"] as? String,
                    includeCompleted: arguments["include_completed"] as? Bool ?? false
                )
            case "update_learning_goal":
                return try await store.updateLearningGoal(
                    goalID: arguments["goal_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    description: arguments["description"] as? String,
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String,
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool,
                    notebookID: arguments["notebook_id"] as? String,
                    statusString: arguments["status"] as? String,
                    artifactID: arguments["artifact_id"] as? String
                )
            case "list_ideas":
                return try store.listIdeas(
                    includeArchived: arguments["include_archived"] as? Bool ?? true,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "list_skills":
                return try store.listSkills()
            case "get_skill":
                return try store.getSkill(
                    name: arguments["name"] as? String,
                    skillID: arguments["skill_id"] as? String
                )
            case "save_skill":
                return try store.saveSkill(
                    skillID: arguments["skill_id"] as? String,
                    name: arguments["name"] as? String,
                    description: arguments["description"] as? String,
                    instructions: arguments["instructions"] as? String,
                    skillMarkdown: arguments["skill_markdown"] as? String
                )
            case "delete_skill":
                return try store.deleteSkill(skillID: arguments["skill_id"] as? String ?? "")
            case "list_working_notes":
                return try await store.listWorkingNotes(arguments: arguments)
            case "save_working_note":
                return try await store.saveWorkingNote(arguments: arguments)
            case "update_working_note":
                return try await store.updateWorkingNote(arguments: arguments)
            case "forget_working_note":
                return try await store.forgetWorkingNote(arguments: arguments)
            case "create_idea":
                return try store.createIdea(
                    title: arguments["title"] as? String ?? "",
                    notes: arguments["notes"] as? String,
                    links: arguments["links"] as? [[String: Any]] ?? []
                )
            case "update_idea":
                return try store.updateIdea(
                    ideaID: arguments["idea_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    notes: arguments["notes"] as? String,
                    statusString: arguments["status"] as? String
                )
            case "link_idea":
                return try store.linkIdea(
                    ideaID: arguments["idea_id"] as? String ?? "",
                    kindString: arguments["kind"] as? String ?? "",
                    targetIDs: arguments["target_ids"] as? [String] ?? []
                )
            case "unlink_idea":
                return try store.unlinkIdea(
                    ideaID: arguments["idea_id"] as? String ?? "",
                    kindString: arguments["kind"] as? String ?? "",
                    targetIDs: arguments["target_ids"] as? [String] ?? []
                )
            case "delete_idea":
                return try store.deleteIdea(ideaID: arguments["idea_id"] as? String ?? "")
            case "find_directions":
                return try await store.findDirections(
                    homeID: arguments["home_id"] as? String ?? "",
                    focus: arguments["focus"] as? String
                )
            case "search_literature":
                return try await store.searchLiterature(
                    query: arguments["query"] as? String ?? "",
                    fromYear: arguments["from_year"] as? Int,
                    toYear: arguments["to_year"] as? Int,
                    preprintsOnly: arguments["preprints_only"] as? Bool ?? false,
                    sortString: arguments["sort"] as? String,
                    limit: arguments["limit"] as? Int ?? 10
                )
            case "propose_directions":
                return try store.proposeDirections(
                    homeID: arguments["home_id"] as? String ?? "",
                    rawDirections: arguments["directions"] as? [[String: Any]] ?? [],
                    sessionID: arguments["session_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "list_directions":
                return try store.listDirections(
                    homeID: arguments["home_id"] as? String,
                    statusString: arguments["status"] as? String
                )
            case "update_direction":
                return try store.updateDirection(
                    directionID: arguments["direction_id"] as? String ?? "",
                    arguments: arguments
                )
            case "delete_direction":
                return try store.deleteDirection(directionID: arguments["direction_id"] as? String ?? "")
            case "get_goal":
                return try store.getGoal(goalID: arguments["goal_id"] as? String ?? "")
            case "add_goal_sources":
                return try await store.addGoalSources(
                    goalID: arguments["goal_id"] as? String ?? "",
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "reorder_goals":
                return try store.reorderGoals(goalIDs: arguments["goal_ids"] as? [String] ?? [])
            case "delete_learning_goal":
                return try store.deleteLearningGoal(goalID: arguments["goal_id"] as? String ?? "")
            case "daily_quiz":
                return try await store.dailyQuiz(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String,
                    startSession: arguments["start_session"] as? Bool ?? true,
                    hostSessionID: hostSessionID
                )
            case "daily_review":
                return try await store.dailyReview(
                    goalID: arguments["goal_id"] as? String,
                    startSession: arguments["start_session"] as? Bool ?? true,
                    hostSessionID: hostSessionID
                )
            case "memory_review":
                return try await store.memoryReview(
                    goalID: arguments["goal_id"] as? String,
                    limit: arguments["limit"] as? Int,
                    startSession: arguments["start_session"] as? Bool ?? true,
                    operationID: arguments["operation_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "cohort_review":
                return try await store.cohortReview(
                    startSession: arguments["start_session"] as? Bool ?? true,
                    goalID: arguments["goal_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "get_memory_review_settings":
                return try await store.getMemoryReviewSettings()
            case "set_memory_review_settings":
                return try await store.setMemoryReviewSettings(
                    budgetMinutes: arguments["budget_minutes"] as? Int,
                    prepareDaily: arguments["prepare_daily"] as? Bool,
                    readyByHour: arguments["ready_by_hour"] as? Int,
                    newCardsPerDay: arguments["new_cards_per_day"] as? Int,
                    autoDraftCards: arguments["auto_draft_cards"] as? Bool,
                    draftNudges: arguments["draft_nudges"] as? Bool
                )
            case "draft_cards":
                return try await store.draftCards(arguments: arguments)
            case "save_card_drafts":
                return try await store.saveCardDrafts(
                    cards: arguments["cards"] as? [[String: Any]] ?? [],
                    keptByDefault: arguments["kept_by_default"] as? Bool ?? false
                )
            case "list_cards":
                return try await store.listCards(
                    status: arguments["status"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "list_source_card_coverage":
                return try await store.listSourceCardCoverage(
                    scope: arguments["scope"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "find_card_sources":
                return try await store.findCardSources(
                    cardID: arguments["card_id"] as? String,
                    question: arguments["question"] as? String,
                    answer: arguments["answer"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    notebookID: arguments["notebook_id"] as? String
                )
            case "triage_cards":
                return try await store.triageCards(
                    decisions: arguments["decisions"] as? [[String: Any]] ?? [],
                    keepSourceIDs: arguments["keep_source_ids"] as? [String] ?? [],
                    skipSourceIDs: arguments["skip_source_ids"] as? [String] ?? []
                )
            case "get_due_cards":
                return try await store.getDueCards(
                    notebookID: arguments["notebook_id"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "record_card_result":
                return try await store.recordCardResult(
                    cardID: arguments["card_id"] as? String,
                    itemID: arguments["item_id"] as? String,
                    remembered: arguments["remembered"],
                    asked: arguments["asked"] as? String,
                    sittingID: arguments["sitting_id"] as? String,
                    practice: arguments["practice"]
                )
            case "practice_cards":
                return try await store.practiceCards(
                    cardIDs: arguments["card_ids"],
                    title: arguments["title"] as? String
                )
            case "update_card":
                return try await store.updateCard(
                    cardID: arguments["card_id"] as? String,
                    itemID: arguments["item_id"] as? String,
                    front: arguments["front"] as? String,
                    back: arguments["back"] as? String,
                    why: arguments["why"],
                    frontImages: arguments["front_images"],
                    backImages: arguments["back_images"],
                    startOver: arguments["start_over"],
                    alwaysAsk: arguments["always_ask"],
                    retire: arguments["retire"]
                )
            case "list_practices":
                return try store.listPractices(status: arguments["status"] as? String)
            case "decide_practice":
                return try await store.decidePractice(
                    practiceID: arguments["practice_id"] as? String,
                    decision: arguments["decision"] as? String
                )
            case "set_practice":
                return try store.setPractice(
                    practiceID: arguments["practice_id"] as? String,
                    title: arguments["title"] as? String,
                    why: arguments["why"] as? String,
                    rule: arguments["rule"],
                    status: arguments["status"] as? String,
                    scope: arguments["scope"] as? String,
                    suggested: arguments["suggested"] as? Bool ?? false
                )
            case "set_review_depth":
                return try store.setReviewDepth(
                    sourceID: arguments["source_id"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    depth: arguments["depth"] as? String ?? ""
                )
            case "record_understanding":
                return try await store.recordUnderstanding(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    sessionSummary: arguments["session_summary"] as? String ?? "",
                    updates: arguments["updates"] as? [[String: Any]] ?? []
                )
            case "review_suggested_sources":
                return try store.reviewSuggestedSources(
                    goalID: arguments["goal_id"] as? String ?? "",
                    approve: arguments["approve"] as? [String] ?? [],
                    reject: arguments["reject"] as? [String] ?? []
                )
            case "search_sources_semantic":
                return try await store.searchSourcesSemantic(
                    queryText: arguments["query"] as? String ?? "",
                    limit: arguments["limit"] as? Int ?? 8,
                    threshold: Float(arguments["threshold"] as? Double ?? Double(EmbeddingSettings.similarityThreshold)),
                    sourceType: arguments["source_type"] as? String,
                    addedFrom: Self.searchAddedWindow(arguments).from,
                    addedTo: Self.searchAddedWindow(arguments).to,
                    notebookID: arguments["notebook_id"] as? String,
                    excludeNotebookID: arguments["exclude_notebook_id"] as? String,
                    show: arguments["show"] as? String
                )
            case "search_sources_keyword":
                return try store.searchSourcesKeyword(
                    keywords: arguments["keywords"] as? [String] ?? [],
                    matchAll: (arguments["match"] as? String)?.lowercased() == "all",
                    limit: arguments["limit"] as? Int ?? 50,
                    snippetsPerSource: arguments["snippets_per_source"] as? Int ?? 2,
                    sourceType: arguments["source_type"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    show: arguments["show"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "list_shows":
                return try store.listShows(kind: arguments["kind"] as? String)
            case "filter_sources":
                return try store.filterSources(
                    show: arguments["show"] as? String,
                    author: arguments["author"] as? String,
                    titleContains: arguments["title_contains"] as? String,
                    text: arguments["text"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    includeArchived: arguments["include_archived"] as? Bool ?? false,
                    limit: arguments["limit"] as? Int ?? 200
                )
            case "start_review_session":
                return try await store.startScopedReviewSession(
                    topic: arguments["topic"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    notebookID: arguments["notebook_id"] as? String,
                    operationID: arguments["operation_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "end_review_session":
                guard let overallScore = ToolArgumentNumber.value(arguments["overall_score"]),
                      overallScore.isFinite,
                      (0.0...1.0).contains(overallScore) else {
                    throw MCPError.invalidInput(
                        "overall_score must be a finite number from 0.0 to 1.0."
                    )
                }
                return try store.endReviewSession(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    hostSessionID: hostSessionID,
                    overallScore: overallScore,
                    summary: arguments["summary"] as? String ?? "",
                    transcript: arguments["transcript"] as? String ?? arguments["chat_export"] as? String,
                    gaps: arguments["gaps"] as? [[String: Any]] ?? [],
                    memoryAttempts: arguments["memory_attempts"] as? [[String: Any]] ?? [],
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    topic: arguments["topic"] as? String
                )
            case "get_review_sessions": return try store.getReviewSessions(topic: arguments["topic"] as? String, sourceId: arguments["source_id"] as? String)
            case "get_review_session_transcript":
                return try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]))
            case "import_review_chat":
                return try store.importReviewChat(
                    title: arguments["title"] as? String ?? "",
                    transcript: arguments["transcript"] as? String ?? arguments["chat_export"] as? String ?? "",
                    transcriptFile: arguments["transcript_file"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String],
                    summary: arguments["summary"] as? String,
                    overallScore: clampUnitInterval(optional: arguments["overall_score"] as? Double),
                    modelProvider: arguments["model_provider"] as? String,
                    modelID: arguments["model_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    sessionID: (arguments["session_id"] as? String).map { MCPDataStore.reviewSessionID(from: $0) },
                    startedAt: (arguments["started_at"] as? String).flatMap(MCPDataStore.parseISODate),
                    endedAt: (arguments["ended_at"] as? String).flatMap(MCPDataStore.parseISODate),
                    marksReviewed: arguments["mark_reviewed"] as? Bool
                )
            case "search_review_sessions":
                return try store.searchReviewSessions(
                    queryText: arguments["query"] as? String ?? "",
                    limit: arguments["limit"] as? Int ?? 10
                )
            case "list_review_session_links": return try store.listReviewSessionLinks()
            case "add_source":
                if let refusal = Self.ingestNotebookRefusal(arguments, access: access) { return refusal }
                return try await store.addSourceNamingVideoChannel(
                    url: arguments["url"] as? String ?? "",
                    title: arguments["title"] as? String ?? "",
                    sourceType: arguments["source_type"] as? String ?? "article",
                    content: arguments["content"] as? String,
                    parentGroup: arguments["parent_group"] as? String,
                    author: arguments["author"] as? String,
                    occurredAt: arguments["occurred_at"] as? String,
                    // Provenance comes from the authenticated OAuth client, never
                    // from arguments; full-scope assistants keep .manual.
                    connectorLabel: access.scope == .ingest ? access.connectorLabel : nil,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "add_sources":
                if let refusal = Self.ingestNotebookRefusal(arguments, access: access) { return refusal }
                return try await store.addSourcesFilingInNotebook(
                    arguments["sources"] as? [[String: Any]] ?? [],
                    connectorLabel: access.scope == .ingest ? access.connectorLabel : nil,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "update_source_content":
                return try store.updateSourceContent(
                    sourceID: arguments["source_id"] as? String,
                    url: arguments["url"] as? String,
                    content: arguments["content"] as? String,
                    title: arguments["title"] as? String,
                    author: arguments["author"] as? String,
                    restrictToPluginLabel: access.scope == .ingest ? access.connectorLabel : nil
                )
            case "remove_connector_sources":
                return try store.removePluginSources(label: arguments["connector_label"] as? String ?? "")
            case "import_paper_from_url":
                return try await store.importPaperFilingInNotebook(
                    url: arguments["url"] as? String ?? "",
                    sourceURL: arguments["source_url"] as? String,
                    title: arguments["title"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                )
            case "import_connector_paper":
                guard access.scope == .ingest else {
                    return "Error: import_connector_paper is only available to an ingest-only plugin."
                }
                return try await store.importPluginPaper(
                    url: arguments["url"] as? String,
                    filePath: arguments["file_path"] as? String,
                    sourceURL: arguments["source_url"] as? String,
                    title: arguments["title"] as? String,
                    connectorLabel: access.connectorLabel
                )
            case "delete_source":
                return try await store.deleteSourceWithItsAudio(arguments["source_id"] as? String ?? "")
            case "remove_source":
                return try store.removeSource(arguments["source_id"] as? String ?? "")
            case "archive_source":
                return try store.archiveSource(arguments["source_id"] as? String ?? "")
            case "unarchive_source":
                return try store.unarchiveSourceRestoringContent(arguments["source_id"] as? String ?? "")
            case "set_source_hidden":
                return try store.setSourceHidden(
                    sourceID: arguments["source_id"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_source_paywall_status":
                return try store.setSourcePaywallStatus(
                    sourceID: arguments["source_id"] as? String ?? "",
                    isPaywalled: arguments["is_paywalled"] as? Bool ?? true
                )
            case "set_podcast_episode_hidden":
                return try store.setPodcastEpisodeHidden(
                    sourceID: arguments["source_id"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_podcast_show_hidden":
                return try store.setPodcastShowHidden(
                    showName: arguments["show_name"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_podcast_show_import_blocked":
                return try store.setPodcastShowImportBlocked(
                    showName: arguments["show_name"] as? String ?? "",
                    blocked: arguments["blocked"] as? Bool ?? true
                )
            case "set_podcast_episode_visible_override":
                return try store.setPodcastEpisodeVisibleOverride(
                    sourceID: arguments["source_id"] as? String ?? "",
                    visible: arguments["visible"] as? Bool ?? true
                )
            case "set_youtube_channel_hidden":
                return try store.setYouTubeChannelHidden(
                    channelName: arguments["channel_name"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_youtube_video_visible_override":
                return try store.setYouTubeVideoVisibleOverride(
                    sourceID: arguments["source_id"] as? String ?? "",
                    visible: arguments["visible"] as? Bool ?? true
                )
            case "attach_text_file_to_source":
                return try store.attachTextFileToSource(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String ?? ""
                )
            case "attach_supplementary_pdf":
                return try await store.attachSupplementaryPDF(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String,
                    pdfURL: arguments["pdf_url"] as? String
                )
            case "attach_pdf_to_paper":
                return try await store.attachPDFToPaper(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String,
                    pdfURL: arguments["pdf_url"] as? String
                )
            case "download_papers_needing_attention":
                return try await store.downloadPapersNeedingAttention(
                    sourceIDs: arguments["source_ids"] as? [String],
                    limit: arguments["limit"] as? Int
                )
            case "recheck_paywalled_papers":
                return try await store.recheckPaywalledPapers(
                    sourceIDs: arguments["source_ids"] as? [String],
                    limit: arguments["limit"] as? Int
                )
            case "rename_group":
                return try store.renameGroup(
                    groupType: arguments["group_type"] as? String ?? "",
                    groupKey: arguments["group_key"] as? String ?? "",
                    newTitle: arguments["new_title"] as? String ?? ""
                )
            case "set_group_hidden":
                return try store.setGroupHidden(
                    groupType: arguments["group_type"] as? String ?? "",
                    groupKey: arguments["group_key"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "get_source_settings":
                return try store.getSourceSettings()
            case "list_unconverted_zoom_recordings":
                return try await store.listUnconvertedZoomRecordings()
            case "resolve_unconverted_zoom_recording":
                return try await store.resolveUnconvertedZoomRecording(
                    folderPath: arguments["folder_path"] as? String ?? "",
                    action: arguments["action"] as? String ?? ""
                )
            case "get_day_settings":
                return try await store.getDaySettings()
            case "set_day_settings":
                return try await store.setDaySettings(
                    dayStartHour: try MCPDataStore.intArgument(arguments, "day_start_hour"),
                    dayEndHour: try MCPDataStore.intArgument(arguments, "day_end_hour"),
                    suggestPlanningTheDay: arguments["suggest_planning_the_day"] as? Bool,
                    forcePlanningTheDay: arguments["force_planning_the_day"] as? Bool,
                    requestNotifications: arguments["request_notifications"] as? Bool,
                    nudgeBackOnTrack: arguments["nudge_back_on_track"] as? Bool,
                    readScreen: arguments["read_screen"] as? Bool
                )
            case "get_own_router_key":
                return try store.getOwnRouterKey()
            case "set_own_router_key":
                return try store.setOwnRouterKey(
                    router: arguments["router"] as? String ?? "",
                    key: arguments["key"] as? String,
                    clear: arguments["clear"] as? Bool ?? false
                )
            case "get_ai_usage_report":
                return try store.getAIUsageReport(
                    days: (arguments["days"] as? NSNumber)?.intValue,
                    from: arguments["from"] as? String,
                    to: arguments["to"] as? String
                )
            case "get_ai_task_settings":
                return try await store.getAITaskSettings()
            case "set_ai_task_settings":
                return try await store.setAITaskSettings(
                    target: arguments["target"] as? String ?? "",
                    provider: arguments["provider"] as? String,
                    model: arguments["model"] as? String,
                    hideTrainingModels: arguments["hide_training_models"] as? Bool,
                    meetingsMayUseFree: arguments["meetings_may_use_free"] as? Bool,
                    hostFor: arguments["host_for"] as? String,
                    host: arguments["host"] as? String,
                    hostFallback: arguments["host_fallback"] as? Bool,
                    hostRegion: arguments["host_region"] as? String,
                    backupsFor: arguments["backups_for"] as? String,
                    backups: arguments["backups"] as? [[String: Any]],
                    taskID: arguments["task_id"] as? String,
                    retiredArguments: MCPDataStore.retiredAITaskSettingsArguments.filter { arguments[$0] != nil }
                )
            case "set_source_settings":
                return try await store.setSourceSettings(
                    family: arguments["family"] as? String ?? "",
                    includeInSearchAndAI: arguments["include_in_search_and_ai"] as? Bool,
                    pinned: arguments["pinned"] as? Bool
                )
            case "set_connector_auto_import":
                return try store.setPluginAutoImport(
                    plugin: arguments["connector"] as? String ?? "",
                    enabled: arguments["enabled"] as? Bool ?? false
                )
            case "follow_youtube_liked_videos":
                return try await store.followYouTubeLikedVideosMCP(
                    account: arguments["account"] as? String,
                    importExisting: arguments["import_existing"] as? Bool ?? true,
                    automaticallyFormatTranscripts:
                        arguments["format_transcripts_automatically"] as? Bool ?? false
                )
            case "follow_youtube_foreverlm_playlist":
                return try await store.followYouTubeForeverLMPlaylistMCP(account: arguments["account"] as? String)
            case "refresh_youtube_sources":
                return try await store.refreshYouTubeSourcesMCP(account: arguments["account"] as? String)
            case "import_youtube_playlist":
                return try await store.importYouTubePlaylistMCP(
                    url: arguments["url"] as? String ?? "",
                    courseID: arguments["course_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "import_teachable_course":
                return try await store.importTeachableCourseMCP(
                    url: arguments["url"] as? String ?? "",
                    courseID: arguments["course_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "import_gemini_notebook":
                return try await store.importGeminiNotebookMCP(
                    url: arguments["url"] as? String ?? "",
                    notebookID: arguments["notebook_id"] as? String
                )
            case "import_video_overview":
                return try await store.importVideoOverviewMCP(
                    filePath: arguments["file_path"] as? String ?? "",
                    notebookID: arguments["notebook_id"] as? String
                )
            case "create_course":
                return try store.createCourse(
                    title: arguments["title"] as? String ?? "",
                    courseCode: arguments["course_code"] as? String,
                    institution: arguments["institution"] as? String,
                    instructors: arguments["instructors"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "generate_course":
                return try await store.generateCourse(
                    topic: arguments["topic"] as? String ?? "",
                    learnerNotes: arguments["learner_notes"] as? String,
                    useWeb: arguments["use_web"] as? Bool ?? false,
                    moduleCount: arguments["module_count"] as? Int,
                    scheduleStart: arguments["schedule_start"] as? String,
                    daysPerModule: arguments["days_per_module"] as? Int,
                    writeQuizzes: arguments["quizzes"] as? Bool ?? false,
                    chosenSourceIDs: arguments["source_ids"] as? [String] ?? [],
                    agreedPlan: arguments["plan"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "generate_course_quizzes":
                return try await store.generateCourseQuizzes(arguments: arguments)
            case "add_course_quiz_pictures":
                return try await store.addCourseQuizPictures(arguments: arguments)
            case "get_course_quiz":
                return try store.getCourseQuiz(arguments: arguments)
            case "save_course_quiz":
                return try store.saveCourseQuiz(arguments: arguments)
            case "delete_course_quiz":
                return try store.deleteCourseQuiz(arguments: arguments)
            case "rename_course_quiz":
                return try store.renameCourseQuiz(arguments: arguments)
            case "set_course_quiz_picture":
                return try store.setCourseQuizPicture(arguments: arguments)
            case "record_course_quiz_result":
                return try await store.recordCourseQuizResult(arguments: arguments)
            case "save_course_textbook_readings":
                return try await store.saveCourseTextbookReadings(arguments: arguments)
            case "add_textbook_to_course":
                return try await store.addTextbookToCourse(arguments: arguments)
            case "generate_explainer":
                return try await store.generateExplainer(
                    sourceID: arguments["source_id"] as? String ?? "",
                    lengthName: arguments["length"] as? String,
                    generateAudio: arguments["generate_audio"] as? Bool ?? true,
                    confirmCost: arguments["confirm_cost"] as? Bool ?? false,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                        ?? MCPRunningWork.defaultSpendLimitUSD
                )
            case "generate_audio_overview":
                return try await store.generateAudioOverview(arguments: arguments)
            case "generate_report":
                return try await store.generateReport(arguments: arguments)
            case "generate_explainer_video":
                return try await store.generateExplainerVideo(arguments: arguments)
            case "generate_walkthrough":
                return try await store.generateWalkthrough(arguments: arguments)
            case "get_walkthrough":
                return try await store.getWalkthrough(arguments: arguments)
            case "list_walkthroughs":
                return try await store.listWalkthroughs(notebookID: arguments["notebook_id"] as? String)
            case "save_walkthrough":
                return try await store.saveWalkthrough(arguments: arguments)
            case "delete_walkthrough":
                return try await store.deleteWalkthrough(arguments: arguments)
            case "update_course":
                return try store.updateCourse(
                    courseID: arguments["course_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    courseCode: arguments["course_code"] as? String,
                    institution: arguments["institution"] as? String,
                    instructors: arguments["instructors"] as? String,
                    playlistURL: arguments["playlist_url"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    unlinkNotebookID: arguments["unlink_notebook_id"] as? String
                )
            case "delete_course":
                return try store.deleteCourse(courseID: arguments["course_id"] as? String ?? "")
            case "create_course_lecture":
                return try store.createCourseLectureResolved(
                    courseIdentifier: arguments["course_id"] as? String
                        ?? arguments["course_name"] as? String
                        ?? "",
                    identifierIsStableID: arguments["course_id"] as? String != nil,
                    title: arguments["title"] as? String,
                    number: arguments["number"] as? Int
                )
            case "rename_course_lecture":
                return try store.renameCourseLecture(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    title: arguments["title"] as? String ?? ""
                )
            case "add_source_to_lecture":
                return try store.addSourceToLecture(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String ?? "",
                    role: arguments["role"] as? String
                )
            case "add_paper_to_lecture":
                return try store.addPaperToLecture(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String ?? "",
                    assignedReading: arguments["assigned_reading"] as? Bool
                )
            case "find_lecture_papers":
                return try await store.findLecturePapers(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false
                )
            case "ingest_lecture_papers":
                return try await store.ingestLecturePapers(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    citedPaperIDs: arguments["cited_paper_ids"] as? [String] ?? [],
                    assignedReadingIDs: arguments["assigned_reading_ids"] as? [String] ?? []
                )
            case "remove_course_lecture_item":
                return try store.removeCourseLectureItem(itemID: arguments["item_id"] as? String ?? "")
            case "move_source_type":
                return try store.moveSourceType(
                    sourceID: arguments["source_id"] as? String ?? "",
                    newType: arguments["new_type"] as? String ?? ""
                )
            case "remove_all_from_podcast":
                return try store.removeAllFromPodcastShow(showName: arguments["show_name"] as? String ?? "")
            case "delete_review_session":
                return try store.deleteReviewSession(sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]))
            case "update_review_session_sources":
                return try store.updateReviewSessionLinkedSources(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "update_review_session":
                return try store.updateReviewSession(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    title: arguments["title"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    isHidden: arguments["is_hidden"] as? Bool,
                    isPinned: arguments["is_pinned"] as? Bool
                )
            case "extract_paper_metadata":
                return try await store.extractPaperMetadataForSource(sourceID: arguments["source_id"] as? String ?? "")
            case "extract_article_metadata":
                return try await store.extractArticleMetadataForSource(sourceID: arguments["source_id"] as? String ?? "")
            case "find_duplicate_papers":
                return try await store.findDuplicatePapers(archiveDuplicates: arguments["archive_duplicates"] as? Bool ?? false)
            case "find_podcast_match":
                return try await store.findPodcastMatch(sourceID: arguments["source_id"] as? String ?? "")
            case "resolve_podcast_match":
                return try await store.resolvePodcastMatch(
                    sourceID: arguments["source_id"] as? String ?? "",
                    confirm: arguments["confirm"] as? Bool ?? false
                )
            case "find_podcast_on_youtube":
                return try await store.findPodcastOnYouTube(
                    sourceID: arguments["source_id"] as? String ?? "",
                    alwaysForShow: arguments["always_for_show"] as? Bool
                )
            case "import_podcast_youtube_transcript":
                return try await store.importPodcastYouTubeTranscript(
                    sourceID: arguments["source_id"] as? String ?? "",
                    video: arguments["video"] as? String ?? "",
                    replace: arguments["replace"] as? Bool ?? false
                )
            case "refetch_source_content":
                return try await store.refetchSourceContent(sourceID: arguments["source_id"] as? String ?? "")
            case "import_local_pdf_as_paper":
                return try await store.importLocalPDFAsPaperInBackground(
                    filePath: arguments["file_path"] as? String ?? "",
                    title: arguments["title"] as? String,
                    tool: "import_local_pdf_as_paper",
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                )
            case "import_local_file":
                return try await store.importLocalFile(
                    filePath: arguments["file_path"] as? String ?? "",
                    kind: arguments["kind"] as? String,
                    title: arguments["title"] as? String,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                )
            case "fetch_video_transcript":
                return try await store.fetchVideoTranscript(
                    sourceID: arguments["source_id"] as? String ?? "",
                    passcode: arguments["passcode"] as? String
                )
            case "list_video_cited_papers":
                return try store.listVideoCitedPapers(sourceID: arguments["source_id"] as? String ?? "")
            case "import_video_cited_paper":
                return try await store.importVideoCitedPaper(
                    citedPaperID: arguments["cited_paper_id"] as? String ?? ""
                )
            case "update_video_cited_paper_status":
                return try store.updateVideoCitedPaperStatus(
                    citedPaperID: arguments["cited_paper_id"] as? String ?? "",
                    status: arguments["status"] as? String ?? ""
                )
            case "extract_video_slides":
                return try await store.extractVideoSlides(sourceID: arguments["source_id"] as? String ?? "")
            case "scan_video_for_cited_papers":
                return try await store.scanVideoForCitedPapers(
                    sourceID: arguments["source_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false,
                    exhaustive: arguments["all_slides"] as? Bool ?? false
                )
            case "scan_meeting_for_mentioned_papers":
                return try await store.scanMeetingForMentionedPapers(
                    sourceID: arguments["source_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false
                )
            case "make_article_reading_view":
                return try await store.makeArticleReadingView(
                    sourceID: arguments["source_id"] as? String ?? "",
                    instruction: arguments["instruction"] as? String ?? ""
                )
            case "get_article_reading_view":
                return try store.getArticleReadingView(sourceID: arguments["source_id"] as? String ?? "")
            case "set_article_reading_view_shown":
                return try store.setArticleReadingViewShown(
                    sourceID: arguments["source_id"] as? String ?? "",
                    shown: arguments["shown"] as? Bool ?? true
                )
            case "clear_article_reading_view":
                return try store.clearArticleReadingView(sourceID: arguments["source_id"] as? String ?? "")
            case "scan_article_for_linked_sources":
                return try await store.scanArticleForLinkedSources(
                    sourceID: arguments["source_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false
                )
            case "fetch_source_from_archive":
                return try await store.fetchSourceFromArchive(sourceID: arguments["source_id"] as? String ?? "")
            case "clear_source_derived_data":
                return try store.clearSourceDerivedData(arguments["source_id"] as? String ?? "")
            case "set_source_read":
                return try store.setSourceRead(
                    sourceID: arguments["source_id"] as? String ?? "",
                    read: arguments["read"] as? Bool ?? true
                )
            case "update_source":
                return try store.updateSource(
                    sourceID: arguments["source_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    author: arguments["author"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    journal: arguments["journal"] as? String,
                    publishedYear: arguments["published_year"] as? String,
                    doi: arguments["doi"] as? String,
                    isPaywalled: arguments["is_paywalled"] as? Bool,
                    parentGroup: arguments["parent_group"] as? String,
                    content: arguments["content"] as? String
                )
            default:
                return "Unknown tool: \(name)"
            }
        } catch {
            logger.error("Tool \(name) failed: \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
    }
}
