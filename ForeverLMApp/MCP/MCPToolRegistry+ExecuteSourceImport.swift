// MCPToolRegistry: runs the source-import, source-setting and Settings tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the source-import, source-setting and Settings tools; nil for any other name.
    func executeSourceImportTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
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
        default:
            return nil
        }
    }
}
