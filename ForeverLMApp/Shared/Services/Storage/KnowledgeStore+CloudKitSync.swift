import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - CloudKit Sync

    func withoutSyncTracking<T>(_ body: () throws -> T) rethrows -> T {
        syncTrackingSuppressionDepth += 1
        defer { syncTrackingSuppressionDepth -= 1 }
        return try body()
    }

    func saveDerivedSourceContent(_ sourceId: String, content: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                bind(stmt, 1, sourceId)
                bind(stmt, 2, content)
            }
            try execBind("UPDATE sources SET state = ? WHERE id = ? AND source_type != ?") { stmt in
                bind(stmt, 1, StudioArticleState.ready.rawValue)
                bind(stmt, 2, sourceId)
                bind(stmt, 3, StudioSourceType.paper.rawValue)
            }
            try enqueueSourceListenableContentPreparation(sourceID: sourceId, content: content)
            try retireSourceReviewGuidePreparation(sourceID: sourceId)
            try markRecordChanged(entity: .source, logicalKey: sourceId)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func saveBookRecord(_ payload: CloudKitBookPayload) throws {
        let bookColumns = try tableColumnNames("books")
        if bookColumns.contains("subtitle") && bookColumns.contains("edition") {
            try execBind("""
                INSERT INTO books (id, title, subtitle, author, edition, cover_path, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    author = excluded.author,
                    edition = excluded.edition,
                    cover_path = excluded.cover_path,
                    kind = excluded.kind
            """) { stmt in
                bind(stmt, 1, payload.id)
                bind(stmt, 2, payload.title)
                bind(stmt, 3, payload.subtitle)
                bind(stmt, 4, SourceAuthor.storable(payload.author))
                bind(stmt, 5, payload.edition)
                bind(stmt, 6, payload.coverPath)
                bind(stmt, 7, payload.kind)
            }
        } else {
            try execBind("""
                INSERT INTO books (id, title, author, cover_path, kind)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    author = excluded.author,
                    cover_path = excluded.cover_path,
                    kind = excluded.kind
            """) { stmt in
                bind(stmt, 1, payload.id)
                bind(stmt, 2, payload.title)
                bind(stmt, 3, SourceAuthor.storable(payload.author))
                bind(stmt, 4, payload.coverPath)
                bind(stmt, 5, payload.kind)
            }
        }
        try markRecordChanged(entity: .book, logicalKey: payload.id)
    }

    func saveDismissedSourceRecord(_ payload: CloudKitDismissedSourcePayload) throws {
        try execBind("""
            INSERT INTO dismissed_sources (url, title, dismissed_at)
            VALUES (?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET title = excluded.title, dismissed_at = excluded.dismissed_at
        """) { stmt in
            bind(stmt, 1, payload.url)
            bind(stmt, 2, payload.title)
            sqlite3_bind_double(stmt, 3, payload.dismissedAt.timeIntervalSinceReferenceDate)
        }
        try archiveSourcesMatchingDismissedURL(payload.url)
        try markRecordChanged(entity: .dismissedSource, logicalKey: payload.url)
    }

    func saveHiddenPodcastShowRecord(_ payload: CloudKitHiddenPodcastShowPayload) throws {
        try execBind("""
            INSERT INTO hidden_podcast_shows (show_name, hidden_at)
            VALUES (?, ?)
            ON CONFLICT(show_name) DO UPDATE SET hidden_at = excluded.hidden_at
        """) { stmt in
            bind(stmt, 1, payload.showName)
            sqlite3_bind_double(stmt, 2, payload.hiddenAt.timeIntervalSinceReferenceDate)
        }
        try deleteVisiblePodcastEpisodeOverrides(forShow: payload.showName)
        try markRecordChanged(entity: .hiddenPodcastShow, logicalKey: payload.showName)
    }

    func saveHiddenYouTubeChannelRecord(_ payload: CloudKitHiddenYouTubeChannelPayload) throws {
        try execBind("""
            INSERT INTO hidden_youtube_channels (channel_name, hidden_at)
            VALUES (?, ?)
            ON CONFLICT(channel_name) DO UPDATE SET hidden_at = excluded.hidden_at
        """) { stmt in
            bind(stmt, 1, payload.channelName)
            sqlite3_bind_double(stmt, 2, payload.hiddenAt.timeIntervalSinceReferenceDate)
        }
        try deleteVisibleYouTubeVideoOverrides(forChannel: payload.channelName)
        try markRecordChanged(entity: .hiddenYouTubeChannel, logicalKey: payload.channelName)
    }

    @discardableResult
    func saveHiddenSourceRecord(_ payload: CloudKitHiddenSourcePayload) throws -> String {
        guard try sourceExists(payload.sourceID) else {
            try savePendingHiddenSource(payload.sourceID, hiddenAt: payload.hiddenAt)
            try markRecordChanged(entity: .hiddenSource, logicalKey: payload.sourceID)
            return payload.sourceID
        }

        try writeSourceHidden(payload.sourceID, hidden: true, hiddenAt: payload.hiddenAt)
        try deletePendingHiddenSource(payload.sourceID)
        if isPodcastSource(payload.sourceID) {
            try execBind("""
                INSERT INTO hidden_podcast_episodes (source_id, hidden_at)
                VALUES (?, ?)
                ON CONFLICT(source_id) DO UPDATE SET hidden_at = excluded.hidden_at
            """) { stmt in
                bind(stmt, 1, payload.sourceID)
                sqlite3_bind_double(stmt, 2, payload.hiddenAt.timeIntervalSinceReferenceDate)
            }
        }
        try markRecordChanged(entity: .hiddenSource, logicalKey: payload.sourceID)
        return payload.sourceID
    }

    /// A doc or site hidden on another Mac. The row is written whether or not
    /// the Artifact itself has arrived yet — the table has no foreign key, so
    /// record order cannot lose the hide — and it is this row, never a field
    /// of the Artifact, that the Docs and Sites lists read.
    func saveHiddenArtifactRecord(_ payload: CloudKitHiddenArtifactPayload) throws {
        try execBind("""
            INSERT INTO hidden_artifacts (artifact_id, hidden_at)
            VALUES (?, ?)
            ON CONFLICT(artifact_id) DO UPDATE SET hidden_at = excluded.hidden_at
        """) { stmt in
            bind(stmt, 1, payload.artifactID)
            sqlite3_bind_double(stmt, 2, payload.hiddenAt.timeIntervalSinceReferenceDate)
        }
        try markRecordChanged(entity: .hiddenArtifact, logicalKey: payload.artifactID)
    }

    /// A chat hidden on another Mac; the same contract as `saveHiddenArtifactRecord`.
    func saveHiddenReviewSessionRecord(_ payload: CloudKitHiddenReviewSessionPayload) throws {
        try execBind("""
            INSERT INTO hidden_review_sessions (session_id, hidden_at)
            VALUES (?, ?)
            ON CONFLICT(session_id) DO UPDATE SET hidden_at = excluded.hidden_at
        """) { stmt in
            bind(stmt, 1, payload.sessionID)
            sqlite3_bind_double(stmt, 2, payload.hiddenAt.timeIntervalSinceReferenceDate)
        }
        try markRecordChanged(entity: .hiddenReviewSession, logicalKey: payload.sessionID)
    }

    func deleteBookRecord(name: String) throws {
        var affectedSourceIDs: [String] = []
        try queryBind("SELECT source_id FROM group_members WHERE group_id = ?", bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                affectedSourceIDs.append(sourceID)
            }
        }
        try execBind("DELETE FROM books WHERE id = ?") { stmt in
            bind(stmt, 1, name)
        }
        try markRecordDeleted(entity: .book, logicalKey: name)
        for sourceID in affectedSourceIDs {
            try markRecordChanged(entity: .source, logicalKey: sourceID)
        }
    }

    func deleteDismissedSource(url: String) throws {
        try execBind("DELETE FROM dismissed_sources WHERE url = ?") { stmt in
            bind(stmt, 1, url)
        }
        try markRecordDeleted(entity: .dismissedSource, logicalKey: url)
    }

    // MARK: - User preferences

    /// Persist a locally-changed preference and queue it for sync.
    ///
    /// `ON CONFLICT ... DO UPDATE SET` rather than `INSERT OR REPLACE`: the latter
    /// blanks columns absent from the statement, which is the failure mode already
    /// documented for `review_sessions.goal_id` in docs/backend-storage-sync.md.
    func writePreference(key: String, valuePlistXML: String, updatedAt: Date = Date()) throws {
        try execBind("""
            INSERT INTO user_preferences (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, valuePlistXML)
            sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSinceReferenceDate)
        }
        try markRecordChanged(entity: .preference, logicalKey: key)
        // Generation 2: a quiz score or a deck's card states are memory records (§10).
        try mirrorMemoryPreference(key: key, valuePlistXML: valuePlistXML)
    }

    /// Clear a preference locally and tombstone it for sync.
    func deletePreference(key: String) throws {
        try execBind("DELETE FROM user_preferences WHERE key = ?") { stmt in
            bind(stmt, 1, key)
        }
        try markRecordDeleted(entity: .preference, logicalKey: key)
    }

    /// Apply a preference that arrived from CloudKit. Called inside
    /// `withoutSyncTracking`, so the `markRecordChanged` below is a no-op and the
    /// inbound value is not echoed back as an outbound save.
    func savePreferenceRecord(_ payload: CloudKitPreferencePayload) throws {
        try execBind("""
            INSERT INTO user_preferences (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, payload.key)
            bind(stmt, 2, payload.valuePlistXML)
            sqlite3_bind_double(stmt, 3, payload.updatedAt.timeIntervalSinceReferenceDate)
        }
        try markRecordChanged(entity: .preference, logicalKey: payload.key)
    }

    func loadPreferenceForSync(_ key: String) throws -> CloudKitPreferencePayload? {
        var payload: CloudKitPreferencePayload?
        try queryBind("""
            SELECT key, value, updated_at
            FROM user_preferences
            WHERE key = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, key)
        }) { stmt in
            guard let persistedKey = self.string(stmt, 0),
                  let value = self.string(stmt, 1) else { return }
            payload = CloudKitPreferencePayload(
                key: persistedKey,
                valuePlistXML: value,
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            )
        }
        return payload
    }

    func loadAllPreferenceKeys() throws -> [String] {
        var keys: [String] = []
        try query("SELECT key FROM user_preferences") { stmt in
            if let key = self.string(stmt, 0) {
                keys.append(key)
            }
        }
        return keys
    }

    /// Every stored preference as `key -> plist XML`. Used to rehydrate
    /// `UserDefaults` after a remote change; small enough (tens of short strings)
    /// to load wholesale rather than tracking which keys the sync touched.
    func loadAllPreferences() throws -> [String: String] {
        var values: [String: String] = [:]
        try query("SELECT key, value FROM user_preferences") { stmt in
            if let key = self.string(stmt, 0), let value = self.string(stmt, 1) {
                values[key] = value
            }
        }
        return values
    }

    /// What `repairUnreadablePreferences()` did: the keys it rewrote, and the
    /// keys it could not read and left as they were.
    struct PreferenceRepairReport: Equatable, Sendable {
        var repaired: [String] = []
        var unreadable: [String] = []
    }

    /// Rewrite every synced preference row whose value `PreferenceStore.decodePlist`
    /// rejects but `recoverPlist` can read, and name the rows that stay unreadable.
    ///
    /// Found on 2026-08-31: two `meetingFolder.image.*` rows whose plist carried
    /// the two-character text `\t` where the encoder writes a tab — what a
    /// `sqlite3` insert typed with escape sequences leaves, since SQL string
    /// literals expand nothing. Written on one Mac and carried by sync to the
    /// other, the row was on both and readable on neither, and hydration skipped
    /// it in silence, so the folder icon looked as if it had never synced. Going
    /// through `writePreference` re-encodes the value canonically and queues the
    /// row, so the clean copy also replaces the broken mirror on the other Mac.
    ///
    /// Not a launch-time job in the banned sense: the table holds tens of rows
    /// that hydration decodes anyway, nothing is written unless a row fails to
    /// decode, and a repaired row decodes next time, so the work retires itself.
    /// An empty value is the payload's form for "no value", not damage, and is
    /// left alone; so is a row for a key that does not sync, since nothing reads it.
    func repairUnreadablePreferences() throws -> PreferenceRepairReport {
        var report = PreferenceRepairReport()
        for (key, xml) in try loadAllPreferences().sorted(by: { $0.key < $1.key }) {
            guard SyncedPreferenceKeys.isSynced(key),
                  !xml.isEmpty,
                  PreferenceStore.decodePlist(xml) == nil
            else { continue }
            if let value = PreferenceStore.recoverPlist(xml),
               let canonical = PreferenceStore.encodePlist(value) {
                try writePreference(key: key, valuePlistXML: canonical)
                report.repaired.append(key)
            } else {
                report.unreadable.append(key)
            }
        }
        return report
    }

    func deleteHiddenPodcastShowRecord(showName: String) throws {
        try execBind("DELETE FROM hidden_podcast_shows WHERE show_name = ?") { stmt in
            bind(stmt, 1, showName)
        }
        // A show unhidden on another device becomes visible here too, and a
        // visible podcast transcript is owed its ad cleanup. The enqueue
        // re-checks visibility and prior results, so it stages only the
        // episodes that have not been cleaned at the current version.
        for sourceID in try podcastSourceIDs(forShow: showName) {
            try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
        }
        try markRecordDeleted(entity: .hiddenPodcastShow, logicalKey: showName)
    }

    func deleteHiddenYouTubeChannelRecord(channelName: String) throws {
        try execBind("DELETE FROM hidden_youtube_channels WHERE channel_name = ?") { stmt in
            bind(stmt, 1, channelName)
        }
        try markRecordDeleted(entity: .hiddenYouTubeChannel, logicalKey: channelName)
    }

    func deleteHiddenSourceRecord(sourceID: String) throws {
        try deletePendingHiddenSource(sourceID)
        try execBind("DELETE FROM hidden_sources WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
        try execBind("DELETE FROM hidden_podcast_episodes WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
        // Same contract as the local unhide: becoming visible again is what
        // makes an uncleaned transcript owed a cleanup pass.
        try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
        try markRecordDeleted(entity: .hiddenSource, logicalKey: sourceID)
    }

    /// A doc or site shown again on another Mac.
    func deleteHiddenArtifactRecord(artifactID: String) throws {
        try execBind("DELETE FROM hidden_artifacts WHERE artifact_id = ?") { stmt in
            bind(stmt, 1, artifactID)
        }
        try markRecordDeleted(entity: .hiddenArtifact, logicalKey: artifactID)
    }

    /// A chat shown again on another Mac.
    func deleteHiddenReviewSessionRecord(sessionID: String) throws {
        try execBind("DELETE FROM hidden_review_sessions WHERE session_id = ?") { stmt in
            bind(stmt, 1, sessionID)
        }
        try markRecordDeleted(entity: .hiddenReviewSession, logicalKey: sessionID)
    }

    func deleteContextSourceIds() throws {
        try exec("DELETE FROM chat_context WHERE key = 'current'")
        try markRecordDeleted(entity: .chatContext, logicalKey: CloudKitRecordMapper.contextLogicalKey)
    }

    func pendingSyncChanges(
        limit: Int? = nil,
        oldestFirst: Bool = false
    ) throws -> [CloudKitPendingChange] {
        var result: [CloudKitPendingChange] = []
        let limitClause = limit.map { "LIMIT \(max(0, $0))" } ?? ""
        let ordering = oldestFirst ? "ASC" : "DESC"
        try query("""
            SELECT changes.entity_type, changes.logical_key, changes.record_name,
                   changes.operation, changes.changed_at,
                   changes.zone_scope, changes.zone_name, changes.zone_owner_record_name
            FROM sync_changes AS changes
            WHERE NOT EXISTS (
                SELECT 1
                FROM sync_conflicts AS conflicts
                WHERE conflicts.entity_type = changes.entity_type
                  AND conflicts.logical_key = changes.logical_key
                  AND conflicts.reason NOT LIKE '\(CloudKitInboundWebPDFRetry.reasonLikePattern)'
            )
            AND NOT (
                changes.entity_type = 'memoryAttempt'
                AND changes.operation = 'save'
                AND NOT EXISTS (
                    SELECT 1
                    FROM memory_attempts AS attempt
                    JOIN sync_metadata AS parent_metadata
                      ON parent_metadata.entity_type = 'memoryItem'
                     AND parent_metadata.logical_key = attempt.memory_item_id
                     AND parent_metadata.system_fields IS NOT NULL
                     AND parent_metadata.is_deleted = 0
                    WHERE attempt.id = changes.logical_key
                )
            )
            AND NOT (
                changes.entity_type = 'sourceHighlight'
                AND changes.operation = 'save'
                AND NOT EXISTS (
                    SELECT 1
                    FROM source_highlights AS highlight
                    JOIN sync_metadata AS parent_metadata
                      ON parent_metadata.entity_type = 'source'
                     AND parent_metadata.logical_key = highlight.source_id
                     AND parent_metadata.system_fields IS NOT NULL
                     AND parent_metadata.is_deleted = 0
                    WHERE highlight.highlight_id = changes.logical_key
                )
            )
            -- Recent user-visible edits (especially completed paper metadata)
            -- must not sit behind thousands of older migration republishes.
            ORDER BY changed_at \(ordering)
            \(limitClause)
        """) { stmt in
            guard
                let entityRaw = self.string(stmt, 0),
                let entity = CloudKitSyncEntity(rawValue: entityRaw),
                let logicalKey = self.string(stmt, 1),
                let recordName = self.string(stmt, 2),
                let operationRaw = self.string(stmt, 3),
                let operation = CloudKitSyncOperation(rawValue: operationRaw)
            else {
                return
            }
            let changedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            result.append(
                CloudKitPendingChange(
                    entity: entity,
                    logicalKey: logicalKey,
                    recordName: recordName,
                    operation: operation,
                    changedAt: changedAt,
                    home: self.zoneHome(stmt, scopeIndex: 5)
                )
            )
        }
        return result
    }

    /// Decode the three zone columns every sync bookkeeping table carries,
    /// starting at `scopeIndex`. Rows written before schema 96 read as the
    /// private Knowledge zone through the column defaults.
    func zoneHome(_ stmt: OpaquePointer?, scopeIndex: Int32) -> CloudKitZoneHome {
        let scopeRaw = string(stmt, Int(scopeIndex)) ?? CloudKitZoneHome.Scope.privateScope.rawValue
        let scope = CloudKitZoneHome.Scope(rawValue: scopeRaw) ?? .privateScope
        let zoneName = string(stmt, Int(scopeIndex) + 1) ?? CloudKitZoneHome.knowledgeZoneName
        let owner = string(stmt, Int(scopeIndex) + 2)
        return CloudKitZoneHome(scope: scope, zoneName: zoneName, ownerRecordName: owner)
    }

    func bindZoneHome(_ stmt: OpaquePointer?, _ home: CloudKitZoneHome, scopeIndex: Int) {
        bind(stmt, scopeIndex, home.scope.rawValue)
        bind(stmt, scopeIndex + 1, home.zoneName)
        bind(stmt, scopeIndex + 2, home.ownerRecordName)
    }

    func pendingSyncChangeCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM sync_changes AS changes
            WHERE NOT EXISTS (
                SELECT 1
                FROM sync_conflicts AS conflicts
                WHERE conflicts.entity_type = changes.entity_type
                  AND conflicts.logical_key = changes.logical_key
                  AND conflicts.reason NOT LIKE '\(CloudKitInboundWebPDFRetry.reasonLikePattern)'
            )
            AND NOT (
                changes.entity_type = 'memoryAttempt'
                AND changes.operation = 'save'
                AND NOT EXISTS (
                    SELECT 1
                    FROM memory_attempts AS attempt
                    JOIN sync_metadata AS parent_metadata
                      ON parent_metadata.entity_type = 'memoryItem'
                     AND parent_metadata.logical_key = attempt.memory_item_id
                     AND parent_metadata.system_fields IS NOT NULL
                     AND parent_metadata.is_deleted = 0
                    WHERE attempt.id = changes.logical_key
                )
            )
            AND NOT (
                changes.entity_type = 'sourceHighlight'
                AND changes.operation = 'save'
                AND NOT EXISTS (
                    SELECT 1
                    FROM source_highlights AS highlight
                    JOIN sync_metadata AS parent_metadata
                      ON parent_metadata.entity_type = 'source'
                     AND parent_metadata.logical_key = highlight.source_id
                     AND parent_metadata.system_fields IS NOT NULL
                     AND parent_metadata.is_deleted = 0
                    WHERE highlight.highlight_id = changes.logical_key
                )
            )
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// A bounded, UI-ready snapshot of the outbound queue. This runs on the
    /// storage/sync actor and is pushed to Settings; views never query SQLite.
    func pendingSyncItemSummaries(limit: Int = 20) throws -> [CloudKitSyncPendingItem] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }

        // Show both ends of the queue. Recent-first sending keeps interactive
        // edits responsive, but showing only that same end hid a six-day-old
        // record behind active imports and made a stalled save look healthy.
        let oldest = try pendingSyncChanges(
            limit: (boundedLimit + 1) / 2,
            oldestFirst: true
        )
        let newest = try pendingSyncChanges(limit: boundedLimit / 2)
        var seen = Set<String>()
        let changes = (oldest + newest).filter { seen.insert($0.recordName).inserted }
        return changes.map { change in
            CloudKitSyncPendingItem(
                id: change.recordName,
                title: (try? pendingSyncItemTitle(for: change)) ?? pendingSyncFallbackTitle(for: change),
                kind: pendingSyncItemKind(change.entity),
                operation: change.operation,
                changedAt: change.changedAt
            )
        }
    }

    /// Bounded, user-readable failures parked outside the active retry queue.
    /// Keeping these beside pending items in Settings makes quarantine a visible
    /// error state instead of changing "Uploading" to an unexplained count.
    func syncIssueItemSummaries(limit: Int = 20) throws -> [CloudKitSyncIssueItem] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        return try loadSyncConflicts(limit: boundedLimit).map { conflict in
            let operation: CloudKitSyncOperation
            let message: String
            if let rejected = CloudKitRejectedChangeQuarantine.decodedReason(conflict.reason) {
                operation = rejected.operation
                message = rejected.message
            } else if let rejected = CloudKitRejectedSaveQuarantine.decodedReason(conflict.reason) {
                operation = .save
                message = rejected.message
            } else if conflict.reason.hasPrefix(CloudKitInboundWebPDFRetry.quarantineReasonPrefix) {
                operation = .save
                message = String(conflict.reason.dropFirst(
                    CloudKitInboundWebPDFRetry.quarantineReasonPrefix.count
                ))
            } else {
                operation = .save
                message = conflict.reason
            }
            let change = CloudKitPendingChange(
                entity: conflict.entity,
                logicalKey: conflict.logicalKey,
                recordName: conflict.recordName,
                operation: operation,
                changedAt: conflict.localModificationDate
            )
            return CloudKitSyncIssueItem(
                id: conflict.recordName,
                title: (try? pendingSyncItemTitle(for: change))
                    ?? pendingSyncFallbackTitle(for: change),
                kind: pendingSyncItemKind(conflict.entity),
                operation: operation,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                detectedAt: conflict.detectedAt
            )
        }
    }

    private func pendingSyncItemTitle(for change: CloudKitPendingChange) throws -> String {
        switch change.entity {
        case .source:
            return try loadSourceForSync(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .sourceHighlight:
            if let sourceID = try loadSourceHighlightForSync(change.logicalKey)?.highlight.sourceID,
               let title = try loadSourceForSync(sourceID)?.title {
                return title
            }
        case .book:
            return try loadBookForSync(change.logicalKey)?.title ?? change.logicalKey
        case .course:
            let course = try loadCourseForSync(change.logicalKey)
            return course?.title ?? course?.name ?? change.logicalKey
        case .videoPlaylist:
            return try loadVideoPlaylistForSync(change.logicalKey)?.metadata.title ?? change.logicalKey
        case .meetingGroup, .hiddenPodcastShow, .hiddenYouTubeChannel, .dismissedSource:
            return change.logicalKey
        case .hiddenSource:
            return try loadSourceForSync(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .hiddenArtifact:
            return try loadArtifact(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .hiddenReviewSession:
            return try loadReviewSessionForSync(change.logicalKey)?.topic ?? pendingSyncFallbackTitle(for: change)
        case .chatContext:
            return "Chat context"
        case .reviewSession:
            return try loadReviewSessionForSync(change.logicalKey)?.topic ?? pendingSyncFallbackTitle(for: change)
        case .memoryItem:
            return try loadMemoryItem(change.logicalKey)?.target ?? pendingSyncFallbackTitle(for: change)
        case .memoryAttempt:
            if let itemID = try loadMemoryAttempt(change.logicalKey)?.memoryItemID,
               let target = try loadMemoryItem(itemID)?.target {
                return target
            }
        case .learningGoal:
            return try loadLearningGoal(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .artifact:
            return try loadArtifact(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .artifactComment:
            return "Article comment"
        case .scheduledSource:
            if let sourceID = try loadScheduledSourceForSync(change.logicalKey)?.placement.sourceID,
               let title = try loadSourceForSync(sourceID)?.title {
                return title
            }
        case .scheduledTask:
            return try loadScheduledTask(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .dayPlan:
            return "Day plan \(change.logicalKey)"
        case .idea:
            return try loadIdea(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .walkthroughProgress:
            return "Walkthrough progress \(change.logicalKey)"
        case .skill:
            return try loadSkill(change.logicalKey).map { "/\($0.name)" } ?? pendingSyncFallbackTitle(for: change)
        case .researchDirection:
            return try loadResearchDirection(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .sourceIdea:
            return try loadSourceIdea(change.logicalKey)?.statement ?? pendingSyncFallbackTitle(for: change)
        case .memoryReviewActivity:
            return "Memory review time"
        case .videoCitedPaper:
            return try loadVideoCitedPaper(id: change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .aiUsageEvent:
            return "AI usage"
        case .preference:
            return change.logicalKey
        case .researchCanvas:
            return "Research canvas"
        case .team:
            return try loadTeam(change.logicalKey)?.name ?? pendingSyncFallbackTitle(for: change)
        case .notebookTask:
            return try loadNotebookTask(change.logicalKey)?.title ?? pendingSyncFallbackTitle(for: change)
        case .shareRequest:
            return try loadShareRequest(change.logicalKey).map { $0.title ?? $0.url } ?? pendingSyncFallbackTitle(for: change)
        }
        return pendingSyncFallbackTitle(for: change)
    }

    private func pendingSyncFallbackTitle(for change: CloudKitPendingChange) -> String {
        let kind = pendingSyncItemKind(change.entity)
        if UUID(uuidString: change.logicalKey) != nil {
            return change.operation == .delete ? "Deleted \(kind.lowercased())" : kind
        }
        return change.logicalKey.isEmpty ? kind : change.logicalKey
    }

    private func pendingSyncItemKind(_ entity: CloudKitSyncEntity) -> String {
        switch entity {
        case .source: return "Source"
        case .sourceHighlight: return "Highlight"
        case .book: return "Book"
        case .course: return "Course"
        case .videoPlaylist: return "Playlist"
        case .meetingGroup: return "Meeting"
        case .hiddenSource: return "Hidden source"
        case .hiddenPodcastShow: return "Podcast setting"
        case .hiddenYouTubeChannel: return "YouTube setting"
        case .hiddenArtifact: return "Hidden page"
        case .hiddenReviewSession: return "Hidden chat"
        case .dismissedSource: return "Dismissed source"
        case .chatContext: return "Chat"
        case .reviewSession: return "Review"
        case .memoryItem: return "Memory item"
        case .memoryAttempt: return "Memory attempt"
        case .sourceIdea: return "Memory idea"
        case .memoryReviewActivity: return "Memory review time"
        case .learningGoal: return "Notebook"
        case .artifact: return "Article"
        case .artifactComment: return "Comment"
        case .scheduledSource: return "Schedule item"
        case .scheduledTask: return "Scheduled task"
        case .dayPlan: return "Day plan"
        case .idea: return "Idea"
        case .walkthroughProgress: return "Walkthrough progress"
        case .skill: return "Skill"
        case .researchDirection: return "Direction"
        case .videoCitedPaper: return "Cited paper"
        case .researchCanvas: return "Research canvas"
        case .aiUsageEvent: return "AI usage"
        case .preference: return "Setting"
        case .team: return "Team"
        case .notebookTask: return "Task"
        case .shareRequest: return "Share request"
        }
    }

    /// Records CloudKit has never acknowledged from this device. Read beside the
    /// pending queue this is the number that separates the two failure shapes: a
    /// large count next to a draining queue is an ordinary first-run backlog,
    /// while a large count next to a static queue means saves are not actually
    /// reaching the server.
    func unacknowledgedSyncRecordCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM sync_metadata
            WHERE system_fields IS NULL
              AND is_deleted = 0
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// The SQLite half of `ICloudStorageUsage`: what the source records iCloud
    /// holds for this library carry as assets. Only records in the learner's
    /// own database count — a team they were invited to is billed to its
    /// creator — and only records CloudKit has acknowledged, less any whose
    /// content a deferring pass has not sent yet.
    ///
    /// Text is summed with `octet_length`, which SQLite answers from the record
    /// header, so no source body is read. The raw extraction is counted from
    /// the one preparation table `CloudKitRecordMapper` ships for the type.
    func iCloudSyncedSourceStorage() throws -> ICloudSyncedSourceStorage {
        let synced = """
            SELECT s.id, s.source_type
            FROM sync_metadata m
            JOIN sources s ON s.id = m.logical_key
            WHERE m.entity_type = 'source'
              AND m.is_deleted = 0
              AND m.zone_scope = 'private'
              AND m.system_fields IS NOT NULL
              AND m.record_name NOT IN (
                  SELECT record_name FROM sync_asset_digests
                  WHERE field = '\(Self.deferredContentMarkerField)'
              )
        """

        var pdfPaths: [ICloudSyncedSourceStorage.StoredPath] = []
        try query("""
            WITH synced AS (\(synced))
            SELECT sp.local_file_path, sp.url
            FROM synced
            JOIN source_projection sp ON sp.id = synced.id
            WHERE synced.source_type IN ('paper', 'book', 'course')
        """) { stmt in
            pdfPaths.append(ICloudSyncedSourceStorage.StoredPath(
                localFilePath: self.string(stmt, 0),
                url: self.string(stmt, 1)
            ))
        }

        var textBytes: Int64 = 0
        try query("""
            WITH synced AS (\(synced))
            SELECT
                (SELECT COALESCE(SUM(octet_length(c.content)), 0)
                 FROM source_content c JOIN synced ON synced.id = c.source_id)
              + (SELECT COALESCE(SUM(octet_length(l.content)), 0)
                 FROM source_listenable_content l JOIN synced ON synced.id = l.source_id)
              + (SELECT COALESCE(SUM(octet_length(p.raw_content)), 0)
                 FROM paper_content_preparations p JOIN synced ON synced.id = p.source_id
                 WHERE synced.source_type = 'paper')
              + (SELECT COALESCE(SUM(octet_length(p.input_content)), 0)
                 FROM podcast_transcript_preparations p JOIN synced ON synced.id = p.source_id
                 WHERE synced.source_type = 'podcast')
              + (SELECT COALESCE(SUM(octet_length(a.raw_content)), 0)
                 FROM article_content_preparations a JOIN synced ON synced.id = a.source_id
                 WHERE synced.source_type NOT IN ('paper', 'podcast'))
              + (SELECT COALESCE(SUM(octet_length(pod.raw_ttml)), 0)
                 FROM podcasts pod JOIN synced ON synced.id = pod.source_id)
        """) { stmt in
            textBytes = sqlite3_column_int64(stmt, 0)
        }

        return ICloudSyncedSourceStorage(pdfPaths: pdfPaths, textBytes: textBytes)
    }

    /// Quarantined changes that need the learner's input, counted without loading
    /// their payload blobs. Automatic inbound document-download retries share the
    /// table as durable work but are not conflicts and must not light a warning.
    func syncConflictCount() throws -> Int {
        var count = 0
        try queryBind("""
            SELECT COUNT(*)
            FROM sync_conflicts
            WHERE reason NOT LIKE ?
        """, bind: { statement in
            bind(statement, 1, CloudKitInboundWebPDFRetry.reasonLikePattern)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Convert a bounded slice of the versioned repair queue into ordinary
    /// CloudKit changes. This deliberately runs after launch, not in the schema
    /// transaction, because record names require hashing and the resulting
    /// source payloads may carry large assets.
    func drainSourceSyncRepairBatch(limit: Int) throws -> Int {
        let boundedLimit = max(1, min(limit, 100))
        var sourceIDs: [String] = []
        try query("""
            SELECT source_id
            FROM source_sync_repair_queue
            ORDER BY enqueued_at, source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            if let sourceID = self.string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }
        guard !sourceIDs.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        do {
            let now = Date()
            for sourceID in sourceIDs {
                try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
                try execBind("DELETE FROM source_sync_repair_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return sourceIDs.count
    }

    /// Schema 98 renamed the CloudKit record type behind review sessions.
    /// Each staged session is enqueued as an ordinary save under the new
    /// type; like the source repair this runs after launch because record
    /// names are hashed and payloads are built from the whole transcript.
    func drainReviewSessionSyncRepairBatch(limit: Int) throws -> Int {
        let boundedLimit = max(1, min(limit, 100))
        var sessionIDs: [String] = []
        try query("""
            SELECT session_id
            FROM review_session_sync_repair_queue
            ORDER BY enqueued_at, session_id
            LIMIT \(boundedLimit)
        """) { stmt in
            if let sessionID = self.string(stmt, 0) {
                sessionIDs.append(sessionID)
            }
        }
        guard !sessionIDs.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        do {
            let now = Date()
            for sessionID in sessionIDs {
                try upsertSyncSave(entity: .reviewSession, logicalKey: sessionID, at: now)
                try execBind("DELETE FROM review_session_sync_repair_queue WHERE session_id = ?") { stmt in
                    bind(stmt, 1, sessionID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return sessionIDs.count
    }

    func reviewSessionSyncRepairQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM review_session_sync_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Decode the HTML character references left in a bounded slice of stored
    /// source text, then republish those sources so the phone stops showing
    /// `&ldquo;` in the reader.
    ///
    /// Deliberately after launch rather than in the schema transaction: this
    /// reads and rewrites content, which is proportional to the library. Each
    /// batch commits on its own, so a quit midway leaves the rest durable, and
    /// re-running is harmless — decoding is idempotent on text that no longer
    /// holds a reference, and the row leaves the queue either way.
    ///
    /// Every decode strictly shortens the text, so `source_index_state`'s
    /// recorded content length stops matching and the ordinary indexer rebuilds
    /// full text and embeddings for the repaired sources.
    func drainSourceTextReferenceRepairBatch(limit: Int) throws -> [String] {
        let boundedLimit = max(1, min(limit, 100))
        var candidates: [(sourceID: String, content: String)] = []
        try query("""
            SELECT q.source_id, sc.content
            FROM source_text_reference_repair_queue q
            JOIN source_content sc ON sc.source_id = q.source_id
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let content = self.string(stmt, 1) else { return }
            candidates.append((sourceID, content))
        }

        // A queued source whose content row has since gone (archived, deleted)
        // has no repair left to do, but its queue row would otherwise block the
        // batch window forever.
        var orphanedIDs: [String] = []
        try query("""
            SELECT q.source_id
            FROM source_text_reference_repair_queue q
            WHERE NOT EXISTS (
                SELECT 1 FROM source_content sc WHERE sc.source_id = q.source_id
            )
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            if let sourceID = self.string(stmt, 0) { orphanedIDs.append(sourceID) }
        }

        guard !candidates.isEmpty || !orphanedIDs.isEmpty else { return [] }

        try exec("BEGIN IMMEDIATE")
        var repairedIDs: [String] = []
        do {
            let now = Date()
            for candidate in candidates {
                let decoded = candidate.content.decodingHTMLCharacterReferences()
                if decoded != candidate.content {
                    try execBind("UPDATE source_content SET content = ? WHERE source_id = ?") { stmt in
                        bind(stmt, 1, decoded)
                        bind(stmt, 2, candidate.sourceID)
                    }
                    try upsertSyncSave(entity: .source, logicalKey: candidate.sourceID, at: now)
                    // The text other devices read is published again (generation 2).
                    try queueSourceFilesRefresh(sourceID: candidate.sourceID)
                    repairedIDs.append(candidate.sourceID)
                }
                try execBind(
                    "DELETE FROM source_text_reference_repair_queue WHERE source_id = ?"
                ) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            }
            for sourceID in orphanedIDs {
                try execBind(
                    "DELETE FROM source_text_reference_repair_queue WHERE source_id = ?"
                ) { stmt in
                    bind(stmt, 1, sourceID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return repairedIDs
    }

    func sourceTextReferenceRepairQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_text_reference_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func sourceSyncRepairQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_sync_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    @discardableResult
    func discardPendingSavesMissingLocalRecords() throws -> [CloudKitPendingChange] {
        var discarded: [CloudKitPendingChange] = []
        // This runs before every send, including a first Production publish with
        // thousands of queued records. Do not load and validate records one at a
        // time: Source validation can materialize large payloads and turns a
        // set-sized migration into minutes of work. Every correlated existence
        // check below uses the entity table's primary/unique key; DELETE RETURNING
        // makes detection and removal one atomic, set-based statement.
        try query("""
            DELETE FROM sync_changes
            WHERE operation = 'save'
              AND NOT CASE entity_type
                WHEN 'source' THEN EXISTS(
                  SELECT 1 FROM source_projection
                  WHERE id = sync_changes.logical_key
                    AND url IS NOT NULL
                    AND title IS NOT NULL
                    AND domain IS NOT NULL
                    AND state IS NOT NULL
                    AND source_type IS NOT NULL
                )
                WHEN 'book' THEN EXISTS(SELECT 1 FROM books WHERE id = sync_changes.logical_key)
                WHEN 'course' THEN EXISTS(SELECT 1 FROM courses WHERE id = sync_changes.logical_key)
                WHEN 'videoPlaylist' THEN EXISTS(SELECT 1 FROM video_playlists WHERE id = sync_changes.logical_key)
                WHEN 'meetingGroup' THEN EXISTS(SELECT 1 FROM meeting_groups WHERE id = sync_changes.logical_key)
                WHEN 'hiddenSource' THEN EXISTS(SELECT 1 FROM hidden_sources WHERE source_id = sync_changes.logical_key)
                WHEN 'hiddenPodcastShow' THEN EXISTS(SELECT 1 FROM hidden_podcast_shows WHERE show_name = sync_changes.logical_key)
                WHEN 'hiddenYouTubeChannel' THEN EXISTS(SELECT 1 FROM hidden_youtube_channels WHERE channel_name = sync_changes.logical_key)
                WHEN 'hiddenArtifact' THEN EXISTS(SELECT 1 FROM hidden_artifacts WHERE artifact_id = sync_changes.logical_key)
                WHEN 'hiddenReviewSession' THEN EXISTS(SELECT 1 FROM hidden_review_sessions WHERE session_id = sync_changes.logical_key)
                WHEN 'dismissedSource' THEN EXISTS(SELECT 1 FROM dismissed_sources WHERE url = sync_changes.logical_key)
                WHEN 'chatContext' THEN EXISTS(SELECT 1 FROM chat_context WHERE key = sync_changes.logical_key)
                WHEN 'reviewSession' THEN EXISTS(SELECT 1 FROM review_sessions WHERE id = sync_changes.logical_key)
                WHEN 'memoryItem' THEN EXISTS(SELECT 1 FROM memory_items WHERE id = sync_changes.logical_key)
                WHEN 'memoryAttempt' THEN EXISTS(SELECT 1 FROM memory_attempts WHERE id = sync_changes.logical_key)
                WHEN 'sourceIdea' THEN EXISTS(SELECT 1 FROM source_ideas WHERE id = sync_changes.logical_key)
                WHEN 'memoryReviewActivity' THEN EXISTS(SELECT 1 FROM memory_review_activity WHERE id = sync_changes.logical_key)
                WHEN 'sourceHighlight' THEN EXISTS(SELECT 1 FROM source_highlights WHERE highlight_id = sync_changes.logical_key)
                WHEN 'learningGoal' THEN EXISTS(SELECT 1 FROM learning_goals WHERE id = sync_changes.logical_key)
                WHEN 'artifact' THEN EXISTS(SELECT 1 FROM global_artifacts WHERE id = sync_changes.logical_key)
                WHEN 'artifactComment' THEN EXISTS(SELECT 1 FROM artifact_comments WHERE id = sync_changes.logical_key)
                WHEN 'scheduledSource' THEN EXISTS(SELECT 1 FROM scheduled_sources WHERE id = sync_changes.logical_key)
                WHEN 'scheduledTask' THEN EXISTS(SELECT 1 FROM scheduled_tasks WHERE id = sync_changes.logical_key)
                WHEN 'dayPlan' THEN EXISTS(SELECT 1 FROM day_plans WHERE id = sync_changes.logical_key)
                WHEN 'idea' THEN EXISTS(SELECT 1 FROM ideas WHERE id = sync_changes.logical_key)
                WHEN 'walkthroughProgress' THEN EXISTS(SELECT 1 FROM walkthrough_progress WHERE subject_id = sync_changes.logical_key)
                WHEN 'skill' THEN EXISTS(SELECT 1 FROM skills WHERE id = sync_changes.logical_key)
                WHEN 'researchDirection' THEN EXISTS(SELECT 1 FROM research_directions WHERE id = sync_changes.logical_key)
                WHEN 'videoCitedPaper' THEN EXISTS(SELECT 1 FROM video_cited_papers WHERE id = sync_changes.logical_key)
                WHEN 'aiUsageEvent' THEN EXISTS(SELECT 1 FROM ai_usage_events WHERE id = sync_changes.logical_key)
                WHEN 'preference' THEN EXISTS(SELECT 1 FROM user_preferences WHERE key = sync_changes.logical_key)
                WHEN 'team' THEN EXISTS(SELECT 1 FROM teams WHERE id = sync_changes.logical_key)
                WHEN 'projectTask' THEN EXISTS(SELECT 1 FROM notebook_tasks WHERE id = sync_changes.logical_key)
                WHEN 'shareRequest' THEN EXISTS(SELECT 1 FROM share_requests WHERE id = sync_changes.logical_key)
                ELSE 0
              END
            RETURNING entity_type, logical_key, record_name, operation, changed_at,
                      zone_scope, zone_name, zone_owner_record_name
        """) { stmt in
            guard
                let entityRaw = self.string(stmt, 0),
                let entity = CloudKitSyncEntity(rawValue: entityRaw),
                let logicalKey = self.string(stmt, 1),
                let recordName = self.string(stmt, 2),
                let operationRaw = self.string(stmt, 3),
                let operation = CloudKitSyncOperation(rawValue: operationRaw)
            else {
                return
            }
            discarded.append(
                CloudKitPendingChange(
                    entity: entity,
                    logicalKey: logicalKey,
                    recordName: recordName,
                    operation: operation,
                    changedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                    home: self.zoneHome(stmt, scopeIndex: 5)
                )
            )
        }
        // The same rule as quarantine, for the other way out of the queue: these
        // saves were dropped because their local row is gone, so no later pass
        // can commit or clear what a previous pass staged for them.
        for change in discarded {
            try clearStagedAssetDigests(recordName: change.recordName)
        }
        return discarded
    }

    func hasLocalSyncRecord(entity: CloudKitSyncEntity, logicalKey: String) throws -> Bool {
        switch entity {
        case .source:
            return try loadSourceForSync(logicalKey) != nil
        case .book:
            return try loadBookForSync(logicalKey) != nil
        case .course:
            return try loadCourseForSync(logicalKey) != nil
        case .videoPlaylist:
            return try loadVideoPlaylistForSync(logicalKey) != nil
        case .meetingGroup:
            return try loadMeetingGroupForSync(logicalKey) != nil
        case .hiddenSource:
            return try loadHiddenSourceForSync(logicalKey) != nil
        case .hiddenPodcastShow:
            return try loadHiddenPodcastShowForSync(logicalKey) != nil
        case .hiddenYouTubeChannel:
            return try loadHiddenYouTubeChannelForSync(logicalKey) != nil
        case .hiddenArtifact:
            return try loadHiddenArtifactForSync(logicalKey) != nil
        case .hiddenReviewSession:
            return try loadHiddenReviewSessionForSync(logicalKey) != nil
        case .dismissedSource:
            return try loadDismissedSourceForSync(logicalKey) != nil
        case .chatContext:
            return try loadChatContextForSync() != nil
        case .reviewSession:
            return try loadReviewSessionForSync(logicalKey) != nil
        case .memoryItem:
            return try loadMemoryItem(logicalKey) != nil
        case .memoryAttempt:
            return try loadMemoryAttempt(logicalKey) != nil
        case .sourceHighlight:
            return try sourceHighlight(id: logicalKey) != nil
        case .learningGoal:
            return try loadLearningGoalForSync(logicalKey) != nil
        case .artifact:
            return try loadArtifactForSync(logicalKey) != nil
        case .artifactComment:
            return try loadArtifactCommentForSync(logicalKey) != nil
        case .scheduledSource:
            return try hasScheduledSource(logicalKey)
        case .scheduledTask:
            return try hasScheduledTask(logicalKey)
        case .dayPlan:
            return try hasDayPlan(logicalKey)
        case .idea:
            return try hasIdea(logicalKey)
        case .walkthroughProgress:
            return try hasWalkthroughProgress(logicalKey)
        case .skill:
            return try hasSkill(logicalKey)
        case .researchDirection:
            return try hasResearchDirection(logicalKey)
        case .sourceIdea:
            return try hasSourceIdea(logicalKey)
        case .memoryReviewActivity:
            return try hasMemoryReviewActivity(logicalKey)
        case .videoCitedPaper:
            return try hasVideoCitedPaper(logicalKey)
        case .researchCanvas:
            return false  // Tombstoned: ResearchCanvas feature removed.
        case .aiUsageEvent:
            return try loadAIUsageEventForSync(logicalKey) != nil
        case .preference:
            return try loadPreferenceForSync(logicalKey) != nil
        case .team:
            return try loadTeam(logicalKey) != nil
        case .notebookTask:
            return try loadNotebookTask(logicalKey) != nil
        case .shareRequest:
            return try loadShareRequest(logicalKey) != nil
        }
    }

    func hasPendingSyncChange(entity: CloudKitSyncEntity, logicalKey: String) throws -> Bool {
        var found = false
        try queryBind("""
            SELECT 1
            FROM sync_changes AS changes
            WHERE changes.entity_type = ?
              AND changes.logical_key = ?
              AND NOT EXISTS (
                    SELECT 1
                    FROM sync_conflicts AS conflicts
                    WHERE conflicts.entity_type = changes.entity_type
                      AND conflicts.logical_key = changes.logical_key
                      AND conflicts.reason NOT LIKE '\(CloudKitInboundWebPDFRetry.reasonLikePattern)'
              )
              AND NOT (
                    changes.entity_type = 'memoryAttempt'
                    AND changes.operation = 'save'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM memory_attempts AS attempt
                        JOIN sync_metadata AS parent_metadata
                          ON parent_metadata.entity_type = 'memoryItem'
                         AND parent_metadata.logical_key = attempt.memory_item_id
                         AND parent_metadata.system_fields IS NOT NULL
                         AND parent_metadata.is_deleted = 0
                        WHERE attempt.id = changes.logical_key
                    )
              )
              AND NOT (
                    changes.entity_type = 'sourceHighlight'
                    AND changes.operation = 'save'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM source_highlights AS highlight
                        JOIN sync_metadata AS parent_metadata
                          ON parent_metadata.entity_type = 'source'
                         AND parent_metadata.logical_key = highlight.source_id
                         AND parent_metadata.system_fields IS NOT NULL
                         AND parent_metadata.is_deleted = 0
                        WHERE highlight.highlight_id = changes.logical_key
                    )
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
        }) { _ in
            found = true
        }
        return found
    }

    /// Whether the pending whole-record save changed only monotonic tutor state
    /// (completion, quiz evidence, or gaps), and therefore carries no editorial
    /// opinion about relationship membership during conflict resolution.
    func hasPendingTutorOnlySyncChange(
        entity: CloudKitSyncEntity,
        logicalKey: String
    ) throws -> Bool {
        var tutorOnly = false
        try queryBind("""
            SELECT tutor_only
            FROM sync_changes
            WHERE entity_type = ? AND logical_key = ? AND operation = 'save'
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, entity.rawValue)
            bind(statement, 2, logicalKey)
        }) { statement in
            tutorOnly = sqlite3_column_int(statement, 0) != 0
        }
        return tutorOnly
    }

    func loadPendingSyncOperation(entity: CloudKitSyncEntity, logicalKey: String) throws -> CloudKitSyncOperation? {
        var result: CloudKitSyncOperation?
        try queryBind("""
            SELECT changes.operation
            FROM sync_changes AS changes
            WHERE changes.entity_type = ?
              AND changes.logical_key = ?
              AND NOT EXISTS (
                    SELECT 1
                    FROM sync_conflicts AS conflicts
                    WHERE conflicts.entity_type = changes.entity_type
                      AND conflicts.logical_key = changes.logical_key
                      AND conflicts.reason NOT LIKE '\(CloudKitInboundWebPDFRetry.reasonLikePattern)'
              )
              AND NOT (
                    changes.entity_type = 'memoryAttempt'
                    AND changes.operation = 'save'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM memory_attempts AS attempt
                        JOIN sync_metadata AS parent_metadata
                          ON parent_metadata.entity_type = 'memoryItem'
                         AND parent_metadata.logical_key = attempt.memory_item_id
                         AND parent_metadata.system_fields IS NOT NULL
                         AND parent_metadata.is_deleted = 0
                        WHERE attempt.id = changes.logical_key
                    )
              )
              AND NOT (
                    changes.entity_type = 'sourceHighlight'
                    AND changes.operation = 'save'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM source_highlights AS highlight
                        JOIN sync_metadata AS parent_metadata
                          ON parent_metadata.entity_type = 'source'
                         AND parent_metadata.logical_key = highlight.source_id
                         AND parent_metadata.system_fields IS NOT NULL
                         AND parent_metadata.is_deleted = 0
                        WHERE highlight.highlight_id = changes.logical_key
                    )
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
        }) { stmt in
            if let raw = self.string(stmt, 0) {
                result = CloudKitSyncOperation(rawValue: raw)
            }
        }
        return result
    }

    /// Remove a queued pending change once its record has been confirmed by CloudKit.
    ///
    /// Pass `changedAt` (the `userModificationDate` carried on the sent record's
    /// descriptor) so an edit made *after* the batch snapshot but before this
    /// sent-event handler runs is not silently dropped: the row is deleted only
    /// when its `changed_at` is still at or before the confirmed change. When
    /// `changedAt` is nil the delete is unconditional (used for remote-apply and
    /// reconciliation paths that intend to clear regardless of local edits).
    func clearPendingSyncChange(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        changedAt: Date? = nil
    ) throws {
        if let changedAt {
            try execBind("""
                DELETE FROM sync_changes
                WHERE entity_type = ? AND logical_key = ? AND changed_at <= ?
            """) { stmt in
                bind(stmt, 1, entity.rawValue)
                bind(stmt, 2, logicalKey)
                sqlite3_bind_double(stmt, 3, changedAt.timeIntervalSinceReferenceDate)
            }
        } else {
            try execBind("DELETE FROM sync_changes WHERE entity_type = ? AND logical_key = ?") { stmt in
                bind(stmt, 1, entity.rawValue)
                bind(stmt, 2, logicalKey)
            }
        }
    }

    /// Clear a queued change by the only identifier CloudKit hands back.
    ///
    /// A `CKRecordID` is all a completed delete reports, and the entity/logical
    /// key normally come from `sync_metadata` — which a deleted row no longer
    /// has. Without this, a delete the server accepted stays queued forever and
    /// blocks everything behind it.
    func clearPendingSyncChange(recordName: String) throws {
        try execBind("DELETE FROM sync_changes WHERE record_name = ?") { stmt in
            bind(stmt, 1, recordName)
        }
    }

    func clearAllPendingSyncChanges() throws {
        try exec("DELETE FROM sync_changes")
    }

    func loadSyncMetadata(entity: CloudKitSyncEntity, logicalKey: String) throws -> CloudKitSyncMetadata? {
        var result: CloudKitSyncMetadata?
        try queryBind("""
            SELECT record_name, system_fields, user_modification_at, is_deleted,
                   zone_scope, zone_name, zone_owner_record_name
            FROM sync_metadata
            WHERE entity_type = ? AND logical_key = ?
        """, bind: { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
        }) { stmt in
            let recordName = self.string(stmt, 0) ?? CloudKitRecordMapper.recordName(for: entity, logicalKey: logicalKey)
            let systemFields = self.data(stmt, 1)
            let modifiedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            let isDeleted = sqlite3_column_int(stmt, 3) != 0
            result = CloudKitSyncMetadata(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                systemFieldsData: systemFields,
                userModificationDate: modifiedAt,
                isDeleted: isDeleted,
                home: self.zoneHome(stmt, scopeIndex: 4)
            )
        }
        return result
    }

    func loadSyncMetadata(recordName: String) throws -> CloudKitSyncMetadata? {
        var result: CloudKitSyncMetadata?
        try queryBind("""
            SELECT entity_type, logical_key, system_fields, user_modification_at, is_deleted,
                   zone_scope, zone_name, zone_owner_record_name
            FROM sync_metadata
            WHERE record_name = ?
        """, bind: { stmt in
            bind(stmt, 1, recordName)
        }) { stmt in
            guard let entityRaw = self.string(stmt, 0), let entity = CloudKitSyncEntity(rawValue: entityRaw) else {
                return
            }
            let logicalKey = self.string(stmt, 1) ?? recordName
            let systemFields = self.data(stmt, 2)
            let modifiedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            let isDeleted = sqlite3_column_int(stmt, 4) != 0
            result = CloudKitSyncMetadata(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                systemFieldsData: systemFields,
                userModificationDate: modifiedAt,
                isDeleted: isDeleted,
                home: self.zoneHome(stmt, scopeIndex: 5)
            )
        }
        return result
    }

    /// The record's metadata under its entity and key. A record name is one CloudKit record, so a row that
    /// holds the name under another key gives it up: a record whose payload now carries another key than the
    /// one its name was minted from (a dismissed URL another device rewrote to a library-relative path keeps
    /// the record it had) belongs to the key it carries now, as the applied row does.
    func saveSyncMetadata(_ metadata: CloudKitSyncMetadata) throws {
        try execBind("""
            DELETE FROM sync_metadata
            WHERE record_name = ? AND NOT (entity_type = ? AND logical_key = ?)
        """) { stmt in
            bind(stmt, 1, metadata.recordName)
            bind(stmt, 2, metadata.entity.rawValue)
            bind(stmt, 3, metadata.logicalKey)
        }
        try execBind("""
            INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at, is_deleted,
                                       zone_scope, zone_name, zone_owner_record_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                record_name = excluded.record_name,
                system_fields = excluded.system_fields,
                user_modification_at = excluded.user_modification_at,
                is_deleted = excluded.is_deleted,
                zone_scope = excluded.zone_scope,
                zone_name = excluded.zone_name,
                zone_owner_record_name = excluded.zone_owner_record_name
        """) { stmt in
            bind(stmt, 1, metadata.entity.rawValue)
            bind(stmt, 2, metadata.logicalKey)
            bind(stmt, 3, metadata.recordName)
            bind(stmt, 4, metadata.systemFieldsData)
            sqlite3_bind_double(stmt, 5, metadata.userModificationDate.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 6, metadata.isDeleted ? 1 : 0)
            bindZoneHome(stmt, metadata.home, scopeIndex: 7)
        }
    }

    /// Atomically remove a permanently divergent immutable save from the active
    /// queue and retain everything needed to diagnose or explicitly resolve it.
    /// This is the bounded failure mode for a deterministic record-name race:
    /// neither local nor server content is overwritten, and CKSyncEngine cannot
    /// spin on the same `serverRecordChanged` forever.
    func quarantineSyncConflict(_ conflict: CloudKitSyncConflict) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO sync_conflicts (
                    entity_type, logical_key, record_name, reason,
                    local_modification_at, server_modification_at, detected_at,
                    server_payload, server_system_fields,
                    zone_scope, zone_name, zone_owner_record_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                    record_name = excluded.record_name,
                    reason = excluded.reason,
                    local_modification_at = excluded.local_modification_at,
                    server_modification_at = excluded.server_modification_at,
                    detected_at = excluded.detected_at,
                    server_payload = COALESCE(
                        excluded.server_payload,
                        sync_conflicts.server_payload
                    ),
                    server_system_fields = COALESCE(
                        excluded.server_system_fields,
                        sync_conflicts.server_system_fields
                    ),
                    zone_scope = excluded.zone_scope,
                    zone_name = excluded.zone_name,
                    zone_owner_record_name = excluded.zone_owner_record_name
            """) { statement in
                bind(statement, 1, conflict.entity.rawValue)
                bind(statement, 2, conflict.logicalKey)
                bind(statement, 3, conflict.recordName)
                bind(statement, 4, conflict.reason)
                sqlite3_bind_double(
                    statement,
                    5,
                    conflict.localModificationDate.timeIntervalSinceReferenceDate
                )
                sqlite3_bind_double(
                    statement,
                    6,
                    conflict.serverModificationDate.timeIntervalSinceReferenceDate
                )
                sqlite3_bind_double(
                    statement,
                    7,
                    conflict.detectedAt.timeIntervalSinceReferenceDate
                )
                bind(statement, 8, conflict.serverPayload)
                bind(statement, 9, conflict.serverSystemFields)
                bindZoneHome(statement, conflict.home, scopeIndex: 10)
            }
            try clearPendingSyncChange(
                entity: conflict.entity,
                logicalKey: conflict.logicalKey
            )
            // Quarantine takes the record out of the retry queue, so nothing
            // will rebuild it and nothing else will ever resolve what it
            // staged. Leaving those rows behind is how a digest ends up
            // pending forever: `commitStagedAssetDigests` and
            // `clearStagedAssetDigests` only run off `savedRecords` and
            // `failedRecordSaves`, and a quarantined record reaches neither.
            try clearStagedAssetDigests(recordName: conflict.recordName)
            if conflict.entity == .memoryItem {
                var dependentAttempts: [(id: String, attemptedAt: Date)] = []
                try queryBind("""
                    SELECT id, attempted_at
                    FROM memory_attempts
                    WHERE memory_item_id = ?
                    ORDER BY id
                """, bind: { statement in
                    bind(statement, 1, conflict.logicalKey)
                }) { statement in
                    guard let id = self.string(statement, 0) else { return }
                    dependentAttempts.append((
                        id,
                        Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
                    ))
                }
                for attempt in dependentAttempts {
                    try upsertSyncConflictRow(CloudKitSyncConflict(
                        entity: .memoryAttempt,
                        logicalKey: attempt.id,
                        recordName: CloudKitRecordMapper.recordName(
                            for: .memoryAttempt,
                            logicalKey: attempt.id
                        ),
                        reason: "Blocked by divergent parent MemoryItem \(conflict.logicalKey).",
                        localModificationDate: attempt.attemptedAt,
                        serverModificationDate: conflict.serverModificationDate,
                        detectedAt: conflict.detectedAt,
                        serverPayload: nil,
                        serverSystemFields: nil
                    ))
                    try clearPendingSyncChange(
                        entity: .memoryAttempt,
                        logicalKey: attempt.id
                    )
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func upsertSyncConflictRow(_ conflict: CloudKitSyncConflict) throws {
        try execBind("""
            INSERT INTO sync_conflicts (
                entity_type, logical_key, record_name, reason,
                local_modification_at, server_modification_at, detected_at,
                server_payload, server_system_fields,
                zone_scope, zone_name, zone_owner_record_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                record_name = CASE
                    WHEN sync_conflicts.server_payload IS NOT NULL
                    THEN sync_conflicts.record_name
                    ELSE excluded.record_name
                END,
                reason = CASE
                    WHEN sync_conflicts.server_payload IS NOT NULL
                    THEN sync_conflicts.reason
                    ELSE excluded.reason
                END,
                local_modification_at = MAX(
                    sync_conflicts.local_modification_at,
                    excluded.local_modification_at
                ),
                server_modification_at = CASE
                    WHEN excluded.server_payload IS NOT NULL
                    THEN excluded.server_modification_at
                    ELSE sync_conflicts.server_modification_at
                END,
                detected_at = MIN(sync_conflicts.detected_at, excluded.detected_at),
                server_payload = COALESCE(
                    excluded.server_payload,
                    sync_conflicts.server_payload
                ),
                server_system_fields = COALESCE(
                    excluded.server_system_fields,
                    sync_conflicts.server_system_fields
                ),
                zone_scope = excluded.zone_scope,
                zone_name = excluded.zone_name,
                zone_owner_record_name = excluded.zone_owner_record_name
        """) { statement in
            bind(statement, 1, conflict.entity.rawValue)
            bind(statement, 2, conflict.logicalKey)
            bind(statement, 3, conflict.recordName)
            bind(statement, 4, conflict.reason)
            sqlite3_bind_double(
                statement,
                5,
                conflict.localModificationDate.timeIntervalSinceReferenceDate
            )
            sqlite3_bind_double(
                statement,
                6,
                conflict.serverModificationDate.timeIntervalSinceReferenceDate
            )
            sqlite3_bind_double(
                statement,
                7,
                conflict.detectedAt.timeIntervalSinceReferenceDate
            )
            bind(statement, 8, conflict.serverPayload)
            bind(statement, 9, conflict.serverSystemFields)
            bindZoneHome(statement, conflict.home, scopeIndex: 10)
        }
    }

    /// Persist a direct-fetch retry before CKSyncEngine is allowed to advance
    /// past the event. The row lives in SQLite, so an app restart or an already
    /// committed zone token cannot strand the browser's only PDF attachment.
    @discardableResult
    func saveInboundWebPDFRetry(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        recordName: String,
        failureReason: String,
        serverModificationDate: Date,
        serverPayload: Data?,
        serverSystemFields: Data?,
        failedAt: Date = Date()
    ) throws -> CloudKitInboundWebPDFRetry {
        var previousAttemptCount = 0
        var firstFailedAt = failedAt
        var existingPermanentReason: String?
        try queryBind("""
            SELECT reason, detected_at
            FROM sync_conflicts
            WHERE entity_type = ? AND logical_key = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, entity.rawValue)
            bind(statement, 2, logicalKey)
        }) { statement in
            guard let reason = self.string(statement, 0) else { return }
            if let decoded = CloudKitInboundWebPDFRetry.decodedReason(reason) {
                previousAttemptCount = decoded.attemptCount
                firstFailedAt = Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)
                )
            } else {
                existingPermanentReason = reason
            }
        }
        if let existingPermanentReason {
            throw KnowledgeStoreError.invalidData(
                "Cannot replace a permanent CloudKit quarantine with a transient retry: "
                    + existingPermanentReason
            )
        }

        let attemptCount = previousAttemptCount + 1
        let nextAttemptAt = failedAt.addingTimeInterval(
            CloudKitInboundWebPDFRetry.retryDelay(afterAttempt: attemptCount)
        )
        let storedReason = CloudKitInboundWebPDFRetry.encodedReason(
            attemptCount: attemptCount,
            failureReason: failureReason
        )
        try execBind("""
            INSERT INTO sync_conflicts (
                entity_type, logical_key, record_name, reason,
                local_modification_at, server_modification_at, detected_at,
                server_payload, server_system_fields
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                record_name = excluded.record_name,
                reason = excluded.reason,
                local_modification_at = excluded.local_modification_at,
                server_modification_at = excluded.server_modification_at,
                detected_at = MIN(sync_conflicts.detected_at, excluded.detected_at),
                server_payload = COALESCE(excluded.server_payload, sync_conflicts.server_payload),
                server_system_fields = COALESCE(
                    excluded.server_system_fields,
                    sync_conflicts.server_system_fields
                )
        """) { statement in
            bind(statement, 1, entity.rawValue)
            bind(statement, 2, logicalKey)
            bind(statement, 3, recordName)
            bind(statement, 4, storedReason)
            sqlite3_bind_double(statement, 5, nextAttemptAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(
                statement,
                6,
                serverModificationDate.timeIntervalSinceReferenceDate
            )
            sqlite3_bind_double(statement, 7, firstFailedAt.timeIntervalSinceReferenceDate)
            bind(statement, 8, serverPayload)
            bind(statement, 9, serverSystemFields)
        }
        return CloudKitInboundWebPDFRetry(
            entity: entity,
            logicalKey: logicalKey,
            recordName: recordName,
            failureReason: failureReason,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            serverModificationDate: serverModificationDate,
            firstFailedAt: firstFailedAt,
            serverPayload: serverPayload,
            serverSystemFields: serverSystemFields
        )
    }

    func loadInboundWebPDFRetries(
        dueAt date: Date? = nil,
        limit: Int = 25
    ) throws -> [CloudKitInboundWebPDFRetry] {
        let boundedLimit = max(1, min(limit, 100))
        var result: [CloudKitInboundWebPDFRetry] = []
        var sql = """
            SELECT entity_type, logical_key, record_name, reason,
                   local_modification_at, server_modification_at, detected_at,
                   server_payload, server_system_fields
            FROM sync_conflicts
            WHERE reason LIKE ?
        """
        if date != nil { sql += " AND local_modification_at <= ?" }
        sql += " ORDER BY local_modification_at, record_name LIMIT \(boundedLimit)"
        try queryBind(sql, bind: { statement in
            bind(statement, 1, CloudKitInboundWebPDFRetry.reasonLikePattern)
            if let date {
                sqlite3_bind_double(statement, 2, date.timeIntervalSinceReferenceDate)
            }
        }) { statement in
            guard let entityRaw = self.string(statement, 0),
                  let entity = CloudKitSyncEntity(rawValue: entityRaw),
                  let logicalKey = self.string(statement, 1),
                  let recordName = self.string(statement, 2),
                  let storedReason = self.string(statement, 3),
                  let decoded = CloudKitInboundWebPDFRetry.decodedReason(storedReason) else {
                return
            }
            result.append(CloudKitInboundWebPDFRetry(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                failureReason: decoded.failureReason,
                attemptCount: decoded.attemptCount,
                nextAttemptAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)
                ),
                serverModificationDate: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)
                ),
                firstFailedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)
                ),
                serverPayload: self.data(statement, 7),
                serverSystemFields: self.data(statement, 8)
            ))
        }
        return result
    }

    func nextInboundWebPDFRetryDate() throws -> Date? {
        var result: Date?
        try queryBind("""
            SELECT MIN(local_modification_at)
            FROM sync_conflicts
            WHERE reason LIKE ?
        """, bind: { statement in
            bind(statement, 1, CloudKitInboundWebPDFRetry.reasonLikePattern)
        }) { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return }
            result = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
        }
        return result
    }

    func loadSyncConflicts(limit: Int? = nil) throws -> [CloudKitSyncConflict] {
        var conflicts: [CloudKitSyncConflict] = []
        let limitClause = limit.map { "LIMIT \(max(0, $0))" } ?? ""
        try queryBind("""
            SELECT entity_type, logical_key, record_name, reason,
                   local_modification_at, server_modification_at, detected_at,
                   server_payload, server_system_fields,
                   zone_scope, zone_name, zone_owner_record_name
            FROM sync_conflicts
            WHERE reason NOT LIKE ?
            ORDER BY detected_at DESC, entity_type, logical_key
            \(limitClause)
        """, bind: { statement in
            bind(statement, 1, CloudKitInboundWebPDFRetry.reasonLikePattern)
        }) { statement in
            guard let entityRaw = self.string(statement, 0),
                  let entity = CloudKitSyncEntity(rawValue: entityRaw),
                  let logicalKey = self.string(statement, 1),
                  let recordName = self.string(statement, 2),
                  let reason = self.string(statement, 3) else { return }
            conflicts.append(CloudKitSyncConflict(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                reason: reason,
                localModificationDate: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)
                ),
                serverModificationDate: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)
                ),
                detectedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)
                ),
                serverPayload: self.data(statement, 7),
                serverSystemFields: self.data(statement, 8),
                home: self.zoneHome(statement, scopeIndex: 9)
            ))
        }
        return conflicts
    }

    func loadSyncConflict(recordName: String) throws -> CloudKitSyncConflict? {
        var result: CloudKitSyncConflict?
        try queryBind("""
            SELECT entity_type, logical_key, record_name, reason,
                   local_modification_at, server_modification_at, detected_at,
                   server_payload, server_system_fields,
                   zone_scope, zone_name, zone_owner_record_name
            FROM sync_conflicts
            WHERE record_name = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, recordName)
        }) { statement in
            guard let entityRaw = self.string(statement, 0),
                  let entity = CloudKitSyncEntity(rawValue: entityRaw),
                  let logicalKey = self.string(statement, 1),
                  let storedRecordName = self.string(statement, 2),
                  let reason = self.string(statement, 3) else { return }
            result = CloudKitSyncConflict(
                entity: entity,
                logicalKey: logicalKey,
                recordName: storedRecordName,
                reason: reason,
                localModificationDate: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)
                ),
                serverModificationDate: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)
                ),
                detectedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)
                ),
                serverPayload: self.data(statement, 7),
                serverSystemFields: self.data(statement, 8),
                home: self.zoneHome(statement, scopeIndex: 9)
            )
        }
        return result
    }

    /// Consume an authoritative server tombstone for a quarantined immutable
    /// attempt without discarding evidence that still belongs to a conflicted
    /// local curriculum. A server-only child is also settled here so its saved
    /// payload cannot be replayed after the parent winner is adopted.
    @discardableResult
    func resolveQuarantinedMemoryAttemptServerDeletion(
        recordName: String,
        deletedAt: Date
    ) throws -> Bool {
        guard let conflict = try loadSyncConflict(recordName: recordName),
              conflict.entity == .memoryAttempt else {
            return false
        }
        let localAttempt = try loadMemoryAttempt(conflict.logicalKey)
        let belongsToConflictedLocalCurriculum: Bool
        if let localAttempt {
            belongsToConflictedLocalCurriculum = try hasSyncConflict(
                entity: .memoryItem,
                logicalKey: localAttempt.memoryItemID
            )
        } else {
            belongsToConflictedLocalCurriculum = true
        }
        guard belongsToConflictedLocalCurriculum else { return false }

        try exec("BEGIN IMMEDIATE")
        do {
            try saveSyncMetadata(CloudKitSyncMetadata(
                entity: .memoryAttempt,
                logicalKey: conflict.logicalKey,
                recordName: conflict.recordName,
                systemFieldsData: nil,
                userModificationDate: deletedAt,
                isDeleted: true
            ))
            try clearPendingSyncChange(
                entity: .memoryAttempt,
                logicalKey: conflict.logicalKey
            )
            try clearSyncConflict(
                entity: .memoryAttempt,
                logicalKey: conflict.logicalKey
            )
            try exec("COMMIT")
            return true
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func hasSyncConflict(entity: CloudKitSyncEntity, logicalKey: String) throws -> Bool {
        var found = false
        try queryBind("""
            SELECT 1 FROM sync_conflicts
            WHERE entity_type = ? AND logical_key = ?
              AND reason NOT LIKE ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, entity.rawValue)
            bind(statement, 2, logicalKey)
            bind(statement, 3, CloudKitInboundWebPDFRetry.reasonLikePattern)
        }) { _ in
            found = true
        }
        return found
    }

    /// Re-arm every save iCloud refused. Kept as the focused compatibility seam
    /// used by existing storage tests and callers that only want save work.
    @discardableResult
    func requeueRejectedSaveQuarantines(at date: Date = Date()) throws -> [CloudKitSyncEntity: Int] {
        try requeueRejectedChangeQuarantines(at: date, savesOnly: true)
    }

    /// Re-arm every locally parked change, preserving whether it was a save or
    /// delete. The conflict row must be removed first because queue writers
    /// deliberately suppress unresolved quarantines. Engine start and the
    /// learner's explicit Retry action call this once; background sync never
    /// turns a deterministic refusal back into a hot loop.
    @discardableResult
    func requeueRejectedChangeQuarantines(
        at date: Date = Date(),
        savesOnly: Bool = false
    ) throws -> [CloudKitSyncEntity: Int] {
        var rearmed: [(
            entity: CloudKitSyncEntity,
            logicalKey: String,
            operation: CloudKitSyncOperation
        )] = []
        try queryBind("""
            SELECT entity_type, logical_key, reason
            FROM sync_conflicts
            WHERE reason LIKE ? OR reason LIKE ?
            ORDER BY detected_at
        """, bind: { statement in
            bind(statement, 1, CloudKitRejectedSaveQuarantine.reasonLikePattern)
            bind(statement, 2, CloudKitRejectedChangeQuarantine.reasonLikePattern)
        }) { statement in
            guard let entityRaw = self.string(statement, 0),
                  let entity = CloudKitSyncEntity(rawValue: entityRaw),
                  let logicalKey = self.string(statement, 1),
                  let reason = self.string(statement, 2) else { return }
            let operation: CloudKitSyncOperation
            if CloudKitRejectedSaveQuarantine.decodedReason(reason) != nil {
                operation = .save
            } else if let rejected = CloudKitRejectedChangeQuarantine.decodedReason(reason) {
                operation = rejected.operation
            } else {
                return
            }
            guard !savesOnly || operation == .save else { return }
            rearmed.append((entity, logicalKey, operation))
        }
        guard !rearmed.isEmpty else { return [:] }

        var counts: [CloudKitSyncEntity: Int] = [:]
        try exec("BEGIN IMMEDIATE")
        do {
            for record in rearmed {
                try clearSyncConflict(entity: record.entity, logicalKey: record.logicalKey)
                switch record.operation {
                case .save:
                    try upsertSyncSave(
                        entity: record.entity,
                        logicalKey: record.logicalKey,
                        at: date,
                        preserveExistingScope: true
                    )
                case .delete:
                    try enqueueRecordDeletion(
                        entity: record.entity,
                        logicalKey: record.logicalKey,
                        at: date
                    )
                }
                counts[record.entity, default: 0] += 1
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return counts
    }

    func clearSyncConflict(entity: CloudKitSyncEntity, logicalKey: String) throws {
        try execBind("""
            DELETE FROM sync_conflicts
            WHERE entity_type = ? AND logical_key = ?
        """) { statement in
            bind(statement, 1, entity.rawValue)
            bind(statement, 2, logicalKey)
        }
    }

    func clearSyncMetadata(entity: CloudKitSyncEntity, logicalKey: String) throws {
        // Digests describe what the *server* holds. Dropping the metadata means
        // the server copy is gone or unknown, so the asset must upload again.
        try execBind("""
            DELETE FROM sync_asset_digests
            WHERE record_name IN (
                SELECT record_name FROM sync_metadata
                WHERE entity_type = ? AND logical_key = ?
            )
        """) { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
        }
        try execBind("DELETE FROM sync_metadata WHERE entity_type = ? AND logical_key = ?") { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
        }
    }

    func clearAllSyncMetadata() throws {
        try exec("DELETE FROM sync_asset_digests")
        try exec("DELETE FROM sync_metadata")
        try exec("DELETE FROM sync_conflicts")
    }

    /// Move the local sync replica to another CloudKit container environment.
    ///
    /// Development and Production never share records or system fields. Keep
    /// SQLite as the source of truth, forget environment-specific CKRecord
    /// metadata and asset acknowledgements, and durably queue every local
    /// record that the previous environment had acknowledged — live rows as
    /// saves, tombstones as deletes. Missing local rows are discarded by
    /// `discardPendingSavesMissingLocalRecords`; rows that never had metadata
    /// are added by the ordinary bootstrap pass.
    ///
    /// Deletions survive the move. They used to be dropped here as if they were
    /// server bookkeeping, and that is how a deleted Notebook came back: clearing
    /// `sync_changes` threw away a delete that had not flushed yet, deleting the
    /// tombstone left nothing to refuse the record with, and the copy still
    /// sitting in the other environment's database was applied on the next fetch
    /// as a brand-new Notebook. A tombstone is the learner's intent, not a
    /// CKRecord detail.
    ///
    /// No application row or source body is read here. The work is one
    /// transaction of set-based metadata statements, so launch never loops
    /// source-by-source and CKSyncEngine can drain the resulting queue later.
    @discardableResult
    func rebaseCloudKitStateForContainerEnvironment() throws -> Int {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM sync_asset_digests")
            try exec("DELETE FROM sync_changes")
            try exec("DELETE FROM sync_conflicts")
            // Only the CKRecord system fields are environment-specific. Keep
            // `is_deleted` exactly as it stands so every deletion is requeued
            // below; a record the new environment never held answers
            // `.unknownItem`, which the send path already settles as done.
            try exec("UPDATE sync_metadata SET system_fields = NULL")
            try exec("""
                INSERT INTO sync_changes (entity_type, logical_key, record_name, operation, changed_at)
                SELECT entity_type,
                       logical_key,
                       record_name,
                       CASE WHEN is_deleted = 1 THEN 'delete' ELSE 'save' END,
                       user_modification_at
                FROM sync_metadata
            """)
            // A Production database needs the encrypted record payload before
            // it needs optional original-PDF and thumbnail assets. Existing
            // paper saves can trigger iCloud downloads while their CKRecord is
            // assembled, so put this one migration cohort behind lightweight
            // records. Any paper edit made after this transaction gets its real
            // current timestamp and immediately regains ordinary recent-first
            // priority.
            try exec("""
                UPDATE sync_changes
                SET changed_at = -1
                WHERE entity_type = 'source'
                  AND logical_key IN (
                    SELECT id FROM sources WHERE source_type = 'paper'
                  )
            """)
            try exec("DELETE FROM sync_engine_states")
            var queued = 0
            try query("SELECT COUNT(*) FROM sync_changes") { stmt in
                queued = Int(sqlite3_column_int64(stmt, 0))
            }
            try exec("COMMIT")
            if queued > 0 {
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            return queued
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Asset digests

    /// The digests CloudKit has acknowledged for one record, keyed by field.
    /// Only committed values are returned; a staged value from an in-flight or
    /// abandoned save is deliberately invisible, so an interrupted upload
    /// re-sends rather than being silently skipped.
    /// Marks a record whose save deliberately shipped without its content
    /// assets. No real asset field is named this, so `makeRecord` never
    /// consults it, and the non-null digest keeps the row clear of the
    /// `digest IS NULL` sweep that follows every save.
    static let deferredContentMarkerField = "__deferredContent"
    private static let deferredContentMarkerDigest = "deferred"

    /// Remember that this record still owes CloudKit its content.
    func markContentDeferred(recordName: String) throws {
        try execBind("""
            INSERT INTO sync_asset_digests (record_name, field, digest, pending_digest)
            VALUES (?, ?, ?, NULL)
            ON CONFLICT(record_name, field) DO UPDATE SET digest = excluded.digest
        """) { stmt in
            bind(stmt, 1, recordName)
            bind(stmt, 2, Self.deferredContentMarkerField)
            bind(stmt, 3, Self.deferredContentMarkerDigest)
        }
    }

    func clearContentDeferred(recordName: String) throws {
        try execBind("DELETE FROM sync_asset_digests WHERE record_name = ? AND field = ?") { stmt in
            bind(stmt, 1, recordName)
            bind(stmt, 2, Self.deferredContentMarkerField)
        }
    }

    func deferredContentRecordCount() throws -> Int {
        var count = 0
        try queryBind("""
            SELECT COUNT(*) FROM sync_asset_digests WHERE field = ?
        """, bind: { stmt in
            bind(stmt, 1, Self.deferredContentMarkerField)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Put a bounded slice of the records that shipped without content back on
    /// the outbound queue. Set-based and idempotent, so an interrupted content
    /// pass simply resumes on the next call.
    @discardableResult
    func enqueueDeferredContentRecords(limit: Int, now: Date = Date()) throws -> Int {
        let names = try deferredContentRecordNames(limit: limit)
        guard !names.isEmpty else { return 0 }
        for recordName in names {
            try execBind("""
                INSERT INTO sync_changes (entity_type, logical_key, record_name, operation, changed_at)
                SELECT entity_type, logical_key, record_name, 'save', ?
                FROM sync_metadata
                WHERE record_name = ? AND is_deleted = 0
                ON CONFLICT(entity_type, logical_key) DO NOTHING
            """) { stmt in
                bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                bind(stmt, 2, recordName)
            }
            try clearContentDeferred(recordName: recordName)
        }
        return names.count
    }

    private func deferredContentRecordNames(limit: Int) throws -> [String] {
        var result: [String] = []
        try queryBind("""
            SELECT record_name FROM sync_asset_digests
            WHERE field = ? LIMIT \(max(0, limit))
        """, bind: { stmt in
            bind(stmt, 1, Self.deferredContentMarkerField)
        }) { stmt in
            if let name = self.string(stmt, 0) { result.append(name) }
        }
        return result
    }

    func committedAssetDigests(recordName: String) throws -> [String: String] {
        var result: [String: String] = [:]
        try queryBind("""
            SELECT field, digest FROM sync_asset_digests
            WHERE record_name = ? AND digest IS NOT NULL AND field <> '\(Self.deferredContentMarkerField)'
        """, bind: { stmt in
            bind(stmt, 1, recordName)
        }) { stmt in
            guard let field = self.string(stmt, 0), let digest = self.string(stmt, 1) else { return }
            result[field] = digest
        }
        return result
    }

    /// What each asset field last *staged* and CloudKit has not yet acknowledged.
    ///
    /// The counterpart to `committedAssetDigests`, and the difference between the
    /// two is the whole state machine: a committed digest asserts the server holds
    /// those bytes, a pending one asserts only that a save carrying them was built.
    /// A row that keeps a pending digest across passes is a save the engine never
    /// resolved either way — neither `commitStagedAssetDigests` nor
    /// `clearStagedAssetDigests` ran — which is the leading indicator of a write
    /// that is being refused rather than rejected.
    func pendingAssetDigests(recordName: String) throws -> [String: String] {
        var result: [String: String] = [:]
        try queryBind("""
            SELECT field, pending_digest FROM sync_asset_digests
            WHERE record_name = ? AND pending_digest IS NOT NULL
              AND field <> '\(Self.deferredContentMarkerField)'
        """, bind: { stmt in
            bind(stmt, 1, recordName)
        }) { stmt in
            guard let field = self.string(stmt, 0), let digest = self.string(stmt, 1) else { return }
            result[field] = digest
        }
        return result
    }

    /// How much asset staging has gone unacknowledged, store-wide.
    ///
    /// Deliberately a different question from `pendingAssetDigests`, which asks
    /// what one record staged. A pending digest on its own cannot support an
    /// alarm: a batch in flight right now and a batch abandoned on 2026-08-30
    /// look identical in a snapshot, and reading the raw pending count as
    /// "stuck" overstates it every time a send is mid-air. Age and attempt
    /// count are what separate them, so the threshold lives in the query rather
    /// than in each caller.
    ///
    /// `staged_attempts` is the load-bearing half. A save that fails visibly is
    /// already handled — `clearStagedAssetDigests` runs and the row resets. The
    /// case this exists for is a save that returns neither `savedRecords` nor
    /// `failedRecordSaves`, where nothing resets anything and the same content
    /// is re-staged on every pass. That shape has no error to report, which is
    /// why no `last_error` column accompanies these two: it would be NULL for
    /// precisely the population worth alarming on.
    func stalledAssetStagingSummary(
        stagedBefore: Date,
        minimumAttempts: Int = 2
    ) throws -> CloudKitStalledAssetStaging {
        var summary = CloudKitStalledAssetStaging.none
        try queryBind("""
            SELECT COUNT(DISTINCT record_name),
                   COUNT(*),
                   MIN(first_staged_at),
                   MAX(staged_attempts)
            FROM sync_asset_digests
            WHERE pending_digest IS NOT NULL
              AND field <> '\(Self.deferredContentMarkerField)'
              AND staged_attempts >= ?
              AND first_staged_at IS NOT NULL
              AND first_staged_at <= ?
        """, bind: { stmt in
            bind(stmt, 1, max(0, minimumAttempts))
            bind(stmt, 2, stagedBefore.timeIntervalSinceReferenceDate)
        }) { stmt in
            let records = Int(sqlite3_column_int64(stmt, 0))
            guard records > 0 else { return }
            let oldest: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            summary = CloudKitStalledAssetStaging(
                recordCount: records,
                fieldCount: Int(sqlite3_column_int64(stmt, 1)),
                oldestStagedAt: oldest,
                maxAttempts: Int(sqlite3_column_int64(stmt, 3))
            )
        }
        return summary
    }

    /// Record what this save is about to upload for each asset field. Fields
    /// whose asset is being skipped must still be staged with their existing
    /// digest so `commitStagedAssetDigests` can promote the whole set at once.
    func stageAssetDigests(_ digests: [String: String], recordName: String) throws {
        guard !digests.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        for (field, digest) in digests {
            try execBind("""
                INSERT INTO sync_asset_digests (
                    record_name, field, digest, pending_digest,
                    staged_attempts, first_staged_at, last_staged_at
                )
                VALUES (?, ?, NULL, ?, 1, ?, ?)
                ON CONFLICT(record_name, field) DO UPDATE SET
                    pending_digest = excluded.pending_digest,
                    -- Counting every staging pass, not just the ones that change
                    -- the digest, is the point: a record rebuilt forty times for
                    -- identical content is exactly the case that was invisible.
                    staged_attempts = sync_asset_digests.staged_attempts + 1,
                    first_staged_at = COALESCE(sync_asset_digests.first_staged_at, excluded.first_staged_at),
                    last_staged_at = excluded.last_staged_at
            """) { stmt in
                bind(stmt, 1, recordName)
                bind(stmt, 2, field)
                bind(stmt, 3, digest)
                bind(stmt, 4, now)
                bind(stmt, 5, now)
            }
        }
    }

    /// Promote staged digests once CloudKit has accepted the record.
    func commitStagedAssetDigests(recordName: String) throws {
        try execBind("""
            UPDATE sync_asset_digests
            SET digest = pending_digest, pending_digest = NULL,
                staged_attempts = 0, first_staged_at = NULL, last_staged_at = NULL
            WHERE record_name = ? AND pending_digest IS NOT NULL
        """) { stmt in
            bind(stmt, 1, recordName)
        }
        try execBind("DELETE FROM sync_asset_digests WHERE record_name = ? AND digest IS NULL") { stmt in
            bind(stmt, 1, recordName)
        }
    }

    /// Drop staged digests after a failed save, leaving the last acknowledged
    /// state intact so the next attempt re-uploads whatever actually changed.
    func clearStagedAssetDigests(recordName: String) throws {
        try execBind("""
            UPDATE sync_asset_digests
            SET pending_digest = NULL,
                staged_attempts = 0, first_staged_at = NULL, last_staged_at = NULL
            WHERE record_name = ?
        """) { stmt in
            bind(stmt, 1, recordName)
        }
        try execBind("DELETE FROM sync_asset_digests WHERE record_name = ? AND digest IS NULL") { stmt in
            bind(stmt, 1, recordName)
        }
    }

    /// Drop staged digests belonging to records that are no longer queued.
    ///
    /// Two exit paths used to strand them. A quarantined save and a save
    /// discarded for a missing local row both left `sync_changes` while their
    /// `pending_digest` rows stayed set, and because only `savedRecords` and
    /// `failedRecordSaves` ever resolve staging, nothing afterwards could clear
    /// them. Both paths now clear as they go; this repairs what they already
    /// left behind.
    ///
    /// Safe set-wise only because it runs inside the migration transaction at
    /// launch, before any send: a record absent from the queue then cannot be
    /// a save in flight. Committed digests are untouched, so a repaired record
    /// re-uploads only what actually changed if it is ever queued again.
    @discardableResult
    func repairOrphanedAssetStaging() throws -> Int {
        var repaired = 0
        try query("""
            SELECT COUNT(*) FROM sync_asset_digests
            WHERE pending_digest IS NOT NULL
              AND record_name NOT IN (SELECT record_name FROM sync_changes)
        """) { stmt in
            repaired = Int(sqlite3_column_int64(stmt, 0))
        }
        guard repaired > 0 else { return 0 }
        try exec("""
            UPDATE sync_asset_digests
            SET pending_digest = NULL,
                staged_attempts = 0, first_staged_at = NULL, last_staged_at = NULL
            WHERE pending_digest IS NOT NULL
              AND record_name NOT IN (SELECT record_name FROM sync_changes)
        """)
        // Scoped to rows that now carry neither digest. An unqualified
        // `digest IS NULL` would also delete the staging of every record still
        // queued and legitimately mid-flight, which is the opposite of a repair.
        try exec("""
            DELETE FROM sync_asset_digests
            WHERE digest IS NULL AND pending_digest IS NULL
        """)
        return repaired
    }

    /// Forget every acknowledged digest, forcing a full asset re-upload. Used
    /// when the whole zone is re-enqueued because the server copy is gone.
    func clearAllAssetDigests() throws {
        try exec("DELETE FROM sync_asset_digests")
    }

    /// Forget the acknowledged digests for specific asset fields of one record,
    /// so the next save re-uploads them even though the local file has not moved.
    ///
    /// A digest asserts what the *server* holds, and `makeRecord` skips any field
    /// whose digest is unchanged. A one-time republish nudge exists precisely
    /// because that assertion is wrong — the server's copy is absent, or another
    /// Mac erased it — so marking the record changed without clearing the digest
    /// queues a save that deliberately omits the very asset it was queued to
    /// restore. That is how the book-cover nudge repaired nothing on the only Mac
    /// that still had the covers. Same rule `clearSyncMetadata` already follows.
    ///
    /// Field-scoped on purpose: a record usually carries several assets, and a
    /// nudge is only ever evidence about the one field it exists to restore.
    /// Republish one article's reader document after it is rewritten locally.
    ///
    /// `markRecordChanged` alone is not enough. `sync_asset_digests` records
    /// what the server already holds, and an unchanged digest row makes the
    /// upload a no-op — the failure mode that made every earlier one-time
    /// republish nudge silently do nothing.
    func republishArticleReaderDocument(sourceID: String) throws {
        try invalidateAssetDigests(
            recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID),
            fields: [CKRecord.FieldKey.sourceReaderHTMLAsset]
        )
        try markRecordChanged(entity: .source, logicalKey: sourceID)
    }

    func invalidateAssetDigests(recordName: String, fields: [String]) throws {
        guard !fields.isEmpty else { return }
        let placeholders = fields.map { _ in "?" }.joined(separator: ", ")
        try execBind("""
            DELETE FROM sync_asset_digests
            WHERE record_name = ? AND field IN (\(placeholders))
        """) { stmt in
            bind(stmt, 1, recordName)
            for (index, field) in fields.enumerated() {
                bind(stmt, index + 2, field)
            }
        }
    }

    /// One serialized CKSyncEngine state per database scope: the private
    /// database that holds the learner's own zone and the teams they own, and
    /// the shared database that carries the teams they joined.
    func saveSyncEngineState(
        _ serialization: CKSyncEngine.State.Serialization?,
        scope: CloudKitZoneHome.Scope = .privateScope
    ) throws {
        let data = try serialization.map { try JSONEncoder().encode($0) }
        try execBind("""
            INSERT INTO sync_engine_states (scope, state_serialization)
            VALUES (?, ?)
            ON CONFLICT(scope) DO UPDATE SET state_serialization = excluded.state_serialization
        """) { stmt in
            bind(stmt, 1, scope.rawValue)
            bind(stmt, 2, data)
        }
    }

    func loadSyncEngineState(
        scope: CloudKitZoneHome.Scope = .privateScope
    ) throws -> CKSyncEngine.State.Serialization? {
        var result: CKSyncEngine.State.Serialization?
        try queryBind("SELECT state_serialization FROM sync_engine_states WHERE scope = ?", bind: { stmt in
            bind(stmt, 1, scope.rawValue)
        }) { stmt in
            guard let data = self.data(stmt, 0) else { return }
            result = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        return result
    }

    func loadSourceForSync(_ sourceID: String) throws -> StudioArticle? {
        var article: StudioArticle?
        let sql = "SELECT \(Self.sourceColumns) \(Self.sourceJoins) WHERE sp.id = ? LIMIT 1"
        try queryBind(sql, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            article = readSourceRow(stmt)
            article?.content = try? loadSourceContent(sourceID)
            article?.podcastMatch = nil
            article?.podcastMatchTrackId = nil
        }
        return article
    }

    func loadPodcastRawTTML(_ sourceID: String) throws -> String? {
        var rawTTML: String?
        try queryBind("SELECT raw_ttml FROM podcasts WHERE source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            rawTTML = string(stmt, 0)
        }
        return rawTTML
    }

    func loadBookForSync(_ name: String) throws -> CloudKitBookPayload? {
        var payload: CloudKitBookPayload?
        let bookColumns = try tableColumnNames("books")
        let subtitleExpression = bookColumns.contains("subtitle") ? "subtitle" : "NULL AS subtitle"
        let editionExpression = bookColumns.contains("edition") ? "edition" : "NULL AS edition"
        try queryBind("""
            SELECT id, title, \(subtitleExpression), author, \(editionExpression), cover_path, kind
            FROM books
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let title = self.string(stmt, 1) else { return }
            payload = CloudKitBookPayload(
                id: id,
                title: title,
                subtitle: self.string(stmt, 2),
                author: self.string(stmt, 3),
                edition: self.string(stmt, 4),
                coverPath: self.string(stmt, 5),
                kind: self.string(stmt, 6)
            )
        }
        return payload
    }

    func loadCourseForSync(_ name: String) throws -> CloudKitCoursePayload? {
        var payload: CloudKitCoursePayload?
        let lecturesForCourse = try loadCourseLectures().filter { $0.courseName == name }
        let lectureIds = Set(lecturesForCourse.map(\.id))
        let itemsForCourse = try loadCourseLectureItems().filter { lectureIds.contains($0.lectureId) }
        let quizzesForCourse = try loadCourseQuizzes(courseID: name)
        let unitsForCourse = try loadSourceUnits(ids: itemsForCourse.compactMap(\.sourceUnitId))
        try queryBind("""
            SELECT id, title, course_code, institution, instructors, playlist_url,
                   is_hidden, pending_playlist_import
            FROM courses
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            guard let courseID = self.string(stmt, 0),
                  let title = self.string(stmt, 1) else { return }
            payload = CloudKitCoursePayload(
                id: courseID,
                title: title,
                courseCode: self.string(stmt, 2),
                institution: self.string(stmt, 3),
                instructors: self.string(stmt, 4),
                playlistURL: self.string(stmt, 5),
                isHidden: sqlite3_column_int(stmt, 6) != 0,
                pendingPlaylistImport: sqlite3_column_int(stmt, 7) != 0,
                lectures: lecturesForCourse,
                lectureItems: itemsForCourse,
                quizzes: quizzesForCourse,
                sourceUnits: unitsForCourse
            )
        }
        return payload
    }

    func loadDismissedSourceForSync(_ url: String) throws -> CloudKitDismissedSourcePayload? {
        var payload: CloudKitDismissedSourcePayload?
        try queryBind("""
            SELECT url, title, dismissed_at
            FROM dismissed_sources
            WHERE url = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, url)
        }) { stmt in
            guard let persistedURL = self.string(stmt, 0) else { return }
            payload = CloudKitDismissedSourcePayload(
                url: persistedURL,
                title: self.string(stmt, 1),
                dismissedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            )
        }
        return payload
    }

    func loadHiddenSourceForSync(_ sourceID: String) throws -> CloudKitHiddenSourcePayload? {
        var payload: CloudKitHiddenSourcePayload?
        try queryBind("""
            SELECT hs.source_id, hs.hidden_at, sp.url, sp.normalized_url
            FROM hidden_sources hs
            LEFT JOIN source_projection sp ON sp.id = hs.source_id
            WHERE hs.source_id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            payload = CloudKitHiddenSourcePayload(
                sourceID: id,
                hiddenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                url: self.string(stmt, 2),
                normalizedURL: self.string(stmt, 3)
            )
        }
        return payload
    }

    func loadHiddenPodcastShowForSync(_ showName: String) throws -> CloudKitHiddenPodcastShowPayload? {
        var payload: CloudKitHiddenPodcastShowPayload?
        try queryBind("""
            SELECT show_name, hidden_at
            FROM hidden_podcast_shows
            WHERE show_name = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, showName)
        }) { stmt in
            guard let name = self.string(stmt, 0) else { return }
            payload = CloudKitHiddenPodcastShowPayload(
                showName: name,
                hiddenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            )
        }
        return payload
    }

    func loadHiddenArtifactForSync(_ artifactID: String) throws -> CloudKitHiddenArtifactPayload? {
        var payload: CloudKitHiddenArtifactPayload?
        try queryBind("""
            SELECT artifact_id, hidden_at
            FROM hidden_artifacts
            WHERE artifact_id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, artifactID)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            payload = CloudKitHiddenArtifactPayload(
                artifactID: id,
                hiddenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            )
        }
        return payload
    }

    func loadHiddenReviewSessionForSync(_ sessionID: String) throws -> CloudKitHiddenReviewSessionPayload? {
        var payload: CloudKitHiddenReviewSessionPayload?
        try queryBind("""
            SELECT session_id, hidden_at
            FROM hidden_review_sessions
            WHERE session_id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            payload = CloudKitHiddenReviewSessionPayload(
                sessionID: id,
                hiddenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            )
        }
        return payload
    }

    func loadHiddenYouTubeChannelForSync(_ channelName: String) throws -> CloudKitHiddenYouTubeChannelPayload? {
        var payload: CloudKitHiddenYouTubeChannelPayload?
        try queryBind("""
            SELECT channel_name, hidden_at
            FROM hidden_youtube_channels
            WHERE channel_name = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, channelName)
        }) { stmt in
            guard let name = self.string(stmt, 0) else { return }
            payload = CloudKitHiddenYouTubeChannelPayload(
                channelName: name,
                hiddenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            )
        }
        return payload
    }

    func loadChatContextForSync() throws -> CloudKitChatContextPayload? {
        guard let sourceIDs = try loadContextSourceIds() else { return nil }
        return CloudKitChatContextPayload(
            key: CloudKitRecordMapper.contextLogicalKey,
            sourceIDs: sourceIDs,
            sourceIdentities: try sourceIdentities(for: sourceIDs)
        )
    }

    func saveAIUsageEvent(_ event: AIUsageEvent) throws {
        // AI usage telemetry is local-only and intentionally NOT synced via CloudKit.
        // It is an append-only per-API-call cost ledger; syncing each call produced
        // thousands of CloudKit records that clogged the content sync queue.
        try saveAIUsageEventRecord(event)
    }

    func managedAIUsageCursor() throws -> Int64 {
        var cursor: Int64 = 0
        try query("SELECT last_ledger_id FROM managed_ai_usage_sync_state WHERE singleton = 1") { stmt in
            cursor = sqlite3_column_int64(stmt, 0)
        }
        return cursor
    }

    func cachedAIResponse(for requestKey: String, notOlderThan cutoff: Date) throws -> String? {
        var response: String?
        try queryBind("""
            SELECT response
            FROM ai_response_cache
            WHERE request_key = ? AND created_at >= ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, requestKey)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSinceReferenceDate)
        }) { stmt in
            response = self.string(stmt, 0)
        }
        return response
    }

    func saveCachedAIResponse(_ response: String, for requestKey: String, at date: Date = Date()) throws {
        try execBind("""
            INSERT INTO ai_response_cache (request_key, response, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(request_key) DO UPDATE SET
                response = excluded.response,
                created_at = excluded.created_at
        """) { stmt in
            bind(stmt, 1, requestKey)
            bind(stmt, 2, response)
            sqlite3_bind_double(stmt, 3, date.timeIntervalSinceReferenceDate)
        }
    }

    /// Mirrors a page from the proxy's append-only D1 ledger and advances the
    /// cursor in the same SQLite transaction. A crash can therefore replay a
    /// page but can never skip it; the unique server ledger id makes replays
    /// idempotent.
    func importManagedAIUsageEvents(
        _ rows: [ManagedAI.UsageLedgerEvent],
        through cursor: Int64
    ) throws {
        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback { try? exec("ROLLBACK") }
        }

        for row in rows {
            // A repaired server debit is appended with a fresh cursor id so
            // clients that already mirrored the broken row receive it. Remove
            // that superseded `:unmetered` mirror in the same transaction;
            // otherwise the exact replacement would coexist with the warning
            // forever even though D1 no longer counts the failed record.
            if row.exactCost != 0, let requestID = row.requestID {
                try execBind("""
                    DELETE FROM ai_usage_events
                    WHERE server_ledger_id IS NOT NULL
                      AND server_request_id = ?
                """) { stmt in
                    bind(stmt, 1, "\(requestID):unmetered")
                }
            }
            let billedUSD = row.exactCost != 0
                ? Double(row.billedMicrousd) / 1_000_000
                : nil
            let cacheCreation = (row.cacheWrite5mTokens ?? 0) + (row.cacheWrite1hTokens ?? 0)
            let event = AIUsageEvent(
                id: "managed-ledger-\(row.id)",
                provider: row.provider,
                model: row.model,
                operation: "managed_proxy",
                task: row.task,
                sessionID: nil,
                activityID: row.activityID,
                subjectID: row.subjectID,
                subjectType: row.subjectType,
                subjectTitle: row.sourceTitle,
                createdAt: Date(timeIntervalSince1970: row.createdAtUnix),
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cachedInputTokens: row.cachedInputTokens,
                cacheCreationInputTokens: cacheCreation > 0 ? cacheCreation : nil,
                reasoningTokens: row.reasoningTokens,
                audioInputTokens: nil,
                audioOutputTokens: nil,
                imageCount: nil,
                totalTokens: (row.inputTokens ?? 0) + (row.outputTokens ?? 0),
                characterCount: nil,
                durationSeconds: nil,
                providerReportedCost: billedUSD,
                estimatedCost: billedUSD,
                currency: billedUSD == nil ? nil : "USD",
                rawUsageJSON: nil,
                clientPlatform: row.clientPlatform,
                serverLedgerID: row.id,
                serverRequestID: row.requestID
            )
            try saveAIUsageEventRecord(event)
        }

        // Also reconcile databases where an older app build already imported
        // both records before learning how server repairs are represented. This
        // set-based cleanup runs whenever the event-driven usage sync imports a
        // page (including an empty one), so advancing the cursor early cannot
        // leave a superseded warning behind permanently.
        try exec("""
            DELETE FROM ai_usage_events
            WHERE id IN (
                SELECT stale.id
                FROM ai_usage_events AS stale
                JOIN ai_usage_events AS exact
                  ON exact.server_request_id = substr(
                      stale.server_request_id,
                      1,
                      length(stale.server_request_id) - 10
                  )
                WHERE stale.server_ledger_id IS NOT NULL
                  AND stale.server_request_id LIKE '%:unmetered'
                  AND exact.server_ledger_id IS NOT NULL
                  AND COALESCE(exact.provider_reported_cost, exact.estimated_cost) IS NOT NULL
            )
        """)

        try execBind("""
            INSERT INTO managed_ai_usage_sync_state (singleton, last_ledger_id)
            VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET
                last_ledger_id = MAX(last_ledger_id, excluded.last_ledger_id)
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, cursor)
        }
        try exec("COMMIT")
        needsRollback = false
    }

    func saveAIUsageEventRecord(_ event: AIUsageEvent) throws {
        try execBind("""
            INSERT INTO ai_usage_events (
                id, provider, model, operation, task, session_id,
                activity_id, subject_id, subject_type, subject_title, created_at,
                input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                reasoning_tokens, audio_input_tokens, audio_output_tokens, image_count, total_tokens,
                character_count, duration_seconds, provider_reported_cost, estimated_cost,
                currency, raw_usage_json, client_platform, server_ledger_id, server_request_id,
                latency_ms, own_key
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider = excluded.provider,
                model = excluded.model,
                operation = excluded.operation,
                task = excluded.task,
                session_id = excluded.session_id,
                activity_id = excluded.activity_id,
                subject_id = excluded.subject_id,
                subject_type = excluded.subject_type,
                subject_title = excluded.subject_title,
                created_at = excluded.created_at,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                cache_creation_input_tokens = excluded.cache_creation_input_tokens,
                reasoning_tokens = excluded.reasoning_tokens,
                audio_input_tokens = excluded.audio_input_tokens,
                audio_output_tokens = excluded.audio_output_tokens,
                image_count = excluded.image_count,
                total_tokens = excluded.total_tokens,
                character_count = excluded.character_count,
                duration_seconds = excluded.duration_seconds,
                provider_reported_cost = excluded.provider_reported_cost,
                estimated_cost = excluded.estimated_cost,
                currency = excluded.currency,
                raw_usage_json = excluded.raw_usage_json,
                client_platform = excluded.client_platform,
                server_ledger_id = excluded.server_ledger_id,
                server_request_id = excluded.server_request_id,
                latency_ms = excluded.latency_ms,
                own_key = excluded.own_key
        """) { stmt in
            bind(stmt, 1, event.id)
            bind(stmt, 2, event.provider)
            bind(stmt, 3, event.model)
            bind(stmt, 4, event.operation)
            bind(stmt, 5, event.task)
            bind(stmt, 6, event.sessionID)
            bind(stmt, 7, event.activityID)
            bind(stmt, 8, event.subjectID)
            bind(stmt, 9, event.subjectType)
            bind(stmt, 10, event.subjectTitle)
            sqlite3_bind_double(stmt, 11, event.createdAt.timeIntervalSinceReferenceDate)
            bind(stmt, 12, event.inputTokens)
            bind(stmt, 13, event.outputTokens)
            bind(stmt, 14, event.cachedInputTokens)
            bind(stmt, 15, event.cacheCreationInputTokens)
            bind(stmt, 16, event.reasoningTokens)
            bind(stmt, 17, event.audioInputTokens)
            bind(stmt, 18, event.audioOutputTokens)
            bind(stmt, 19, event.imageCount)
            bind(stmt, 20, event.totalTokens)
            bind(stmt, 21, event.characterCount)
            bind(stmt, 22, event.durationSeconds)
            bind(stmt, 23, event.providerReportedCost)
            // Priced at the write, whatever path the row came from, so no
            // caller can land an unpriced row the rate card could have priced.
            bind(stmt, 24, event.ledgerEstimatedCost)
            bind(stmt, 25, event.currency)
            bind(stmt, 26, event.rawUsageJSON)
            bind(stmt, 27, event.clientPlatform)
            if let serverLedgerID = event.serverLedgerID {
                sqlite3_bind_int64(stmt, 28, serverLedgerID)
            } else {
                sqlite3_bind_null(stmt, 28)
            }
            bind(stmt, 29, event.serverRequestID)
            bind(stmt, 30, event.latencyMilliseconds)
            sqlite3_bind_int(stmt, 31, event.paidByOwnKey ? 1 : 0)
        }
    }

    /// Prices every stored row that still has no cost but can now get one
    /// (`AIUsageEvent.ledgerEstimatedCost`): rows written before the write
    /// itself priced them, and rows whose model only gained a rate since —
    /// a later build's rate card, or a refreshed OpenRouter directory. Only a
    /// NULL `estimated_cost` is ever filled, so a price already stamped is
    /// never rewritten. Returns how many rows it priced.
    @discardableResult
    func repriceUnpricedAIUsageEvents() throws -> Int {
        var unpriced: [AIUsageEvent] = []
        try query("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND \(Self.aiUsageEventCostExpression) IS NULL
        """) { stmt in
            if let event = self.decodeAIUsageEvent(stmt) { unpriced.append(event) }
        }
        let priced = unpriced.compactMap { event in
            event.ledgerEstimatedCost.map { (event.id, $0) }
        }
        guard !priced.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback { try? exec("ROLLBACK") }
        }
        for (id, cost) in priced {
            try execBind("""
                UPDATE ai_usage_events
                SET estimated_cost = ?
                WHERE id = ? AND estimated_cost IS NULL
            """) { stmt in
                bind(stmt, 1, cost)
                bind(stmt, 2, id)
            }
        }
        try exec("COMMIT")
        needsRollback = false
        return priced.count
    }

    /// How many picture calls still have no cost. Their price is OpenRouter's
    /// image directory's, which is read over the network, so the repricing
    /// sweep reads it only when this is above zero.
    func unpricedImageUsageEventCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND operation = 'image_generation'
              AND \(Self.aiUsageEventCostExpression) IS NULL
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Rows OpenRouter has charged for but whose charge the ledger has not
    /// read yet: a generation id is stored (`CloudArticleTTS.generationMarker`)
    /// and no cost is. Newest first, so what the learner is looking at settles
    /// before older leftovers.
    func aiUsageEventsAwaitingGenerationCost(limit: Int) throws -> [(id: String, rawUsageJSON: String)] {
        var rows: [(id: String, rawUsageJSON: String)] = []
        try queryBind("""
            SELECT id, raw_usage_json
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND \(Self.aiUsageEventCostExpression) IS NULL
              AND raw_usage_json LIKE '%"generation_id"%'
            ORDER BY created_at DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }) { stmt in
            if let id = self.string(stmt, 0), let raw = self.string(stmt, 1) {
                rows.append((id, raw))
            }
        }
        return rows
    }

    /// Stamps OpenRouter's own charge on a row that was waiting for it. Only a
    /// row still without any cost is written, so a price already there stands.
    func setAIUsageEventGenerationCost(id: String, costUSD: Double) throws {
        try execBind("""
            UPDATE ai_usage_events
            SET provider_reported_cost = ?, estimated_cost = ?, currency = 'USD'
            WHERE id = ?
              AND server_ledger_id IS NULL
              AND provider_reported_cost IS NULL
              AND estimated_cost IS NULL
        """) { stmt in
            bind(stmt, 1, costUSD)
            bind(stmt, 2, costUSD)
            bind(stmt, 3, id)
        }
    }

    /// Resets to zero every stored estimate for a call OpenRouter says it
    /// billed nothing for (`AIUsageEvent.estimatesSpendOpenRouterDidNotBill`).
    /// Older builds priced `:free` calls at their paid sibling's list rate
    /// even though the row's own usage said cost 0, adding spend that never
    /// happened to every total. This is the one case a stamped estimate is
    /// rewritten: the provider's bill contradicts it. Returns how many rows
    /// it corrected.
    @discardableResult
    func zeroEstimatesOpenRouterDidNotBill() throws -> Int {
        var invented: [String] = []
        // The LIKE is only a cheap prefilter; the Swift check decides.
        try query("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND estimated_cost > 0
              AND COALESCE(provider_reported_cost, 0) <= 0
              AND raw_usage_json LIKE '%"cost":0%'
        """) { stmt in
            if let event = self.decodeAIUsageEvent(stmt), event.estimatesSpendOpenRouterDidNotBill {
                invented.append(event.id)
            }
        }
        guard !invented.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback { try? exec("ROLLBACK") }
        }
        for id in invented {
            try execBind("""
                UPDATE ai_usage_events
                SET estimated_cost = 0
                WHERE id = ? AND server_ledger_id IS NULL
            """) { stmt in
                bind(stmt, 1, id)
            }
        }
        try exec("COMMIT")
        needsRollback = false
        return invented.count
    }

    /// Column list every per-call read shares, so the row decoder below can be
    /// used against any of them.
    private static let aiUsageEventColumns = """
        id, provider, model, operation, task, session_id,
        activity_id, subject_id, subject_type, subject_title, created_at,
        input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
        reasoning_tokens, audio_input_tokens, audio_output_tokens, image_count, total_tokens,
        character_count, duration_seconds, provider_reported_cost, estimated_cost,
        currency, raw_usage_json, client_platform, server_ledger_id, server_request_id,
        latency_ms, own_key
    """

    private func decodeAIUsageEvent(_ stmt: OpaquePointer?) -> AIUsageEvent? {
        guard let id = string(stmt, 0),
              let provider = string(stmt, 1),
              let model = string(stmt, 2),
              let operation = string(stmt, 3) else {
            return nil
        }
        return AIUsageEvent(
            id: id,
            provider: provider,
            model: model,
            operation: operation,
            task: string(stmt, 4),
            sessionID: string(stmt, 5),
            activityID: string(stmt, 6),
            subjectID: string(stmt, 7),
            subjectType: string(stmt, 8),
            subjectTitle: string(stmt, 9),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10)),
            inputTokens: optionalInt(stmt, 11),
            outputTokens: optionalInt(stmt, 12),
            cachedInputTokens: optionalInt(stmt, 13),
            cacheCreationInputTokens: optionalInt(stmt, 14),
            reasoningTokens: optionalInt(stmt, 15),
            audioInputTokens: optionalInt(stmt, 16),
            audioOutputTokens: optionalInt(stmt, 17),
            imageCount: optionalInt(stmt, 18),
            totalTokens: optionalInt(stmt, 19),
            characterCount: optionalInt(stmt, 20),
            durationSeconds: optionalDouble(stmt, 21),
            providerReportedCost: optionalDouble(stmt, 22),
            estimatedCost: optionalDouble(stmt, 23),
            currency: string(stmt, 24),
            rawUsageJSON: string(stmt, 25),
            clientPlatform: string(stmt, 26),
            serverLedgerID: sqlite3_column_type(stmt, 27) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(stmt, 27),
            serverRequestID: string(stmt, 28),
            latencyMilliseconds: optionalInt(stmt, 29),
            ownKey: sqlite3_column_int(stmt, 30) != 0
        )
    }

    /// Recorded spend attributed to one chat/review session. `totalUSD` prefers
    /// the provider's own billed amount per row and falls back to the list-price
    /// estimate; `unpricedEventCount` says how many rows carried neither, so the
    /// UI can mark the total as a floor rather than exact.
    struct AIUsageSessionCost: Sendable, Equatable {
        var totalUSD: Double = 0
        var eventCount: Int = 0
        var unpricedEventCount: Int = 0
    }

    /// Sums the ledger for one session, bounded to rows recorded strictly
    /// before `cutoff`. The caller counts events at/after the cutoff live from
    /// the record notification, so the two halves partition cleanly and a row
    /// can never be counted twice however the load races an active stream.
    func aiUsageCost(sessionID: String, before cutoff: Date) throws -> AIUsageSessionCost {
        var cost = AIUsageSessionCost()
        try queryBind("""
            SELECT
                COALESCE(SUM(\(Self.aiUsageEventCostExpression)), 0),
                COUNT(*),
                COALESCE(SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END), 0)
            FROM ai_usage_events
            WHERE session_id = ? AND created_at < ?
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSinceReferenceDate)
        }) { stmt in
            cost.totalUSD = sqlite3_column_double(stmt, 0)
            cost.eventCount = Int(sqlite3_column_int64(stmt, 1))
            cost.unpricedEventCount = Int(sqlite3_column_int64(stmt, 2))
        }
        return cost
    }

    func loadAIUsageEventForSync(_ id: String) throws -> AIUsageEvent? {
        var event: AIUsageEvent?
        try queryBind("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            event = self.decodeAIUsageEvent(stmt)
        }
        return event
    }

    /// Period and column filters shared by the paged read, the count, and the
    /// CSV export, so a filtered view can never disagree with its own total.
    /// Once server rows exist, they replace client estimates over the server's
    /// covered time range. Rows before the first server entry remain visible;
    /// rows during coverage come only from D1, preventing double counting.
    ///
    /// A direct-rail call is the exception. `own_key` is set only when the
    /// learner's own key paid *and* the call went straight to the router, so
    /// the proxy never saw it and no D1 row will ever arrive to stand in for
    /// it. Deferring to server coverage would erase it from the pane, its
    /// totals and the export — the spend the learner most needs to see, since
    /// it is the spend ForeverLM is not billing them for. There is nothing to
    /// double count, so it stays.
    private static let aiUsageAccountingRowPredicate = """
        (server_ledger_id IS NOT NULL
         OR own_key = 1
         OR created_at < COALESCE(
            (SELECT MIN(authoritative.created_at)
               FROM ai_usage_events AS authoritative
              WHERE authoritative.server_ledger_id IS NOT NULL),
            1.0e100
        ))
    """

    struct AIUsageEventFilter: Sendable, Equatable {
        var since: Date?
        /// Exclusive upper bound on `created_at`, so a report for an explicit
        /// period stops at the end of its last day rather than at "now".
        var until: Date?
        var provider: String?
        var model: String?
        var operation: String?
        var task: String?
        var clientPlatform: String?
        /// Only the calls the learner's own key paid for straight at the router
        /// (`own_key`), or only the rest. Nil counts both.
        var paidByOwnKey: Bool?

        init(since: Date? = nil, until: Date? = nil, provider: String? = nil, model: String? = nil, operation: String? = nil, task: String? = nil, clientPlatform: String? = nil, paidByOwnKey: Bool? = nil) {
            self.since = since
            self.until = until
            self.provider = provider
            self.model = model
            self.operation = operation
            self.task = task
            self.clientPlatform = clientPlatform
            self.paidByOwnKey = paidByOwnKey
        }

        fileprivate var whereClause: String {
            var clauses: [String] = [KnowledgeStore.aiUsageAccountingRowPredicate]
            if since != nil { clauses.append("created_at >= ?") }
            if until != nil { clauses.append("created_at < ?") }
            if provider != nil { clauses.append("provider = ?") }
            if model != nil { clauses.append("model = ?") }
            if operation != nil { clauses.append("operation = ?") }
            if task != nil { clauses.append("task = ?") }
            if clientPlatform != nil { clauses.append("client_platform = ?") }
            // A literal, not a bound value, so `bindAIUsageFilter` stays in step.
            if let paidByOwnKey { clauses.append(paidByOwnKey ? "own_key = 1" : "own_key = 0") }
            return "WHERE " + clauses.joined(separator: " AND ")
        }
    }

    /// Binds the filter's values in `whereClause` order and returns the next
    /// free parameter index, so callers can append LIMIT/OFFSET after it.
    private func bindAIUsageFilter(_ filter: AIUsageEventFilter, to stmt: OpaquePointer?) -> Int32 {
        var index: Int32 = 1
        if let since = filter.since {
            sqlite3_bind_double(stmt, index, since.timeIntervalSinceReferenceDate)
            index += 1
        }
        if let until = filter.until {
            sqlite3_bind_double(stmt, index, until.timeIntervalSinceReferenceDate)
            index += 1
        }
        for value in [filter.provider, filter.model, filter.operation, filter.task, filter.clientPlatform].compactMap({ $0 }) {
            bind(stmt, Int(index), value)
            index += 1
        }
        return index
    }

    /// One page of the per-call ledger, newest first. The AI Usage pane pages
    /// through this so every recorded call stays reachable — the summaries
    /// above it aggregate the same rows and would otherwise be the only view.
    /// `id` breaks ties so paging can't repeat or skip rows recorded in the
    /// same instant.
    func loadAIUsageEvents(filter: AIUsageEventFilter = .init(), limit: Int, offset: Int = 0) throws -> [AIUsageEvent] {
        var events: [AIUsageEvent] = []
        try queryBind("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            \(filter.whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ? OFFSET ?
        """, bind: { stmt in
            let index = self.bindAIUsageFilter(filter, to: stmt)
            sqlite3_bind_int64(stmt, index, Int64(limit))
            sqlite3_bind_int64(stmt, index + 1, Int64(offset))
        }) { stmt in
            if let event = self.decodeAIUsageEvent(stmt) {
                events.append(event)
            }
        }
        return events
    }

    /// What one call cost, in SQL: the amount the provider actually billed when
    /// it reported a real one, else the list-price estimate stamped at record
    /// time. `NULLIF(...,0)` mirrors `AIUsageParser.billedCost` — a reported
    /// zero is "not reported", not free — so the pane's per-row cost and these
    /// totals can never disagree.
    ///
    /// The trailing CASE is the one place a reported zero is taken at face
    /// value: no estimate exists and the row reports no billable quantity at
    /// all, so the call consumed nothing and cost exactly nothing. Without it
    /// an empty row (a voice session that ended before the model answered)
    /// counted against the unpriced warning as if real spend were missing.
    /// `AIUsageEvent.accountedCostUSD` is the same rule in Swift.
    static let aiUsageEventCostExpression = """
        COALESCE(
            NULLIF(provider_reported_cost, 0),
            estimated_cost,
            CASE WHEN provider_reported_cost = 0
                      AND COALESCE(input_tokens, 0) = 0
                      AND COALESCE(output_tokens, 0) = 0
                      AND COALESCE(cached_input_tokens, 0) = 0
                      AND COALESCE(cache_creation_input_tokens, 0) = 0
                      AND COALESCE(reasoning_tokens, 0) = 0
                      AND COALESCE(audio_input_tokens, 0) = 0
                      AND COALESCE(audio_output_tokens, 0) = 0
                      AND COALESCE(image_count, 0) = 0
                      AND COALESCE(total_tokens, 0) = 0
                      AND COALESCE(character_count, 0) = 0
                      AND COALESCE(duration_seconds, 0) = 0
                 THEN 0 END
        )
        """

    /// Count, total spend, and how many calls carry no cost at all. The
    /// unpriced count is reported rather than folded into the total silently:
    /// a total that quietly omits calls understates real spend.
    ///
    /// Also carries the prompt-cache read and write token sums, so a caching
    /// regression is visible as a number instead of only as a larger bill.
    func aiUsageEventTotals(
        filter: AIUsageEventFilter = .init()
    ) throws -> AIUsageEventTotals {
        var totals = AIUsageEventTotals()
        try queryBind("""
            SELECT COUNT(*),
                   SUM(\(Self.aiUsageEventCostExpression)),
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END),
                   SUM(COALESCE(cached_input_tokens, 0)),
                   SUM(COALESCE(cache_creation_input_tokens, 0))
            FROM ai_usage_events
            \(filter.whereClause)
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            totals = AIUsageEventTotals(
                count: Int(sqlite3_column_int64(stmt, 0)),
                cost: self.optionalDouble(stmt, 1),
                unpriced: Int(sqlite3_column_int64(stmt, 2)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 3)),
                cacheWriteTokens: Int(sqlite3_column_int64(stmt, 4))
            )
        }
        return totals
    }

    /// Total recorded calls matching the filter, so the pane can say how many
    /// rows remain unloaded instead of implying the first page is everything.
    func countAIUsageEvents(filter: AIUsageEventFilter = .init()) throws -> Int {
        try aiUsageEventTotals(filter: filter).count
    }

    /// Task-first rows for the human-readable usage log. Every task gets a
    /// drill-down identity: an explicit source first, then its chat session,
    /// workflow activity, or immutable event as the historical last resort.
    /// This query returns a small aggregate even when the append-only ledger
    /// contains tens of thousands of calls; SwiftUI never receives the full
    /// ledger to group it.
    ///
    /// Rows come most spend first, because the pane is read to find where the
    /// money went. SQLite sorts NULL lowest, so a task with no priced call
    /// falls to the bottom; ties, such as a run of free tasks, go most recent
    /// first.
    func loadAIUsageTaskActivities(
        filter: AIUsageEventFilter = .init()
    ) throws -> [AIUsageTaskActivitySummary] {
        let resolvedSubjectType = """
            CASE
                WHEN (subject_id IS NOT NULL AND TRIM(subject_id) <> '')
                  OR (subject_title IS NOT NULL AND TRIM(subject_title) <> '')
                    THEN COALESCE(NULLIF(TRIM(subject_type), ''), 'item')
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> '' THEN 'chat'
                WHEN review_sessions.id IS NOT NULL THEN 'chat'
                ELSE 'activity'
            END
        """
        let subjectIdentity = """
            CASE
                WHEN subject_id IS NOT NULL AND TRIM(subject_id) <> ''
                    THEN COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_id
                WHEN subject_title IS NOT NULL AND TRIM(subject_title) <> ''
                    THEN 'legacy-title' || char(31) || COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_title
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> ''
                    THEN 'chat' || char(31) || session_id
                WHEN review_sessions.id IS NOT NULL
                    THEN 'chat' || char(31) || activity_id
                WHEN activity_id IS NOT NULL AND TRIM(activity_id) <> ''
                    THEN 'activity' || char(31) || activity_id
                ELSE 'event' || char(31) || ai_usage_events.id
            END
        """
        let taskKey = "COALESCE(NULLIF(TRIM(task), ''), '__unattributed__')"
        var rows: [AIUsageTaskActivitySummary] = []
        try queryBind("""
            SELECT \(taskKey) AS task_key,
                   NULLIF(TRIM(task), '') AS task_value,
                   CASE WHEN COUNT(DISTINCT \(resolvedSubjectType)) = 1
                        THEN MAX(\(resolvedSubjectType)) ELSE NULL END AS sole_subject_type,
                   COUNT(DISTINCT \(subjectIdentity)) AS subject_count,
                   COUNT(DISTINCT COALESCE(
                       NULLIF(TRIM(activity_id), ''),
                       NULLIF(TRIM(session_id), ''),
                       ai_usage_events.id
                   )) AS activity_count,
                   COUNT(*) AS call_count,
                   COALESCE(SUM(input_tokens), 0) AS input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS output_tokens,
                   SUM(\(Self.aiUsageEventCostExpression)) AS cost,
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END) AS unpriced_count,
                   MAX(created_at) AS latest_at
            FROM ai_usage_events
            LEFT JOIN review_sessions ON review_sessions.id = COALESCE(
                NULLIF(TRIM(ai_usage_events.session_id), ''),
                NULLIF(TRIM(ai_usage_events.activity_id), '')
            )
            \(filter.whereClause)
            GROUP BY task_key
            ORDER BY cost DESC, latest_at DESC, task_key ASC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let key = self.string(stmt, 0) else { return }
            rows.append(AIUsageTaskActivitySummary(
                key: key,
                task: self.string(stmt, 1),
                subjectType: self.string(stmt, 2),
                subjectCount: Int(sqlite3_column_int64(stmt, 3)),
                activityCount: Int(sqlite3_column_int64(stmt, 4)),
                callCount: Int(sqlite3_column_int64(stmt, 5)),
                inputTokens: Int(sqlite3_column_int64(stmt, 6)),
                outputTokens: Int(sqlite3_column_int64(stmt, 7)),
                cost: self.optionalDouble(stmt, 8),
                unpricedCallCount: Int(sqlite3_column_int64(stmt, 9)),
                latestAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))
            ))
        }
        let models = try loadAIUsageModelUses(groupKey: taskKey, filter: filter)
        for index in rows.indices {
            rows[index].models = models[rows[index].key] ?? []
        }
        return rows
    }

    /// Item rows beneath one task. Deterministic source identity is preferred;
    /// title-only rows from the already-deployed source-title attribution are
    /// kept visibly grouped as legacy data, never promoted to source identity.
    /// Chat identity falls back to activity_id because authoritative proxy
    /// rows preserve that workflow ID but do not carry the local session_id.
    /// LIMIT/OFFSET is applied in SQLite so a large grouped result never crosses
    /// onto the UI actor just to be discarded there.
    func loadAIUsageSubjectActivities(
        task: String?,
        filter: AIUsageEventFilter = .init(),
        limit: Int = Int.max,
        offset: Int = 0
    ) throws -> [AIUsageSubjectActivitySummary] {
        let subjectKey = """
            CASE
                WHEN subject_id IS NOT NULL AND TRIM(subject_id) <> ''
                    THEN 'id' || char(31) || COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_id
                WHEN subject_title IS NOT NULL AND TRIM(subject_title) <> ''
                    THEN 'legacy-title' || char(31) || COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_title
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> ''
                    THEN 'chat' || char(31) || session_id
                WHEN review_sessions.id IS NOT NULL
                    THEN 'chat' || char(31) || activity_id
                WHEN activity_id IS NOT NULL AND TRIM(activity_id) <> ''
                    THEN 'activity' || char(31) || activity_id
                ELSE 'event' || char(31) || ai_usage_events.id
            END
        """
        let resolvedSubjectID = """
            COALESCE(
                NULLIF(TRIM(subject_id), ''),
                NULLIF(TRIM(session_id), ''),
                NULLIF(TRIM(activity_id), ''),
                ai_usage_events.id
            )
        """
        let resolvedSubjectType = """
            CASE
                WHEN (subject_id IS NOT NULL AND TRIM(subject_id) <> '')
                  OR (subject_title IS NOT NULL AND TRIM(subject_title) <> '')
                    THEN COALESCE(NULLIF(TRIM(subject_type), ''), 'item')
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> '' THEN 'chat'
                WHEN review_sessions.id IS NOT NULL THEN 'chat'
                ELSE 'activity'
            END
        """
        let resolvedSubjectTitle = """
            COALESCE(
                NULLIF(TRIM(subject_title), ''),
                (
                    SELECT NULLIF(TRIM(source_projection.title), '')
                    FROM source_projection
                    WHERE source_projection.id = ai_usage_events.subject_id
                    LIMIT 1
                ),
                NULLIF(TRIM(review_sessions.topic), '')
            )
        """
        let taskPredicate = task == nil
            ? "(task IS NULL OR TRIM(task) = '')"
            : "task = ?"
        var rows: [AIUsageSubjectActivitySummary] = []
        try queryBind("""
            SELECT \(subjectKey) AS subject_key,
                   MAX(\(resolvedSubjectID)) AS subject_id,
                   MAX(\(resolvedSubjectType)) AS subject_type,
                   MAX(\(resolvedSubjectTitle)) AS subject_title,
                   COUNT(DISTINCT COALESCE(
                       NULLIF(TRIM(activity_id), ''),
                       NULLIF(TRIM(session_id), ''),
                       ai_usage_events.id
                   )) AS activity_count,
                   COUNT(*) AS call_count,
                   COALESCE(SUM(input_tokens), 0) AS input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS output_tokens,
                   SUM(\(Self.aiUsageEventCostExpression)) AS cost,
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END) AS unpriced_count,
                   MAX(created_at) AS latest_at
            FROM ai_usage_events
            LEFT JOIN review_sessions ON review_sessions.id = COALESCE(
                NULLIF(TRIM(ai_usage_events.session_id), ''),
                NULLIF(TRIM(ai_usage_events.activity_id), '')
            )
            \(filter.whereClause) AND \(taskPredicate)
            GROUP BY subject_key
            ORDER BY latest_at DESC, subject_key ASC
            LIMIT ? OFFSET ?
        """, bind: { stmt in
            var next = self.bindAIUsageFilter(filter, to: stmt)
            if let task {
                self.bind(stmt, Int(next), task)
                next += 1
            }
            sqlite3_bind_int64(stmt, next, Int64(max(0, limit)))
            sqlite3_bind_int64(stmt, next + 1, Int64(max(0, offset)))
        }) { stmt in
            guard let key = self.string(stmt, 0) else { return }
            rows.append(AIUsageSubjectActivitySummary(
                key: key,
                subjectID: self.string(stmt, 1),
                subjectType: self.string(stmt, 2),
                subjectTitle: self.string(stmt, 3),
                activityCount: Int(sqlite3_column_int64(stmt, 4)),
                callCount: Int(sqlite3_column_int64(stmt, 5)),
                inputTokens: Int(sqlite3_column_int64(stmt, 6)),
                outputTokens: Int(sqlite3_column_int64(stmt, 7)),
                cost: self.optionalDouble(stmt, 8),
                unpricedCallCount: Int(sqlite3_column_int64(stmt, 9)),
                latestAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))
            ))
        }
        guard !rows.isEmpty else { return rows }
        // Only the page's items: a task with thousands of chats would
        // otherwise group every one of them to name the models of fifty.
        let pageKeys = rows.map(\.key)
        let models = try loadAIUsageModelUses(
            groupKey: subjectKey,
            filter: filter,
            predicate: taskPredicate,
            having: "group_key IN (\(Array(repeating: "?", count: pageKeys.count).joined(separator: ", ")))",
            bind: { stmt, first in
                var next = first
                if let task {
                    self.bind(stmt, Int(next), task)
                    next += 1
                }
                for key in pageKeys {
                    self.bind(stmt, Int(next), key)
                    next += 1
                }
            }
        )
        for index in rows.indices {
            rows[index].models = models[rows[index].key] ?? []
        }
        return rows
    }

    /// The models behind each row of an activity-log query, most calls first.
    /// `groupKey` is the SQL expression the caller grouped its rows by, so a
    /// row finds its models under its own key, and `predicate` narrows the
    /// scan the way the caller's query was narrowed. `bind` receives the first
    /// parameter index after the filter's. Grouped by model id alone: the
    /// ledger spells one router two ways ("OpenRouter", "openrouter").
    private func loadAIUsageModelUses(
        groupKey: String,
        filter: AIUsageEventFilter,
        predicate: String? = nil,
        having: String? = nil,
        bind: (OpaquePointer?, Int32) -> Void = { _, _ in }
    ) throws -> [String: [AIUsageModelUse]] {
        var uses: [String: [AIUsageModelUse]] = [:]
        try queryBind("""
            SELECT \(groupKey) AS group_key,
                   MAX(ai_usage_events.provider) AS provider,
                   ai_usage_events.model AS model,
                   COUNT(*) AS call_count,
                   COALESCE(SUM(\(Self.byokUsagePredicate)), 0) AS byok_calls,
                   COALESCE(SUM(\(Self.creditUsagePredicate)), 0) AS credit_calls
            FROM ai_usage_events
            LEFT JOIN review_sessions ON review_sessions.id = COALESCE(
                NULLIF(TRIM(ai_usage_events.session_id), ''),
                NULLIF(TRIM(ai_usage_events.activity_id), '')
            )
            \(filter.whereClause)\(predicate.map { " AND \($0)" } ?? "")
            GROUP BY group_key, ai_usage_events.model
            \(having.map { "HAVING \($0)" } ?? "")
            ORDER BY group_key ASC, call_count DESC, model ASC
        """, bind: { stmt in
            bind(stmt, self.bindAIUsageFilter(filter, to: stmt))
        }) { stmt in
            guard let key = self.string(stmt, 0),
                  let provider = self.string(stmt, 1),
                  let model = self.string(stmt, 2) else { return }
            uses[key, default: []].append(AIUsageModelUse(
                provider: provider,
                model: model,
                callCount: Int(sqlite3_column_int64(stmt, 3)),
                byokCallCount: Int(sqlite3_column_int64(stmt, 4)),
                creditCallCount: Int(sqlite3_column_int64(stmt, 5))
            ))
        }
        return uses
    }

    /// OpenRouter's `usage.is_byok`, read from the stored raw usage block
    /// (compact JSON, but the spaced spelling is matched too).
    private static let byokUsagePredicate = """
        (ai_usage_events.raw_usage_json LIKE '%"is_byok":true%'
         OR ai_usage_events.raw_usage_json LIKE '%"is_byok": true%')
        """
    private static let creditUsagePredicate = """
        (ai_usage_events.raw_usage_json LIKE '%"is_byok":false%'
         OR ai_usage_events.raw_usage_json LIKE '%"is_byok": false%')
        """

    /// Distinct providers, models, operations, and tasks present in the
    /// period — the filter menus are built from what the ledger actually
    /// contains rather than from a hardcoded list that could drift from it.
    /// Tasks skip NULL rows (recorded before the column existed), so the menu
    /// never offers a blank entry.
    func loadAIUsageFacets(since: Date? = nil) throws -> (providers: [String], models: [String], operations: [String], tasks: [String], platforms: [String]) {
        func distinct(_ column: String) throws -> [String] {
            var predicates = [Self.aiUsageAccountingRowPredicate, "\(column) IS NOT NULL"]
            if since != nil { predicates.append("created_at >= ?") }
            let predicate = "WHERE " + predicates.joined(separator: " AND ")
            var values: [String] = []
            try queryBind("SELECT DISTINCT \(column) FROM ai_usage_events \(predicate) ORDER BY \(column)", bind: { stmt in
                if let since {
                    sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
                }
            }) { stmt in
                if let value = self.string(stmt, 0) {
                    values.append(value)
                }
            }
            return values
        }
        return (try distinct("provider"), try distinct("model"), try distinct("operation"), try distinct("task"), try distinct("client_platform"))
    }

    func deleteAIUsageEventRecord(_ id: String) throws {
        try execBind("DELETE FROM ai_usage_events WHERE id = ?") { stmt in
            bind(stmt, 1, id)
        }
    }

    func loadAIUsageSummaries(filter: AIUsageEventFilter = .init()) throws -> [AIUsageSummary] {
        var summaries: [AIUsageSummary] = []
        try queryBind("""
            SELECT provider, model, COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cached_input_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(reasoning_tokens), 0),
                   COALESCE(SUM(audio_input_tokens), 0),
                   COALESCE(SUM(audio_output_tokens), 0),
                   COALESCE(SUM(image_count), 0),
                   COALESCE(SUM(total_tokens), 0),
                   COALESCE(SUM(character_count), 0),
                   COALESCE(SUM(duration_seconds), 0),
                   SUM(provider_reported_cost),
                   SUM(estimated_cost),
                   SUM(CASE WHEN estimated_cost IS NULL THEN 1 ELSE 0 END),
                   MAX(currency)
            FROM ai_usage_events
            \(filter.whereClause)
            GROUP BY provider, model
            ORDER BY created_at DESC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let provider = self.string(stmt, 0),
                  let model = self.string(stmt, 1) else {
                return
            }
            summaries.append(AIUsageSummary(
                provider: provider,
                model: model,
                requestCount: Int(sqlite3_column_int64(stmt, 2)),
                inputTokens: Int(sqlite3_column_int64(stmt, 3)),
                outputTokens: Int(sqlite3_column_int64(stmt, 4)),
                cachedInputTokens: Int(sqlite3_column_int64(stmt, 5)),
                cacheCreationInputTokens: Int(sqlite3_column_int64(stmt, 6)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 7)),
                audioInputTokens: Int(sqlite3_column_int64(stmt, 8)),
                audioOutputTokens: Int(sqlite3_column_int64(stmt, 9)),
                imageCount: Int(sqlite3_column_int64(stmt, 10)),
                totalTokens: Int(sqlite3_column_int64(stmt, 11)),
                characterCount: Int(sqlite3_column_int64(stmt, 12)),
                durationSeconds: sqlite3_column_double(stmt, 13),
                providerReportedCost: self.optionalDouble(stmt, 14),
                estimatedCost: self.optionalDouble(stmt, 15),
                unpricedCount: Int(sqlite3_column_int64(stmt, 16)),
                currency: self.string(stmt, 17)
            ))
        }
        return summaries
    }

    /// One row per task and model the ledger saw in the period, with every
    /// billable token dimension summed and the cost expression the pane uses,
    /// so a cost report can say which model each feature actually ran and what
    /// it paid per call. Rows recorded before task attribution existed group
    /// under an empty task. Grouped in SQLite: the ledger never crosses the
    /// actor boundary row by row.
    func loadAIUsageTaskModelSummaries(filter: AIUsageEventFilter = .init()) throws -> [AIUsageTaskModelSummary] {
        var rows: [AIUsageTaskModelSummary] = []
        try queryBind("""
            SELECT COALESCE(NULLIF(TRIM(task), ''), '') AS task_key,
                   provider,
                   model,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cached_input_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(reasoning_tokens), 0),
                   SUM(\(Self.aiUsageEventCostExpression)),
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END),
                   MAX(created_at)
            FROM ai_usage_events
            \(filter.whereClause)
            GROUP BY task_key, provider, model
            ORDER BY task_key ASC, provider ASC, model ASC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let task = self.string(stmt, 0),
                  let provider = self.string(stmt, 1),
                  let model = self.string(stmt, 2) else { return }
            rows.append(AIUsageTaskModelSummary(
                task: task,
                provider: provider,
                model: model,
                callCount: Int(sqlite3_column_int64(stmt, 3)),
                inputTokens: Int(sqlite3_column_int64(stmt, 4)),
                outputTokens: Int(sqlite3_column_int64(stmt, 5)),
                cachedInputTokens: Int(sqlite3_column_int64(stmt, 6)),
                cacheCreationInputTokens: Int(sqlite3_column_int64(stmt, 7)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 8)),
                cost: self.optionalDouble(stmt, 9),
                unpricedCallCount: Int(sqlite3_column_int64(stmt, 10)),
                latestAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11))
            ))
        }
        return rows
    }

    /// Per-local-day spend under a full filter, priced with the same cost
    /// expression as the totals (provider-billed amount first, then the
    /// list-price estimate), so a day's figure agrees with the period total.
    /// `loadAIUsageDailyTotals(since:)` keeps the dashboard chart's estimate
    /// column; this one is for the usage report over MCP.
    func loadAIUsageDailyCosts(filter: AIUsageEventFilter = .init()) throws -> [AIUsageDailyTotal] {
        var totals: [AIUsageDailyTotal] = []
        try queryBind("""
            SELECT strftime('%Y-%m-%d', created_at + 978307200, 'unixepoch', 'localtime') AS day,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   SUM(\(Self.aiUsageEventCostExpression))
            FROM ai_usage_events
            \(filter.whereClause)
            GROUP BY day
            ORDER BY day ASC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let day = self.string(stmt, 0) else { return }
            totals.append(AIUsageDailyTotal(
                day: day,
                requestCount: Int(sqlite3_column_int64(stmt, 1)),
                inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                estimatedCost: self.optionalDouble(stmt, 4)
            ))
        }
        return totals
    }

    func loadAIUsageDailyTotals(since: Date? = nil) throws -> [AIUsageDailyTotal] {
        let predicate = "WHERE " + [
            Self.aiUsageAccountingRowPredicate,
            since == nil ? nil : "created_at >= ?",
        ].compactMap { $0 }.joined(separator: " AND ")
        var totals: [AIUsageDailyTotal] = []
        // created_at is seconds since the Cocoa reference date (2001-01-01);
        // shift by 978307200 to the unix epoch for SQLite's date functions.
        try queryBind("""
            SELECT strftime('%Y-%m-%d', created_at + 978307200, 'unixepoch', 'localtime') AS day,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   SUM(estimated_cost)
            FROM ai_usage_events
            \(predicate)
            GROUP BY day
            ORDER BY day ASC
        """, bind: { stmt in
            if let since {
                sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
            }
        }) { stmt in
            guard let day = self.string(stmt, 0) else { return }
            totals.append(AIUsageDailyTotal(
                day: day,
                requestCount: Int(sqlite3_column_int64(stmt, 1)),
                inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                estimatedCost: self.optionalDouble(stmt, 4)
            ))
        }
        return totals
    }

    func loadAIUsageOperationSummaries(since: Date? = nil) throws -> [AIUsageOperationSummary] {
        let predicate = "WHERE " + [
            Self.aiUsageAccountingRowPredicate,
            since == nil ? nil : "created_at >= ?",
        ].compactMap { $0 }.joined(separator: " AND ")
        var summaries: [AIUsageOperationSummary] = []
        try queryBind("""
            SELECT operation,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   SUM(estimated_cost)
            FROM ai_usage_events
            \(predicate)
            GROUP BY operation
            ORDER BY SUM(estimated_cost) DESC
        """, bind: { stmt in
            if let since {
                sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
            }
        }) { stmt in
            guard let operation = self.string(stmt, 0) else { return }
            summaries.append(AIUsageOperationSummary(
                operation: operation,
                requestCount: Int(sqlite3_column_int64(stmt, 1)),
                inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                estimatedCost: self.optionalDouble(stmt, 4)
            ))
        }
        return summaries
    }

    func enqueueAllSyncableRecords(at date: Date = Date()) throws {
        for sourceID in try loadAllSourceIDs() {
            try markRecordChanged(entity: .source, logicalKey: sourceID, at: date)
        }
        for bookName in try loadAllBookNames() {
            try markRecordChanged(entity: .book, logicalKey: bookName, at: date)
        }
        for courseName in try loadAllCourseNames() {
            try markRecordChanged(entity: .course, logicalKey: courseName, at: date)
        }
        for playlistID in try loadAllVideoPlaylistIDs() {
            try markRecordChanged(entity: .videoPlaylist, logicalKey: playlistID, at: date)
        }
        for meetingName in try loadAllMeetingGroupNames() {
            try markRecordChanged(entity: .meetingGroup, logicalKey: meetingName, at: date)
        }
        for sourceID in try loadAllHiddenSourceIDs() {
            try markRecordChanged(entity: .hiddenSource, logicalKey: sourceID, at: date)
        }
        for showName in try loadAllHiddenPodcastShowNames() {
            try markRecordChanged(entity: .hiddenPodcastShow, logicalKey: showName, at: date)
        }
        for channelName in try loadAllHiddenYouTubeChannelNames() {
            try markRecordChanged(entity: .hiddenYouTubeChannel, logicalKey: channelName, at: date)
        }
        for artifactID in try loadAllHiddenArtifactIDs() {
            try markRecordChanged(entity: .hiddenArtifact, logicalKey: artifactID, at: date)
        }
        for sessionID in try loadAllHiddenReviewSessionIDs() {
            try markRecordChanged(entity: .hiddenReviewSession, logicalKey: sessionID, at: date)
        }
        for dismissedURL in try loadAllDismissedSourceKeys() {
            try markRecordChanged(entity: .dismissedSource, logicalKey: dismissedURL, at: date)
        }
        for preferenceKey in try loadAllPreferenceKeys() {
            try markRecordChanged(entity: .preference, logicalKey: preferenceKey, at: date)
        }
        if try loadContextSourceIds() != nil {
            try markRecordChanged(entity: .chatContext, logicalKey: CloudKitRecordMapper.contextLogicalKey, at: date)
        }
        for sessionID in try loadAllReviewSessionIDs() {
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID, at: date)
        }
        for itemID in try loadAllMemoryItemIDs() {
            try markRecordChanged(entity: .memoryItem, logicalKey: itemID, at: date)
        }
        for attemptID in try loadAllMemoryAttemptIDs() {
            try markRecordChanged(entity: .memoryAttempt, logicalKey: attemptID, at: date)
        }
        for highlightID in try loadAllSourceHighlightIDs() {
            try markRecordChanged(entity: .sourceHighlight, logicalKey: highlightID, at: date)
        }
        for goalID in try loadAllLearningGoalIDs() {
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: date)
        }
        for artifactID in try loadAllArtifactIDs() {
            try markRecordChanged(entity: .artifact, logicalKey: artifactID, at: date)
        }
        for placementID in try loadAllScheduledSourceIDs() {
            try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: date)
        }
        for taskID in try loadAllScheduledTaskIDs() {
            try markRecordChanged(entity: .scheduledTask, logicalKey: taskID, at: date)
        }
        for planID in try loadAllDayPlanIDs() {
            try markRecordChanged(entity: .dayPlan, logicalKey: planID, at: date)
        }
        for ideaID in try loadAllIdeaIDs() {
            try markRecordChanged(entity: .idea, logicalKey: ideaID, at: date)
        }
        for subjectID in try loadAllWalkthroughProgressIDs() {
            try markRecordChanged(entity: .walkthroughProgress, logicalKey: subjectID, at: date)
        }
        for skillID in try loadAllSkillIDs() {
            try markRecordChanged(entity: .skill, logicalKey: skillID, at: date)
        }
        for directionID in try loadAllResearchDirectionIDs() {
            try markRecordChanged(entity: .researchDirection, logicalKey: directionID, at: date)
        }
        for ideaID in try loadAllSourceIdeaIDs() {
            try markRecordChanged(entity: .sourceIdea, logicalKey: ideaID, at: date)
        }
        for activityID in try loadAllMemoryReviewActivityIDs() {
            try markRecordChanged(entity: .memoryReviewActivity, logicalKey: activityID, at: date)
        }
        for citedPaperID in try loadAllVideoCitedPaperIDs() {
            try markRecordChanged(entity: .videoCitedPaper, logicalKey: citedPaperID, at: date)
        }
        // Only the owner publishes a team's own record; a member holds a copy
        // that arrived from the owner's zone and has nothing to republish.
        for team in try loadTeams() where team.role == .owner {
            try markRecordChanged(entity: .team, logicalKey: team.id, at: date)
        }
        for taskID in try loadAllNotebookTaskIDs() {
            try markRecordChanged(entity: .notebookTask, logicalKey: taskID, at: date)
        }
        for requestID in try loadAllShareRequestIDs() {
            try markRecordChanged(entity: .shareRequest, logicalKey: requestID, at: date)
        }
        // researchCanvas is tombstoned (feature removed); aiUsageEvent is local-only.
    }

    @discardableResult
    func enqueueMissingSyncableRecords(at fallbackDate: Date = Date()) throws -> Int {
        var enqueued = 0

        func reconcile(_ entity: CloudKitSyncEntity, _ logicalKey: String) throws {
            let metadata = try loadSyncMetadata(entity: entity, logicalKey: logicalKey)
            let pending = try loadPendingSyncOperation(entity: entity, logicalKey: logicalKey)
            let needsSave = metadata == nil || metadata?.isDeleted == true || pending == .delete
            // Only (re)enqueue records that genuinely need a save. A healthy, already-synced
            // record (metadata present, not deleted, nothing pending) must be left alone —
            // otherwise every launch re-queues the entire library.
            guard needsSave else { return }
            let backfillDate = try syncBackfillDate(for: entity, logicalKey: logicalKey) ?? fallbackDate
            try upsertSyncSave(entity: entity, logicalKey: logicalKey, at: backfillDate)
            enqueued += 1
        }

        for sourceID in try loadAllSourceIDs() {
            try reconcile(.source, sourceID)
        }
        for bookName in try loadAllBookNames() {
            try reconcile(.book, bookName)
        }
        for courseName in try loadAllCourseNames() {
            try reconcile(.course, courseName)
        }
        for playlistID in try loadAllVideoPlaylistIDs() {
            try reconcile(.videoPlaylist, playlistID)
        }
        for meetingName in try loadAllMeetingGroupNames() {
            try reconcile(.meetingGroup, meetingName)
        }
        for sourceID in try loadAllHiddenSourceIDs() {
            try reconcile(.hiddenSource, sourceID)
        }
        for showName in try loadAllHiddenPodcastShowNames() {
            try reconcile(.hiddenPodcastShow, showName)
        }
        for channelName in try loadAllHiddenYouTubeChannelNames() {
            try reconcile(.hiddenYouTubeChannel, channelName)
        }
        for artifactID in try loadAllHiddenArtifactIDs() {
            try reconcile(.hiddenArtifact, artifactID)
        }
        for sessionID in try loadAllHiddenReviewSessionIDs() {
            try reconcile(.hiddenReviewSession, sessionID)
        }
        for dismissedURL in try loadAllDismissedSourceKeys() {
            try reconcile(.dismissedSource, dismissedURL)
        }
        for preferenceKey in try loadAllPreferenceKeys() {
            try reconcile(.preference, preferenceKey)
        }
        if try loadContextSourceIds() != nil {
            try reconcile(.chatContext, CloudKitRecordMapper.contextLogicalKey)
        }
        for sessionID in try loadAllReviewSessionIDs() {
            try reconcile(.reviewSession, sessionID)
        }
        for itemID in try loadAllMemoryItemIDs() {
            try reconcile(.memoryItem, itemID)
        }
        for attemptID in try loadAllMemoryAttemptIDs() {
            try reconcile(.memoryAttempt, attemptID)
        }
        for highlightID in try loadAllSourceHighlightIDs() {
            try reconcile(.sourceHighlight, highlightID)
        }
        for goalID in try loadAllLearningGoalIDs() {
            try reconcile(.learningGoal, goalID)
        }
        for artifactID in try loadAllArtifactIDs() {
            try reconcile(.artifact, artifactID)
        }
        for placementID in try loadAllScheduledSourceIDs() {
            try reconcile(.scheduledSource, placementID)
        }
        for taskID in try loadAllScheduledTaskIDs() {
            try reconcile(.scheduledTask, taskID)
        }
        for planID in try loadAllDayPlanIDs() {
            try reconcile(.dayPlan, planID)
        }
        for ideaID in try loadAllIdeaIDs() {
            try reconcile(.idea, ideaID)
        }
        for subjectID in try loadAllWalkthroughProgressIDs() {
            try reconcile(.walkthroughProgress, subjectID)
        }
        for skillID in try loadAllSkillIDs() {
            try reconcile(.skill, skillID)
        }
        for directionID in try loadAllResearchDirectionIDs() {
            try reconcile(.researchDirection, directionID)
        }
        for ideaID in try loadAllSourceIdeaIDs() {
            try reconcile(.sourceIdea, ideaID)
        }
        for activityID in try loadAllMemoryReviewActivityIDs() {
            try reconcile(.memoryReviewActivity, activityID)
        }
        for citedPaperID in try loadAllVideoCitedPaperIDs() {
            try reconcile(.videoCitedPaper, citedPaperID)
        }
        for team in try loadTeams() where team.role == .owner {
            try reconcile(.team, team.id)
        }
        for taskID in try loadAllNotebookTaskIDs() {
            try reconcile(.notebookTask, taskID)
        }
        for requestID in try loadAllShareRequestIDs() {
            try reconcile(.shareRequest, requestID)
        }
        // researchCanvas is tombstoned (feature removed); aiUsageEvent is local-only.

        if enqueued > 0 {
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        }
        return enqueued
    }

    func syncBackfillDate(for entity: CloudKitSyncEntity, logicalKey: String) throws -> Date? {
        switch entity {
        case .source:
            return try sourceSyncBackfillDate(sourceID: logicalKey)
        case .hiddenSource:
            return try singleDate(
                "SELECT hidden_at FROM hidden_sources WHERE source_id = ? LIMIT 1",
                key: logicalKey
            )
        case .hiddenPodcastShow:
            return try singleDate(
                "SELECT hidden_at FROM hidden_podcast_shows WHERE show_name = ? LIMIT 1",
                key: logicalKey
            )
        case .hiddenYouTubeChannel:
            return try singleDate(
                "SELECT hidden_at FROM hidden_youtube_channels WHERE channel_name = ? LIMIT 1",
                key: logicalKey
            )
        case .hiddenArtifact:
            return try singleDate(
                "SELECT hidden_at FROM hidden_artifacts WHERE artifact_id = ? LIMIT 1",
                key: logicalKey
            )
        case .hiddenReviewSession:
            return try singleDate(
                "SELECT hidden_at FROM hidden_review_sessions WHERE session_id = ? LIMIT 1",
                key: logicalKey
            )
        case .dismissedSource:
            return try singleDate(
                "SELECT dismissed_at FROM dismissed_sources WHERE url = ? LIMIT 1",
                key: logicalKey
            )
        case .chatContext:
            return try singleDate(
                "SELECT last_updated FROM chat_context WHERE key = ? LIMIT 1",
                key: logicalKey
            )
        case .reviewSession:
            return try reviewSessionSyncBackfillDate(sessionID: logicalKey)
        case .memoryItem:
            return try singleDate(
                "SELECT updated_at FROM memory_items WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .memoryAttempt:
            return try singleDate(
                "SELECT attempted_at FROM memory_attempts WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .sourceHighlight:
            return try singleDate(
                "SELECT updated_at FROM source_highlights WHERE highlight_id = ? LIMIT 1",
                key: logicalKey
            )
        case .learningGoal:
            return try singleDate(
                "SELECT updated_at FROM learning_goals WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .artifact:
            return try singleDate(
                "SELECT updated_at FROM global_artifacts WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .artifactComment:
            return try singleDate(
                "SELECT updated_at FROM artifact_comments WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .scheduledSource:
            return try singleDate(
                "SELECT updated_at FROM scheduled_sources WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .scheduledTask:
            return try scheduledTaskSyncBackfillDate(taskID: logicalKey)
        case .dayPlan:
            return try dayPlanSyncBackfillDate(logicalKey)
        case .idea:
            return try ideaSyncBackfillDate(logicalKey)
        case .walkthroughProgress:
            return try walkthroughProgressSyncBackfillDate(logicalKey)
        case .skill:
            return try skillSyncBackfillDate(logicalKey)
        case .researchDirection:
            return try researchDirectionSyncBackfillDate(logicalKey)
        case .sourceIdea:
            return try singleDate(
                "SELECT updated_at FROM source_ideas WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .memoryReviewActivity:
            return try singleDate(
                "SELECT updated_at FROM memory_review_activity WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .videoCitedPaper:
            return try singleDate(
                "SELECT updated_at FROM video_cited_papers WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .researchCanvas:
            return nil  // Tombstoned: ResearchCanvas feature removed.
        case .aiUsageEvent:
            return try singleDate(
                "SELECT created_at FROM ai_usage_events WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .preference:
            return try singleDate(
                "SELECT updated_at FROM user_preferences WHERE key = ? LIMIT 1",
                key: logicalKey
            )
        case .book, .course, .videoPlaylist, .meetingGroup:
            return Date(timeIntervalSinceReferenceDate: 0)
        case .team:
            return try singleDate(
                "SELECT updated_at FROM teams WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .notebookTask:
            return try singleDate(
                "SELECT updated_at FROM notebook_tasks WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        case .shareRequest:
            return try singleDate(
                "SELECT updated_at FROM share_requests WHERE id = ? LIMIT 1",
                key: logicalKey
            )
        }
    }

    func sourceSyncBackfillDate(sourceID: String) throws -> Date? {
        var date: Date?
        try queryBind("""
            SELECT date_added, archived_at
            FROM sources
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            if let archivedAt = self.string(stmt, 1),
               let archivedDate = Self.iso8601Formatter.date(from: archivedAt) {
                date = archivedDate
            } else {
                date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
            }
        }
        return date
    }

    func reviewSessionSyncBackfillDate(sessionID: String) throws -> Date? {
        var date: Date?
        try queryBind("""
            SELECT COALESCE(ended_at, started_at)
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return date
    }

    func singleDate(_ sql: String, key: String) throws -> Date? {
        var date: Date?
        try queryBind(sql, bind: { stmt in
            bind(stmt, 1, key)
        }) { stmt in
            date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return date
    }

    func requeueSyncChange(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        operation: CloudKitSyncOperation,
        at date: Date = Date()
    ) throws {
        switch operation {
        case .save:
            guard syncTrackingSuppressionDepth == 0 else { return }
            try upsertSyncSave(
                entity: entity,
                logicalKey: logicalKey,
                at: date,
                preserveExistingScope: true
            )
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        case .delete:
            try markRecordDeleted(entity: entity, logicalKey: logicalKey, at: date)
        }
    }

    func loadAllSourceIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM sources") { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    func loadAllPaperSourceIDs() throws -> [String] {
        var ids: [String] = []
        try queryBind("SELECT id FROM sources WHERE source_type = ?", bind: { stmt in
            bind(stmt, 1, StudioSourceType.paper.rawValue)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Every meeting whose artwork is a file this app wrote, rather than a
    /// remote cover. The icon republish nudge walks these.
    ///
    /// Filtered in SQL on the stored string rather than by stat: this runs at
    /// startup, and a Mac that holds a path but not the bytes still belongs in
    /// the list — attaching the asset is skipped for it anyway, and it is the
    /// Mac with the icons that this exists for.
    func loadAllStoredMeetingIconSourceIDs() throws -> [String] {
        var ids: [String] = []
        try query("""
            SELECT source_id FROM meeting_sources
            WHERE artwork_url IS NOT NULL
              AND artwork_url <> ''
              AND artwork_url NOT LIKE 'http%'
        """) { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Every book chapter source. Chapters are `sources` rows of type `book`
    /// whose parent is the Book record; the republish nudge for chapter reader
    /// documents walks these.
    func loadAllBookChapterSourceIDs() throws -> [String] {
        var ids: [String] = []
        try queryBind("SELECT id FROM sources WHERE source_type = ?", bind: { stmt in
            bind(stmt, 1, StudioSourceType.book.rawValue)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Archived web articles created after canonical source bytes moved from
    /// CloudDocs to local Application Support on 2026-08-18. Older archives
    /// retain their existing iCloud Drive transport and do not need a bulk
    /// CloudKit upload; bounding the one-time republish to the cutover avoids
    /// turning hundreds of historical image archives into a visible sync storm.
    func loadLocalStorageCutoverArchivedArticleSourceIDs() throws -> [String] {
        var ids: [String] = []
        let cutover = Date(timeIntervalSinceReferenceDate: 808_718_400)
        try queryBind("""
            SELECT id, local_file_path
            FROM source_projection
            WHERE date_added >= ? AND local_file_path IS NOT NULL
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, cutover.timeIntervalSinceReferenceDate)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let path = self.string(stmt, 1) else { return }
            let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
            guard normalized.hasSuffix(".html"),
                  normalized.hasPrefix("articles/") || normalized.contains("/articles/") else { return }
            ids.append(id)
        }
        return ids
    }

    /// Every active source that has an original PDF on record, with the path it
    /// was recorded at. The sync engine's document-recovery read walks these and
    /// keeps only the ones whose file is on no disk this Mac can see.
    ///
    /// Papers, book chapters, and course lectures all publish their original as
    /// `sourcePDFAsset`, so all three are eligible; hidden sources are too, since
    /// hiding is a display filter and the document still opens.
    func loadRecordedSourcePDFPaths() throws -> [(sourceID: String, storedPath: String)] {
        var rows: [(sourceID: String, storedPath: String)] = []
        try query("""
            SELECT id, local_file_path
            FROM source_projection
            WHERE status = 'active'
              AND local_file_path IS NOT NULL
              AND local_file_path <> ''
        """) { stmt in
            guard let id = self.string(stmt, 0),
                  let path = self.string(stmt, 1),
                  path.lowercased().hasSuffix(".pdf") else { return }
            rows.append((sourceID: id, storedPath: path))
        }
        return rows
    }

    /// Every active EPUB book chapter with its recorded markup path — the
    /// chapters whose document travels as `sourceReaderHTMLAsset` rather than
    /// a PDF. Same recovery read as `loadRecordedSourcePDFPaths`.
    func loadRecordedBookChapterDocumentPaths() throws -> [(sourceID: String, storedPath: String)] {
        var rows: [(sourceID: String, storedPath: String)] = []
        try query("""
            SELECT id, local_file_path
            FROM source_projection
            WHERE status = 'active'
              AND source_type = 'book'
              AND local_file_path IS NOT NULL
              AND local_file_path <> ''
        """) { stmt in
            guard let id = self.string(stmt, 0),
                  let path = self.string(stmt, 1),
                  EPUBParser.isMarkupChapter(path) else { return }
            rows.append((sourceID: id, storedPath: path))
        }
        return rows
    }

    /// Record a digest for one asset field as already acknowledged by the server.
    ///
    /// The staged/committed dance exists for uploads, where the acknowledgement
    /// is CloudKit accepting the record. A download needs no such proof: the
    /// bytes came from the server copy this digest describes, so it is committed
    /// on arrival. Scoped to the single field so nothing else about the record's
    /// upload bookkeeping moves.
    func recordCommittedAssetDigest(recordName: String, field: String, digest: String) throws {
        try execBind("""
            INSERT INTO sync_asset_digests (record_name, field, digest, pending_digest)
            VALUES (?, ?, ?, NULL)
            ON CONFLICT(record_name, field) DO UPDATE SET digest = excluded.digest
        """) { stmt in
            bind(stmt, 1, recordName)
            bind(stmt, 2, field)
            bind(stmt, 3, digest)
        }
    }

    func loadAllBookNames() throws -> [String] {
        var names: [String] = []
        try query("SELECT id FROM books") { stmt in
            if let name = self.string(stmt, 0) {
                names.append(name)
            }
        }
        return names
    }

    func loadAllCourseNames() throws -> [String] {
        var names: [String] = []
        try query("SELECT id FROM courses") { stmt in
            if let name = self.string(stmt, 0) {
                names.append(name)
            }
        }
        return names
    }

    func loadAllVideoPlaylistIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM video_playlists") { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    func loadAllMeetingGroupNames() throws -> [String] {
        var names: [String] = []
        try query("SELECT id FROM meeting_groups") { stmt in
            if let name = self.string(stmt, 0) {
                names.append(name)
            }
        }
        return names
    }

    func loadAllHiddenSourceIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT source_id FROM hidden_sources") { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    func loadAllHiddenPodcastShowNames() throws -> [String] {
        var names: [String] = []
        try query("SELECT show_name FROM hidden_podcast_shows") { stmt in
            if let name = self.string(stmt, 0) {
                names.append(name)
            }
        }
        return names
    }

    func loadAllHiddenYouTubeChannelNames() throws -> [String] {
        var names: [String] = []
        try query("SELECT channel_name FROM hidden_youtube_channels") { stmt in
            if let name = self.string(stmt, 0) { names.append(name) }
        }
        return names
    }

    func loadAllHiddenArtifactIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT artifact_id FROM hidden_artifacts") { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func loadAllHiddenReviewSessionIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT session_id FROM hidden_review_sessions") { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func loadAllDismissedSourceKeys() throws -> [String] {
        var urls: [String] = []
        try query("SELECT url FROM dismissed_sources") { stmt in
            if let url = self.string(stmt, 0) {
                urls.append(url)
            }
        }
        return urls
    }

    func loadAllReviewSessionIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM review_sessions") { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }


    /// `home` names the zone a record lives in. Almost every caller leaves it
    /// nil: the queue then keeps the home the record already has, and a record
    /// seen for the first time takes the home its `team_id` implies
    /// (`resolveRecordHome`), so the hundreds of existing call sites route team
    /// content correctly without naming a zone.
    func markRecordChanged(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        at date: Date = Date(),
        home: CloudKitZoneHome? = nil
    ) throws {
        // Once activated, generation 2 records changes in the outbox's triggers, never here: a row written here would read
        // as a pending old-world change at a reconcile (docs/cloudkit-schema-design.md §13.5).
        guard writesGenerationOneQueue else {
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            return
        }
        guard syncTrackingSuppressionDepth == 0 else { return }
        try upsertSyncSave(
            entity: entity,
            logicalKey: logicalKey,
            at: date,
            tutorOnly: false,
            home: home
        )
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    /// Queue a save that only advances monotonic tutor evidence. If an
    /// editorial save is already pending, the combined row remains editorial;
    /// otherwise conflict resolution can preserve remote relationship edits.
    func markTutorStateChanged(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        at date: Date = Date()
    ) throws {
        // Once activated, generation 2 records changes in the outbox's triggers, never here: a row written here would read
        // as a pending old-world change at a reconcile (docs/cloudkit-schema-design.md §13.5).
        guard writesGenerationOneQueue else {
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            return
        }
        guard syncTrackingSuppressionDepth == 0 else { return }
        guard entity == .learningGoal || entity == .scheduledSource else {
            throw KnowledgeStoreError.invalidData(
                "Tutor-only sync state is unsupported for \(entity.rawValue)."
            )
        }
        try upsertSyncSave(
            entity: entity,
            logicalKey: logicalKey,
            at: date,
            tutorOnly: true
        )
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    /// Queue a save that only advances this device's reading progress. A scroll
    /// offset or a read stamp is bookkeeping the learner never performed as an
    /// edit, so it must not outrank a real edit — a rename, say — still waiting
    /// on another Mac. `sync_changes.tutor_only` is the general "this pending
    /// save carries no editorial change" scope; sources reuse it. If an
    /// editorial save is already pending the combined row stays editorial,
    /// exactly as tutor evidence does.
    func markSourceProgressChanged(sourceID: String, at date: Date = Date()) throws {
        // Once activated, generation 2 records changes in the outbox's triggers, never here: a row written here would read
        // as a pending old-world change at a reconcile (docs/cloudkit-schema-design.md §13.5).
        guard writesGenerationOneQueue else {
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            return
        }
        guard syncTrackingSuppressionDepth == 0 else { return }
        try upsertSyncSave(
            entity: .source,
            logicalKey: sourceID,
            at: date,
            tutorOnly: true
        )
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    func markRecordDeleted(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        at date: Date = Date(),
        home: CloudKitZoneHome? = nil
    ) throws {
        guard writesGenerationOneQueue else { return }
        guard syncTrackingSuppressionDepth == 0 else { return }
        try enqueueRecordDeletion(entity: entity, logicalKey: logicalKey, at: date, home: home)
    }

    /// A remotely deleted parent can own separately synced child records unknown
    /// to the deleting (older) client. Those children still need server tombstones
    /// even though the inbound parent apply is otherwise sync-suppressed.
    func enqueueCascadingRecordDeletion(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        at date: Date = Date()
    ) throws {
        guard writesGenerationOneQueue else { return }
        try enqueueRecordDeletion(entity: entity, logicalKey: logicalKey, at: date)
    }

    private func enqueueRecordDeletion(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        at date: Date,
        home explicitHome: CloudKitZoneHome? = nil
    ) throws {
        // A quarantined row is a local loser for an immutable server identity.
        // Deleting that local copy must never enqueue a tombstone for the
        // unrelated server winner. Retain the durable conflict/server payload
        // until an explicit resolver accepts or replaces the winner.
        if try hasSyncConflict(entity: entity, logicalKey: logicalKey) {
            try clearPendingSyncChange(entity: entity, logicalKey: logicalKey)
            return
        }
        let recordName = CloudKitRecordMapper.recordName(for: entity, logicalKey: logicalKey)
        // The row is usually gone by now, so the home has to come from the
        // metadata the record left behind; a record never acknowledged falls
        // back to the private zone, where an unknown-item answer settles it.
        let home = try explicitHome
            ?? loadSyncMetadata(entity: entity, logicalKey: logicalKey)?.home
            ?? resolveRecordHome(entity: entity, logicalKey: logicalKey)
        try saveSyncMetadata(
            CloudKitSyncMetadata(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                systemFieldsData: nil,
                userModificationDate: date,
                isDeleted: true,
                home: home
            )
        )
        try execBind("""
            INSERT INTO sync_changes (entity_type, logical_key, record_name, operation, changed_at,
                                      zone_scope, zone_name, zone_owner_record_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                record_name = excluded.record_name,
                operation = excluded.operation,
                changed_at = excluded.changed_at,
                zone_scope = excluded.zone_scope,
                zone_name = excluded.zone_name,
                zone_owner_record_name = excluded.zone_owner_record_name
        """) { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
            bind(stmt, 3, recordName)
            bind(stmt, 4, CloudKitSyncOperation.delete.rawValue)
            sqlite3_bind_double(stmt, 5, date.timeIntervalSinceReferenceDate)
            bindZoneHome(stmt, home, scopeIndex: 6)
        }
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    func upsertSyncSave(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        at date: Date,
        tutorOnly: Bool = false,
        preserveExistingScope: Bool = false,
        home explicitHome: CloudKitZoneHome? = nil
    ) throws {
        // Quarantined immutable identities are deliberately absent from the
        // active retry queue. Keep future edits suppressed until the learner
        // explicitly resolves the conflict instead of recreating a hot loop.
        if try hasSyncConflict(entity: entity, logicalKey: logicalKey) {
            try clearPendingSyncChange(entity: entity, logicalKey: logicalKey)
            return
        }

        // A tombstone plus a missing local row is a deletion this device has
        // already committed. The metadata this method writes is unconditionally
        // `isDeleted: false`, so letting a save through here would reopen that
        // tombstone and replace the queued delete — recreating the record on the
        // server and leaving nothing to refuse it when it is fetched back. Rows
        // whose logical key is reused (a re-hidden source, a preference set
        // again) are present locally and pass straight through.
        if try loadSyncMetadata(entity: entity, logicalKey: logicalKey)?.isDeleted == true,
           try !hasLocalSyncRecord(entity: entity, logicalKey: logicalKey) {
            return
        }

        if entity == .memoryAttempt {
            var parentConflict: (
                memoryItemID: String,
                serverModificationAt: Date,
                detectedAt: Date
            )?
            try queryBind("""
                SELECT attempts.memory_item_id,
                       conflicts.server_modification_at,
                       conflicts.detected_at
                FROM memory_attempts AS attempts
                JOIN sync_conflicts AS conflicts
                  ON conflicts.entity_type = ?
                 AND conflicts.logical_key = attempts.memory_item_id
                WHERE attempts.id = ?
                LIMIT 1
            """, bind: { statement in
                bind(statement, 1, CloudKitSyncEntity.memoryItem.rawValue)
                bind(statement, 2, logicalKey)
            }) { statement in
                guard let memoryItemID = self.string(statement, 0) else { return }
                parentConflict = (
                    memoryItemID,
                    Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                    Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
                )
            }
            if let parentConflict {
                try clearPendingSyncChange(entity: entity, logicalKey: logicalKey)
                throw KnowledgeStoreError.invalidData(
                    "Memory attempt \(logicalKey) cannot be recorded because its parent MemoryItem \(parentConflict.memoryItemID) has an unresolved CloudKit curriculum conflict (server \(parentConflict.serverModificationAt), detected \(parentConflict.detectedAt))."
                )
            }
        }

        let recordName = CloudKitRecordMapper.recordName(for: entity, logicalKey: logicalKey)
        let existing = try loadSyncMetadata(entity: entity, logicalKey: logicalKey)
        // A record keeps the home it has. Only a record seen for the first time
        // consults its own row, and only an explicit caller (team lifecycle)
        // overrides either.
        let home = try explicitHome
            ?? existing?.home
            ?? resolveRecordHome(entity: entity, logicalKey: logicalKey)
        if home.isTeamZone, try teamPermission(forHome: home) == .readOnly {
            throw KnowledgeStoreError.invalidData(
                "This team is read-only for you; ask its owner for edit access to change it."
            )
        }
        let metadata = existing.map {
            CloudKitSyncMetadata(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                systemFieldsData: $0.systemFieldsData,
                userModificationDate: date,
                isDeleted: false,
                home: home
            )
        } ?? CloudKitSyncMetadata(
            entity: entity,
            logicalKey: logicalKey,
            recordName: recordName,
            systemFieldsData: nil,
            userModificationDate: date,
            isDeleted: false,
            home: home
        )
        try saveSyncMetadata(metadata)
        try execBind("""
            INSERT INTO sync_changes (
                entity_type, logical_key, record_name, operation, changed_at, tutor_only,
                zone_scope, zone_name, zone_owner_record_name
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                record_name = excluded.record_name,
                operation = excluded.operation,
                changed_at = excluded.changed_at,
                tutor_only = CASE
                    WHEN ? THEN sync_changes.tutor_only
                    WHEN sync_changes.tutor_only = 1 AND excluded.tutor_only = 1 THEN 1
                    ELSE 0
                END,
                zone_scope = excluded.zone_scope,
                zone_name = excluded.zone_name,
                zone_owner_record_name = excluded.zone_owner_record_name
        """) { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
            bind(stmt, 3, recordName)
            bind(stmt, 4, CloudKitSyncOperation.save.rawValue)
            sqlite3_bind_double(stmt, 5, date.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 6, tutorOnly ? 1 : 0)
            bindZoneHome(stmt, home, scopeIndex: 7)
            sqlite3_bind_int(stmt, 10, preserveExistingScope ? 1 : 0)
        }
    }

    /// Execute raw SQL — exposed for testing only. Use targeted methods in production code.
    func execForTesting(_ sql: String) throws {
        try exec(sql)
    }
}

// MARK: - Schema-forward usage accounting

extension KnowledgeStore {
    /// Append one immutable usage event when normal `KnowledgeStore` startup
    /// fails. This is intentionally the only operation allowed against a
    /// database whose `user_version` is newer than this build supports.
    ///
    /// The writer discovers the live table columns and supplies only values
    /// this build understands. It never creates or alters a table, changes
    /// `user_version`, reads application records, or updates sync state. A
    /// missing required ledger column fails the call rather than guessing.
    static func appendAIUsageEventForwardCompatibly(
        _ event: AIUsageEvent,
        storeDirectory: URL,
        after primaryFailure: String
    ) throws {
        enum SQLiteValue {
            case text(String?)
            case integer(Int?)
            case integer64(Int64?)
            case real(Double?)
        }

        struct Field {
            let name: String
            let value: SQLiteValue
        }

        func combinedError(_ compatibilityFailure: String) -> KnowledgeStoreError {
            .invalidData(
                "AI usage could not be recorded. Primary storage failed: "
                    + primaryFailure
                    + ". Schema-forward ledger append failed: "
                    + compatibilityFailure
            )
        }

        let databasePath = storeDirectory.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databasePath,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw combinedError("SQLite open error \(openResult).")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 10_000)

        var tableInfo: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(ai_usage_events)",
            -1,
            &tableInfo,
            nil
        ) == SQLITE_OK else {
            throw combinedError(String(cString: sqlite3_errmsg(database)))
        }
        var liveColumns = Set<String>()
        while sqlite3_step(tableInfo) == SQLITE_ROW {
            if let rawName = sqlite3_column_text(tableInfo, 1) {
                liveColumns.insert(String(cString: rawName))
            }
        }
        sqlite3_finalize(tableInfo)

        let requiredColumns: Set<String> = ["id", "provider", "model", "operation", "created_at"]
        let missingRequiredColumns = requiredColumns.subtracting(liveColumns).sorted()
        guard missingRequiredColumns.isEmpty else {
            throw combinedError(
                "ai_usage_events is missing required column(s): "
                    + missingRequiredColumns.joined(separator: ", ")
                    + "."
            )
        }

        let knownFields: [Field] = [
            Field(name: "id", value: .text(event.id)),
            Field(name: "provider", value: .text(event.provider)),
            Field(name: "model", value: .text(event.model)),
            Field(name: "operation", value: .text(event.operation)),
            Field(name: "task", value: .text(event.task)),
            Field(name: "session_id", value: .text(event.sessionID)),
            Field(name: "activity_id", value: .text(event.activityID)),
            Field(name: "subject_id", value: .text(event.subjectID)),
            Field(name: "subject_type", value: .text(event.subjectType)),
            Field(name: "subject_title", value: .text(event.subjectTitle)),
            Field(name: "created_at", value: .real(event.createdAt.timeIntervalSinceReferenceDate)),
            Field(name: "input_tokens", value: .integer(event.inputTokens)),
            Field(name: "output_tokens", value: .integer(event.outputTokens)),
            Field(name: "cached_input_tokens", value: .integer(event.cachedInputTokens)),
            Field(name: "cache_creation_input_tokens", value: .integer(event.cacheCreationInputTokens)),
            Field(name: "reasoning_tokens", value: .integer(event.reasoningTokens)),
            Field(name: "audio_input_tokens", value: .integer(event.audioInputTokens)),
            Field(name: "audio_output_tokens", value: .integer(event.audioOutputTokens)),
            Field(name: "image_count", value: .integer(event.imageCount)),
            Field(name: "total_tokens", value: .integer(event.totalTokens)),
            Field(name: "character_count", value: .integer(event.characterCount)),
            Field(name: "duration_seconds", value: .real(event.durationSeconds)),
            Field(name: "provider_reported_cost", value: .real(event.providerReportedCost)),
            Field(name: "estimated_cost", value: .real(event.ledgerEstimatedCost)),
            Field(name: "currency", value: .text(event.currency)),
            Field(name: "raw_usage_json", value: .text(event.rawUsageJSON)),
            Field(name: "client_platform", value: .text(event.clientPlatform)),
            Field(name: "server_ledger_id", value: .integer64(event.serverLedgerID)),
            Field(name: "server_request_id", value: .text(event.serverRequestID)),
            Field(name: "latency_ms", value: .integer(event.latencyMilliseconds)),
        ]
        let fields = knownFields.filter { liveColumns.contains($0.name) }
        let placeholders = Array(repeating: "?", count: fields.count).joined(separator: ", ")
        let sql = """
            INSERT INTO ai_usage_events (\(fields.map(\.name).joined(separator: ", ")))
            VALUES (\(placeholders))
            ON CONFLICT(id) DO NOTHING
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw combinedError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, field) in fields.enumerated() {
            let index = Int32(offset + 1)
            switch field.value {
            case .text(let value):
                if let value {
                    SQLiteText.bind(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .integer(let value):
                if let value {
                    sqlite3_bind_int64(statement, index, Int64(value))
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .integer64(let value):
                if let value {
                    sqlite3_bind_int64(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .real(let value):
                if let value {
                    sqlite3_bind_double(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw combinedError(String(cString: sqlite3_errmsg(database)))
        }
    }
}

/// Aggregate for the AI Usage pane: how many calls, what they cost, how many
/// carry no price, and how the prompt cache actually behaved.
///
/// The cache figures are deliberately reads-and-writes only, with no total-prompt
/// denominator. `ai_usage_events.input_tokens` is stored exactly as the provider
/// reported it, and the two conventions disagree: Anthropic-direct excludes
/// cached and cache-write tokens from it, while the OpenAI/OpenRouter shape
/// includes them (which is why `AIUsageRates.inputIncludesCached` exists). A
/// `cached / (cached + write + input)` ratio would therefore double-count the
/// denominator on most of this app's traffic. Reads-versus-writes needs no such
/// assumption and answers the question that matters anyway.
struct AIUsageEventTotals: Sendable, Equatable {
    var count: Int = 0
    var cost: Double?
    var unpriced: Int = 0
    /// Prompt tokens served from the provider's cache, billed at ~0.1x input.
    var cacheReadTokens: Int = 0
    /// Prompt tokens written into the cache, billed at 1.25x (5-minute TTL) or
    /// 2x (1-hour TTL) input.
    var cacheWriteTokens: Int = 0

    /// Share of cache-handled prompt tokens that were reads rather than writes,
    /// or `nil` when nothing touched the cache in this range.
    ///
    /// How to read it: a write is only worth making if it is read back, so
    /// healthy caching sits high — each write amortized over many turns. Around
    /// 0.5 means every write is read back roughly once, which barely breaks even.
    /// Below 0.5 the app is writing more than it reads, the signature of a prefix
    /// that changes before it can be reused: a volatile system head, a churning
    /// tool list, or budget truncation moving the cut boundary every turn.
    var cacheReadShare: Double? {
        let handled = cacheReadTokens + cacheWriteTokens
        guard handled > 0 else { return nil }
        return Double(cacheReadTokens) / Double(handled)
    }
}
