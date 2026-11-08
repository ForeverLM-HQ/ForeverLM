import Foundation
import ImageIO
import OSLog
import PDFKit
import SQLite3

extension MCPDataStore {

    // MARK: - Schedule

    /// The Schedule as an assistant plans against it: the week containing
    /// today, every deliberate placement on it, and the Goals and Notebooks each
    /// placement serves. `goalID` narrows the calendar to one Goal's or
    /// Notebook's placements.
    func getSchedule(goalID: String? = nil, includeCompleted: Bool = true) throws -> String {
        // Screen record mode (admin only): a placement on a source the take
        // keeps off screen is not listed or counted, a Goal or Notebook it keeps
        // off screen is never named in a tag, and one asked for by id reads as
        // absent, the answer an unknown id gets. All empty while the mode is off.
        let screenScope = screenRecordScope()
        let screenRecordHidden = try screenRecordHiddenSourceIDs(scope: screenScope)
        let screenRecordHiddenGoalIDs: Set<String> = try screenScope.map { scope in
            Set(try knowledgeStore().loadLearningGoals()
                .filter { !screenRecordAllowsGoal($0, scope: scope) }
                .map(\.id))
        } ?? []
        return try withDB { db in
            let calendar = Calendar.current
            let now = Date()
            let today = calendar.startOfDay(for: now)
            // The schedule is a continuous calendar; the week is always the one
            // containing today, computed from the live date (never a stored window).
            let reviewDays = scheduleWeekDayStarts(containing: today, calendar: calendar)

            let filterGoalID: String? = (goalID?.isEmpty == false) ? goalID : nil
            var scopedGoal: [String: Any]?
            if let filterGoalID {
                if screenRecordHiddenGoalIDs.contains(filterGoalID) {
                    throw MCPError.notFound("Goal or Notebook not found: \(filterGoalID)")
                }
                scopedGoal = try query(db, """
                    SELECT id, title, status FROM learning_goals WHERE id = ? AND kind = 'companion' LIMIT 1
                """, params: [filterGoalID]).first
                if scopedGoal == nil {
                    throw MCPError.notFound("Goal or Notebook not found: \(filterGoalID)")
                }
            }

            // Shared placements: one row per deliberately scheduled source,
            // optionally scoped to one goal. `is_automatic` rows are anchors the
            // app wrote to record reading/listening activity, not plans anyone
            // made: they belong to activity_days, never to a planned day.
            let placementSQL = """
                SELECT ss.id AS placement_id, ss.source_id, ss.planned_at, ss.added_at, ss.completed_at,
                       sp.title, sp.source_type, sp.domain,
                       COALESCE(sp.parent_group_title, sp.parent_group) AS parent_group, sp.group_sort_index,
                       sp.word_count, sp.author
                FROM scheduled_sources ss
                \(filterGoalID != nil ? "JOIN scheduled_source_goals ssg ON ssg.scheduled_source_id = ss.id AND ssg.goal_id = ?" : "")
                LEFT JOIN source_projection sp ON sp.id = ss.source_id
                WHERE ss.is_automatic = 0
            """
            let placementRows = try query(db, placementSQL, params: filterGoalID != nil ? [filterGoalID!] : [])
            let linkedReviewDates = try linkedReviewDatesBySource(db)
            let activityBySource = Dictionary(
                grouping: try knowledgeStore().loadSourceActivityDays(),
                by: \.sourceID
            )

            // Goal tags per placement: the Goals and Notebooks it serves, since a
            // placement can serve several. The plain goals older builds created
            // stay in the database, but no tool names them any more.
            var tagsByPlacement: [String: [[String: Any]]] = [:]
            for row in try query(db, """
                SELECT ssg.scheduled_source_id AS placement_id, g.id AS goal_id, g.title AS goal_title
                FROM scheduled_source_goals ssg
                JOIN learning_goals g ON g.id = ssg.goal_id
                WHERE g.kind = 'companion'
                ORDER BY g.created_at ASC
            """) {
                guard let placementID = row["placement_id"] as? String,
                      let tagGoalID = row["goal_id"] as? String,
                      !screenRecordHiddenGoalIDs.contains(tagGoalID),
                      let goalTitle = row["goal_title"] as? String else { continue }
                tagsByPlacement[placementID, default: []].append(["id": tagGoalID, "title": goalTitle])
            }

            let sortedRows = placementRows
                .filter { !screenRecordHidden.contains($0["source_id"] as? String ?? "") }
                .sorted { scheduleSortKey($0) < scheduleSortKey($1) }
            var itemsByDay: [Date: [[String: Any]]] = [:]
            var completedCount = 0
            let totalCount = sortedRows.count

            for row in sortedRows {
                let isCompleted = row["completed_at"] != nil
                if isCompleted { completedCount += 1 }
                if !includeCompleted && isCompleted { continue }

                let sourceID = row["source_id"] as? String ?? ""
                let placementID = row["placement_id"] as? String ?? ""
                let plannedAtDouble = row["planned_at"] as? Double ?? today.timeIntervalSinceReferenceDate
                let plannedDay = calendar.startOfDay(for: appleDate(plannedAtDouble))
                let sourceType = row["source_type"] as? String ?? ""
                let title = row["title"] as? String ?? sourceID
                let groupTitle = row["parent_group"] as? String
                let domain = row["domain"] as? String ?? ""
                let isMissingSource = row["title"] == nil
                let subtitle: String
                if isMissingSource {
                    subtitle = "Source no longer exists"
                } else if let groupTitle, !groupTitle.isEmpty {
                    subtitle = sourceType == "book" ? "Book chapter" : groupTitle
                } else {
                    subtitle = domain
                }
                let latestLinkedReviewAt = linkedReviewDates[sourceID]
                let completedAt = row["completed_at"] as? Double
                let latestReviewAt = maxReviewTimestamp(latestLinkedReviewAt, completedAt)
                let hasLinkedReviewSession = latestLinkedReviewAt != nil

                var item: [String: Any] = [
                    "item_id": placementID,
                    "source_id": sourceID,
                    "title": title,
                    "subtitle": subtitle,
                    "source_type": sourceType.isEmpty ? "missing" : sourceType,
                    "planned_date": isoDateOnly(plannedDay, calendar: calendar),
                    "added_at": appleToISO(row["added_at"] as? Double ?? plannedAtDouble),
                    "is_completed": isCompleted,
                    "can_mark_done": !isMissingSource,
                    "has_linked_review_session": hasLinkedReviewSession,
                    "is_missing_source": isMissingSource,
                    "goal_tags": tagsByPlacement[placementID] ?? [],
                ]
                if let completedAt {
                    item["completed_at"] = appleToISO(completedAt)
                }
                if let latestReviewAt {
                    item["latest_review_at"] = appleToISO(latestReviewAt)
                }
                if let groupTitle, !groupTitle.isEmpty {
                    item["group_title"] = groupTitle
                }
                if !domain.isEmpty {
                    item["domain"] = domain
                }
                if let wordCount = row["word_count"] as? Int {
                    item["word_count"] = wordCount
                }
                if let author = row["author"] as? String, !author.isEmpty {
                    item["author"] = author
                }
                let activityDays = activityBySource[sourceID] ?? []
                if !activityDays.isEmpty {
                    item["activity_days"] = activityDays.map { activity in
                        [
                            "date": isoDateOnly(activity.dayStart, calendar: calendar),
                            "first_at": ISO8601DateFormatter().string(from: activity.firstActivityAt),
                            "last_at": ISO8601DateFormatter().string(from: activity.lastActivityAt),
                            "kinds": activity.kinds.map(\.rawValue).sorted(),
                            "completed_kinds": activity.completedKinds.map(\.rawValue).sorted(),
                        ] as [String: Any]
                    }
                }
                itemsByDay[plannedDay, default: []].append(item)
            }

            let days: [[String: Any]] = reviewDays.map { day in
                let items = itemsByDay[day, default: []]
                return [
                    "date": isoDateOnly(day, calendar: calendar),
                    "is_today": calendar.isDate(day, inSameDayAs: today),
                    "is_past": day < today,
                    "pending_count": items.filter { ($0["is_completed"] as? Bool) != true }.count,
                    "completed_count": items.filter { ($0["is_completed"] as? Bool) == true }.count,
                    "items": items,
                ]
            }

            let weekStart = reviewDays.first
            let weekEnd = reviewDays.last

            var payload: [String: Any] = [
                "today": isoDateOnly(today, calendar: calendar),
                "current_week": [
                    "starts_on": weekStart.map { isoDateOnly($0, calendar: calendar) } ?? "",
                    "ends_on": weekEnd.map { isoDateOnly($0, calendar: calendar) } ?? "",
                    "contains_today": true,
                    "status": "current",
                ],
                "days": days,
                "include_completed": includeCompleted,
                "scope": filterGoalID == nil ? "all_goals" : "goal",
                "progress": [
                    "completed_count": completedCount,
                    "total_count": totalCount,
                    "percent": totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount),
                ],
                "planning_guidance": "The schedule is one continuous calendar anchored on the live today field; current_week is always the Mon–Sun week containing today. With no goal_id this is the whole Schedule — each item lists goal_tags for the Goals and Notebooks it serves, and an item with no tags is on the Schedule for its own sake. A source appears once even if it serves several; completing it (set_source_completion or mark_schedule_day_done) marks it done for all of them at once. Goals are not week windows: assign_sources_to_day accepts any date. Use pending, non-missing items as the near-term plan; has_linked_review_session distinguishes sources with saved review chats from schedule-only reviews. Only deliberate placements appear here: opening or playing a source records activity_days, which is history, never a planned day and never a completion. An item is completed only by set_source_completion, mark_schedule_day_done, or a graded review.",
                "generated_at": ISO8601DateFormatter().string(from: now),
            ]
            if let filterGoalID, let scopedGoal {
                payload["goal"] = [
                    "id": filterGoalID,
                    "title": scopedGoal["title"] as? String ?? "",
                    "status": scopedGoal["status"] as? String ?? "",
                ]
            }
            return try jsonString(payload)
        }
    }

    func getTodaySources(
        goalID: String? = nil,
        dateString: String? = nil,
        dateBasis: String? = nil,
        activityKind: String? = nil,
        includeCompleted: Bool = false,
        maxCharsPerSource: Int? = nil
    ) throws -> String {
        let calendar = Calendar.current
        let targetDay: Date
        if let dateString, !dateString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetDay = try parseScheduleDate(dateString, calendar: calendar)
        } else {
            targetDay = calendar.startOfDay(for: Date())
        }
        let dayString = isoDateOnly(targetDay, calendar: calendar)
        let isToday = calendar.isDate(targetDay, inSameDayAs: calendar.startOfDay(for: Date()))
        let dayLabel = isToday ? "today (\(dayString))" : dayString
        let normalizedDateBasis = dateBasis?.lowercased() ?? "planned"
        let usesCompletionDate = normalizedDateBasis == "completed"
        let usesActivityDate = normalizedDateBasis == "activity"
        let normalizedActivityKind = activityKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestedActivityKind = normalizedActivityKind.flatMap(SourceActivityKind.init(rawValue:))
        if normalizedActivityKind?.isEmpty == false, requestedActivityKind == nil {
            throw MCPError.invalidInput("activity_kind must be reading, listening, watching, chat, or review.")
        }
        let activityKindMask: Int64? = requestedActivityKind.flatMap { kind in
            SourceActivityKind.allCases.firstIndex(of: kind).map { Int64(1) << Int64($0) }
        }

        // Placements scheduled for the day, across all goals or scoped to one.
        let filterGoalID: String? = (goalID?.isEmpty == false) ? goalID : nil
        let dayStart = targetDay
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw MCPError.invalidInput("Could not resolve the requested local calendar day.")
        }
        // Screen record mode (admin only): a placement on a source the take
        // keeps off screen is not listed. Empty, and so a no-op, when off.
        let screenRecordHidden = try screenRecordHiddenSourceIDs(scope: screenRecordScope())
        let sourceIDs: [String] = try withDB { db in
            let sql = usesActivityDate ? """
                SELECT DISTINCT ss.source_id, ss.planned_at, ss.added_at, ss.completed_at, sp.title,
                       COALESCE(sp.parent_group_title, sp.parent_group) AS parent_group,
                       sp.group_sort_index, sad.last_activity_at
                FROM source_activity_days sad
                JOIN scheduled_sources ss ON ss.id = sad.scheduled_source_id
                \(filterGoalID != nil ? "JOIN scheduled_source_goals ssg ON ssg.scheduled_source_id = ss.id AND ssg.goal_id = ?" : "")
                LEFT JOIN source_projection sp ON sp.id = ss.source_id
                WHERE sad.last_activity_at >= ? AND sad.last_activity_at < ?
                  \(activityKindMask != nil ? "AND (sad.kinds & ?) != 0" : "")
            """ : """
                SELECT DISTINCT ss.source_id, ss.planned_at, ss.added_at, ss.completed_at, sp.title,
                       COALESCE(sp.parent_group_title, sp.parent_group) AS parent_group, sp.group_sort_index
                FROM scheduled_sources ss
                \(filterGoalID != nil ? "JOIN scheduled_source_goals ssg ON ssg.scheduled_source_id = ss.id AND ssg.goal_id = ?" : "")
                LEFT JOIN source_projection sp ON sp.id = ss.source_id
                WHERE \(usesCompletionDate ? "ss.completed_at" : "ss.planned_at") >= ?
                  AND \(usesCompletionDate ? "ss.completed_at" : "ss.planned_at") < ?
                  \(usesCompletionDate ? "" : "AND ss.is_automatic = 0")
            """
            var params: [Any] = []
            if let filterGoalID { params.append(filterGoalID) }
            params.append(dayStart.timeIntervalSinceReferenceDate)
            params.append(dayEnd.timeIntervalSinceReferenceDate)
            if let activityKindMask, usesActivityDate { params.append(activityKindMask) }
            let rows = try query(db, sql, params: params)
            let sorted = usesActivityDate
                ? rows.sorted {
                    ($0["last_activity_at"] as? Double ?? 0)
                        < ($1["last_activity_at"] as? Double ?? 0)
                }
                : usesCompletionDate
                ? rows.sorted {
                    ($0["completed_at"] as? Double ?? 0)
                        < ($1["completed_at"] as? Double ?? 0)
                }
                : rows.sorted { scheduleSortKey($0) < scheduleSortKey($1) }
            return sorted.compactMap { row -> String? in
                if !usesCompletionDate && !usesActivityDate && !includeCompleted && row["completed_at"] != nil { return nil }
                if row["title"] == nil { return nil }
                guard let sourceID = row["source_id"] as? String,
                      !screenRecordHidden.contains(sourceID) else { return nil }
                return sourceID
            }
        }
        guard !sourceIDs.isEmpty else {
            if usesCompletionDate {
                return "No sources were completed in ForeverLM on \(dayLabel)."
            }
            if usesActivityDate {
                let activityLabel = requestedActivityKind.map { "\($0.rawValue) activity" }
                    ?? "reading, listening, watching, chat, or review activity"
                return "No \(activityLabel) was recorded in ForeverLM on \(dayLabel)."
            }
            let scope = includeCompleted ? "" : "pending "
            return "No \(scope)sources are scheduled for \(dayLabel). Use get_schedule to see the week, or assign_sources_to_day to plan the day.\(includeCompleted ? "" : " Pass include_completed to load already-reviewed sources.")"
        }

        // Name a collection only when the caller explicitly scoped this read.
        // App-selected Notebook state is never inherited by a Schedule request.
        let contextGoal = filterGoalID.flatMap { try? knowledgeStore().loadLearningGoal($0) }
        let notebookLine = contextGoal.map {
            "These sources live in your ForeverLM knowledge base, in the Notebook \"\($0.title)\".\n"
        } ?? ""

        let charLimit = min(max(maxCharsPerSource ?? 50_000, 1_000), 200_000)
        let heading = usesActivityDate
            ? requestedActivityKind.map { "Sources used for \($0.rawValue) in ForeverLM" }
                ?? "Sources used in ForeverLM"
            : usesCompletionDate
            ? "Sources completed in ForeverLM"
            : (includeCompleted ? "Schedule sources" : "Pending Schedule sources")
        let completionInstruction: String
        if usesCompletionDate {
            completionInstruction = "To quiz or review them, call start_review_session with the returned source IDs so the new review is linked back to these sources. They are already marked finished; do not mark the Schedule done again."
        } else if usesActivityDate {
            completionInstruction = "To quiz or review them, call start_review_session with the returned source IDs. Their activity is already logged; the new review will be linked and recorded automatically."
        } else {
            completionInstruction = "To quiz or review, call start_review_session with the returned source IDs so the completed review is linked back to these sources."
        }
        var sections: [String] = ["""
        \(heading) for \(dayLabel): \(sourceIDs.count) source\(sourceIDs.count == 1 ? "" : "s").
        \(notebookLine)\(completionInstruction)
        """]
        for sourceID in sourceIDs {
            let body: String
            do {
                var content = try getSourceContent(sourceID)
                if content.count > charLimit {
                    content = String(content.prefix(charLimit)) + "\n\n[Truncated at \(charLimit) characters. Call get_source_content with source_id \(sourceID) for the full text.]"
                }
                body = content
            } catch {
                body = "Could not load content for source \(sourceID): \(error.localizedDescription)"
            }
            sections.append("=== source_id: \(sourceID) ===\n\(body)")
        }
        return sections.joined(separator: "\n\n")
    }

    func assignSourcesToDay(goalID: String? = nil, sourceIDs: [String], dateString: String) async throws -> String {
        let uniqueSourceIDs = sanitizedSourceIDs(sourceIDs)
        guard !uniqueSourceIDs.isEmpty else {
            throw MCPError.invalidInput("At least one source_id is required.")
        }

        let calendar = Calendar.current
        let targetDay = try parseScheduleDate(dateString, calendar: calendar)
        let store = try knowledgeStore()

        // scheduled_sources.source_id has no FK on purpose (CloudKit can deliver a
        // placement before its source), so a typo would otherwise create a placement
        // pointing at nothing.
        try validateSourcesExist(uniqueSourceIDs)

        // A Goal or Notebook is named only by goal_id: a window's notebook in
        // ForeverLM is never inherited. Without one, a source already on the
        // Schedule moves and one that is not yet there is placed untagged.
        let scheduleGoal = try resolveScheduleGoal(goalID)

        // With a goal named, every source that is not yet the goal's joins it
        // here — one with no placement at all, and one already on the Schedule
        // but tagged only to other goals — pool and tag, then the day. Until
        // 2026-09-19 only a source with no placement joined: one placed for
        // another goal was moved to the day and never tagged, so the tool
        // answered "Assigned 2 sources" while the goal's own Schedule read
        // stayed at zero items.
        var joining: [String] = []
        if let scheduleGoal {
            // Join the goal's pool as well as the calendar. `addSourceToGoal`
            // writes only scheduled_sources + scheduled_source_goals; without a
            // learning_goal_items row the source is absent from
            // LearningGoalRecord.items, so it never counts toward progress, never
            // gets its completion mirrored back onto the goal, and doesn't reach a
            // second device (loadLearningGoalForSync builds the payload from items).
            guard let placementGoal = try store.loadLearningGoal(scheduleGoal.id) else {
                throw MCPError.invalidInput("Goal or Notebook not found: \(scheduleGoal.id)")
            }
            let tagged = Set(scheduleGoal.sourceIDs)
            joining = uniqueSourceIDs.filter { !tagged.contains($0) }
            if !joining.isEmpty {
                // A team's Goal or Notebook takes sources only while this
                // account may edit it: refused before anything is placed,
                // tagged or filed. A source it already holds still moves.
                do {
                    try requireNotebookTeamTakesSources(placementGoal, store: store)
                } catch MCPError.invalidInput(let refusal) {
                    throw MCPError.invalidInput(refusal + " Leave goal_id out to plan the day without it.")
                }
            }
            let pooled = Set(placementGoal.items.map(\.sourceID))
            let joiningPool = joining.filter { !pooled.contains($0) }
            if !joiningPool.isEmpty {
                if placementGoal.teamID != nil {
                    // A team's pool holds the team's copies of the learner's
                    // own sources, never their ids, as add_goal_sources files
                    // them (`fileSourcesInTeamPool`, which ticks what arrives).
                    // Until 2026-09-30 this wrote the member's own ids into the
                    // team's pool. The placement and its tag below stay the
                    // learner's own day plan, on the ids they named, as the
                    // app's day plan keeps them (`addSourcesToNotebookSchedule`).
                    _ = try await fileSourcesInTeamPool(joiningPool, in: placementGoal)
                } else {
                    // A Goal's additions reach its Notebook too; what arrives in
                    // a Notebook is ticked for its chats (`tickArrivingNotebookSources`).
                    let pools = [placementGoal.id] + (placementGoal.parentNotebookID.map { [$0] } ?? [])
                    var heldBefore: [String: Set<String>] = [:]
                    for pool in pools {
                        heldBefore[pool] = Set(try store.loadLearningGoal(pool)?.approvedSourceIDs ?? [])
                    }
                    _ = try store.addCompanionSeedSources(goalID: scheduleGoal.id, sourceIDs: joiningPool)
                    followTeamShares { storage in
                        await storage.propagateNotebookSourcesToTeams(notebookID: scheduleGoal.id, sourceIDs: joiningPool)
                    }
                    var arrivals: [String: [String]] = [:]
                    for (pool, held) in heldBefore {
                        arrivals[pool] = (try store.loadLearningGoal(pool)?.approvedSourceIDs ?? []).filter { !held.contains($0) }
                    }
                    await tickArrivingNotebookSources(arrivals)
                }
            }
        }

        for sourceID in uniqueSourceIDs {
            if let scheduleGoal, joining.contains(sourceID) {
                // Places AND tags in one transaction. setScheduledSourcePlannedDate
                // would create or move the placement without the
                // scheduled_source_goals row, leaving it invisible to
                // loadScheduledSources(goalID:) and treated as an orphan by
                // removeSourceFromGoal's cleanup.
                try store.addSourceToGoal(sourceID: sourceID, goalID: scheduleGoal.id, plannedAt: targetDay)
            } else {
                // Moves the placement, or creates an untagged one: the Schedule
                // holds a source whether or not a Goal claims it.
                try store.setScheduledSourcePlannedDate(sourceID: sourceID, plannedAt: targetDay)
            }
        }

        let refreshed = try getSchedule(goalID: scheduleGoal?.id, includeCompleted: true)
        return """
        Assigned \(uniqueSourceIDs.count) source\(uniqueSourceIDs.count == 1 ? "" : "s") to \(isoDateOnly(targetDay, calendar: calendar)).

        \(refreshed)
        """
    }

    /// Take sources off the Schedule. With a Goal or Notebook named, only its
    /// tag comes off and the placement stays for anything else it serves. With
    /// no goal the placement itself goes — the unified Schedule's own removal —
    /// and any activity history stays behind as an automatic entry.
    func unscheduleSources(goalID: String? = nil, sourceIDs: [String]) throws -> String {
        let uniqueSourceIDs = sanitizedSourceIDs(sourceIDs)
        guard !uniqueSourceIDs.isEmpty else {
            throw MCPError.invalidInput("At least one source_id is required.")
        }
        let scheduleGoal = try resolveScheduleGoal(goalID)
        if let scheduleGoal {
            try validateSourcesTagged(uniqueSourceIDs, goal: scheduleGoal)
        } else {
            try validateSourcesScheduled(uniqueSourceIDs)
        }

        try knowledgeStore().removeSourcesFromSchedule(goalID: scheduleGoal?.id, sourceIDs: uniqueSourceIDs)

        let scope = scheduleGoal.map { "the Schedule of \($0.id)" } ?? "the Schedule"
        let refreshed = try getSchedule(goalID: scheduleGoal?.id, includeCompleted: true)
        return """
        Removed \(uniqueSourceIDs.count) source\(uniqueSourceIDs.count == 1 ? "" : "s") from \(scope).

        \(refreshed)
        """
    }

    /// Take back activity ForeverLM recorded on sources that did not happen;
    /// see `KnowledgeStore.forgetAutomaticSourceActivity`. Nothing else could:
    /// `unschedule_sources` keeps activity history by design and takes only a
    /// plan, and `set_source_read` covers only the source types that track a
    /// read state, so a review wrongly recorded on seven sources on 2026-09-28
    /// had no way off over MCP.
    func forgetSourceActivity(sourceIDs: [String], dateString: String?) throws -> String {
        let uniqueSourceIDs = sanitizedSourceIDs(sourceIDs)
        guard !uniqueSourceIDs.isEmpty else {
            throw MCPError.invalidInput("At least one source_id is required.")
        }
        let rawDate = dateString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawDate.isEmpty else {
            throw MCPError.invalidInput(
                "date is required: the day the activity was recorded, YYYY-MM-DD (get_today_sources with date_basis activity lists a day's)."
            )
        }
        let calendar = Calendar.current
        let day = try parseScheduleDate(rawDate, calendar: calendar)
        let store = try knowledgeStore()
        let forgotten: [KnowledgeStore.ForgottenSourceActivity]
        do {
            forgotten = try store.forgetAutomaticSourceActivity(sourceIDs: uniqueSourceIDs, on: day)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }

        let titles: [String: String] = try withDB { db in
            let placeholders = uniqueSourceIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, "SELECT id, title FROM source_projection WHERE id IN (\(placeholders))", params: uniqueSourceIDs)
            return rows.reduce(into: [String: String]()) { result, row in
                if let id = row["id"] as? String, let title = row["title"] as? String { result[id] = title }
            }
        }
        let formatter = ISO8601DateFormatter()
        let sources: [[String: Any]] = forgotten.map { entry in
            [
                "source_id": entry.sourceID,
                "title": titles[entry.sourceID].map { $0 as Any } ?? NSNull(),
                "days": entry.days.map { activity in
                    [
                        "date": isoDateOnly(activity.dayStart, calendar: calendar),
                        "kinds": activity.kinds.map(\.rawValue).sorted(),
                        "completed_kinds": activity.completedKinds.map(\.rawValue).sorted(),
                    ] as [String: Any]
                },
                "was_completed": entry.wasCompleted,
                "read_at_cleared": entry.clearedReadAt.map { formatter.string(from: $0) as Any } ?? NSNull(),
                "reopened_task_ids": entry.reopenedTaskIDs,
            ] as [String: Any]
        }
        let dayLabel = isoDateOnly(day, calendar: calendar)
        let readCount = forgotten.filter { $0.clearedReadAt != nil }.count
        let taskCount = forgotten.reduce(0) { $0 + $1.reopenedTaskIDs.count }
        var parts = ["their automatic Schedule entries and activity days are gone"]
        if readCount > 0 { parts.append("\(readCount) read stamp\(readCount == 1 ? " was" : "s were") cleared") }
        if taskCount > 0 { parts.append("\(taskCount) assignment\(taskCount == 1 ? " was" : "s were") reopened") }
        return try jsonString([
            "status": "forgotten",
            "date": dayLabel,
            "sources": sources,
            "message": "Forgot what ForeverLM recorded on \(forgotten.count) source\(forgotten.count == 1 ? "" : "s") on \(dayLabel): \(parts.joined(separator: ", ")), on every device.",
        ] as [String: Any])
    }

    func clearScheduleDay(goalID: String? = nil, dateString: String, includeCompleted: Bool = false) throws -> String {
        let calendar = Calendar.current
        let targetDay = try parseScheduleDate(dateString, calendar: calendar)
        let scheduleGoal = try resolveScheduleGoal(goalID)

        let sourceIDs = try scheduledSourceIDs(
            on: targetDay,
            goalID: scheduleGoal?.id,
            includeCompleted: includeCompleted,
            includeMissing: true,
            calendar: calendar
        )
        guard !sourceIDs.isEmpty else {
            return "No \(includeCompleted ? "" : "pending ")sources are scheduled for \(isoDateOnly(targetDay, calendar: calendar))\(scheduleGoal == nil ? "" : " in this Goal or Notebook")."
        }

        try knowledgeStore().removeSourcesFromSchedule(goalID: scheduleGoal?.id, sourceIDs: sourceIDs)

        let refreshed = try getSchedule(goalID: scheduleGoal?.id, includeCompleted: true)
        return """
        Removed \(sourceIDs.count) source\(sourceIDs.count == 1 ? "" : "s") from \(isoDateOnly(targetDay, calendar: calendar)).

        \(refreshed)
        """
    }

    func markScheduleDayDone(goalID: String? = nil, dateString: String) throws -> String {
        let calendar = Calendar.current
        let targetDay = try parseScheduleDate(dateString, calendar: calendar)
        let scheduleGoal = try resolveScheduleGoal(goalID)

        let sourceIDs = try scheduledSourceIDs(
            on: targetDay,
            goalID: scheduleGoal?.id,
            includeCompleted: false,
            includeMissing: false,
            calendar: calendar
        )
        guard !sourceIDs.isEmpty else {
            return "No pending, non-missing sources are scheduled for \(isoDateOnly(targetDay, calendar: calendar))."
        }

        // The app's own check-off: one completion, shared by every Goal and
        // Notebook the placement serves.
        let store = try knowledgeStore()
        for sourceID in sourceIDs {
            try store.setScheduledSourceCompletion(sourceID: sourceID, isCompleted: true)
        }

        let refreshed = try getSchedule(goalID: scheduleGoal?.id, includeCompleted: true)
        return """
        Marked \(sourceIDs.count) source\(sourceIDs.count == 1 ? "" : "s") done for \(isoDateOnly(targetDay, calendar: calendar)).

        \(refreshed)
        """
    }

    func setSourceCompletion(goalID: String? = nil, sourceID: String, isCompleted: Bool) throws -> String {
        let trimmedSourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceID.isEmpty else {
            throw MCPError.invalidInput("source_id is required.")
        }
        let store = try knowledgeStore()
        guard try store.scheduledSourceID(forSource: trimmedSourceID) != nil else {
            throw MCPError.invalidInput("Source is not on the Schedule: \(trimmedSourceID).")
        }
        try store.setScheduledSourceCompletion(sourceID: trimmedSourceID, isCompleted: isCompleted)

        let refreshed = try getSchedule(goalID: goalID, includeCompleted: true)
        return """
        \(isCompleted ? "Marked" : "Reopened") source \(trimmedSourceID) (applies to every Goal and Notebook it serves).

        \(refreshed)
        """
    }

    /// A Goal or Notebook named as a Schedule tool's scope, with the sources its
    /// tag carries on shared placements.
    struct MCPScheduleGoal {
        let id: String
        let sourceIDs: [String]
    }

    /// Resolve a Schedule tool's `goal_id`. nil when none was given: the call
    /// then acts on the Schedule itself, never on a notebook open in a
    /// ForeverLM window. Only a Goal or a Notebook can be named; the plain goals older
    /// builds created stay in the database untouched, but no tool scopes to one.
    func resolveScheduleGoal(_ goalID: String?) throws -> MCPScheduleGoal? {
        guard let goalID = goalID?.trimmingCharacters(in: .whitespacesAndNewlines), !goalID.isEmpty else {
            return nil
        }
        let goal: MCPScheduleGoal = try withDB { db in
            let row = try query(db, """
                SELECT id FROM learning_goals WHERE id = ? AND kind = 'companion' LIMIT 1
            """, params: [goalID]).first
            guard let row, let id = row["id"] as? String else {
                throw MCPError.notFound("Goal or Notebook not found: \(goalID)")
            }
            let sourceRows = try query(db, """
                SELECT ss.source_id
                FROM scheduled_source_goals ssg
                JOIN scheduled_sources ss ON ss.id = ssg.scheduled_source_id
                WHERE ssg.goal_id = ?
            """, params: [id])
            return MCPScheduleGoal(
                id: id,
                sourceIDs: sourceRows.compactMap { $0["source_id"] as? String }
            )
        }
        return goal
    }

    func sanitizedSourceIDs(_ sourceIDs: [String]) -> [String] {
        Array(dictUnique(sourceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
    }

    func validateSourcesExist(_ sourceIDs: [String]) throws {
        guard !sourceIDs.isEmpty else { return }
        let existing = try withDB { db in
            let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, "SELECT id FROM source_projection WHERE id IN (\(placeholders))", params: sourceIDs)
            return Set(rows.compactMap { $0["id"] as? String })
        }
        let missing = sourceIDs.filter { !existing.contains($0) }
        guard missing.isEmpty else {
            throw MCPError.invalidInput("Source IDs not found: \(missing.joined(separator: ", "))")
        }
    }

    func validateSourcesTagged(_ sourceIDs: [String], goal: MCPScheduleGoal) throws {
        let taggedSourceIDs = Set(goal.sourceIDs)
        let missing = sourceIDs.filter { !taggedSourceIDs.contains($0) }
        guard missing.isEmpty else {
            throw MCPError.invalidInput("These source_ids are not on the Schedule of \(goal.id): \(missing.joined(separator: ", "))")
        }
    }

    /// Only a deliberate placement is on the Schedule. A source with nothing
    /// but an automatic activity entry has no plan to take off.
    func validateSourcesScheduled(_ sourceIDs: [String]) throws {
        guard !sourceIDs.isEmpty else { return }
        let scheduled = try withDB { db in
            let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, """
                SELECT source_id FROM scheduled_sources
                WHERE is_automatic = 0 AND source_id IN (\(placeholders))
            """, params: sourceIDs)
            return Set(rows.compactMap { $0["source_id"] as? String })
        }
        let missing = sourceIDs.filter { !scheduled.contains($0) }
        guard missing.isEmpty else {
            throw MCPError.invalidInput("These source_ids are not on the Schedule: \(missing.joined(separator: ", "))")
        }
    }

    /// The sources placed on `day`, in the Schedule's order: every deliberate
    /// placement, or only those tagged with `goalID`. An automatic activity
    /// entry is history rather than a plan, so a day operation on the whole
    /// Schedule never touches one.
    func scheduledSourceIDs(
        on day: Date,
        goalID: String?,
        includeCompleted: Bool,
        includeMissing: Bool,
        calendar: Calendar
    ) throws -> [String] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(24 * 60 * 60)
        return try withDB { db in
            var params: [Any] = []
            if let goalID { params.append(goalID) }
            params.append(dayStart.timeIntervalSinceReferenceDate)
            params.append(dayEnd.timeIntervalSinceReferenceDate)
            let rows = try query(db, """
                SELECT ss.source_id, ss.added_at, ss.completed_at,
                       sp.title, COALESCE(sp.parent_group_title, sp.parent_group) AS parent_group, sp.group_sort_index
                FROM scheduled_sources ss
                \(goalID != nil ? "JOIN scheduled_source_goals ssg ON ssg.scheduled_source_id = ss.id AND ssg.goal_id = ?" : "")
                LEFT JOIN source_projection sp ON sp.id = ss.source_id
                WHERE ss.planned_at >= ? AND ss.planned_at < ?
                  \(goalID == nil ? "AND ss.is_automatic = 0" : "")
            """, params: params)
            let sortedRows = rows.sorted { lhs, rhs in
                scheduleSortKey(lhs) < scheduleSortKey(rhs)
            }
            return sortedRows.compactMap { row -> String? in
                if !includeCompleted && row["completed_at"] != nil {
                    return nil
                }
                if !includeMissing && row["title"] == nil {
                    return nil
                }
                return row["source_id"] as? String
            }
        }
    }

    /// Resolve a caller-supplied day to the start of that local calendar day.
    ///
    /// `YYYY-MM-DD` is the documented shape and is validated component-wise, so
    /// an impossible day (`2026-02-31`) is refused rather than silently rolled
    /// forward into March the way a lenient formatter would.
    ///
    /// Every unambiguous spelling of a *day* is accepted, because the one thing
    /// worse than a model inventing a date is these tools refusing a date they
    /// printed themselves. A source search renders its hits as
    /// `occurred: 2026-06-10 16:53 PDT`, and a model narrowing its next call
    /// hands that string straight back; the strict parser refused it, along with
    /// a timestamp carrying fractional seconds and one carrying no zone at all.
    /// So: a timestamp with a real UTC offset names an instant and resolves to
    /// the local day that instant falls on, and anything else that begins with a
    /// day and continues into a time of day is taken at face value — it was
    /// printed in the learner's own zone, so its date part is already local.
    ///
    /// A bare year or year-month is still refused. It is not a day, and when a
    /// model sends one it has read a book's publication year and is hoping the
    /// field means that; accepting it would widen the day to a range nobody
    /// asked for and search a different axis in silence. The refusal names the
    /// field and the value, so the model's next call can drop or fix the one
    /// argument that was wrong instead of guessing — the arguments of a failed
    /// call are not otherwise shown to anyone, so this message is also the only
    /// record of what was sent.
    ///
    /// "today", "yesterday" and "tomorrow" are days too, resolved on this Mac's
    /// clock. The day-plan and bout tools advertise "today", so a model that has
    /// just used one of them passes the word here as well; refusing it cost a
    /// failed call and a retry before a review could start.
    func parseScheduleDate(
        _ value: String,
        calendar: Calendar,
        field: String = "date",
        now: Date = Date()
    ) throws -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let offset = Self.relativeDayOffsets[trimmed.lowercased()],
           let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) {
            return calendar.startOfDay(for: day)
        }
        if let day = Self.calendarDayComponents(trimmed) {
            return try startOfLocalDay(day, calendar: calendar, raw: trimmed, field: field)
        }
        if Self.carriesUTCOffset(trimmed), let instant = Self.parseFlexibleTimestamp(trimmed) {
            return calendar.startOfDay(for: instant)
        }
        if let day = Self.calendarDayComponents(Self.dayPrefix(of: trimmed)) {
            return try startOfLocalDay(day, calendar: calendar, raw: trimmed, field: field)
        }

        throw MCPError.invalidInput(
            "\(field) \"\(trimmed)\" is not a date. Pass a full local day as YYYY-MM-DD, a full ISO8601 timestamp, or \"today\", \"yesterday\" or \"tomorrow\"; a bare year or month is not accepted."
        )
    }

    private static let relativeDayOffsets: [String: Int] = ["today": 0, "yesterday": -1, "tomorrow": 1]

    /// The `YYYY-MM-DD` head of a timestamp, i.e. everything before the time of
    /// day. Empty unless a time of day actually follows: "2026-06-10 16:53 PDT"
    /// is a day, and "2026-06-10 or so" is a model thinking out loud, which is
    /// refused so it hears that rather than being answered for a day it half
    /// meant.
    private static func dayPrefix(of value: String) -> Substring {
        let head = value.prefix { $0 != " " && $0 != "T" }
        let rest = value.dropFirst(head.count).dropFirst()
        guard rest.first?.isNumber == true else { return "" }
        return head
    }

    /// The three integers of a `YYYY-MM-DD` day, without judging whether they
    /// name a day that exists — `2026-02-31` parses here and is refused below,
    /// so the refusal can say it is not a real date rather than not a date.
    private static func calendarDayComponents(_ value: some StringProtocol) -> (year: Int, month: Int, day: Int)? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return (year, month, day)
    }

    /// A trailing `Z` or `±HH:MM`. Only these pin a timestamp to an instant; a
    /// zone *abbreviation* (`PDT`) does not, and no formatter here reads one.
    private static func carriesUTCOffset(_ value: String) -> Bool {
        value.hasSuffix("Z")
            || value.range(of: "[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) != nil
    }

    private func startOfLocalDay(
        _ components: (year: Int, month: Int, day: Int),
        calendar: Calendar,
        raw: String,
        field: String
    ) throws -> Date {
        guard let date = calendar.date(
                from: DateComponents(year: components.year, month: components.month, day: components.day)
              ),
              calendar.component(.year, from: date) == components.year,
              calendar.component(.month, from: date) == components.month,
              calendar.component(.day, from: date) == components.day else {
            throw MCPError.invalidInput("\(field) \"\(raw)\" is not a real calendar date.")
        }
        return calendar.startOfDay(for: date)
    }

    /// `added_from` / `added_to` on a source search filter on the day a source was
    /// *added to the library*, not on when it was written or published. A model
    /// asked about a 2021 book reads the year off the book and reaches for these
    /// fields; the refusal has to say which axis the field is on, or the retry
    /// mends the spelling and the search then silently finds nothing.
    func parseSourceSearchDate(_ value: String, field: String, calendar: Calendar) throws -> Date {
        do {
            return try parseScheduleDate(value, calendar: calendar, field: field)
        } catch let error as MCPError {
            throw MCPError.invalidInput(
                "\(error.localizedDescription) \(field) filters on the local day a source was added to the library, not on when it was published; omit it unless the request is about when something was saved."
            )
        }
    }

    func scheduleSortKey(_ row: [String: Any]) -> String {
        let sourceID = row["source_id"] as? String ?? ""
        let addedAt = row["added_at"] as? Double ?? 0
        guard row["title"] != nil else {
            return "\(String(format: "%020.6f", addedAt))|zzzz|\(sourceID)"
        }
        let title = (row["title"] as? String ?? sourceID).lowercased()
        let group = ((row["parent_group"] as? String) ?? title).lowercased()
        let sortIndex = row["group_sort_index"] as? Int ?? Int.max
        return "\(String(format: "%020.6f", addedAt))|\(group)|\(String(format: "%08d", sortIndex))|\(title)"
    }

    func linkedReviewDatesBySource(_ db: OpaquePointer) throws -> [String: Double] {
        var result: [String: Double] = [:]
        let joinRows = try query(db, """
            SELECT fss.source_id, MAX(COALESCE(fs.ended_at, fs.started_at)) AS latest_review_at
            FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
            GROUP BY fss.source_id
        """)
        for row in joinRows {
            guard let sourceID = row["source_id"] as? String,
                  let latestReviewAt = row["latest_review_at"] as? Double else { continue }
            result[sourceID] = latestReviewAt
        }

        let sessionRows = try query(db, """
            SELECT source_ids, COALESCE(ended_at, started_at) AS latest_review_at
            FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """)
        for row in sessionRows {
            guard let latestReviewAt = row["latest_review_at"] as? Double else { continue }
            for sourceID in decodeStringArray(row["source_ids"] as? String) {
                result[sourceID] = maxReviewTimestamp(result[sourceID], latestReviewAt)
            }
        }
        return result
    }

    func maxReviewTimestamp(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }

    /// The seven Mon–Sun day-starts of the calendar week containing `date`.
    func scheduleWeekDayStarts(containing date: Date, calendar: Calendar) -> [Date] {
        let weekStart = mondayWeekStart(containing: date, calendar: calendar)
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart)
        }
    }

    func mondayWeekStart(containing date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart) ?? dayStart
    }

    func dictUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    func existingColumn(in table: String, candidates: [String], db: OpaquePointer) throws -> String? {
        let columns = try query(db, "PRAGMA table_info(\(table))").compactMap { $0["name"] as? String }
        return candidates.first { columns.contains($0) }
    }

    func existingGroupID(in table: String, matching input: String, db: OpaquePointer) throws -> String? {
        guard let idColumn = try existingColumn(in: table, candidates: ["id", "name"], db: db) else {
            return nil
        }
        let rows = try query(
            db,
            "SELECT \(idColumn) AS group_id FROM \(table) WHERE \(idColumn) = ? OR title = ? COLLATE NOCASE LIMIT 1",
            params: [input, input]
        )
        return rows.first?["group_id"] as? String
    }

    func resolveGroupID(input: String, preferredType: String, store: KnowledgeStore) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if preferredType == "course" {
            return try resolveOrCreateCourseID(input: trimmed, store: store)
        }

        // Read AI and transcript-file imports keep sending the provider's old
        // group title after the learner merges it. Resolve the durable alias in
        // SQLite before the generic title lookup can recreate that retired row.
        if preferredType == "meeting",
           let existing = try store.resolvedMeetingGroupID(matching: trimmed) {
            return existing
        }

        if let existing = try withDB({ db in
            if preferredType == "book" {
                return try existingGroupID(in: "books", matching: trimmed, db: db)
            }
            return nil as String?
        }) {
            return existing
        }

        if preferredType == "book" {
            try store.saveBookRecord(CloudKitBookPayload(id: trimmed, title: trimmed, author: nil, coverPath: nil))
        } else if preferredType == "meeting" {
            try store.saveMeetingGroup(name: trimmed, metadata: MeetingMetadata(title: trimmed))
        }
        return trimmed
    }

    /// The library's sources for `query`, best first, ranked as
    /// search_sources_semantic and the in-app search rank them (by meaning
    /// and by words): their ids only. Speaking to the Canvas finds what to
    /// set down with it. Runs the search where it is called, so call it off
    /// the main actor.
    func rankedSourceIDs(query: String, limit: Int) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let store = try knowledgeStore()
        let embeddingProvider = sourceEmbeddingProvider ?? liveSourceEmbeddingProvider
        let queryVector = try await embeddingProvider(trimmed)
        return StorageService.searchSources(
            queryText: trimmed,
            queryVector: queryVector,
            limit: max(1, min(limit, 25)),
            threshold: EmbeddingSettings.similarityThreshold,
            using: store
        ).map(\.sourceId)
    }

    func searchSourcesSemantic(
        queryText: String,
        limit: Int = 8,
        threshold: Float = EmbeddingSettings.similarityThreshold,
        sourceType: String? = nil,
        addedFrom: String? = nil,
        addedTo: String? = nil,
        notebookID: String? = nil,
        excludeNotebookID: String? = nil,
        show: String? = nil
    ) async throws -> String {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = try knowledgeStore()
        let requestedLimit = max(1, min(limit, 25))
        let queryTerms = SourceSearchEngine.searchTerms(for: trimmedQuery)

        let normalizedSourceType = sourceType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sourceTypeFamily: [String] = []
        if let normalizedSourceType, !normalizedSourceType.isEmpty {
            guard let family = StudioSourceType.searchFamily(named: normalizedSourceType) else {
                throw MCPError.invalidInput("Unknown source_type '\(normalizedSourceType)'. Use one of: \(StudioSourceType.searchFamilyNames.joined(separator: ", ")).")
            }
            sourceTypeFamily = family
        }

        let calendar = Calendar.current
        let parsedDateFrom = try addedFrom.map { try parseSourceSearchDate($0, field: "added_from", calendar: calendar) }
        let parsedDateTo = try addedTo.map { try parseSourceSearchDate($0, field: "added_to", calendar: calendar) }
        if let parsedDateFrom, let parsedDateTo, parsedDateFrom > parsedDateTo {
            throw MCPError.invalidInput("added_from must be on or before added_to.")
        }
        // A show scope is a metadata filter like the others: "what has Huberman
        // said about mitochondria" ranks inside the show's episodes instead of
        // letting every other show's mitochondria episode take the slots.
        let showScope = try show.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map { try showScopedSourceIDs($0) }
        let hasMetadataFilter = normalizedSourceType?.isEmpty == false || parsedDateFrom != nil || parsedDateTo != nil
        guard !trimmedQuery.isEmpty || hasMetadataFilter || showScope != nil else {
            throw MCPError.invalidInput("Source search requires a query, source_type, added_from, added_to, or show.")
        }

        let scopedNotebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let excludedNotebookID = excludeNotebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard scopedNotebookID.isEmpty || excludedNotebookID.isEmpty else {
            throw MCPError.invalidInput(
                "notebook_id and exclude_notebook_id cannot be combined. Use notebook_id to search inside a Notebook, or exclude_notebook_id to look outside it."
            )
        }

        var restrictedSourceIDs: Set<String>?
        var scopedNotebookTitle: String?
        if !scopedNotebookID.isEmpty {
            let goal = try resolveMCPNotebookGoal(notebookID: scopedNotebookID, store: store)
            // Its own sources and those of the context notebooks its chats read.
            restrictedSourceIDs = Set(notebookChatPoolSourceIDs(goal: goal, store: store))
            scopedNotebookTitle = goal.title
            guard restrictedSourceIDs?.isEmpty == false else {
                return "No approved sources are available in Notebook '\(goal.title)' to search."
            }
        }

        if let showScope {
            restrictedSourceIDs = restrictedSourceIDs.map { $0.intersection(showScope.sourceIDs) } ?? showScope.sourceIDs
        }

        if hasMetadataFilter {
            var predicates: [String] = ["status = 'active'"]
            var params: [Any] = []
            if !sourceTypeFamily.isEmpty {
                predicates.append("source_type IN (\(sourceTypeFamily.map { _ in "?" }.joined(separator: ", ")))")
                params.append(contentsOf: sourceTypeFamily)
            }
            if let parsedDateFrom {
                predicates.append("date_added >= ?")
                params.append(parsedDateFrom.timeIntervalSinceReferenceDate)
            }
            if let parsedDateTo,
               let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: parsedDateTo) {
                predicates.append("date_added < ?")
                params.append(exclusiveEnd.timeIntervalSinceReferenceDate)
            }
            let metadataIDs: Set<String> = try withDB { db in
                Set(try query(
                    db,
                    "SELECT id FROM source_projection WHERE \(predicates.joined(separator: " AND "))",
                    params: params
                ).compactMap { $0["id"] as? String })
            }
            restrictedSourceIDs = restrictedSourceIDs.map { $0.intersection(metadataIDs) } ?? metadataIDs
            guard restrictedSourceIDs?.isEmpty == false else {
                // A well-formed date on the wrong axis matches nothing, and an
                // empty result reads as "the library does not have this" unless
                // it says what it filtered on. Name the window and its axis so
                // the retry drops the filter instead of the search.
                var filters: [String] = []
                if let showScope {
                    filters.append("show \(showScope.names.map { "'\($0)'" }.joined(separator: " or "))")
                }
                if let normalizedSourceType, !normalizedSourceType.isEmpty {
                    filters.append("source_type \(normalizedSourceType)")
                }
                if parsedDateFrom != nil || parsedDateTo != nil {
                    let day = DateFormatter()
                    day.locale = Locale(identifier: "en_US_POSIX")
                    day.timeZone = calendar.timeZone
                    day.dateFormat = "yyyy-MM-dd"
                    let from = parsedDateFrom.map(day.string(from:))
                    let to = parsedDateTo.map(day.string(from:))
                    switch (from, to) {
                    case let (from?, to?): filters.append("added to the library between \(from) and \(to)")
                    case let (from?, nil): filters.append("added to the library on or after \(from)")
                    case let (nil, to?): filters.append("added to the library on or before \(to)")
                    case (nil, nil): break
                    }
                }
                return "No sources match \(filters.joined(separator: ", "))."
                    + " added_from/added_to filter on the day a source was saved, never on when it was"
                    + " published — if the day came from a work's own year, search again without them."
            }
        }

        // "Find me more sources for this Notebook" is a search whose whole point is what
        // the Notebook does *not* already have. Every state counts as attached: approved
        // and pending are visibly in the pool, and rejected is tombstoned precisely so it
        // is never re-proposed.
        var excludedSourceIDs: Set<String> = []
        var excludedNotebookTitle: String?
        if !excludedNotebookID.isEmpty {
            let goal = try resolveMCPNotebookGoal(notebookID: excludedNotebookID, store: store)
            excludedSourceIDs = Set(notebookChatPoolSourceIDs(goal: goal, store: store))
                .union(goal.items.map(\.sourceID))
            excludedNotebookTitle = goal.title
        }

        // The ranking itself lives in `SourceSearchEngine`, shared with the in-app Studio
        // search, so an assistant asking "what do I have on GDF15?" and a learner typing
        // the same thing into the app get the same answer in the same order.
        //
        // Over-fetch by the exclusion count so a Notebook holding 100 sources still yields
        // a full page of candidates instead of a page that filters down to nothing.
        let fetchLimit = excludedSourceIDs.isEmpty
            ? requestedLimit
            : min(requestedLimit + excludedSourceIDs.count, 400)
        if showScope != nil, restrictedSourceIDs?.isEmpty != false {
            return "No searchable source of \(showScope?.names.map { "'\($0)'" }.joined(separator: " or ") ?? "that show") matches these filters: the show may be hidden, kept from AI in Settings, archived, or outside this Notebook."
        }
        let ranked: [SourceSearchHit]
        if trimmedQuery.isEmpty {
            // The metadata-only listing reads ids straight from the filters,
            // so the screen-record scope is applied here; the ranked branch
            // below already drops it through `knowledgeSearchExcludedSourceIDs`.
            let screenRecordHidden = try screenRecordHiddenSourceIDs(scope: screenRecordScope())
            ranked = try withDB { db in
                let ids = (restrictedSourceIDs ?? []).subtracting(screenRecordHidden)
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                return try query(
                    db,
                    "SELECT id FROM source_projection WHERE id IN (\(placeholders)) ORDER BY date_added DESC, title LIMIT ?",
                    params: ids.map { $0 as Any } + [fetchLimit as Any]
                ).compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    return SourceSearchHit(
                        sourceId: id,
                        score: 0,
                        semanticScore: nil,
                        lexicalScore: nil,
                        metadataScore: nil,
                        bestChunkId: nil
                    )
                }
            }
        } else {
            let embeddingProvider = sourceEmbeddingProvider ?? liveSourceEmbeddingProvider
            let queryVector = try await embeddingProvider(trimmedQuery)
            ranked = StorageService.searchSources(
                queryText: trimmedQuery,
                queryVector: queryVector,
                limit: fetchLimit,
                threshold: threshold,
                restrictedTo: restrictedSourceIDs,
                using: store
            )
        }
        let results = excludedSourceIDs.isEmpty
            ? ranked
            : Array(ranked.filter { !excludedSourceIDs.contains($0.sourceId) }.prefix(requestedLimit))

        guard !results.isEmpty else {
            if let scopedNotebookTitle {
                return "No semantically or text-matched sources found for '\(trimmedQuery)' in Notebook '\(scopedNotebookTitle)'."
            }
            if let excludedNotebookTitle, !ranked.isEmpty {
                return "No sources found for '\(trimmedQuery)' outside the Notebook '\(excludedNotebookTitle)' — every match is already in it."
            }
            return "No semantically or text-matched sources found for '\(trimmedQuery)'."
        }

        let ids = results.map(\.sourceId)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")

        return try withDB { db in
            let rows = try query(db, """
                SELECT sp.id, sp.title, sp.source_type, sp.domain, sp.author, COALESCE(sp.parent_group_title, sp.parent_group) as group_name, sp.word_count, sp.date_added, sc.content
                FROM source_projection sp
                LEFT JOIN source_content sc ON sp.id = sc.source_id
                WHERE sp.id IN (\(placeholders))
            """, params: ids)

            // Keyed with a uniquing rule, never `uniqueKeysWithValues`: this is a
            // lookup table built from whatever the database hands back, and a
            // duplicate id is a data anomaly to absorb rather than a reason to
            // trap the whole app out from under a learner mid-search.
            let rowsById: [String: [String: Any]] = Dictionary(
                rows.compactMap { row -> (String, [String: Any])? in
                    guard let id = row["id"] as? String else { return nil }
                    return (id, row)
                },
                uniquingKeysWith: { first, _ in first }
            )

            let excludedNote = excludedNotebookTitle.map {
                " — excluding \(excludedSourceIDs.count) already in Notebook '\($0)'"
            } ?? ""
            let scopedNote = (scopedNotebookTitle.map { " in Notebook '\($0)'" } ?? "")
                + (showScope.map { " in \($0.names.joined(separator: " or "))" } ?? "")
            let searchLabel = trimmedQuery.isEmpty ? "Filtered source search" : "Semantic source search for '\(trimmedQuery)'"
            var lines = ["\(searchLabel)\(scopedNote) (\(results.count) results)\(excludedNote):"]
            for result in results {
                guard let row = rowsById[result.sourceId] else { continue }
                let title = row["title"] as? String ?? "Untitled"
                let sourceType = row["source_type"] as? String ?? "unknown"
                let domain = row["domain"] as? String ?? "unknown"
                let author = row["author"] as? String ?? ""
                let parentGroup = row["group_name"] as? String ?? ""
                let wordCount = row["word_count"] as? Int ?? 0
                let dateAdded = (row["date_added"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
                let content = (row["content"] as? String ?? "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let evidence = Self.sourceSearchEvidence(
                    from: content,
                    query: trimmedQuery,
                    queryTerms: queryTerms,
                    chunkId: result.bestChunkId
                )
                var metadata: [String] = ["id: \(result.sourceId)", String(format: "score: %.3f", result.score), domain]
                if let semantic = result.semanticScore {
                    metadata.append(String(format: "semantic: %.3f", semantic))
                }
                if let lexical = result.lexicalScore {
                    metadata.append(String(format: "text: %.3f", lexical))
                }
                if wordCount > 0 { metadata.append("\(wordCount) words") }
                if !author.isEmpty { metadata.append("by \(author)") }
                if !parentGroup.isEmpty { metadata.append(parentGroup) }
                if let dateAdded {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = .current
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    metadata.append(sourceType == "meeting" ? "occurred: \(formatter.string(from: dateAdded))" : "added: \(formatter.string(from: dateAdded))")
                }
                // Keep the canonical id in both the metadata and link. Models reuse link
                // targets as tool arguments, so shortening it here can turn a valid search
                // result into a failed follow-up read.
                let linkTitle = title.replacingOccurrences(of: "]", with: "\\]")
                let titleLink = "[\(linkTitle)](foreverlm://source/\(result.sourceId))"
                lines.append("- [\(sourceType)] \(titleLink) (\(metadata.joined(separator: ", ")))")
                if !evidence.isEmpty {
                    lines.append("  Evidence: \(evidence)")
                }
            }
            lines.append("")
            lines.append("When you present these to the learner, show each source as its [title](foreverlm://source/id) link above — never print a raw source id as visible text. Call get_source_content with the ids to pull the full texts into context.")
            return lines.joined(separator: "\n")
        }
    }

    static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func sourceSearchEvidence(
        from content: String,
        query: String,
        queryTerms: [String],
        chunkId: String?,
        maxLength: Int = 520
    ) -> String {
        guard !content.isEmpty else { return "" }
        let passage: String
        if let chunkId,
           let chunkIndex = StorageService.sourceChunkIndex(fromSourceChunkEmbeddingId: chunkId) {
            let chunks = sourceEmbeddingTextChunks(from: content)
            passage = chunkIndex < chunks.count ? chunks[chunkIndex] : content
        } else {
            passage = content
        }
        return sourceSearchExcerpt(from: passage, query: query, queryTerms: queryTerms, maxLength: maxLength)
    }

    static func sourceSearchExcerpt(
        from passage: String,
        query: String,
        queryTerms: [String],
        maxLength: Int
    ) -> String {
        let normalized = passage
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        let ns = normalized as NSString
        guard ns.length > maxLength else { return normalized }

        let lower = normalized.lowercased() as NSString
        let exactRange = lower.range(of: query.lowercased())
        let terms = queryTerms.sorted { $0.count > $1.count }
        let termLocation = terms
            .lazy
            .map { lower.range(of: $0.lowercased()) }
            .first { $0.location != NSNotFound }?
            .location
        let matchLocation = exactRange.location != NSNotFound ? exactRange.location : (termLocation ?? 0)
        let desiredStart = max(0, matchLocation - 180)
        let start = min(desiredStart, max(0, ns.length - maxLength))
        let length = min(maxLength, ns.length - start)
        var excerpt = ns.substring(with: NSRange(location: start, length: length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { excerpt = "..." + excerpt }
        if start + length < ns.length { excerpt += "..." }
        return excerpt
    }

    // Canonical chunker lives in `SourceEmbeddingText`; this thin alias keeps the
    // existing evidence-lookup call site readable while guaranteeing the MCP search
    // path splits identically to the ingest and indexer paths.
    static func sourceEmbeddingTextChunks(from content: String) -> [String] {
        SourceEmbeddingText.textChunks(from: content)
    }

    /// Literal keyword search across the whole library.
    ///
    /// The semantic tool answers "what is this about"; this one answers "where
    /// does this word appear". They are different questions, and the ranked one
    /// cannot serve this: it tokenizes, so `uncoupler` misses a body that says
    /// `uncouplers`, and it fuses whatever it does match with semantic
    /// neighbours and cuts the list to a page. Here every source containing the
    /// spelling comes back, most mentions first, with the passages that prove
    /// it — so the assistant, not the ranker, drops the irrelevant ones.
    ///
    /// `sourceIDs` narrows the sweep to named sources. "Which of these 25
    /// compounds do these two papers share?" asked in a chat on two papers is a
    /// question about those two, and the whole-library sweep it got instead
    /// (2026-09-23) answered it with fifty-odd unrelated sources.
    func searchSourcesKeyword(
        keywords: [String],
        matchAll: Bool = false,
        limit: Int = 50,
        snippetsPerSource: Int = 2,
        sourceType: String? = nil,
        notebookID: String? = nil,
        show: String? = nil,
        sourceIDs: [String] = []
    ) throws -> String {
        let terms = SourceKeywordSearch.normalized(keywords)
        guard !terms.isEmpty else {
            throw MCPError.invalidInput("keywords must contain at least one word or phrase to look for.")
        }
        let maximum = SourceKeywordSearch.maximumKeywords
        guard terms.count <= maximum else {
            throw MCPError.invalidInput(
                "keywords takes at most \(maximum) words or phrases in one search, and this one has \(terms.count)."
                    + " Split them across several calls of up to \(maximum) each."
            )
        }
        let store = try knowledgeStore()
        let requestedLimit = max(1, min(limit, 200))
        let requestedSnippets = max(0, min(snippetsPerSource, 5))

        let normalizedSourceType = sourceType?.trimmingCharacters(in: .whitespacesAndNewlines)
        var sourceTypeFamily: [String] = []
        if let normalizedSourceType, !normalizedSourceType.isEmpty {
            guard let family = StudioSourceType.searchFamily(named: normalizedSourceType) else {
                throw MCPError.invalidInput("Unknown source_type '\(normalizedSourceType)'. Use one of: \(StudioSourceType.searchFamilyNames.joined(separator: ", ")).")
            }
            sourceTypeFamily = family
        }

        var restrictedSourceIDs: Set<String>?
        var scopedNotebookTitle: String?
        let scopedNotebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !scopedNotebookID.isEmpty {
            let goal = try resolveMCPNotebookGoal(notebookID: scopedNotebookID, store: store)
            // Its own sources and those of the context notebooks its chats read.
            restrictedSourceIDs = Set(notebookChatPoolSourceIDs(goal: goal, store: store))
            scopedNotebookTitle = goal.title
            guard restrictedSourceIDs?.isEmpty == false else {
                return "No approved sources are available in Notebook '\(goal.title)' to search."
            }
        }
        let showScope = try show.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map { try showScopedSourceIDs($0) }
        if let showScope {
            restrictedSourceIDs = restrictedSourceIDs.map { $0.intersection(showScope.sourceIDs) } ?? showScope.sourceIDs
            guard restrictedSourceIDs?.isEmpty == false else {
                return "No source of \(showScope.names.joined(separator: " or ")) is searchable here: the show is hidden, kept from AI in Settings, or outside this Notebook."
            }
        }
        var namedSourceIDs: [String] = []
        for id in sourceIDs {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !namedSourceIDs.contains(trimmed) else { continue }
            guard try store.sourceExists(trimmed) else {
                throw MCPError.invalidInput("No source with id \(trimmed). Use the ids of the sources attached to this chat, or find one with list_sources or search_sources_semantic.")
            }
            namedSourceIDs.append(trimmed)
        }
        if !namedSourceIDs.isEmpty {
            let named = Set(namedSourceIDs)
            restrictedSourceIDs = restrictedSourceIDs.map { $0.intersection(named) } ?? named
            guard restrictedSourceIDs?.isEmpty == false else {
                return "None of the given source_ids is in the Notebook or show this search is scoped to."
            }
        }

        // The same knowledge boundary every other library tool draws: the
        // families the learner keeps away from AI in Settings are not part of
        // the sweep. Hidden sources are (hiding is visual only); archived
        // sources are already out by status.
        let excludedSourceIDs = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let (matches, truncated) = try store.sourcesContainingKeywords(
            terms,
            matchAll: matchAll,
            maxSources: requestedLimit,
            snippetsPerSource: requestedSnippets,
            restrictedTo: restrictedSourceIDs,
            sourceTypes: sourceTypeFamily,
            excluding: excludedSourceIDs
        )

        let quoted = terms.map { "\"\($0)\"" }.joined(separator: matchAll ? " and " : " or ")
        let scopedNote = (scopedNotebookTitle.map { " in Notebook '\($0)'" } ?? "")
            + (showScope.map { " in \($0.names.joined(separator: " or "))" } ?? "")
            + (namedSourceIDs.isEmpty ? "" : namedSourceIDs.count == 1
                ? " in the given source"
                : " among the \(namedSourceIDs.count) given sources")
        guard !matches.isEmpty else {
            return "No source\(scopedNote) contains \(quoted) literally."
                + " This search matches the exact spelling as a substring and nothing else,"
                + " so try a shorter stem (\"uncoupl\" rather than \"uncouplers\"),"
                + " or call search_sources_semantic for the topic rather than the word."
        }

        let countNote = truncated
            ? "\(matches.count)+ sources (more than the limit of \(requestedLimit) contain it)"
            : "\(matches.count) source\(matches.count == 1 ? "" : "s")"
        var lines = ["Keyword search for \(quoted)\(scopedNote) — \(countNote), most mentions first:"]
        for match in matches {
            var metadata = ["id: \(match.sourceID)", match.sourceType]
            if let author = match.author, !author.isEmpty { metadata.append(author) }
            if let group = match.groupName, !group.isEmpty { metadata.append("in \(group)") }
            let mentions = match.keywordCounts
                .map { "\($0.keyword) ×\($0.count)" }
                .joined(separator: ", ")
            metadata.append("mentions: \(mentions)")
            lines.append("")
            lines.append("- \(match.title)")
            lines.append("  \(metadata.joined(separator: " | "))")
            for snippet in match.snippets {
                lines.append("  \(snippet)")
            }
        }
        if truncated {
            lines.append("")
            lines.append("Raise limit to see the rest, or narrow with source_ids, source_type or notebook_id.")
        } else {
            // A sweep of many names ("these 25 compounds") is answered as much by
            // the names that are nowhere as by the ones that are; with every match
            // listed, that set is exact.
            let found = Set(matches.flatMap(\.matchedKeywords))
            let absent = terms.filter { !found.contains($0) }
            if !absent.isEmpty {
                lines.append("")
                lines.append("In none of them: \(absent.map { "\"\($0)\"" }.joined(separator: ", ")).")
            }
        }
        return lines.joined(separator: "\n")
    }

    func liveSourceEmbeddingProvider(_ query: String) async throws -> [Float] {
        // Apple's on-device embedding model needs no key and no network. The compute
        // runs on the AIService actor's executor, off the main actor.
        return try await AIService().embedText(query)
    }

}
