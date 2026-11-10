// KnowledgeStore: reconciling and merging shared Schedule placements.
import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Shared Schedule Placement sync

    private func mergedSourceActivityDays(
        _ existing: [SourceActivityDay],
        _ incoming: [SourceActivityDay],
        sourceID: String,
        portableSourceKey: String
    ) -> [SourceActivityDay] {
        var byDay: [Date: SourceActivityDay] = [:]
        for candidate in existing + incoming {
            let dayStart = candidate.dayStart
            let canonical = SourceActivityDay(
                id: MemoryTutorIdentity.sourceActivityDayID(
                    portableSourceKey: portableSourceKey,
                    dayStart: dayStart
                ),
                sourceID: sourceID,
                dayStart: dayStart,
                firstActivityAt: candidate.firstActivityAt,
                lastActivityAt: candidate.lastActivityAt,
                kinds: candidate.kinds,
                completedKinds: candidate.completedKinds,
                maxFraction: candidate.maxFraction,
                engagedSeconds: candidate.engagedSeconds
            )
            if let current = byDay[dayStart] {
                byDay[dayStart] = SourceActivityDay(
                    id: canonical.id,
                    sourceID: sourceID,
                    dayStart: dayStart,
                    firstActivityAt: min(current.firstActivityAt, canonical.firstActivityAt),
                    lastActivityAt: max(current.lastActivityAt, canonical.lastActivityAt),
                    kinds: current.kinds.union(canonical.kinds),
                    completedKinds: current.completedKinds.union(canonical.completedKinds),
                    maxFraction: max(current.maxFraction, canonical.maxFraction),
                    // Two records of one day are the same sitting seen twice,
                    // so the longer one stands; adding would double it.
                    engagedSeconds: max(current.engagedSeconds, canonical.engagedSeconds)
                )
            } else {
                byDay[dayStart] = canonical
            }
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private func replaceSourceActivityDays(
        _ activityDays: [SourceActivityDay],
        placementID: String,
        sourceID: String
    ) throws {
        try execBind("DELETE FROM source_activity_days WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
        for day in activityDays {
            // The id is derived from the source's portable identity and the day,
            // so a duplicate source row that shares that identity can already
            // hold it under its own source_id; the DELETE above only cleared
            // this source's rows. A plain INSERT then failed the primary key,
            // the inbound placement save rolled back, and its CloudKit record
            // retried on every flush. Fold the two into one row instead.
            // Engaged seconds merge by MAX here: this is another device's total
            // for the same day, not a fresh slice, so adding would count the
            // synced total twice on every flush.
            try execBind("""
                INSERT INTO source_activity_days (
                    id, scheduled_source_id, source_id, day_start,
                    first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction,
                    engaged_seconds
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    scheduled_source_id = excluded.scheduled_source_id,
                    source_id = excluded.source_id,
                    day_start = excluded.day_start,
                    first_activity_at = MIN(source_activity_days.first_activity_at, excluded.first_activity_at),
                    last_activity_at = MAX(source_activity_days.last_activity_at, excluded.last_activity_at),
                    kinds = source_activity_days.kinds | excluded.kinds,
                    completed_kinds = source_activity_days.completed_kinds | excluded.completed_kinds,
                    max_fraction = MAX(source_activity_days.max_fraction, excluded.max_fraction),
                    engaged_seconds = MAX(source_activity_days.engaged_seconds, excluded.engaged_seconds)
            """) { stmt in
                bind(stmt, 1, day.id)
                bind(stmt, 2, placementID)
                bind(stmt, 3, sourceID)
                sqlite3_bind_double(stmt, 4, day.dayStart.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 5, day.firstActivityAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 6, day.lastActivityAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_int64(stmt, 7, sourceActivityMask(day.kinds))
                sqlite3_bind_int64(stmt, 8, sourceActivityMask(day.completedKinds))
                sqlite3_bind_double(stmt, 9, SourceActivityDay.clampFraction(day.maxFraction))
                sqlite3_bind_double(stmt, 10, SourceActivityDay.clampSeconds(day.engagedSeconds))
            }
        }
    }

    func loadScheduledSourceRow(id: String) throws -> ScheduledSource? {
        var placement: ScheduledSource?
        try queryBind("""
            SELECT id, source_id, planned_at, added_at, completed_at, created_at, updated_at
            FROM scheduled_sources
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, id)
        }) { statement in
            placement = self.readScheduledSourceRow(statement)
        }
        return placement
    }

    private func scheduledSourceMembershipIDs(placementID: String) throws -> [String] {
        var goalIDs: [String] = []
        try queryBind(
            "SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ? ORDER BY goal_id",
            bind: { statement in bind(statement, 1, placementID) }
        ) { statement in
            if let goalID = self.string(statement, 0) {
                goalIDs.append(goalID)
            }
        }
        return goalIDs
    }

    private func normalizedScheduledIdentityURL(
        _ identity: CloudKitSourceIdentityPayload
    ) -> String? {
        if let normalized = identity.normalizedURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty {
            return normalized
        }
        guard let url = identity.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }
        return URLNormalizer.normalize(url)
    }

    private func normalizedScheduledIdentityDOI(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !value.isEmpty else { return nil }
        return value
    }

    /// Repair a ScheduledSource that arrived before its Source. Portable identity
    /// columns make this
    /// targeted and indexed; no per-source full Schedule scan is permitted.
    @discardableResult
    func reconcileScheduledSourcePlacements(forSourceID sourceID: String) throws -> Int {
        guard let identity = try sourceIdentities(for: [sourceID]).first else { return 0 }
        let normalizedURL = normalizedScheduledIdentityURL(identity)
        let doi = normalizedScheduledIdentityDOI(identity.doi)
        let publishedDOI = normalizedScheduledIdentityDOI(identity.publishedDOI)
        let portableKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: sourceID,
            normalizedURL: normalizedURL,
            doi: doi,
            publishedDOI: publishedDOI
        )
        let canonicalID = MemoryTutorIdentity.scheduledSourcePlacementID(
            portableSourceKey: portableKey
        )
        var candidateIDs = Set<String>()
        func collect(_ sql: String, _ value: String) throws {
            try queryBind(sql, bind: { statement in
                bind(statement, 1, value)
            }) { statement in
                if let id = self.string(statement, 0) { candidateIDs.insert(id) }
            }
        }
        try collect(
            "SELECT id FROM scheduled_sources INDEXED BY idx_scheduled_sources_source WHERE source_id = ?",
            sourceID
        )
        if let normalizedURL {
            try collect(
                """
                    SELECT id
                    FROM scheduled_sources INDEXED BY idx_scheduled_sources_identity_url
                    WHERE source_normalized_url = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = scheduled_sources.source_id
                      )
                """,
                normalizedURL
            )
        }
        for value in Set([doi, publishedDOI].compactMap { $0 }) {
            try collect(
                """
                    SELECT id
                    FROM scheduled_sources INDEXED BY idx_scheduled_sources_identity_doi
                    WHERE source_doi = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = scheduled_sources.source_id
                      )
                """,
                value
            )
            try collect(
                """
                    SELECT id
                    FROM scheduled_sources INDEXED BY idx_scheduled_sources_identity_published_doi
                    WHERE source_published_doi = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = scheduled_sources.source_id
                      )
                """,
                value
            )
        }
        guard !candidateIDs.isEmpty else { return 0 }

        // A portable identity can legitimately be shared by two extant local
        // sources. Exact relationships remain authoritative; never let a later
        // duplicate Source save steal a canonical placement or absorb an orphan
        // while that canonical ID already belongs to another valid source.
        if let canonical = try loadScheduledSourceRow(id: canonicalID),
           canonical.sourceID != sourceID,
           try sourceExists(canonical.sourceID) {
            return 0
        }

        var rows: [ScheduledSource] = []
        var goalIDs = Set<String>()
        var activityRows: [SourceActivityDay] = []
        var isAutomatic = true
        for id in candidateIDs.sorted() {
            if let row = try loadScheduledSourceRow(id: id) { rows.append(row) }
            goalIDs.formUnion(try scheduledSourceMembershipIDs(placementID: id))
            let candidateIsAutomatic = try scheduledSourceIsAutomatic(placementID: id)
            isAutomatic = isAutomatic && candidateIsAutomatic
            try queryBind("""
                SELECT id, source_id, day_start, first_activity_at, last_activity_at,
                       kinds, completed_kinds, max_fraction, engaged_seconds
                FROM source_activity_days
                WHERE scheduled_source_id = ?
            """, bind: { statement in
                bind(statement, 1, id)
            }) { statement in
                if let activity = self.readSourceActivityDay(statement) {
                    activityRows.append(activity)
                }
            }
        }
        guard var merged = rows.first else { return 0 }
        merged = ScheduledSource(
            id: canonicalID,
            sourceID: sourceID,
            plannedAt: merged.plannedAt,
            addedAt: merged.addedAt,
            completedAt: merged.completedAt,
            createdAt: merged.createdAt,
            updatedAt: merged.updatedAt
        )
        for row in rows.dropFirst() {
            merged = mergedScheduledSource(
                existing: merged,
                incoming: row,
                canonicalID: canonicalID,
                resolvedSourceID: sourceID
            )
        }
        let repairedCount = rows.filter {
            $0.id != canonicalID || $0.sourceID != sourceID
        }.count

        for id in candidateIDs {
            try execBind(
                "DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?",
                { statement in bind(statement, 1, id) }
            )
            try execBind(
                "DELETE FROM source_activity_days WHERE scheduled_source_id = ?",
                { statement in bind(statement, 1, id) }
            )
        }
        for id in candidateIDs {
            try execBind(
                "DELETE FROM scheduled_sources WHERE id = ?",
                { statement in bind(statement, 1, id) }
            )
        }
        try execBind("""
            INSERT INTO scheduled_sources (
                id, source_id, source_url, source_normalized_url,
                source_doi, source_published_doi,
                planned_at, added_at, completed_at, created_at, updated_at,
                is_automatic
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            bind(statement, 1, canonicalID)
            bind(statement, 2, sourceID)
            bind(statement, 3, identity.url)
            bind(statement, 4, normalizedURL)
            bind(statement, 5, doi)
            bind(statement, 6, publishedDOI)
            sqlite3_bind_double(statement, 7, merged.plannedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 8, merged.addedAt.timeIntervalSinceReferenceDate)
            bind(statement, 9, merged.completedAt?.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 10, merged.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 11, merged.updatedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(statement, 12, isAutomatic ? 1 : 0)
        }
        for goalID in goalIDs.sorted() {
            try execBind("""
                INSERT OR IGNORE INTO scheduled_source_goals (
                    scheduled_source_id, goal_id, added_at
                ) VALUES (?, ?, ?)
            """) { statement in
                bind(statement, 1, canonicalID)
                bind(statement, 2, goalID)
                sqlite3_bind_double(statement, 3, merged.addedAt.timeIntervalSinceReferenceDate)
            }
        }
        let mergedActivities = mergedSourceActivityDays(
            activityRows,
            [],
            sourceID: sourceID,
            portableSourceKey: portableKey
        )
        try replaceSourceActivityDays(
            mergedActivities,
            placementID: canonicalID,
            sourceID: sourceID
        )
        return repairedCount
    }

    /// The alias merge is intentionally commutative. `updatedAt` owns the
    /// editable planned day; equal timestamps break toward the earlier planned
    /// value so opposite CloudKit delivery orders still produce identical rows.
    /// All other dates are monotonic high/low-water marks.
    private func mergedScheduledSource(
        existing: ScheduledSource,
        incoming: ScheduledSource,
        canonicalID: String,
        resolvedSourceID: String
    ) -> ScheduledSource {
        let plannedAt: Date
        if existing.updatedAt > incoming.updatedAt {
            plannedAt = existing.plannedAt
        } else if incoming.updatedAt > existing.updatedAt {
            plannedAt = incoming.plannedAt
        } else {
            plannedAt = min(existing.plannedAt, incoming.plannedAt)
        }
        let completedAt: Date?
        switch (existing.completedAt, incoming.completedAt) {
        case let (left?, right?):
            completedAt = max(left, right)
        case let (left?, nil):
            completedAt = left
        case let (nil, right?):
            completedAt = right
        case (nil, nil):
            completedAt = nil
        }
        return ScheduledSource(
            id: canonicalID,
            sourceID: resolvedSourceID,
            plannedAt: plannedAt,
            addedAt: min(existing.addedAt, incoming.addedAt),
            completedAt: completedAt,
            createdAt: min(existing.createdAt, incoming.createdAt),
            updatedAt: max(existing.updatedAt, incoming.updatedAt)
        )
    }

}
