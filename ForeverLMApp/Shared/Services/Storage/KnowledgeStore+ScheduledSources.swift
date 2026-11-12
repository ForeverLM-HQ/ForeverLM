// KnowledgeStore: listening heard elsewhere, and putting, moving, finishing and forgetting scheduled sources.
import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Listening heard in Apple Podcasts

    /// Records plays Apple Podcasts saw as the learner's listening, the way the
    /// in-app player records its own: the source's activity day on the local
    /// day of the play, with the automatic Schedule entry every activity day
    /// hangs from, and a minute on that day's log at the moment of the play.
    /// "What did I listen to last week" is then one question with one answer,
    /// whichever app played the episode.
    ///
    /// Only an episode the library holds, active and not hidden (the source,
    /// the episode or its show), is recorded; a listen names no source until
    /// discovery has imported it. Any play counts, however short: Apple keeps
    /// the moment of the last play and not how much of the episode it covered,
    /// and an episode sampled on Tuesday was still heard on Tuesday. Nothing
    /// is claimed beyond that moment: no engaged seconds, no depth, no
    /// completion.
    ///
    /// Idempotent: a play already on the source's day (from an earlier sync
    /// pass, or listening in ForeverLM later that day) is skipped, so a pass
    /// that finds nothing new reads and never takes the write lock. Returns the
    /// ids of the sources whose play was recorded now.
    @discardableResult
    func recordExternalListening(_ listens: [ExternalListen], now: Date = Date()) throws -> [String] {
        var pending: [(sourceID: String, listen: ExternalListen)] = []
        for listen in listens {
            guard let sourceID = try visiblePodcastSourceID(for: listen),
                  try !externalListenIsRecorded(sourceID: sourceID, playedAt: listen.playedAt) else { continue }
            pending.append((sourceID, listen))
        }
        guard !pending.isEmpty else { return [] }

        var recorded: [String] = []
        try exec("BEGIN IMMEDIATE")
        do {
            for (sourceID, listen) in pending {
                // Read again under the lock: the same episode twice in a batch,
                // or a heartbeat that landed in between, is already there.
                guard try !externalListenIsRecorded(sourceID: sourceID, playedAt: listen.playedAt) else { continue }
                try recordScheduledSourceActivityRows(
                    sourceID: sourceID,
                    on: listen.playedAt,
                    kind: .listening,
                    recordedAt: now
                )
                try recordDayActivitySpanRows(
                    kind: .listening,
                    targetID: sourceID,
                    title: listen.title,
                    from: listen.playedAt,
                    to: listen.playedAt.addingTimeInterval(60),
                    now: now
                )
                recorded.append(sourceID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return recorded
    }

    /// Whether the source's day already holds listening at or after `playedAt`.
    private func externalListenIsRecorded(sourceID: String, playedAt: Date) throws -> Bool {
        let dayStart = Calendar.current.startOfDay(for: playedAt)
        var found = false
        try queryBind("""
            SELECT 1 FROM source_activity_days
            WHERE source_id = ? AND day_start = ?
              AND (kinds & ?) != 0
              AND last_activity_at >= ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 3, sourceActivityMask([.listening]))
            // A second of slack: the stored stamp is the play's own, read back.
            sqlite3_bind_double(stmt, 4, playedAt.timeIntervalSinceReferenceDate - 1)
        }) { _ in found = true }
        return found
    }

    /// The learner's own library source a listen names, found by the keys the
    /// import that made it dedups on (`insertSourceIfNew`): work keys, the
    /// normalized URL (with the older spelling of a track-id URL), then show
    /// and title for an episode with no public track id. Every lookup is on an
    /// index, never the source projection, since a sync pass asks once per
    /// play in the window. Nil unless that source is active and shown: not
    /// hidden itself, not a hidden episode, and not in a hidden show unless
    /// the episode was let back in.
    private func visiblePodcastSourceID(for listen: ExternalListen) throws -> String? {
        var probe = StudioArticle(url: listen.url, title: listen.title, sourceType: .podcast)
        probe.domain = listen.showName
        var match = try sourceID(forWorkKeys: workKeys(for: probe, hashingFile: false), teamID: nil)
        if match == nil {
            var normalizedURLs = [URLNormalizer.normalize(listen.url)]
            if let trackID = Self.extractTrackIdFromURL(listen.url) {
                // How rows imported before the canonical form normalized.
                normalizedURLs.append("episode/\(trackID)")
            }
            let marks = Array(repeating: "?", count: normalizedURLs.count).joined(separator: ", ")
            try queryBind("""
                SELECT s.id FROM podcasts p JOIN sources s ON s.id = p.source_id
                WHERE p.normalized_url IN (\(marks)) AND s.team_id IS NULL
                ORDER BY s.status = 'active' DESC, s.id
                LIMIT 1
            """, bind: { stmt in
                for (index, url) in normalizedURLs.enumerated() { bind(stmt, index + 1, url) }
            }) { stmt in match = string(stmt, 0) }
        }
        if match == nil, Self.extractTrackIdFromURL(listen.url) == nil {
            match = sourceExistsByPodcastShowAndTitle(probe)?.id
        }
        guard let sourceID = match else { return nil }
        var visible = false
        try queryBind("""
            SELECT 1
            FROM sources s
            LEFT JOIN podcasts p ON p.source_id = s.id
            WHERE s.id = ?
              AND s.status = 'active'
              AND NOT EXISTS (SELECT 1 FROM hidden_sources h WHERE h.source_id IN (s.id, s.wire_key))
              AND NOT EXISTS (SELECT 1 FROM pending_hidden_sources h WHERE h.source_id IN (s.id, s.wire_key))
              AND NOT EXISTS (SELECT 1 FROM hidden_podcast_episodes h WHERE h.source_id IN (s.id, s.wire_key))
              AND (
                    EXISTS (SELECT 1 FROM visible_podcast_episode_overrides v WHERE v.source_id IN (s.id, s.wire_key))
                 OR NOT EXISTS (
                        SELECT 1 FROM hidden_podcast_shows h
                        WHERE h.show_name = p.domain OR h.show_name = p.show_name
                    )
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { _ in visible = true }
        return visible ? sourceID : nil
    }

    /// Tag a source's shared placement with a goal, creating the placement if needed.
    /// When `plannedAt` is given, the placement is (re)scheduled to that day.
    func addSourceToGoal(sourceID: String, goalID: String, plannedAt: Date? = nil) throws {
        let now = Date()
        var placementID = ""
        try exec("BEGIN IMMEDIATE")
        do {
            placementID = try ensureScheduledSourcePlacement(sourceID: sourceID, plannedAt: plannedAt ?? now, now: now)
            try setScheduledSourceAutomatic(placementID: placementID, isAutomatic: false)
            if let plannedAt {
                let plannedDay = Calendar.current.startOfDay(for: plannedAt)
                let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
                let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
                try execBind("UPDATE scheduled_sources SET planned_at = ?, updated_at = ? WHERE id = ?") { stmt in
                    sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, placementID)
                }
            }
            try execBind("INSERT OR IGNORE INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at) VALUES (?, ?, ?)") { stmt in
                bind(stmt, 1, placementID)
                bind(stmt, 2, goalID)
                sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
            }
            try touchLearningGoal(goalID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Untag a source from a goal. If that leaves the placement with no goals,
    /// remove it only when it has no activity history; otherwise retain it as an
    /// automatic Schedule entry on its latest activity day.
    func removeSourceFromGoal(sourceID: String, goalID: String) throws {
        let now = Date()
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ? AND goal_id = ?") { stmt in
                bind(stmt, 1, placementID)
                bind(stmt, 2, goalID)
            }
            if try scheduledSourceGoalCount(placementID: placementID) == 0,
               try sourceActivityDayCount(sourceID: sourceID) == 0 {
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, placementID)
                }
            } else if try scheduledSourceGoalCount(placementID: placementID) == 0 {
                try convertPlacementToAutomaticHistory(
                    placementID: placementID,
                    sourceID: sourceID,
                    at: now
                )
            }
            try touchLearningGoal(goalID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Remove a source's explicit plan and every goal tag. Activity history is
    /// retained, so an interacted-with source falls back to its automatic entry
    /// on the latest activity day instead of disappearing from the Schedule.
    func removeScheduledSource(sourceID: String) throws {
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?") { stmt in
                bind(stmt, 1, placementID)
            }
            if try sourceActivityDayCount(sourceID: sourceID) == 0 {
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, placementID)
                }
            } else {
                try convertPlacementToAutomaticHistory(
                    placementID: placementID,
                    sourceID: sourceID,
                    at: Date()
                )
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Take sources off the Schedule. Scoped to a Goal or Notebook only that tag
    /// comes off (`removeSourceFromGoal`); on the whole Schedule the placement
    /// and all its tags go (`removeScheduledSource`). Activity history survives
    /// either way. `StorageService.removeSourcesFromSchedule` and the MCP
    /// Schedule tools both remove through here.
    func removeSourcesFromSchedule(goalID: String?, sourceIDs: [String]) throws {
        for sourceID in sourceIDs {
            if let goalID {
                try removeSourceFromGoal(sourceID: sourceID, goalID: goalID)
            } else {
                try removeScheduledSource(sourceID: sourceID)
            }
        }
    }

    /// What `forgetAutomaticSourceActivity` took back for one source.
    struct ForgottenSourceActivity: Equatable, Sendable {
        let sourceID: String
        let placementID: String
        /// The activity days that went, with what each had recorded.
        let days: [SourceActivityDay]
        /// Whether the entry had been checked off, by a review or a finish.
        let wasCompleted: Bool
        /// The read stamp that went with it, when that day set one.
        let clearedReadAt: Date?
        /// Assignments the entry's completion had closed, reopened.
        let reopenedTaskIDs: [String]
    }

    /// Takes back activity the app recorded on a source that did not happen:
    /// a review marked by a chat that reviewed nothing (a chat saved with
    /// `mark_reviewed` false that marked reviewed the sources a later call
    /// linked). It undoes what recording the activity wrote —
    /// the source's automatic Schedule entry (the placement no one planned,
    /// `is_automatic` 1) with every activity day under it, the read stamp when
    /// it falls on `day`, and the assignments the entry's completion closed
    /// (`reopenAssignedTasks`). The placement's deletion is what reaches the
    /// other Macs: applying it deletes the activity days under it there, which
    /// a saved record never could, because inbound activity days are unioned
    /// with the local ones. The read stamp travels as the source's own change.
    ///
    /// All or nothing: when any source has no entry, has a plan instead (a
    /// day someone chose, or a Goal's tag — `unschedule_sources` and
    /// `set_source_completion` are for those), or holds activity on a day
    /// other than `day`, nothing is written for any of them. Activity on
    /// another day is history this call was not asked to forget, and deleting
    /// the entry would take it too.
    @discardableResult
    func forgetAutomaticSourceActivity(
        sourceIDs rawSourceIDs: [String],
        on day: Date,
        now: Date = Date()
    ) throws -> [ForgottenSourceActivity] {
        let sourceIDs = rawSourceIDs.reduce(into: [String]()) { result, raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        guard !sourceIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("At least one source is required to forget its activity.")
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(MemoryTutorScheduler.secondsPerDay)
        let dayLabel = DayPlan.dateString(for: dayStart)

        try exec("BEGIN IMMEDIATE")
        do {
            var entries: [(sourceID: String, placementID: String, days: [SourceActivityDay], completedAt: Date?, readAt: Date?)] = []
            var refusals: [String] = []
            for sourceID in sourceIDs {
                guard let placementID = try scheduledSourceID(forSource: sourceID) else {
                    refusals.append("\(sourceID) has no recorded activity")
                    continue
                }
                guard try scheduledSourceIsAutomatic(placementID: placementID),
                      try scheduledSourceGoalCount(placementID: placementID) == 0 else {
                    refusals.append("\(sourceID) is on the Schedule as a plan, not an automatic entry: take it off with unschedule_sources, or reopen it with set_source_completion")
                    continue
                }
                let days = try loadSourceActivityDays(sourceID: sourceID)
                let elsewhere = days.filter { !calendar.isDate($0.dayStart, inSameDayAs: dayStart) }
                guard elsewhere.isEmpty else {
                    let otherDays = elsewhere.map { DayPlan.dateString(for: $0.dayStart) }.joined(separator: ", ")
                    refusals.append("\(sourceID) also has activity on \(otherDays), which forgetting \(dayLabel) would take with it")
                    continue
                }
                let completedAt = try loadScheduledSourceRow(id: placementID)?.completedAt
                let readAt = try loadSourceProgress(sourceID: sourceID)?.readAt
                entries.append((sourceID: sourceID, placementID: placementID, days: days, completedAt: completedAt, readAt: readAt))
            }
            guard refusals.isEmpty else {
                throw KnowledgeStoreError.invalidData("Nothing was forgotten: \(refusals.joined(separator: "; ")).")
            }

            var forgotten: [ForgottenSourceActivity] = []
            for entry in entries {
                try execBind("DELETE FROM source_activity_days WHERE source_id = ? OR scheduled_source_id = ?") { stmt in
                    bind(stmt, 1, entry.sourceID)
                    bind(stmt, 2, entry.placementID)
                }
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, entry.placementID)
                }

                var clearedReadAt: Date?
                if let readAt = entry.readAt, readAt >= dayStart, readAt < dayEnd {
                    try updateReadingState(sourceID: entry.sourceID) { $0.readAt = nil }
                    clearedReadAt = readAt
                }
                var reopened: [String] = []
                if let completedAt = entry.completedAt {
                    reopened = try reopenAssignedTasks(forSourceID: entry.sourceID, completedAt: completedAt, at: now)
                }
                forgotten.append(ForgottenSourceActivity(
                    sourceID: entry.sourceID,
                    placementID: entry.placementID,
                    days: entry.days,
                    wasCompleted: entry.completedAt != nil,
                    clearedReadAt: clearedReadAt,
                    reopenedTaskIDs: reopened
                ))
            }
            try exec("COMMIT")
            return forgotten
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Move a source's shared placement to a different day and optionally place
    /// it immediately before another source on that day. Creates the placement
    /// if missing. Every changed order timestamp is sync-published in the same
    /// transaction so another device reconstructs the exact row order.
    func setScheduledSourcePlannedDate(
        sourceID: String,
        plannedAt: Date,
        beforeSourceID: String? = nil
    ) throws {
        let now = Date()
        let plannedDay = Calendar.current.startOfDay(for: plannedAt)
        let dayEnd = plannedDay.addingTimeInterval(MemoryTutorScheduler.secondsPerDay)
        var placementID = ""
        try exec("BEGIN IMMEDIATE")
        do {
            placementID = try ensureScheduledSourcePlacement(sourceID: sourceID, plannedAt: plannedAt, now: now)

            var ordered: [(placementID: String, sourceID: String)] = []
            try queryBind("""
                SELECT id, source_id
                FROM scheduled_sources
                WHERE source_id != ? AND planned_at >= ? AND planned_at < ?
                ORDER BY planned_at ASC, added_at ASC, id ASC
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
                sqlite3_bind_double(stmt, 2, plannedDay.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 3, dayEnd.timeIntervalSinceReferenceDate)
            }) { stmt in
                guard let id = self.string(stmt, 0), let idSource = self.string(stmt, 1) else { return }
                ordered.append((id, idSource))
            }

            let destination = beforeSourceID.flatMap { target in
                ordered.firstIndex(where: { $0.sourceID == target })
            } ?? ordered.endIndex
            ordered.insert((placementID, sourceID), at: destination)

            for (order, row) in ordered.enumerated() {
                let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
                try execBind("""
                    UPDATE scheduled_sources
                    SET planned_at = ?, updated_at = ?,
                        is_automatic = CASE WHEN id = ? THEN 0 ELSE is_automatic END
                    WHERE id = ?
                """) { stmt in
                    sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, placementID)
                    bind(stmt, 4, row.placementID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Shared completion: reviewing once flips the placement done for every goal it's tagged with.
    /// Completing also marks the source itself read; reopening never clears an existing read date.
    func markScheduledSourceDone(sourceID: String) throws {
        let now = Date()
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try execBind("UPDATE scheduled_sources SET completed_at = COALESCE(completed_at, ?), updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, placementID)
        }

        try fillReadingStateReadAt(sourceID: sourceID, at: now)

        try mirrorPlacementCompletion(placementID: placementID, sourceID: sourceID, completedAt: now, now: now)
        try completeAssignedTasks(forSourceID: sourceID, at: now)
    }

    func reopenScheduledSource(sourceID: String) throws {
        let now = Date()
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try execBind("UPDATE scheduled_sources SET completed_at = NULL, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
            bind(stmt, 2, placementID)
        }

        // Deliberately NOT mirrored back onto learning_goal_items. Reopening a
        // Schedule row means "put this back on my calendar", not "erase the record
        // that I ever studied it" — and an item's completion can also have come
        // from another device or an older build, which has nothing to do with
        // this placement. Clearing it here would destroy that. It would also never
        // converge: the CloudKit inbound merge resolves item `completedAt` with
        // `max(left, right)` and only fills nil from non-nil, so a date→NULL
        // transition is never propagated and the other device would re-complete it.
    }

    /// Mirror a placement's completion onto `learning_goal_items.completed_at` for
    /// every goal the placement is tagged with.
    ///
    /// The two tables record the same fact for different consumers: the Schedule
    /// reads `scheduled_sources`, while `LearningGoalRecord.completedCount` — and
    /// so Notebook goal cards, MCP `completed_sources`, and DailyReviewPlan's
    /// `!isCompleted` filter — reads `learning_goal_items`. Only the placement was
    /// ever written by the review path, so item completion stayed NULL forever and
    /// every companion goal reported 0% done. Keeping them in step here means
    /// `learning_goal_items` is a durable record of the work even if the placement
    /// is later removed from the calendar.
    private func mirrorPlacementCompletion(
        placementID: String,
        sourceID: String,
        completedAt: Date,
        now: Date
    ) throws {
        var goalIDs: [String] = []
        try queryBind("SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ?", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            if let goalID = self.string(stmt, 0) { goalIDs.append(goalID) }
        }
        guard !goalIDs.isEmpty else { return }
        // Generation 2: an item's completion travels as its source's (`ReadingState.completedAt`, §10).
        try fillReadingStateCompletedAt(sourceID: sourceID, at: completedAt)

        for goalID in goalIDs {
            // COALESCE so re-marking an already-complete item keeps the original
            // completion date rather than sliding it forward.
            try execBind("""
                UPDATE learning_goal_items
                SET completed_at = COALESCE(completed_at, ?)
                WHERE goal_id = ? AND source_id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, completedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 2, goalID)
                bind(stmt, 3, sourceID)
            }
            guard sqlite3_changes(db) > 0 else { continue }
            try touchLearningGoal(goalID, at: now)
        }
    }

    func setScheduledSourceCompletion(sourceID: String, isCompleted: Bool) throws {
        if isCompleted {
            try markScheduledSourceDone(sourceID: sourceID)
        } else {
            try reopenScheduledSource(sourceID: sourceID)
        }
    }

    /// Record a completed review on the Schedule. A source that has no placement yet
    /// is placed on `day` first, so a source attached to a chat and reviewed there
    /// lands on that day already checked off instead of leaving no trace. A source
    /// that is already scheduled keeps the day the learner planned it for — reviewing
    /// checks it off in place rather than pulling it forward to today.
    func recordScheduledSourceReview(sourceID: String, on day: Date) throws {
        try recordScheduledSourceCompletion(sourceID: sourceID, on: day, kind: .review)
    }

    func recordScheduledSourceCompletion(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        try recordScheduledSourceCompletions(sourceIDs: [sourceID], on: day, kind: kind)
    }

    /// Records a learner's externally completed reading, listening, or watching
    /// as one atomic library operation. A chapter range must never be half logged
    /// because a later source is invalid or a write fails.
    func recordScheduledSourceCompletions(
        sourceIDs rawSourceIDs: [String],
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        let sourceIDs = rawSourceIDs.reduce(into: [String]()) { result, raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        guard !sourceIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("At least one source is required to record completed activity.")
        }
        let now = Date()
        let sourceReadAt: Date?
        switch kind {
        case .reading, .listening, .watching:
            sourceReadAt = day
        case .chat, .review:
            sourceReadAt = nil
        }
        try exec("BEGIN IMMEDIATE")
        do {
            for sourceID in sourceIDs {
                try recordScheduledSourceReviewRows(
                    sourceID: sourceID,
                    on: day,
                    kind: kind,
                    sourceReadAt: sourceReadAt,
                    recordedAt: now
                )
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Transaction-free row helper used when review completion, transcript,
    /// memory evidence, Schedule state, and Notebook state must commit together.
    func recordScheduledSourceReviewRows(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind = .review,
        sourceReadAt: Date? = nil,
        recordedAt: Date
    ) throws {
        let existingPlacementID = try scheduledSourceID(forSource: sourceID)
        let placementID = try ensureScheduledSourcePlacement(
            sourceID: sourceID,
            plannedAt: day,
            now: recordedAt
        )
        if existingPlacementID == nil {
            try setScheduledSourceAutomatic(placementID: placementID, isAutomatic: true)
        }
        _ = try recordSourceActivityDayRows(
            placementID: placementID,
            sourceID: sourceID,
            kind: kind,
            occurredAt: day,
            completed: true,
            fraction: 1
        )
        if try scheduledSourceIsAutomatic(placementID: placementID) {
            let plannedDay = Calendar.current.startOfDay(for: day)
            let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
            let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
            try execBind("UPDATE scheduled_sources SET planned_at = ?, updated_at = ? WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 3, placementID)
            }
        }
        try execBind("""
            UPDATE scheduled_sources
            SET completed_at = COALESCE(completed_at, ?), updated_at = ?
            WHERE id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, recordedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 3, placementID)
        }

        try fillReadingStateReadAt(sourceID: sourceID, at: sourceReadAt ?? recordedAt)

        try mirrorPlacementCompletion(
            placementID: placementID,
            sourceID: sourceID,
            completedAt: recordedAt,
            now: recordedAt
        )
        // A review (or a finished reading, listening or watching) completes
        // the source's assignments in the same transaction
        // (docs/family-design.md).
        try completeAssignedTasks(forSourceID: sourceID, at: recordedAt)
    }

    func readScheduledSourceRow(_ stmt: OpaquePointer?) -> ScheduledSource? {
        guard let id = string(stmt, 0), let sourceID = string(stmt, 1) else { return nil }
        return ScheduledSource(
            id: id,
            sourceID: sourceID,
            plannedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
            addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            completedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
        )
    }

    /// Visible Goal tags for placements, keyed by placement id. Top-level Notebooks
    /// stay out of chips; every timebound Goal, standing alone or in a Notebook,
    /// is shown, as are plain goals.
    func loadGoalTagsByPlacement() throws -> [String: [GoalTag]] {
        var result: [String: [GoalTag]] = [:]
        try queryBind("""
            SELECT ssg.scheduled_source_id, g.id, g.title
            FROM scheduled_source_goals ssg
            JOIN learning_goals g ON g.id = ssg.goal_id
            WHERE (g.kind IS NULL OR g.kind != 'companion'
                   OR TRIM(COALESCE(g.parent_notebook_id, '')) != ''
                   OR g.end_at < ?)
            ORDER BY g.created_at ASC
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, LearningGoalRecord.openEndedThreshold.timeIntervalSinceReferenceDate)
        }) { stmt in
            guard let placementID = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1),
                  let title = self.string(stmt, 2) else { return }
            result[placementID, default: []].append(GoalTag(id: goalID, title: title))
        }
        return result
    }

    /// Full goal membership per placement, keyed by placement id. Includes companion
    /// Notebooks (unlike `loadGoalTagsByPlacement`), so a Notebook's own schedule can be
    /// scoped to the placements tagged with it.
    func loadGoalMembershipByPlacement() throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        try query("SELECT scheduled_source_id, goal_id FROM scheduled_source_goals") { stmt in
            guard let placementID = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1) else { return }
            result[placementID, default: []].insert(goalID)
        }
        return result
    }

    /// Load the whole Schedule, or the placements tagged with one Goal or Notebook.
    func loadScheduledSources(goalID: String? = nil) throws -> [ScheduledSourceEntry] {
        var placements: [ScheduledSource] = []
        if let goalID {
            try queryBind("""
                SELECT ss.id, ss.source_id, ss.planned_at, ss.added_at, ss.completed_at, ss.created_at, ss.updated_at
                FROM scheduled_sources ss
                JOIN scheduled_source_goals ssg ON ssg.scheduled_source_id = ss.id
                WHERE ssg.goal_id = ?
                ORDER BY ss.planned_at ASC
            """, bind: { stmt in
                bind(stmt, 1, goalID)
            }) { stmt in
                if let row = self.readScheduledSourceRow(stmt) { placements.append(row) }
            }
        } else {
            try query("""
                SELECT id, source_id, planned_at, added_at, completed_at, created_at, updated_at
                FROM scheduled_sources
                ORDER BY planned_at ASC
            """) { stmt in
                if let row = self.readScheduledSourceRow(stmt) { placements.append(row) }
            }
        }
        let tagsByPlacement = try loadGoalTagsByPlacement()
        let membershipByPlacement = try loadGoalMembershipByPlacement()
        let activityBySource = Dictionary(
            grouping: try loadSourceActivityDays(),
            by: \.sourceID
        )
        var automaticPlacementIDs: Set<String> = []
        try query("SELECT id FROM scheduled_sources WHERE is_automatic = 1") { stmt in
            if let id = self.string(stmt, 0) { automaticPlacementIDs.insert(id) }
        }
        return placements.map {
            ScheduledSourceEntry(
                placement: $0,
                goalTags: tagsByPlacement[$0.id] ?? [],
                goalIDs: membershipByPlacement[$0.id] ?? [],
                isAutomatic: automaticPlacementIDs.contains($0.id),
                activityDays: activityBySource[$0.sourceID] ?? []
            )
        }
    }

}
