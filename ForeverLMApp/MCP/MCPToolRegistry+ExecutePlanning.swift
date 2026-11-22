// MCPToolRegistry: runs the schedule, goal, idea, direction and memory-review tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the schedule, goal, idea, direction and memory-review tools; nil for any other name.
    func executePlanningTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
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
        default:
            return nil
        }
    }
}
