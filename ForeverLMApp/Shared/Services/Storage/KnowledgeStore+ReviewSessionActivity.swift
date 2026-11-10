// KnowledgeStore: review activity of sources, memory review stats and source identity aliases.
import Foundation
import SQLite3

extension KnowledgeStore {

    /// Sources attached to the learner's most recent ordinary chats and review
    /// sessions. Memory-check launch sessions are excluded by their non-empty
    /// `card_ids`: their source relationship is the whole planned queue, not
    /// evidence that every target was actually discussed. The result is only a
    /// queue-ordering preference; review dates and schedules remain unchanged.
    func recentReviewSourceActivity(
        now: Date = Date(),
        sessionLimit: Int = 12,
        maximumAgeDays: Int = 14
    ) throws -> [MemoryTutorRecentSourceActivity] {
        let boundedSessionLimit = max(0, min(sessionLimit, 50))
        let boundedAgeDays = max(1, min(maximumAgeDays, 90))
        guard boundedSessionLimit > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(boundedAgeDays) * MemoryTutorScheduler.secondsPerDay)
        var result: [MemoryTutorRecentSourceActivity] = []
        try queryBind("""
            WITH recent_sessions AS (
                SELECT
                    fs.id,
                    MAX(COALESCE(fe.answered_at, fs.ended_at, fs.started_at)) AS activity_at
                FROM review_sessions fs
                LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                WHERE fs.status IN ('active', 'completed', 'external_link')
                  AND COALESCE(fs.card_ids, '[]') = '[]'
                GROUP BY fs.id
                HAVING (fs.status = 'external_link' OR COUNT(fe.id) > 0)
                   AND activity_at >= ?
                ORDER BY activity_at DESC, fs.id
                LIMIT ?
            )
            SELECT fss.source_id, MAX(recent_sessions.activity_at) AS discussed_at
            FROM recent_sessions
            JOIN review_session_sources fss
              ON fss.session_id = recent_sessions.id
            GROUP BY fss.source_id
            ORDER BY discussed_at DESC, fss.source_id
        """, bind: { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(statement, 2, Int64(boundedSessionLimit))
        }) { statement in
            guard let sourceID = self.string(statement, 0) else { return }
            result.append(MemoryTutorRecentSourceActivity(
                sourceID: sourceID,
                discussedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)
                )
            ))
        }
        return result
    }

    /// Returns the latest review date for each source. A source is reviewed
    /// once it has a completed local review session, a saved external review
    /// chat link, or a completed Schedule item.
    func sourceReviewDates() throws -> [String: Date] {
        let aliasMap = try buildSourceIdentityAliasMap()
        var result: [String: Date] = [:]
        var rows: [(id: String, date: Date)] = []
        var sessionRows: [String: (date: Date, sourceIDs: Set<String>)] = [:]
        try query("""
            SELECT id, source_ids, COALESCE(ended_at, started_at)
            FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """) { stmt in
            guard let sessionID = self.string(stmt, 0) else { return }
            sessionRows[sessionID] = (
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
                Set(self.decodeStringArray(json: self.string(stmt, 1)) ?? [])
            )
        }
        try query("""
            SELECT fss.session_id, fss.source_id
            FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
        """) { stmt in
            guard let sessionID = self.string(stmt, 0),
                  let sourceID = self.string(stmt, 1),
                  var row = sessionRows[sessionID] else { return }
            row.sourceIDs.insert(sourceID)
            sessionRows[sessionID] = row
        }
        for (sessionID, attemptedSourceIDs) in try attemptedMemorySourceIDsBySessionID() {
            guard var row = sessionRows[sessionID] else { continue }
            row.sourceIDs = attemptedSourceIDs
            sessionRows[sessionID] = row
        }
        for row in sessionRows.values {
            for sourceID in row.sourceIDs {
                rows.append((sourceID, row.date))
            }
        }
        try query("""
            SELECT source_id, MAX(completed_at)
            FROM learning_goal_items
            WHERE completed_at IS NOT NULL
            GROUP BY source_id
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            rows.append((id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))))
        }
        for row in rows {
            recordReviewDate(row.date, for: row.id, aliasMap: aliasMap, into: &result)
        }
        return result
    }

    /// When a completed session has concept attempts, their anchors are the
    /// authoritative coverage set. The session itself may retain the larger queue
    /// it launched with so transcript context and resume remain lossless.
    private func attemptedMemorySourceIDsBySessionID() throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        try query("""
            SELECT ma.session_id, mis.source_id
            FROM memory_attempts ma
            JOIN review_sessions fs ON fs.id = ma.session_id
            LEFT JOIN memory_item_sources mis
              ON mis.memory_item_id = ma.memory_item_id
             AND ma.grade_state = 'graded'
            WHERE ma.session_id IS NOT NULL
              AND fs.status IN ('completed', 'external_link')
            ORDER BY ma.session_id, mis.source_id
        """) { stmt in
            guard let sessionID = self.string(stmt, 0) else { return }
            if result[sessionID] == nil { result[sessionID] = [] }
            if let sourceID = self.string(stmt, 1) {
                result[sessionID]?.insert(sourceID)
            }
        }
        return result
    }

    /// Per-source retention stats from completed/external reviews: when each
    /// source was last reviewed, the most recent recall score, and how many times it
    /// has been reviewed. Keyed by raw source_id and restricted to currently-active
    /// sources. Powers the daily memory-training surface. Pass `restrictToSourceIDs`
    /// (e.g. one Learning Companion goal's approved sources) for a per-notebook refresh.
    func memoryReviewStats(restrictToSourceIDs requestedSourceIDs: Set<String>? = nil) throws -> [MemoryReviewStat] {
        // Screen record mode (admin only): unchanged when off.
        let restrictToSourceIDs = try screenRecordNarrowedMemorySourceIDs(requestedSourceIDs)
        struct SessionRow { var date: Date; var score: Double?; var sourceIDs: Set<String> }
        var sessions: [String: SessionRow] = [:]

        // Session-level rows carry the score and the JSON source list.
        try query("""
            SELECT id, COALESCE(ended_at, started_at), overall_score, source_ids
            FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            let score: Double? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let ids = Set(self.decodeStringArray(json: self.string(stmt, 3)) ?? [])
            sessions[id] = SessionRow(date: date, score: score, sourceIDs: ids)
        }

        // The junction table covers sessions whose source_ids JSON is empty.
        try query("""
            SELECT fss.session_id, fss.source_id
            FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
        """) { stmt in
            guard let sid = self.string(stmt, 0), let srcID = self.string(stmt, 1) else { return }
            sessions[sid]?.sourceIDs.insert(srcID)
        }

        // Memory-review sessions may launch with a larger queue than the learner
        // actually reaches. Once concept attempts exist, their item anchors are
        // the authoritative reviewed-source set; the session relationship remains
        // the full launch/transcript context for resume and sync.
        for (sessionID, attemptedSourceIDs) in try attemptedMemorySourceIDsBySessionID() {
            sessions[sessionID]?.sourceIDs = attemptedSourceIDs
        }

        // Fold sessions into per-source aggregates (each session counted once per
        // source). `lastScore` tracks the most recent *scored* session and stays
        // order-independent regardless of dictionary iteration order.
        struct Aggregate { var last: Date; var lastScore: Double?; var lastScoreDate: Date?; var count: Int }
        var bySource: [String: Aggregate] = [:]
        for row in sessions.values {
            for srcID in row.sourceIDs {
                if let restrict = restrictToSourceIDs, !restrict.contains(srcID) { continue }
                if var agg = bySource[srcID] {
                    agg.count += 1
                    if row.date > agg.last { agg.last = row.date }
                    if let score = row.score, agg.lastScoreDate == nil || row.date >= agg.lastScoreDate! {
                        agg.lastScore = score
                        agg.lastScoreDate = row.date
                    }
                    bySource[srcID] = agg
                } else {
                    bySource[srcID] = Aggregate(
                        last: row.date,
                        lastScore: row.score,
                        lastScoreDate: row.score != nil ? row.date : nil,
                        count: 1
                    )
                }
            }
        }
        guard !bySource.isEmpty else { return [] }

        // Resolve title/type, keeping only active sources (drops archived/deleted).
        let ids = Array(bySource.keys)
        var meta: [String: (title: String, type: String)] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < ids.count {
            let chunk = Array(ids[offset..<min(offset + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            try queryBind("""
                SELECT id, title, source_type
                FROM source_projection
                WHERE status = 'active'
                  AND is_collection_hidden = 0
                  AND id IN (\(placeholders))
            """, bind: { stmt in
                for (index, id) in chunk.enumerated() { bind(stmt, index + 1, id) }
            }) { stmt in
                guard let id = self.string(stmt, 0) else { return }
                meta[id] = (self.string(stmt, 1) ?? id, self.string(stmt, 2) ?? "unknown")
            }
            offset += chunkSize
        }

        return bySource.compactMap { srcID, agg in
            guard let resolved = meta[srcID] else { return nil }
            return MemoryReviewStat(
                sourceID: srcID,
                title: resolved.title,
                sourceType: resolved.type,
                lastReviewedAt: agg.last,
                lastScore: agg.lastScore,
                reviewCount: agg.count
            )
        }
    }

    /// Sources the learner has consumed but never reviewed — how new material
    /// enters the retention loop at all.
    ///
    /// `memoryReviewStats` can only score sources that already have review history,
    /// so without this a source read once and never reviewed would never come due
    /// and would simply be forgotten. Eligibility is deliberately narrow: the
    /// source must be active, not hidden, have extracted text worth reviewing
    /// against, have no completed review of any kind, and carry positive evidence
    /// of consumption (see `SourceConsumption` — mere presence in the library never
    /// qualifies). Pass `restrictToSourceIDs` to scope to one goal's sources.
    func unreviewedConsumedSources(restrictToSourceIDs requestedSourceIDs: Set<String>? = nil) throws -> [MemoryReviewNewCandidate] {
        // Screen record mode (admin only): unchanged when off.
        let restrictToSourceIDs = try screenRecordNarrowedMemorySourceIDs(requestedSourceIDs)
        // Alias-aware and broader than `memoryReviewStats`: a source reviewed under
        // a since-deduped ID, or completed on the Schedule, is not new.
        let reviewed = try sourceIdsWithCompletedReviewSession()

        var candidates: [MemoryReviewNewCandidate] = []
        // `depth`/`depth_at` widen intake beyond explicitly finished sources: a
        // podcast played to 70% is evidence the learner went through it, even
        // though nothing ever set read_at. The bare `last_activity_at` beside a
        // single MAX() is SQLite's documented min/max row selection — it is the
        // timestamp of the deepest day, not an arbitrary one. The content check
        // must stay `octet_length` (answered from the record header); trimming
        // materialized every source's full text on each call.
        try query("""
            SELECT sp.id, sp.title, sp.source_type, sp.date_added, sp.read_at,
                   sp.reading_position_page, sp.reading_position_locator,
                   COALESCE(depth.fraction, 0), depth.reached_at
            FROM source_projection sp
            JOIN source_content sc ON sc.source_id = sp.id
            LEFT JOIN (
                SELECT source_id,
                       MAX(CASE WHEN completed_kinds != 0 THEN 1.0 ELSE max_fraction END) AS fraction,
                       last_activity_at AS reached_at
                FROM source_activity_days
                GROUP BY source_id
            ) depth ON depth.source_id = sp.id
            WHERE sp.status = 'active'
              AND sp.is_collection_hidden = 0
              AND octet_length(sc.content) > 0
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            if let restrict = restrictToSourceIDs, !restrict.contains(id) { return }
            if reviewed.contains(id) { return }

            let signals = SourceConsumptionSignals(
                readAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                readingPositionPage: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(stmt, 5)),
                readingPositionLocator: self.string(stmt, 6),
                dateAdded: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                maxFraction: sqlite3_column_double(stmt, 7),
                deepestActivityAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8))
            )
            guard let consumedAt = SourceConsumption.consumedAt(
                signals,
                minimumConfidence: .substantial
            ) else { return }

            candidates.append(
                MemoryReviewNewCandidate(
                    sourceID: id,
                    title: self.string(stmt, 1) ?? id,
                    sourceType: self.string(stmt, 2) ?? "unknown",
                    consumedAt: consumedAt
                )
            )
        }
        return candidates
    }

    /// Most recent completed reviews linked to a Learning Companion goal, newest
    /// first, for the in-app goal dashboard's history list.
    func companionRecentSessions(goalID: String, limit: Int) throws -> [CompanionSessionSummary] {
        var sessions: [CompanionSessionSummary] = []
        try queryBind("""
            SELECT id, COALESCE(ended_at, started_at), overall_score, summary
            FROM review_sessions
            WHERE goal_id = ? AND status = 'completed'
            ORDER BY COALESCE(ended_at, started_at) DESC
            LIMIT ?
        """, bind: { stmt in
            bind(stmt, 1, goalID)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            sessions.append(
                CompanionSessionSummary(
                    id: id,
                    endedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                    overallScore: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
                    summary: self.string(stmt, 3)
                )
            )
        }
        return sessions
    }

    /// Returns the set of source IDs that have been reviewed through any source,
    /// including completed Schedule items.
    func sourceIdsWithCompletedReviewSession() throws -> Set<String> {
        Set(try sourceReviewDates().keys)
    }

    /// Returns source IDs referenced by any review session, including active chats.
    func sourceIdsWithReviewSession() throws -> Set<String> {
        var sourceIDs = Set<String>()
        try query("SELECT DISTINCT source_id FROM review_session_sources") { stmt in
            if let id = self.string(stmt, 0) { sourceIDs.insert(id) }
        }
        try query("SELECT source_ids FROM review_sessions") { stmt in
            for id in self.decodeStringArray(json: self.string(stmt, 0)) ?? [] {
                sourceIDs.insert(id)
            }
        }
        return try expandingSourceIdentityAliases(sourceIDs)
    }

    /// Returns source IDs that have a completed local review session or a saved external chat link.
    func sourceIdsWithLinkedChatSession() throws -> Set<String> {
        var sourceIDs = Set<String>()
        try query("""
            SELECT DISTINCT fss.source_id FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
        """) { stmt in
            if let id = self.string(stmt, 0) { sourceIDs.insert(id) }
        }
        try query("""
            SELECT source_ids FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """) { stmt in
            for id in self.decodeStringArray(json: self.string(stmt, 0)) ?? [] {
                sourceIDs.insert(id)
            }
        }
        return try expandingSourceIdentityAliases(sourceIDs)
    }

    /// Expand a set of source IDs to include all identity aliases using the
    /// one-pass alias map. The previous per-ID `sourceIdentityAliases(for:)` loop
    /// ran two SQLite queries per session source and showed up as multi-second
    /// storage work in UI-stall samples during CloudKit remote refreshes.
    private func expandingSourceIdentityAliases(_ sourceIDs: Set<String>) throws -> Set<String> {
        guard !sourceIDs.isEmpty else { return [] }
        let aliasMap = try buildSourceIdentityAliasMap()
        var result = Set<String>()
        for sourceID in sourceIDs {
            result.formUnion(aliasMap[sourceID] ?? [sourceID])
        }
        return result
    }

    func sourceHasLinkedChatSession(_ sourceID: String) throws -> Bool {
        let aliases = try sourceIdentityAliases(for: sourceID)
        let placeholders = aliases.map { _ in "?" }.joined(separator: ",")
        var hasSession = false
        try queryBind("""
            SELECT 1 FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fss.source_id IN (\(placeholders))
              AND fs.status IN ('completed', 'external_link')
            LIMIT 1
        """, bind: { stmt in
            for (index, alias) in aliases.enumerated() {
                bind(stmt, index + 1, alias)
            }
        }) { _ in
            hasSession = true
        }
        if !hasSession {
            try query("""
                SELECT source_ids FROM review_sessions
                WHERE status IN ('completed', 'external_link')
            """) { stmt in
                guard !hasSession else { return }
                hasSession = !(Set(self.decodeStringArray(json: self.string(stmt, 0)) ?? []).isDisjoint(with: aliases))
            }
        }
        return hasSession
    }

    func recordReviewDate(_ date: Date, for sourceID: String, into result: inout [String: Date]) throws {
        for id in try sourceIdentityAliases(for: sourceID) {
            if let existing = result[id] {
                result[id] = max(existing, date)
            } else {
                result[id] = date
            }
        }
    }

    func recordReviewDate(
        _ date: Date,
        for sourceID: String,
        aliasMap: [String: Set<String>],
        into result: inout [String: Date]
    ) {
        for id in aliasMap[sourceID] ?? [sourceID] {
            if let existing = result[id] {
                result[id] = max(existing, date)
            } else {
                result[id] = date
            }
        }
    }

    func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func sourceIdentityAliases(for sourceID: String) throws -> Set<String> {
        var aliases: Set<String> = [sourceID]
        var url: String?
        var normalizedURL: String?
        var doi: String?

        try queryBind("""
            SELECT url, normalized_url, doi
            FROM source_projection
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            url = self.string(stmt, 0)
            normalizedURL = self.string(stmt, 1)
            doi = self.string(stmt, 2)
        }

        let trimmedURL = trimmedNonEmpty(url)
        let normalizedFromURL = trimmedURL.map(URLNormalizer.normalize).flatMap { trimmedNonEmpty($0) }
        let normalizedCandidates = Set([
            trimmedNonEmpty(normalizedURL),
            normalizedFromURL
        ].compactMap { $0 })
        let normalizedDOI = trimmedNonEmpty(doi)?.lowercased()

        guard !normalizedCandidates.isEmpty || normalizedDOI != nil || trimmedURL != nil else {
            return aliases
        }

        var clauses = ["id = ?"]
        var params = [sourceID]
        if let trimmedURL {
            clauses.append("url = ?")
            params.append(trimmedURL)
        }
        for normalized in normalizedCandidates.sorted() {
            clauses.append("normalized_url = ?")
            params.append(normalized)
        }
        if let normalizedDOI {
            clauses.append("LOWER(doi) = ?")
            params.append(normalizedDOI)
        }

        try queryBind("""
            SELECT id
            FROM source_projection
            WHERE \(clauses.joined(separator: " OR "))
        """, bind: { stmt in
            for (index, param) in params.enumerated() {
                bind(stmt, index + 1, param)
            }
        }) { stmt in
            if let id = self.string(stmt, 0) {
                aliases.insert(id)
            }
        }

        return aliases
    }

    /// One-pass alias lookup for all sources. Used by `sourceReviewDates()` to
    /// avoid N+1 SQLite queries during startup queue load.
    func buildSourceIdentityAliasMap() throws -> [String: Set<String>] {
        struct Row {
            let id: String
            let url: String?
            let normalizedURL: String?
            let doi: String?
        }

        var rows: [Row] = []
        try query("""
            SELECT id, url, normalized_url, doi
            FROM source_projection
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            rows.append(Row(
                id: id,
                url: self.string(stmt, 1),
                normalizedURL: self.string(stmt, 2),
                doi: self.string(stmt, 3)
            ))
        }

        var parent: [String: String] = [:]
        func find(_ id: String) -> String {
            var current = id
            while parent[current] != current {
                parent[current] = parent[parent[current]!]!
                current = parent[current]!
            }
            return current
        }
        func unite(_ lhs: String, _ rhs: String) {
            let rootLHS = find(lhs)
            let rootRHS = find(rhs)
            guard rootLHS != rootRHS else { return }
            parent[rootRHS] = rootLHS
        }

        var bucketOwner: [String: String] = [:]
        func link(_ id: String, bucket: String) {
            parent[id] = id
            if let owner = bucketOwner[bucket] {
                unite(id, owner)
            } else {
                bucketOwner[bucket] = id
            }
        }

        for row in rows {
            link(row.id, bucket: "id:\(row.id)")
            if let trimmedURL = trimmedNonEmpty(row.url) {
                link(row.id, bucket: "url:\(trimmedURL)")
            }
            let normalizedFromURL = trimmedNonEmpty(row.url)
                .map(URLNormalizer.normalize)
                .flatMap { trimmedNonEmpty($0) }
            let normalizedCandidates = Set([
                trimmedNonEmpty(row.normalizedURL),
                normalizedFromURL
            ].compactMap { $0 })
            for normalized in normalizedCandidates {
                link(row.id, bucket: "norm:\(normalized)")
            }
            if let normalizedDOI = trimmedNonEmpty(row.doi)?.lowercased() {
                link(row.id, bucket: "doi:\(normalizedDOI)")
            }
        }

        var groups: [String: Set<String>] = [:]
        for row in rows {
            groups[find(row.id), default: []].insert(row.id)
        }

        var aliasMap: [String: Set<String>] = [:]
        for row in rows {
            aliasMap[row.id] = groups[find(row.id)] ?? [row.id]
        }
        return aliasMap
    }

}
