// MCPToolRegistry: runs the plugin, audio and transcript tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the plugin, audio and transcript tools; nil for any other name.
    func executeIntegrationsTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
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
        default:
            return nil
        }
    }
}
