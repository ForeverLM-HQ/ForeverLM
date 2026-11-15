// MCPToolRegistry: runs the scheduled-task, notebook, team, task, calendar and learning-bout tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the scheduled-task, notebook, team, task, calendar and learning-bout tools; nil for any other name.
    func executeNotebooksTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
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
        default:
            return nil
        }
    }
}
