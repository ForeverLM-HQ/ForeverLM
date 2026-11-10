// KnowledgeStore: deleting and archiving sources, and moving what duplicates held.
import Foundation
import SQLite3

extension KnowledgeStore {

    func deleteSource(_ sourceId: String) throws {
        // Deletes the source plus its goal items and embeddings and records the
        // tombstones in one atomic transaction.
        // An audio overview's carrier names its Artifact in its URL.
        let overviewID = try loadSourceWithoutContent(sourceId).flatMap(GeneratedAudioOverview.artifactID(ofCarrier:))
        try exec("BEGIN IMMEDIATE")
        do {
            try deleteSourceRows(sourceId)
            // An explainer is written about one source and has no life of its
            // own: it goes with the source it explains, in the same transaction
            // (explainer-design.md). Its id is fixed by the URL grammar, so one
            // lookup says whether there is one.
            let explainerID = GeneratedExplainer.sourceID(explaining: sourceId)
            if explainerID != sourceId, try loadSourceWithoutContent(explainerID) != nil {
                try deleteSourceRows(explainerID)
            }
            // An audio overview is its Artifact and its carrier together: the
            // carrier going takes the Artifact, as the Artifact going takes the
            // carrier (`deleteArtifactRecord`). An inbound delete runs
            // sync-suppressed, and a client that deleted only the carrier
            // never tombstoned the Artifact, so that tombstone is published here.
            if let overviewID, try loadArtifact(overviewID) != nil {
                try deleteArtifactRecord(overviewID)
            }
            try exec("COMMIT")
            // Source-scoped credentials should not outlive their source. This
            // also covers MCP and inbound CloudKit deletions, both of which
            // delete through KnowledgeStore rather than StorageService.
            KeychainService.deleteZoomRecordingPasscode(forSourceID: sourceId)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The row-level half of `deleteSource`, without a transaction of its own,
    /// so a caller deleting several sources at once — a whole meeting series —
    /// gets one atomic delete instead of one per source.
    ///
    /// The source's highlights, hidden marks, visible overrides and
    /// Understanding row stay, the learner's own state outliving the source
    /// (D18).
    func deleteSourceRows(_ sourceId: String) throws {
        var affectedGoalIds: [String] = []
        try queryBind("SELECT DISTINCT goal_id FROM learning_goal_items WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceId)
        }) { stmt in
            if let id = string(stmt, 0) {
                affectedGoalIds.append(id)
            }
        }
        // The source's notebook items stay: their Entries stay live on the server and hide on read
        // while the source is missing, and a re-import of the same id shows them again
        // (schema v2 §3.5.8, §5.4). The item table has no foreign key to `sources`.
        // Its vectors, full-text row and stamps: a deleted source left in search is found by
        // keyword search and, at the next launch, by meaning.
        try dropSourceSearchRows(sourceID: sourceId)
        try execBind("DELETE FROM sources WHERE id = ?") { stmt in
            bind(stmt, 1, sourceId)
        }
    }

    /// Archive one paper identity duplicate after moving every user-authored
    /// relationship that names it to the canonical source. Derived paper rows stay
    /// attached to the archived record until ordinary cleanup removes them; this
    /// keeps the merge bounded and reversible while Notebooks, chats, Schedule, and
    /// highlights immediately converge on the surviving identity.
    func archivePaperIdentityDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try archiveSourceIdentityDuplicate(duplicateID, replacingWith: canonicalID)
    }

    /// Archive one meeting session that a retired session-key rule filed a
    /// second time, handing its schedule placements, Notebook membership, chats
    /// and highlights to the session that survives.
    ///
    /// Its artifacts are discarded rather than moved: both rows were read from
    /// the same Drive files, the surviving session already carries a row per
    /// file, and an artifact id is derived from the session that owns it — so
    /// moving them would leave every file listed twice under one meeting.
    func archiveMeetingSessionDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try archiveSourceIdentityDuplicate(
            duplicateID,
            replacingWith: canonicalID,
            discardingMeetingArtifacts: true
        )
    }

    private func archiveSourceIdentityDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String,
        discardingMeetingArtifacts: Bool = false
    ) throws {
        guard duplicateID != canonicalID,
              try sourceExists(duplicateID),
              try sourceExists(canonicalID) else { return }

        try exec("BEGIN IMMEDIATE")
        do {
            try archiveSourceIdentityDuplicateRows(
                duplicateID,
                replacingWith: canonicalID,
                discardingMeetingArtifacts: discardingMeetingArtifacts,
                at: Date()
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The row-level half of `archiveSourceIdentityDuplicate`, inside the
    /// caller's transaction: every relationship authored against the duplicate
    /// — Notebook items, review sessions, schedule placements, highlights,
    /// memory items, group membership, and its meeting artifacts unless they
    /// are discarded — moves to the canonical source, and the duplicate is
    /// archived. Not private, so a caller folding several rows into one at
    /// once (`mergeMeetingSessions`) gets one atomic write rather than one
    /// transaction per row.
    func archiveSourceIdentityDuplicateRows(
        _ duplicateID: String,
        replacingWith canonicalID: String,
        discardingMeetingArtifacts: Bool,
        at now: Date
    ) throws {
        do {
            if discardingMeetingArtifacts {
                try execBind("DELETE FROM meeting_artifacts WHERE source_id = ?") { stmt in
                    bind(stmt, 1, duplicateID)
                }
            }
            try reassignLearningGoalItems(from: duplicateID, to: canonicalID)
            try reassignReviewSessionSources(from: duplicateID, to: canonicalID)
            try reassignScheduledSource(from: duplicateID, to: canonicalID)
            try reassignSimpleSourceRelationships(from: duplicateID, to: canonicalID)

            try execBind("UPDATE sources SET status = ?, archived_at = ? WHERE id = ?") { stmt in
                bind(stmt, 1, SourceStatus.archived.rawValue)
                bind(stmt, 2, Self.iso8601Formatter.string(from: now))
                bind(stmt, 3, duplicateID)
            }
            // The canonical source is searched in its place; the duplicate's rows would answer for it.
            try dropSourceSearchRows(sourceID: duplicateID)

            noteStoreChanged()
        }
    }

    /// Merge Notebook membership and learning evidence for a duplicate source.
    /// An approved item wins over a pending/rejected copy, while monotonic study
    /// evidence is combined so deduplication cannot erase completion or quiz work.
    private func reassignLearningGoalItems(
        from duplicateID: String,
        to canonicalID: String
    ) throws {
        // Move non-overlapping Notebook membership without changing its stable item id.
        try execBind("""
            UPDATE learning_goal_items
            SET source_id = ?
            WHERE source_id = ?
              AND NOT EXISTS (
                  SELECT 1 FROM learning_goal_items canonical
                  WHERE canonical.goal_id = learning_goal_items.goal_id
                    AND canonical.source_id = ?
              )
        """) { stmt in
            bind(stmt, 1, canonicalID)
            bind(stmt, 2, duplicateID)
            bind(stmt, 3, canonicalID)
        }

        // Overlapping membership is one logical Notebook item. Fold the duplicate's
        // evidence into the canonical row before deleting the redundant item.
        try execBind("""
            UPDATE learning_goal_items AS canonical
            SET added_at = MIN(canonical.added_at, (
                    SELECT duplicate.added_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                completed_at = COALESCE(MAX(canonical.completed_at, (
                    SELECT duplicate.completed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.completed_at, (
                    SELECT duplicate.completed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                origin = COALESCE(canonical.origin, (
                    SELECT duplicate.origin FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                review_state = CASE
                    WHEN canonical.review_state = 'approved' OR EXISTS (
                        SELECT 1 FROM learning_goal_items duplicate
                        WHERE duplicate.goal_id = canonical.goal_id
                          AND duplicate.source_id = ? AND duplicate.review_state = 'approved'
                    ) THEN 'approved'
                    WHEN canonical.review_state = 'pending' OR EXISTS (
                        SELECT 1 FROM learning_goal_items duplicate
                        WHERE duplicate.goal_id = canonical.goal_id
                          AND duplicate.source_id = ? AND duplicate.review_state = 'pending'
                    ) THEN 'pending'
                    ELSE COALESCE(canonical.review_state, 'rejected')
                END,
                relevance = COALESCE(MAX(canonical.relevance, (
                    SELECT duplicate.relevance FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.relevance, (
                    SELECT duplicate.relevance FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                last_quizzed_at = COALESCE(MAX(canonical.last_quizzed_at, (
                    SELECT duplicate.last_quizzed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.last_quizzed_at, (
                    SELECT duplicate.last_quizzed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                quiz_count = COALESCE(MAX(canonical.quiz_count, (
                    SELECT duplicate.quiz_count FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.quiz_count, (
                    SELECT duplicate.quiz_count FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                last_score = COALESCE(MAX(canonical.last_score, (
                    SELECT duplicate.last_score FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.last_score, (
                    SELECT duplicate.last_score FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                sequence = COALESCE(MIN(canonical.sequence, (
                    SELECT duplicate.sequence FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.sequence, (
                    SELECT duplicate.sequence FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                ))
            WHERE canonical.source_id = ?
              AND EXISTS (
                  SELECT 1 FROM learning_goal_items duplicate
                  WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
              )
        """) { stmt in
            for index in 1...16 { bind(stmt, index, duplicateID) }
            bind(stmt, 17, canonicalID)
            bind(stmt, 18, duplicateID)
        }
        try execBind("DELETE FROM learning_goal_items WHERE source_id = ?") { stmt in
            bind(stmt, 1, duplicateID)
        }
    }

    /// Session JSON is the canonical relationship and the junction is its local
    /// projection. Rewrite both so neither still names the duplicate id.
    private func reassignReviewSessionSources(
        from duplicateID: String,
        to canonicalID: String
    ) throws {
        var sessions: [(id: String, sourceIDs: [String])] = []
        try queryBind("""
            SELECT id, source_ids FROM review_sessions
            WHERE EXISTS (
                SELECT 1 FROM json_each(
                    CASE WHEN json_valid(review_sessions.source_ids)
                         THEN review_sessions.source_ids ELSE '[]' END
                ) WHERE value = ?
            )
        """, bind: { stmt in
            bind(stmt, 1, duplicateID)
        }) { stmt in
            guard let id = string(stmt, 0) else { return }
            let raw = string(stmt, 1) ?? "[]"
            let ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
            sessions.append((id, ids))
        }

        for session in sessions {
            var seen = Set<String>()
            let rewritten = session.sourceIDs.compactMap { sourceID -> String? in
                let resolved = sourceID == duplicateID ? canonicalID : sourceID
                return seen.insert(resolved).inserted ? resolved : nil
            }
            try execBind("UPDATE review_sessions SET source_ids = ? WHERE id = ?") { stmt in
                bind(stmt, 1, jsonString(from: rewritten))
                bind(stmt, 2, session.id)
            }
            try replaceReviewSessionSources(sessionID: session.id, sourceIDs: rewritten)
        }
    }

    /// Schedule is source-global. If both duplicate ids were placed, merge their
    /// goal tags and activity ledger into the canonical placement; otherwise move
    /// the sole placement without changing its stable id.
    private func reassignScheduledSource(
        from duplicateID: String,
        to canonicalID: String
    ) throws {
        struct Placement {
            let id: String
            let isAutomatic: Bool
        }
        func placement(for sourceID: String) throws -> Placement? {
            var result: Placement?
            try queryBind(
                "SELECT id, is_automatic FROM scheduled_sources WHERE source_id = ? LIMIT 1",
                bind: { stmt in bind(stmt, 1, sourceID) }
            ) { stmt in
                if let id = string(stmt, 0) {
                    result = Placement(id: id, isAutomatic: sqlite3_column_int(stmt, 1) != 0)
                }
            }
            return result
        }

        guard let duplicate = try placement(for: duplicateID) else { return }
        guard let canonical = try placement(for: canonicalID) else {
            try execBind("""
                UPDATE scheduled_sources
                SET source_id = ?,
                    source_url = (SELECT url FROM source_projection WHERE id = ?),
                    source_normalized_url = (SELECT normalized_url FROM source_projection WHERE id = ?),
                    source_doi = (SELECT doi FROM source_projection WHERE id = ?),
                    source_published_doi = (SELECT published_doi FROM source_projection WHERE id = ?),
                    updated_at = ?
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, canonicalID)
                bind(stmt, 2, canonicalID)
                bind(stmt, 3, canonicalID)
                bind(stmt, 4, canonicalID)
                bind(stmt, 5, canonicalID)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSinceReferenceDate)
                bind(stmt, 7, duplicate.id)
            }
            // The placement keeps its id and moves; its ledger follows under
            // the canonical source's own day ids.
            try moveSourceActivityDays(
                fromPlacement: duplicate.id,
                toPlacement: duplicate.id,
                canonicalID: canonicalID
            )
            return
        }

        try execBind("""
            INSERT OR IGNORE INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
            SELECT ?, goal_id, added_at FROM scheduled_source_goals
            WHERE scheduled_source_id = ?
        """) { stmt in
            bind(stmt, 1, canonical.id)
            bind(stmt, 2, duplicate.id)
        }
        try moveSourceActivityDays(
            fromPlacement: duplicate.id,
            toPlacement: canonical.id,
            canonicalID: canonicalID
        )
        try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?") { stmt in
            bind(stmt, 1, duplicate.id)
        }
        // An explicit placement wins over an automatic history row. Otherwise
        // keep the canonical day and only combine monotonic completion evidence.
        try execBind("""
            UPDATE scheduled_sources
            SET planned_at = CASE WHEN is_automatic = 1 AND ? = 0
                                  THEN (SELECT planned_at FROM scheduled_sources WHERE id = ?)
                                  ELSE planned_at END,
                completed_at = COALESCE(MAX(completed_at, (
                    SELECT completed_at FROM scheduled_sources WHERE id = ?
                )), completed_at, (
                    SELECT completed_at FROM scheduled_sources WHERE id = ?
                )),
                added_at = MIN(added_at, (SELECT added_at FROM scheduled_sources WHERE id = ?)),
                updated_at = MAX(updated_at, (SELECT updated_at FROM scheduled_sources WHERE id = ?)),
                is_automatic = CASE WHEN is_automatic = 0 OR ? = 0 THEN 0 ELSE 1 END
            WHERE id = ?
        """) { stmt in
            sqlite3_bind_int(stmt, 1, duplicate.isAutomatic ? 1 : 0)
            bind(stmt, 2, duplicate.id)
            bind(stmt, 3, duplicate.id)
            bind(stmt, 4, duplicate.id)
            bind(stmt, 5, duplicate.id)
            bind(stmt, 6, duplicate.id)
            sqlite3_bind_int(stmt, 7, duplicate.isAutomatic ? 1 : 0)
            bind(stmt, 8, canonical.id)
        }
        try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
            bind(stmt, 1, duplicate.id)
        }
    }

    /// Move a duplicate placement's activity ledger under the canonical source.
    /// A day the canonical source already has folds into that row (earliest
    /// first, latest last, kinds OR-ed, depth and engaged time by MAX); a day it
    /// lacks keeps the duplicate's row, re-keyed to the canonical source under
    /// the id the canonical source gives that day (`sourceActivityDayID`, so a
    /// device syncing the same day derives the same row).
    ///
    /// The rows are moved, not copied under their old ids with an upsert on
    /// `(source_id, day_start)`: the row being copied is still in the table, so
    /// whenever the duplicate had a day the canonical did not, the copy hit the
    /// primary key instead of the upsert's target and the whole merge failed —
    /// which is how Merge Same-Day Sessions refused two standup calls that had
    /// both been read, and so both placed on the calendar (2026-09-19).
    private func moveSourceActivityDays(
        fromPlacement duplicatePlacementID: String,
        toPlacement canonicalPlacementID: String,
        canonicalID: String
    ) throws {
        struct Row {
            let id: String
            let dayStart: Double
        }
        var rows: [Row] = []
        try queryBind(
            "SELECT id, day_start FROM source_activity_days WHERE scheduled_source_id = ?",
            bind: { stmt in bind(stmt, 1, duplicatePlacementID) }
        ) { stmt in
            if let id = string(stmt, 0) {
                rows.append(Row(id: id, dayStart: sqlite3_column_double(stmt, 1)))
            }
        }
        guard !rows.isEmpty else { return }
        let canonicalKey = try portableMemorySourceKey(sourceID: canonicalID)

        for row in rows {
            var canonicalRowID: String?
            try queryBind(
                "SELECT id FROM source_activity_days WHERE source_id = ? AND day_start = ? AND id != ? LIMIT 1",
                bind: { stmt in
                    bind(stmt, 1, canonicalID)
                    bind(stmt, 2, row.dayStart)
                    bind(stmt, 3, row.id)
                }
            ) { stmt in
                canonicalRowID = string(stmt, 0)
            }

            if let canonicalRowID {
                // Both sources were used that day: one row keeps the union of
                // the evidence. Engaged time merges by MAX, as a synced total
                // does, because the duplicate's seconds are the same sitting
                // counted under another id, not a fresh slice.
                try execBind("""
                    UPDATE source_activity_days SET
                        first_activity_at = MIN(first_activity_at, (SELECT first_activity_at FROM source_activity_days WHERE id = ?)),
                        last_activity_at = MAX(last_activity_at, (SELECT last_activity_at FROM source_activity_days WHERE id = ?)),
                        kinds = kinds | (SELECT kinds FROM source_activity_days WHERE id = ?),
                        completed_kinds = completed_kinds | (SELECT completed_kinds FROM source_activity_days WHERE id = ?),
                        max_fraction = MAX(max_fraction, (SELECT max_fraction FROM source_activity_days WHERE id = ?)),
                        engaged_seconds = MAX(engaged_seconds, (SELECT engaged_seconds FROM source_activity_days WHERE id = ?))
                    WHERE id = ?
                """) { stmt in
                    bind(stmt, 1, row.id)
                    bind(stmt, 2, row.id)
                    bind(stmt, 3, row.id)
                    bind(stmt, 4, row.id)
                    bind(stmt, 5, row.id)
                    bind(stmt, 6, row.id)
                    bind(stmt, 7, canonicalRowID)
                }
                try execBind("DELETE FROM source_activity_days WHERE id = ?") { stmt in
                    bind(stmt, 1, row.id)
                }
            } else {
                let derivedID = MemoryTutorIdentity.sourceActivityDayID(
                    portableSourceKey: canonicalKey,
                    dayStart: Date(timeIntervalSinceReferenceDate: row.dayStart)
                )
                var derivedIDTaken = false
                try queryBind(
                    "SELECT 1 FROM source_activity_days WHERE id = ? AND id != ? LIMIT 1",
                    bind: { stmt in
                        bind(stmt, 1, derivedID)
                        bind(stmt, 2, row.id)
                    }
                ) { _ in derivedIDTaken = true }
                try execBind("""
                    UPDATE source_activity_days
                    SET id = ?, scheduled_source_id = ?, source_id = ?
                    WHERE id = ?
                """) { stmt in
                    bind(stmt, 1, derivedIDTaken ? row.id : derivedID)
                    bind(stmt, 2, canonicalPlacementID)
                    bind(stmt, 3, canonicalID)
                    bind(stmt, 4, row.id)
                }
            }
        }
    }

    /// Move source relationships whose rows have their own stable identity. The
    /// duplicate Source itself remains archived, so source-owned derived products
    /// do not need an unbounded copy during this user-visible repair.
    private func reassignSimpleSourceRelationships(
        from duplicateID: String,
        to canonicalID: String
    ) throws {
        func tableExists(_ table: String) throws -> Bool {
            var exists = false
            try queryBind(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
                bind: { stmt in bind(stmt, 1, table) }
            ) { _ in exists = true }
            return exists
        }

        let simpleTables = [
            "source_highlights", "memory_item_sources", "learning_goal_gaps",
            "meeting_artifacts", "research_canvas_items",
            "research_canvas_slide_blocks", "draft_cards"
        ]
        for table in simpleTables {
            guard try tableExists(table) else { continue }
            try execBind("UPDATE \(table) SET source_id = ? WHERE source_id = ?") { stmt in
                bind(stmt, 1, canonicalID)
                bind(stmt, 2, duplicateID)
            }
        }
        try execBind("UPDATE video_cited_papers SET imported_source_id = ? WHERE imported_source_id = ?") { stmt in
            bind(stmt, 1, canonicalID)
            bind(stmt, 2, duplicateID)
        }
        try execBind("""
            INSERT OR IGNORE INTO group_members (source_id, group_id, sort_index, lecture_group_id)
            SELECT ?, group_id, sort_index, lecture_group_id
            FROM group_members WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, canonicalID)
            bind(stmt, 2, duplicateID)
        }
        try execBind("DELETE FROM group_members WHERE source_id = ?") { stmt in
            bind(stmt, 1, duplicateID)
        }
    }

}
