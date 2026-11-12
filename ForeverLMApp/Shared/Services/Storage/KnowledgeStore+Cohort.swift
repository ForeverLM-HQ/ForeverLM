import Foundation
import SQLite3

extension KnowledgeStore {

    /// Every source with real consumption evidence, paired with its review
    /// history. One query; the bucketing that turns this into a cohort is a pure
    /// function in `CohortSelector` so it can be tested without a database.
    ///
    /// `depth` folds the activity ledger down to how much of the source actually
    /// landed, and the bare `last_activity_at` beside a single MAX() is SQLite's
    /// documented min/max row selection — the timestamp of the deepest day.
    ///
    /// The content check must stay `octet_length`, which SQLite answers from the
    /// record header. `length(trim(...))` materialized every source's full text —
    /// the entire content table — on each call, and this runs on every app
    /// activation.
    func cohortCandidates(
        now: Date = Date(),
        minimumConfidence: SourceConsumptionConfidence = .substantial,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [CohortCandidate] {
        if let restrictToSourceIDs, restrictToSourceIDs.isEmpty { return [] }

        // Graded contours are the memory review's own record of a source being
        // discussed. A memory chat stays `active` all day, so the session
        // history below would never count it; the grade does, and it is what
        // the ladder is derived from.
        let contourHistory = try memoryContourHistory()
        // Chats the learner wrote in, by the source they were about: the
        // ledger's strongest evidence (docs/memory-design.md, "The engagement
        // ledger"). Looked up in Swift rather than joined; the set is small.
        let chatDiscussed = try chatDiscussionDates(now: now)

        var candidates: [CohortCandidate] = []
        try query("""
            SELECT sp.id, sp.title, sp.source_type, sp.date_added, sp.read_at,
                   sp.reading_position_page, sp.reading_position_locator,
                   COALESCE(depth.fraction, 0), depth.reached_at,
                   COALESCE(hist.review_count, 0), hist.last_discussed,
                   COALESCE(depth.engaged, 0), sp.word_count,
                   COALESCE(marks.annotation_count, 0)
            FROM source_projection sp
            JOIN source_content sc ON sc.source_id = sp.id
            LEFT JOIN (
                SELECT source_id,
                       MAX(CASE WHEN completed_kinds != 0 THEN 1.0 ELSE max_fraction END) AS fraction,
                       last_activity_at AS reached_at,
                       SUM(\(Self.engagedTimeExpression)) AS engaged
                FROM source_activity_days
                GROUP BY source_id
            ) depth ON depth.source_id = sp.id
            LEFT JOIN (
                SELECT fss.source_id,
                       COUNT(DISTINCT fs.id) AS review_count,
                       MAX(COALESCE(fs.ended_at, fs.started_at)) AS last_discussed
                FROM review_session_sources fss
                JOIN review_sessions fs ON fs.id = fss.session_id
                WHERE fs.status IN ('completed', 'external_link')
                GROUP BY fss.source_id
            ) hist ON hist.source_id = sp.id
            LEFT JOIN (
                SELECT source_id, COUNT(*) AS annotation_count
                FROM source_highlights
                WHERE \(Self.notBareSlideMark)
                GROUP BY source_id
            ) marks ON marks.source_id = sp.id
            WHERE sp.status = 'active'
              AND sp.is_collection_hidden = 0
              AND octet_length(sc.content) > 0
              -- An audio overview's script retells its notebook's sources:
              -- hearing it is not a source to review, and its ideas would
              -- repeat theirs.
              AND \(Self.notAudioOverviewScriptURL("sp.url"))
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            if let restrict = restrictToSourceIDs, !restrict.contains(id) { return }

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
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                engagedSeconds: sqlite3_column_double(stmt, 11),
                expectedSeconds: SourceConsumption.expectedSeconds(
                    wordCount: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 12))
                ),
                chatDiscussedAt: chatDiscussed[id],
                annotationCount: Int(sqlite3_column_int64(stmt, 13))
            )
            guard let consumedAt = SourceConsumption.consumedAt(
                signals,
                minimumConfidence: minimumConfidence
            ) else { return }
            // A source consumed "in the future" would sort ahead of everything
            // real; clock skew and hand-edited dates both produce it.
            guard consumedAt <= now else { return }

            let contours = contourHistory[id] ?? []
            let sessionReviewCount = Int(sqlite3_column_int64(stmt, 9))
            let sessionLastDiscussed: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))
            let contourLastGraded = contours.last?.gradedAt
            let lastDiscussed = [sessionLastDiscussed, contourLastGraded].compactMap { $0 }.max()
            candidates.append(
                CohortCandidate(
                    sourceID: id,
                    title: self.string(stmt, 1) ?? id,
                    sourceType: self.string(stmt, 2) ?? "unknown",
                    consumedAt: consumedAt,
                    confidence: SourceConsumption.confidence(signals),
                    reviewCount: max(sessionReviewCount, Set(contours.map(\.sessionID)).count),
                    lastDiscussedAt: lastDiscussed,
                    contourRung: contours.isEmpty
                        ? nil
                        : ForeverLMCore.memoryReviewRung(producedFractions: contours.map(\.producedFraction)),
                    engagement: MemoryReviewCandidates.engagement(signals: signals),
                    isFinished: SourceConsumption.isFinished(signals)
                )
            )
        }
        // The chats the learner had are material too; see `ReviewableChat`.
        for chat in try reviewableChatCandidates(now: now, contourHistory: contourHistory) {
            if let restrict = restrictToSourceIDs, !restrict.contains(chat.sourceID) { continue }
            candidates.append(chat)
        }
        return candidates
    }

    /// A day's time evidence as SQL: measured seconds when the row has them,
    /// else the span between its first and last activity — the value-level
    /// twin of `SourceActivityDay.engagedTime`, kept identical so the Mac and
    /// the phone gate the same rows the same way.
    static let engagedTimeExpression = """
        CASE WHEN engaged_seconds > 0 THEN engaged_seconds
             ELSE MAX(0, last_activity_at - first_activity_at) END
        """

    /// Ordinary chats the learner wrote in — not memory reviews, graded
    /// quizzes, scheduled tasks' chats, or chats nobody took part in — and
    /// when they last wrote in each. The SQL twin of
    /// `MemoryReviewCandidates.SessionInput.isChatDiscussion`.
    func chatDiscussionSessions(now: Date) throws -> [String: Date] {
        var result: [String: Date] = [:]
        try queryBind("""
            SELECT fs.id,
                   COALESCE(MAX(e.answered_at), fs.ended_at, fs.started_at) AS last_turn
            FROM review_sessions fs
            JOIN review_exchanges e ON e.session_id = fs.id
            WHERE fs.status IN ('active', 'completed')
              AND COALESCE(fs.kind, 'chat') = 'chat'
              AND fs.id NOT LIKE ?
              AND COALESCE(fs.card_ids, '[]') IN ('[]', '')
              AND fs.overall_score IS NULL
              AND TRIM(COALESCE(e.user_answer, '')) <> ''
              AND NOT EXISTS (SELECT 1 FROM scheduled_task_runs r WHERE r.session_id = fs.id)
              AND NOT EXISTS (
                  SELECT 1 FROM review_exchanges g
                  WHERE g.session_id = fs.id AND (g.score IS NOT NULL OR g.idea_coverage IS NOT NULL)
              )
            GROUP BY fs.id
        """, bind: { stmt in
            bind(stmt, 1, MemoryReviewSession.idPrefix + "%")
        }) { stmt in
            guard let id = self.string(stmt, 0), sqlite3_column_type(stmt, 1) != SQLITE_NULL else { return }
            let at = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            guard at <= now else { return }
            result[id] = at
        }
        return result
    }

    /// The most recent day each source was discussed in a chat the learner
    /// wrote in: cited by in-app link in one of the chat's turns, or the one
    /// source the chat was opened on (`ChatSourceEvidence.discussedSourceIDs`).
    ///
    /// Attachment alone does not count. A Notebook chat attaches the whole
    /// Notebook, so one question across 122 sources would make every
    /// one of them "discussed yesterday" — most of the next morning's
    /// review sources would only ever have been context behind such a question. The
    /// exchange rows' `source_refs` carry the same attached set, so they are
    /// not read here either; the turns' text is, and only the rows that hold
    /// a link are pulled out of the table.
    func chatDiscussionDates(now: Date) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for chat in try chatDiscussions(now: now) {
            for sourceID in chat.sourceIDs {
                result[sourceID] = max(result[sourceID] ?? .distantPast, chat.at)
            }
        }
        return result
    }

    /// One chat the learner wrote in, with when they last wrote in it and the
    /// sources it discussed (`ChatSourceEvidence.discussedSourceIDs`).
    struct ChatDiscussion: Equatable, Sendable {
        let sessionID: String
        let at: Date
        let sourceIDs: Set<String>
    }

    /// The chats the learner wrote in, each with the sources it discussed:
    /// what `chatDiscussionDates` folds by source, and what background card
    /// drafting reads to find a chat that discussed many sources
    /// (`AutomaticCardDrafting.wideChatSourceIDs`). A chat that discussed
    /// none is left out.
    func chatDiscussions(now: Date) throws -> [ChatDiscussion] {
        let sessions = try chatDiscussionSessions(now: now)
        guard !sessions.isEmpty else { return [] }

        var attachedBySession: [String: Set<String>] = [:]
        try query("SELECT session_id, source_id FROM review_session_sources") { stmt in
            guard let sessionID = self.string(stmt, 0), let sourceID = self.string(stmt, 1),
                  sessions[sessionID] != nil else { return }
            attachedBySession[sessionID, default: []].insert(sourceID)
        }

        // Collect first, resolve after: resolving a token runs its own query,
        // and the tokens are few once the rows without a link are skipped.
        var tokensBySession: [String: [String]] = [:]
        try queryBind("""
            SELECT session_id, question, user_answer, evaluation
            FROM review_exchanges
            WHERE instr(COALESCE(question, ''), ?) > 0
               OR instr(COALESCE(user_answer, ''), ?) > 0
               OR instr(COALESCE(evaluation, ''), ?) > 0
        """, bind: { stmt in
            for index in 1...3 { bind(stmt, index, ChatSourceEvidence.sourceLinkMarker) }
        }) { stmt in
            guard let sessionID = self.string(stmt, 0), sessions[sessionID] != nil else { return }
            let tokens = ChatSourceEvidence.sourceLinkTokens(
                question: self.string(stmt, 1),
                userAnswer: self.string(stmt, 2),
                evaluation: self.string(stmt, 3)
            )
            if !tokens.isEmpty { tokensBySession[sessionID, default: []].append(contentsOf: tokens) }
        }
        var resolvedByToken: [String: String?] = [:]
        var citedBySession: [String: Set<String>] = [:]
        for (sessionID, tokens) in tokensBySession {
            for token in tokens {
                let resolved: String?
                if let known = resolvedByToken[token] {
                    resolved = known
                } else {
                    resolved = try resolveSourceID(forLinkToken: token)
                    resolvedByToken[token] = resolved
                }
                if let resolved { citedBySession[sessionID, default: []].insert(resolved) }
            }
        }

        return sessions.compactMap { sessionID, at in
            let discussed = ChatSourceEvidence.discussedSourceIDs(
                attached: attachedBySession[sessionID] ?? [],
                cited: citedBySession[sessionID] ?? []
            )
            return discussed.isEmpty ? nil : ChatDiscussion(sessionID: sessionID, at: at, sourceIDs: discussed)
        }
        .sorted { ($0.at, $0.sessionID) > ($1.at, $1.sessionID) }
    }

    /// One row per source with activity in a window: the ledger's raw material
    /// for "also opened yesterday" and the day's totals.
    struct EngagementDayRow: Equatable, Sendable {
        let sourceID: String
        let title: String
        let sourceType: String
        let lastActivityAt: Date
        let engagedSeconds: Double
        let depth: Double
        let listened: Bool
    }

    func engagementRows(since: Date, now: Date) throws -> [EngagementDayRow] {
        var rows: [EngagementDayRow] = []
        let listenMask = sourceActivityMask([.listening, .watching])
        try queryBind("""
            SELECT sp.id, sp.title, sp.source_type,
                   MAX(sad.last_activity_at),
                   SUM(\(Self.engagedTimeExpression)),
                   MAX(CASE WHEN sad.completed_kinds != 0 THEN 1.0 ELSE sad.max_fraction END),
                   MAX(CASE WHEN (sad.kinds & ?) != 0 THEN 1 ELSE 0 END)
            FROM source_activity_days sad
            JOIN source_projection sp ON sp.id = sad.source_id
            WHERE sad.last_activity_at >= ? AND sad.last_activity_at <= ?
              AND sp.status = 'active' AND sp.is_collection_hidden = 0
            GROUP BY sp.id
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, listenMask)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            rows.append(
                EngagementDayRow(
                    sourceID: id,
                    title: self.string(stmt, 1) ?? id,
                    sourceType: self.string(stmt, 2) ?? "unknown",
                    lastActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                    engagedSeconds: sqlite3_column_double(stmt, 4),
                    depth: SourceActivityDay.clampFraction(sqlite3_column_double(stmt, 5)),
                    listened: sqlite3_column_int64(stmt, 6) != 0
                )
            )
        }
        return rows
    }

    /// Time spent with one source across its activity days, for the automatic
    /// read mark's time floor.
    func sourceEngagedSeconds(sourceID: String) throws -> Double {
        var total = 0.0
        try queryBind("""
            SELECT COALESCE(SUM(\(Self.engagedTimeExpression)), 0)
            FROM source_activity_days WHERE source_id = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            total = sqlite3_column_double(stmt, 0)
        }
        return total
    }

    /// Every ordinary chat the learner took part in and said enough in, as a
    /// candidate under the session's own id (`ReviewableChat`). The numbers
    /// qualification turns on are summed in SQL so this stays cheap enough for
    /// every app activation; the transcript itself is read only when a chat is
    /// prepared or briefed (`reviewableChat(sessionID:)`).
    ///
    /// The ladder is the contours graded against the chat's ideas, whose ids
    /// name the session as their source, exactly as a source's are.
    func reviewableChatCandidates(
        now: Date,
        contourHistory: [String: [MemoryContourOutcome]]
    ) throws -> [CohortCandidate] {
        var candidates: [CohortCandidate] = []
        try query("""
            SELECT fs.id, fs.topic, fs.kind, fs.status, fs.started_at, fs.ended_at,
                   COALESCE(fs.card_ids, '[]'), fs.overall_score,
                   COALESCE(SUM(LENGTH(e.question) + LENGTH(COALESCE(e.evaluation, ''))), 0),
                   COALESCE(SUM(CASE WHEN TRIM(COALESCE(e.user_answer, '')) <> '' THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN e.score IS NOT NULL OR e.idea_coverage IS NOT NULL THEN 1 ELSE 0 END), 0),
                   MAX(e.answered_at),
                   EXISTS (SELECT 1 FROM scheduled_task_runs r WHERE r.session_id = fs.id)
            FROM review_sessions fs
            JOIN review_exchanges e ON e.session_id = fs.id
            WHERE fs.status IN ('active', 'completed')
              AND COALESCE(fs.kind, 'chat') = 'chat'
            GROUP BY fs.id
        """) { stmt in
            guard let id = self.string(stmt, 0), let status = self.string(stmt, 3) else { return }
            let startedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            let endedAt: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
            let cardIDs = self.string(stmt, 6) ?? "[]"
            let lastAnswered: Date? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11))
            let summary = ReviewableChat.Summary(
                title: self.string(stmt, 1) ?? "Chat",
                kind: self.string(stmt, 2),
                hasCardIDs: !(cardIDs == "[]" || cardIDs.isEmpty),
                overallScore: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                learnerTurns: Int(sqlite3_column_int64(stmt, 9)),
                assistantCharacters: Int(sqlite3_column_int64(stmt, 8)),
                gradedExchanges: Int(sqlite3_column_int64(stmt, 10)),
                isScheduledTaskRun: sqlite3_column_int64(stmt, 12) != 0,
                lastActivityAt: lastAnswered ?? endedAt ?? startedAt
            )
            guard ReviewableChat.qualifies(id: id, status: status, summary: summary),
                  summary.lastActivityAt <= now else { return }
            let contours = contourHistory[id] ?? []
            candidates.append(
                CohortCandidate(
                    sourceID: id,
                    title: summary.title,
                    sourceType: ReviewableChat.sourceType,
                    consumedAt: summary.lastActivityAt,
                    confidence: .complete,
                    reviewCount: Set(contours.map(\.sessionID)).count,
                    lastDiscussedAt: contours.last?.gradedAt,
                    contourRung: contours.isEmpty
                        ? nil
                        : ForeverLMCore.memoryReviewRung(producedFractions: contours.map(\.producedFraction))
                )
            )
        }
        return candidates
    }

    /// One chat as review material: its title and the transcript its ideas are
    /// extracted from. nil when the session does not exist or is not a
    /// reviewable chat by `ReviewableChat.qualifies`, so a caller that was
    /// handed a source id and found no source can ask here without guessing.
    func reviewableChat(sessionID: String) throws -> ReviewableChatTranscript? {
        var row: (title: String, kind: String?, status: String, startedAt: Date, endedAt: Date?, cardIDs: String, overallScore: Double?, isRun: Bool)?
        try queryBind("""
            SELECT fs.topic, fs.kind, fs.status, fs.started_at, fs.ended_at, COALESCE(fs.card_ids, '[]'), fs.overall_score,
                   EXISTS (SELECT 1 FROM scheduled_task_runs r WHERE r.session_id = fs.id)
            FROM review_sessions fs
            WHERE fs.id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let status = self.string(stmt, 2) else { return }
            row = (
                title: self.string(stmt, 0) ?? "Chat",
                kind: self.string(stmt, 1),
                status: status,
                startedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                endedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                cardIDs: self.string(stmt, 5) ?? "[]",
                overallScore: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
                isRun: sqlite3_column_int64(stmt, 7) != 0
            )
        }
        guard let row else { return nil }
        let exchanges = try loadReviewExchanges(sessionID: sessionID).map {
            ReviewableChat.Exchange(
                sequenceNumber: $0.sequenceNumber,
                question: $0.question,
                userAnswer: $0.userAnswer,
                evaluation: $0.evaluation,
                score: $0.score,
                ideaCoverage: $0.ideaCoverage,
                answeredAt: $0.answeredAt
            )
        }
        let summary = ReviewableChat.summary(
            title: row.title,
            kind: row.kind,
            hasCardIDs: !(row.cardIDs == "[]" || row.cardIDs.isEmpty),
            overallScore: row.overallScore,
            exchanges: exchanges,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            isScheduledTaskRun: row.isRun
        )
        guard ReviewableChat.qualifies(id: sessionID, status: row.status, summary: summary) else { return nil }
        return ReviewableChatTranscript(
            sessionID: sessionID,
            title: summary.title,
            text: ReviewableChat.transcript(title: summary.title, exchanges: exchanges)
        )
    }

    /// One representative vector per source, for bridge selection.
    ///
    /// The first chunk is a deliberate proxy rather than a pooled average: for the
    /// papers and articles this library is mostly made of, the opening chunk is
    /// the abstract or lede, which is the most topical part of the document. A
    /// source with no index yet simply cannot be bridged.
    func cohortProbeVector(sourceID: String) throws -> [Float]? {
        try loadEmbedding(entityType: .sourceChunk, entityId: "\(sourceID)::chunk::0")
    }

    /// The notebooks holding each of `sourceIDs` in their approved pool, by
    /// title: what says whether Go deeper's analogy partner sits in another
    /// notebook (`MemoryUnderstandingProbe.isInAnotherNotebook`). A Goal is
    /// not a notebook, and a pending or rejected suggestion is not a member;
    /// under generation 2 a merged or moved notebook's stub is a redirect,
    /// never a notebook of its own. A source in none is absent.
    func notebooksHolding(sourceIDs: [String]) throws -> [String: [MemoryUnderstandingProbe.Notebook]] {
        let ids = Array(Set(sourceIDs))
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let live = "AND COALESCE(g.merged_into, '') = '' AND COALESCE(g.moved_to, '') = ''"
        var result: [String: [MemoryUnderstandingProbe.Notebook]] = [:]
        try queryBind("""
            SELECT DISTINCT i.source_id, g.id, g.title, g.kind, g.end_at, g.parent_notebook_id
            FROM learning_goal_items i
            JOIN learning_goals g ON g.id = i.goal_id
            WHERE i.source_id IN (\(placeholders))
              AND COALESCE(i.review_state, 'approved') = 'approved'
              \(live)
            ORDER BY g.title COLLATE NOCASE, g.id
        """, bind: { stmt in
            for (index, id) in ids.enumerated() { bind(stmt, index + 1, id) }
        }) { stmt in
            guard let sourceID = self.string(stmt, 0), let notebookID = self.string(stmt, 1),
                  LearningGoalShape.isNotebook(
                    kind: self.string(stmt, 3),
                    parentNotebookID: self.string(stmt, 5),
                    endAtReferenceSeconds: sqlite3_column_double(stmt, 4)
                  ) else { return }
            let title = (self.string(stmt, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result[sourceID, default: []].append(
                MemoryUnderstandingProbe.Notebook(id: notebookID, title: title.isEmpty ? "Untitled notebook" : title)
            )
        }
        return result
    }

    /// The titles of those of `sourceIDs` a learner can be shown as an
    /// analogy's partner: active and not hidden (`source_projection.is_hidden`
    /// covers a hidden source, episode, show or channel), with a title.
    func visibleSourceTitles(sourceIDs: [String]) throws -> [String: String] {
        let ids = Array(Set(sourceIDs))
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        var titles: [String: String] = [:]
        try queryBind("""
            SELECT id, title FROM source_projection
            WHERE id IN (\(placeholders)) AND status = 'active' AND is_hidden = 0
        """, bind: { stmt in
            for (index, id) in ids.enumerated() { bind(stmt, index + 1, id) }
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            let title = (self.string(stmt, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles[id] = title }
        }
        return titles
    }

    /// Past questions about this source that the learner answered well.
    ///
    /// These are grounding exemplars. Judging a generated question in isolation
    /// is unreliable; judging it beside known-good examples drawn from the same
    /// material is markedly better, and here the examples have the added weight
    /// of having already worked for this particular learner.
    ///
    /// Matched on `source_refs` rather than session membership: a session
    /// covering five sources says nothing about which one a given question was
    /// about, and a mislabeled exemplar is worse than none.
    func exemplarQuestions(sourceID: String, limit: Int = 4) throws -> [String] {
        var questions: [String] = []
        try queryBind("""
            SELECT fe.question
            FROM review_exchanges fe
            WHERE fe.score >= 0.7
              AND TRIM(fe.question) != ''
              AND fe.source_refs LIKE '%"' || ? || '"%'
            ORDER BY fe.answered_at DESC
            LIMIT ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int64(stmt, 2, Int64(max(0, limit)))
        }) { stmt in
            if let question = self.string(stmt, 0) { questions.append(question) }
        }
        return questions
    }

    /// Summaries of the most recent completed reviews, newest first.
    func recentReviewSessionSummaries(limit: Int = 3) throws -> [String] {
        var summaries: [String] = []
        try queryBind("""
            SELECT summary
            FROM review_sessions
            WHERE status = 'completed'
              AND summary IS NOT NULL
              AND TRIM(summary) != ''
            ORDER BY COALESCE(ended_at, started_at) DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))
        }) { stmt in
            if let summary = self.string(stmt, 0) { summaries.append(summary) }
        }
        return summaries
    }
}

/// A chat read as review material: what the idea extraction and the brief work
/// from. Built by `KnowledgeStore.reviewableChat(sessionID:)`.
struct ReviewableChatTranscript: Equatable, Sendable {
    let sessionID: String
    let title: String
    /// `ReviewableChat.transcript`, whole; its hash is the ideas' content hash.
    let text: String

    /// The head of the transcript, cut to what a brief carries.
    func excerpt(maxCharacters: Int) -> String {
        String(text.prefix(maxCharacters))
    }
}
