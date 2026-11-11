// MCPDataStoreTests: getSchedule, getTodaySources and the Schedule write tools.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    @Test("getSchedule returns the active week plan")
    func getScheduleReturnsPlan() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        // The schedule is a continuous calendar whose rendered week is always the
        // live week containing today, so placements must land on current-week days.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Mechanistic Biology", content: "Cells and mechanisms.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Aging Clocks", content: "Biomarkers and methylation.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: otherDay, completedAt: nil),
            ]
        )
        try insertCompletedReviewSession(dbPath: dbPath, sessionID: "session-a", sourceID: "source-a", endedAt: today.addingTimeInterval(600))

        let store = MCPDataStore(dbPath: dbPath)
        // The `goal` key is only present when the Schedule is scoped to a goal.
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let goal = payload["goal"] as? [String: Any]
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let firstSource = allItems.first { ($0["source_id"] as? String) == "source-a" }
        let secondSource = allItems.first { ($0["source_id"] as? String) == "source-b" }

        #expect(goal?["id"] as? String == "goal-1")
        #expect(days?.count == 7)
        #expect(allItems.count == 2)
        #expect(firstSource?["title"] as? String == "Mechanistic Biology")
        #expect(firstSource?["has_linked_review_session"] as? Bool == true)
        #expect(firstSource?["can_mark_done"] as? Bool == true)
        #expect(secondSource?["has_linked_review_session"] as? Bool == false)
        #expect(secondSource?["can_mark_done"] as? Bool == true)
    }

    @Test("getSchedule recognizes source ids stored on session rows")
    func getScheduleRecognizesSessionSourceIDs() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Session Row Source", content: "Cells and mechanisms.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [(id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil)]
        )
        try execSQL(dbPath: dbPath, """
            INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary, source_ids)
            VALUES ('session-a', 'Review', \(today.timeIntervalSinceReferenceDate), \(today.addingTimeInterval(600).timeIntervalSinceReferenceDate), 'completed', 0.9, 'Reviewed', '["source-a"]');
        """)

        let store = MCPDataStore(dbPath: dbPath)
        let payload = try parseJSON(try store.getSchedule())
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let source = allItems.first { ($0["source_id"] as? String) == "source-a" }

        #expect(source?["has_linked_review_session"] as? Bool == true)
        #expect(source?["can_mark_done"] as? Bool == true)
    }

    @Test("getSchedule can omit completed items")
    func getScheduleOmitsCompletedItems() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Done Source", content: "Done.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Pending Source", content: "Pending.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: today),
                (id: "item-b", sourceID: "source-b", addedAt: otherDay, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let payload = try parseJSON(try store.getSchedule(includeCompleted: false))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []

        #expect(allItems.count == 1)
        #expect(allItems.first?["source_id"] as? String == "source-b")
    }

    @Test("getTodaySources returns content for today's pending sources only")
    func getTodaySourcesReturnsContent() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-today", title: "Today Source", content: "Spaced repetition fundamentals.")
        try insertSource(dbPath: dbPath, id: "source-other", title: "Other Day Source", content: "Tomorrow material.")
        try insertSource(dbPath: dbPath, id: "source-done", title: "Done Source", content: "Already reviewed.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-today", sourceID: "source-today", addedAt: today, completedAt: nil),
                (id: "item-other", sourceID: "source-other", addedAt: otherDay, completedAt: nil),
                (id: "item-done", sourceID: "source-done", addedAt: today, completedAt: today),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let result = try store.getTodaySources()

        #expect(result.contains("source_id: source-today"))
        #expect(result.contains("Spaced repetition fundamentals."))
        #expect(result.contains("start_review_session"))
        #expect(!result.contains("source_id: source-other"))
        #expect(!result.contains("source_id: source-done"))
    }

    @Test("getTodaySources truncates long content per source")
    func getTodaySourcesTruncatesContent() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        let longContent = String(repeating: "alpha beta gamma ", count: 200)
        try insertSource(dbPath: dbPath, id: "source-long", title: "Long Source", content: longContent)
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [(id: "item-long", sourceID: "source-long", addedAt: today, completedAt: nil)]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let result = try store.getTodaySources(maxCharsPerSource: 1_000)

        #expect(result.contains("Truncated at 1000 characters"))
        #expect(result.contains("get_source_content with source_id source-long"))
    }

    @Test("getTodaySources loads any Schedule day, including completed sources and past weeks")
    func getTodaySourcesSupportsDateAndPastWeeks() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        let lastWeekDay = calendar.date(byAdding: .day, value: 1, to: lastWeekStart)!

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-other", title: "Other Day Source", content: "Other day content.")
        try insertSource(dbPath: dbPath, id: "source-done", title: "Done Source", content: "Completed source content.")
        try insertSource(dbPath: dbPath, id: "source-lastweek", title: "Last Week Source", content: "Last week content.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-current",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-other", sourceID: "source-other", addedAt: otherDay, completedAt: nil),
                (id: "item-done", sourceID: "source-done", addedAt: today, completedAt: today),
            ]
        )
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-past",
            startAt: lastWeekStart,
            endAt: weekStart,
            items: [(id: "item-lastweek", sourceID: "source-lastweek", addedAt: lastWeekDay, completedAt: lastWeekDay)]
        )

        let store = MCPDataStore(dbPath: dbPath)

        // Another day of the current week, by date.
        let otherResult = try store.getTodaySources(dateString: formatter.string(from: otherDay))
        #expect(otherResult.contains("Other day content."))
        #expect(!otherResult.contains("Completed source content."))

        // Today's completed sources load with include_completed.
        let completedResult = try store.getTodaySources(includeCompleted: true)
        #expect(completedResult.contains("Completed source content."))

        // A day in a past week loads from the continuous calendar directly; the
        // shared-placement model no longer resolves (or names) a per-week goal.
        let lastWeekResult = try store.getTodaySources(
            dateString: formatter.string(from: lastWeekDay),
            includeCompleted: true
        )
        #expect(lastWeekResult.contains("Last week content."))
        #expect(lastWeekResult.contains("source_id: source-lastweek"))
    }

    @Test("getTodaySources can load actual completion activity independently of planned day")
    func getTodaySourcesSupportsCompletionDateBasis() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let weekStart = calendar.date(
            byAdding: .day,
            value: -((calendar.component(.weekday, from: today) + 5) % 7),
            to: today
        )!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(
            dbPath: dbPath,
            id: "source-listened",
            title: "Listened Source",
            content: "The source completed by listening."
        )
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-activity",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (
                    id: "item-listened",
                    sourceID: "source-listened",
                    addedAt: tomorrow,
                    completedAt: yesterday.addingTimeInterval(3_600)
                ),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let result = try store.getTodaySources(
            dateString: formatter.string(from: yesterday),
            dateBasis: "completed"
        )

        #expect(result.contains("Sources completed in ForeverLM"))
        #expect(result.contains("source_id: source-listened"))
        #expect(result.contains("already marked finished"))
    }

    @Test("getTodaySources uses daily activity rather than planned or completed dates")
    func getTodaySourcesSupportsActivityDateBasis() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(
            dbPath: dbPath,
            id: "source-chatted",
            title: "Chatted Source",
            content: "The source used in yesterday's chat."
        )
        let store = MCPDataStore(dbPath: dbPath)
        let knowledge = try store.knowledgeStore()
        try knowledge.setScheduledSourcePlannedDate(
            sourceID: "source-chatted",
            plannedAt: tomorrow
        )
        _ = try knowledge.recordScheduledSourceActivity(
            sourceID: "source-chatted",
            on: yesterday.addingTimeInterval(600),
            kind: .chat
        )
        let result = try store.getTodaySources(
            dateString: formatter.string(from: yesterday),
            dateBasis: "activity",
            activityKind: "chat"
        )

        #expect(result.contains("Sources used for chat in ForeverLM"))
        #expect(result.contains("source_id: source-chatted"))
        #expect(result.contains("yesterday's chat"))
        #expect(try store.getTodaySources(
            dateString: formatter.string(from: yesterday),
            dateBasis: "activity",
            activityKind: "reading"
        ).contains("No reading activity"))
    }

    /// The chat's "quiz me on the podcasts I listened to last week" reads
    /// listening activity by day; an episode played in Apple Podcasts must be
    /// in it on the day it was played, not only ForeverLM's own player's log.
    @Test("getTodaySources lists an episode played in Apple Podcasts as that day's listening")
    func getTodaySourcesListsApplePodcastsListening() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(
            dbPath: dbPath,
            id: "source-played-elsewhere",
            title: "Bioelectric Fields",
            content: "An episode about bioelectric fields in development.",
            sourceType: "podcast",
            discoveryOrigin: "applePodcasts",
            url: "apple-podcast://episode/1000700001"
        )
        let store = MCPDataStore(dbPath: dbPath)
        let recorded = try store.knowledgeStore().recordExternalListening([
            ExternalListen(
                url: "apple-podcast://episode/1000700001",
                title: "Bioelectric Fields",
                showName: "example.com",
                playedAt: fourDaysAgo.addingTimeInterval(14 * 3_600)
            ),
        ])
        #expect(recorded == ["source-played-elsewhere"])

        let result = try store.getTodaySources(
            dateString: formatter.string(from: fourDaysAgo),
            dateBasis: "activity",
            activityKind: "listening"
        )
        #expect(result.contains("Sources used for listening in ForeverLM"))
        #expect(result.contains("source_id: source-played-elsewhere"))
        // Heard, not finished: a play is never a completion.
        #expect(try store.getTodaySources(
            dateString: formatter.string(from: fourDaysAgo),
            dateBasis: "completed"
        ).contains("No sources were completed"))
    }

    @Test("Loading source content for an external chat records today's chat activity")
    func getSourceContentRecordsChatActivityWhenRequested() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-chat-activity",
            title: "Chat Activity",
            content: "Loaded into the external assistant."
        )

        _ = try await store.getSourceContent("source-chat-activity", recordChatActivity: true)

        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM source_activity_days WHERE source_id = 'source-chat-activity' AND (kinds & 8) != 0"
        ) == 1)
    }

    /// get_source_content shares the store gate as a reader. Until 2026-09-27 it
    /// recorded its chat activity in a transaction on the cached connection, so
    /// an assistant reading sources in parallel could have one read begin its
    /// transaction inside another's and fail.
    @Test("Source reads that record chat activity run together without failing inside each other")
    func parallelSourceReadsRecordTheirActivity() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let count = 8
        for index in 0..<count {
            try insertSource(
                dbPath: dbPath,
                id: "parallel-read-\(index)",
                title: "Parallel read \(index)",
                content: "Loaded beside the other reads."
            )
        }
        let registry = MCPToolRegistry(store: store)

        let failures = await withTaskGroup(of: String?.self) { group in
            for index in 0..<count {
                group.addTask {
                    let outcome = await registry.callToolDetailed(
                        name: "get_source_content",
                        arguments: ["source_id": "parallel-read-\(index)"]
                    )
                    return outcome.isError ? outcome.text : nil
                }
            }
            var failed: [String] = []
            for await failure in group {
                if let failure { failed.append(failure) }
            }
            return failed
        }

        #expect(failures.isEmpty, "\(failures)")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(DISTINCT source_id) FROM source_activity_days WHERE source_id LIKE 'parallel-read-%' AND (kinds & 8) != 0"
        ) == count)
    }

    @Test("getSchedule tags placements with their Goals and Notebooks, never a plain goal")
    func getScheduleTagsGoalsAndNotebooks() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Tagged Source", content: "Tagged.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-now",
            startAt: today,
            endAt: weekEnd,
            items: [(id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil)]
        )
        // A plain goal an older build left behind, tagged to the same placement.
        try execSQL(dbPath: dbPath, """
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status)
            VALUES ('goal-plain', 'This Week', \(today.timeIntervalSinceReferenceDate), \(weekEnd.timeIntervalSinceReferenceDate), 0, 0, 'active');
            INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
            VALUES ('item-a', 'goal-plain', 0);
        """)

        let store = MCPDataStore(dbPath: dbPath)
        let payload = try parseJSON(try store.getSchedule())
        let items = (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let tags = items.first { ($0["source_id"] as? String) == "source-a" }?["goal_tags"] as? [[String: Any]]

        #expect(payload["schedules"] == nil)
        #expect(tags?.compactMap { $0["id"] as? String } == ["goal-now"])
        #expect(throws: MCPError.self) { try store.getSchedule(goalID: "goal-plain") }
    }

    @Test("Google Docs interface placeholders are not exposed as source content")
    func googleDocsInterfacePlaceholderIsRejected() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let placeholder = """
        Google Docs
        JavaScript isn't enabled in your browser, so this file can't be opened.
        Enable and reload.
        """

        try insertSource(
            dbPath: dbPath,
            id: "google-doc",
            title: "Feedback",
            content: placeholder
        )
        try execSQL(
            dbPath: dbPath,
            """
            UPDATE articles
            SET url = 'https://docs.google.com/document/d/document-123/edit',
                normalized_url = 'https://docs.google.com/document/d/document-123/edit',
                domain = 'docs.google.com'
            WHERE source_id = 'google-doc'
            """
        )

        let result = try store.getSourceContent("google-doc")

        #expect(result.contains("Google Doc content is not loaded"))
        #expect(!result.contains("JavaScript isn't enabled"))
    }

    @Test("assignSourcesToDay moves existing items")
    func assignSourcesToDayMovesExistingItems() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-a", title: "Movable Source", content: "Move me.")
        // Seeding the goal places source-a on the Schedule; only placed sources can move.
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(
            goalID: "goal-1",
            sourceIDs: ["source-a"],
            dateString: formatter.string(from: otherDay)
        )
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let movedItem = allItems.first { ($0["source_id"] as? String) == "source-a" }

        #expect(movedItem?["planned_date"] as? String == formatter.string(from: otherDay))
    }

    /// Slotting a source in part-way through a plan. Adding a source to a Goal
    /// writes only `learning_goal_items`, so it has no placement and used to be
    /// unreachable from the calendar without a full re-plan — which is exactly the
    /// destructive operation. It now gets placed and tagged in one call.
    @Test("assignSourcesToDay places a pool source that has no placement yet")
    func assignSourcesToDayPlacesUnscheduledPoolSource() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-late", title: "Found while reading", content: "Discovered mid-plan.")
        // A goal with no items at all: the source exists in the library but is on
        // neither the pool nor the calendar.
        try insertScheduleGoal(dbPath: dbPath, goalID: "goal-1", startAt: weekStart, endAt: weekEnd, items: [])

        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(
            goalID: "goal-1",
            sourceIDs: ["source-late"],
            dateString: formatter.string(from: today)
        )

        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let placed = allItems.first { ($0["source_id"] as? String) == "source-late" }

        // Tagged to the goal, not just placed — an untagged placement would be
        // invisible to a goal-scoped Schedule read and treated as an orphan.
        #expect(placed != nil)
        #expect(placed?["planned_date"] as? String == formatter.string(from: today))
    }

    /// The report of 2026-09-19: two sources already on the Schedule for one
    /// goal, assigned to a day with another goal's id — "Assigned 2 sources",
    /// and that goal's own Schedule read still at zero items, because only a
    /// source with no placement at all joined the goal; a placed one was moved
    /// and never tagged, so a second call had to do what the first had
    /// promised.
    @Test("assignSourcesToDay tags a source already on the Schedule for another goal")
    func assignSourcesToDayTagsSourcePlacedForAnotherGoal() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-shared", title: "Read for two goals", content: "Placed once, wanted twice.")
        try insertScheduleGoal(dbPath: dbPath, goalID: "goal-first", startAt: weekStart, endAt: weekEnd, items: [])
        try insertScheduleGoal(dbPath: dbPath, goalID: "goal-second", startAt: weekStart, endAt: weekEnd, items: [])

        let store = MCPDataStore(dbPath: dbPath)
        // On the Schedule already, for the first goal.
        _ = try await store.assignSourcesToDay(goalID: "goal-first", sourceIDs: ["source-shared"], dateString: formatter.string(from: today))
        _ = try await store.assignSourcesToDay(
            goalID: "goal-second",
            sourceIDs: ["source-shared"],
            dateString: formatter.string(from: today)
        )

        func placed(in goalID: String) throws -> [String: Any]? {
            let payload = try parseJSON(try store.getSchedule(goalID: goalID, includeCompleted: true))
            let days = payload["days"] as? [[String: Any]]
            return days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
                .first { ($0["source_id"] as? String) == "source-shared" }
        }
        // The second goal owns it now — tagged and pooled, not just moved —
        // and the first keeps it: one placement, two tags.
        let second = try placed(in: "goal-second")
        #expect(second != nil)
        #expect(second?["planned_date"] as? String == formatter.string(from: today))
        #expect(try placed(in: "goal-first") != nil)
        let knowledge = try store.knowledgeStore()
        #expect(try knowledge.scheduledSourceGoalIDs(sourceID: "source-shared").sorted() == ["goal-first", "goal-second"])
        #expect(try knowledge.loadLearningGoal("goal-second")?.items.map(\.sourceID) == ["source-shared"])
    }

    /// A source that isn't on the Schedule yet is now *placed* rather than rejected
    /// (that used to be a dead end — the advice was "add them to a goal first", but
    /// adding to a goal never created a placement). A source that doesn't exist at
    /// all is still refused, now by `validateSourcesExist`, which also stops a typo
    /// creating a placement pointing at nothing: `scheduled_sources.source_id` has
    /// no foreign key by design.
    @Test("assignSourcesToDay rejects sources that do not exist")
    func assignSourcesToDayRejectsUnknownSource() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4))!
        let end = calendar.date(byAdding: .day, value: 7, to: monday)!

        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: monday,
            endAt: end,
            items: []
        )

        let store = MCPDataStore(dbPath: dbPath)
        do {
            _ = try await store.assignSourcesToDay(
                goalID: "goal-1",
                sourceIDs: ["missing-source"],
                dateString: "2026-05-06"
            )
            Issue.record("Assigning a source that does not exist should fail")
        } catch {
            #expect(error.localizedDescription.contains("Source IDs not found"))
        }
    }

    @Test("assignSourcesToDay places a source untagged when no goal is named")
    func assignSourcesToDayPlacesUntaggedWithoutGoal() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-loose", title: "No Goal Yet", content: "Loose.")

        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(sourceIDs: ["source-loose"], dateString: formatter.string(from: today))

        let payload = try parseJSON(try store.getSchedule())
        let items = (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let placed = items.first { ($0["source_id"] as? String) == "source-loose" }
        #expect(placed?["planned_date"] as? String == formatter.string(from: today))
        #expect((placed?["goal_tags"] as? [[String: Any]])?.isEmpty == true)
        // Nothing stands in for the missing goal.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM learning_goals") == 0)
    }

    @Test("unscheduleSources with a goal removes that goal's items")
    func unscheduleSourcesFromGoal() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Keep Source", content: "Keep.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Remove Source", content: "Remove.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: otherDay, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.unscheduleSources(goalID: "goal-1", sourceIDs: ["source-b"])
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []

        #expect(allItems.count == 1)
        #expect(allItems.first?["source_id"] as? String == "source-a")
    }

    @Test("clearScheduleDay with a goal removes its pending sources on that day")
    func clearScheduleDayForGoal() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-a", title: "Clear Source", content: "Clear.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Other Source", content: "Other.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: today, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let before = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let beforeItems = (before["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        #expect(beforeItems.count == 2)

        _ = try store.clearScheduleDay(goalID: "goal-1", dateString: formatter.string(from: today))
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []

        #expect(allItems.isEmpty)
    }

    @Test("setSourceCompletion marks done and reopens")
    func setSourceCompletionMarksDoneAndReopens() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Reviewed Source", content: "Reviewed.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Schedule Reviewed Source", content: "Schedule reviewed.")
        // Seeding the goal places both sources on the Schedule; completion can only
        // be toggled for sources that already have a placement.
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: today, completedAt: nil),
            ]
        )
        try insertCompletedReviewSession(dbPath: dbPath, sessionID: "session-a", sourceID: "source-a", endedAt: today.addingTimeInterval(600))

        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.setSourceCompletion(goalID: "goal-1", sourceID: "source-a", isCompleted: true)
        var payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        var days = payload["days"] as? [[String: Any]]
        var allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        var reviewedItem = allItems.first { ($0["source_id"] as? String) == "source-a" }
        #expect(reviewedItem?["is_completed"] as? Bool == true)

        _ = try store.setSourceCompletion(goalID: "goal-1", sourceID: "source-b", isCompleted: true)
        payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        days = payload["days"] as? [[String: Any]]
        allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let scheduleReviewedItem = allItems.first { ($0["source_id"] as? String) == "source-b" }
        #expect(scheduleReviewedItem?["is_completed"] as? Bool == true)
        #expect(scheduleReviewedItem?["latest_review_at"] as? String != nil)
        #expect(scheduleReviewedItem?["has_linked_review_session"] as? Bool == false)

        _ = try store.setSourceCompletion(goalID: "goal-1", sourceID: "source-a", isCompleted: false)
        payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        days = payload["days"] as? [[String: Any]]
        allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        reviewedItem = allItems.first { ($0["source_id"] as? String) == "source-a" }
        #expect(reviewedItem?["is_completed"] as? Bool == false)
    }

    @Test("unscheduleSources with no goal takes the placement off the Schedule, whatever serves it")
    func unscheduleSourcesWithoutGoal() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Keep Source", content: "Keep.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Remove Source", content: "Remove.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: today,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: today, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.unscheduleSources(sourceIDs: ["source-b"])

        let payload = try parseJSON(try store.getSchedule())
        let items = (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        #expect(items.map { $0["source_id"] as? String } == ["source-a"])
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'source-b'") == 0)
        // The goal and its pool are untouched: only the plan went.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM learning_goal_items WHERE source_id = 'source-b'") == 1)
        #expect(throws: MCPError.self) {
            _ = try store.unscheduleSources(sourceIDs: ["source-b"])
        }
    }

    @Test("clearScheduleDay and markScheduleDayDone with no goal cover every source on the day")
    func dayToolsWithoutGoalCoverTheWholeDay() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-goal", title: "Goal Source", content: "Tagged.")
        try insertSource(dbPath: dbPath, id: "source-loose", title: "Loose Source", content: "Untagged.")
        try insertSource(dbPath: dbPath, id: "source-later", title: "Later Source", content: "Another day.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-goal", sourceID: "source-goal", addedAt: today, completedAt: nil),
                (id: "item-later", sourceID: "source-later", addedAt: otherDay, completedAt: nil),
            ]
        )
        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(sourceIDs: ["source-loose"], dateString: formatter.string(from: today))

        func items() throws -> [[String: Any]] {
            let payload = try parseJSON(try store.getSchedule())
            return (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        }

        _ = try store.markScheduleDayDone(dateString: formatter.string(from: today))
        let done = try items().filter { ($0["is_completed"] as? Bool) == true }.compactMap { $0["source_id"] as? String }
        #expect(Set(done) == ["source-goal", "source-loose"])

        _ = try store.clearScheduleDay(dateString: formatter.string(from: today), includeCompleted: true)
        #expect(try items().compactMap { $0["source_id"] as? String } == ["source-later"])
    }
}

#endif
