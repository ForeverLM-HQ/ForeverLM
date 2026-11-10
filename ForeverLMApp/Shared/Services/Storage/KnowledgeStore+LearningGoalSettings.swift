// KnowledgeStore: related notebooks, goal items and gaps, and the setters of a notebook.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    func relatedNotebookIDsForNotebook(notebookID: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT related_notebook_id
            FROM notebook_related_notebook_links
            WHERE notebook_id = ?
            ORDER BY linked_at, related_notebook_id
        """, bind: { stmt in
            bind(stmt, 1, notebookID)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Replace a Notebook's directional context links. Notebooks stay flat and
    /// their source memberships remain independent.
    func setRelatedNotebooks(notebookID: String, relatedNotebookIDs: [String]) throws {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        let ids = dictUnique(relatedNotebookIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        guard ids.count <= 50 else {
            throw KnowledgeStoreError.invalidData("A Notebook can link at most 50 related Notebooks.")
        }
        guard !ids.contains(notebookID) else {
            throw KnowledgeStoreError.invalidData("A Notebook cannot link to itself.")
        }
        for id in ids {
            guard let related = try loadLearningGoal(id), related.isNotebook else {
                throw KnowledgeStoreError.invalidData("Related Notebook not found: \(id)")
            }
        }

        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try replaceRelatedNotebookLinksInCurrentTransaction(
                notebookID: notebookID,
                relatedNotebookIDs: ids,
                linkedAt: now
            )
            try touchLearningGoal(notebookID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Each link is stamped a millisecond after the one before it, so the
    /// order the caller gave (`ORDER BY linked_at` in
    /// `relatedNotebookIDsForNotebook`) is the order read back: a notebook's
    /// context notebooks are listed, and read into its chats, in link order,
    /// the same on every device the record reaches. One stamp for all fell
    /// back to the ids' order.
    func replaceRelatedNotebookLinksInCurrentTransaction(
        notebookID: String,
        relatedNotebookIDs: [String],
        linkedAt: Date
    ) throws {
        try execBind("DELETE FROM notebook_related_notebook_links WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, notebookID)
        }
        let ids = dictUnique(relatedNotebookIDs).filter { $0 != notebookID }
        for (index, relatedID) in ids.enumerated() {
            try execBind("""
                INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at)
                VALUES (?, ?, ?)
            """) { stmt in
                bind(stmt, 1, notebookID)
                bind(stmt, 2, relatedID)
                sqlite3_bind_double(stmt, 3, linkedAt.timeIntervalSinceReferenceDate + Double(index) / 1_000)
            }
        }
    }

    /// research_questions column codec: a JSON string array, kept nil (never
    /// "[]") for never-set so sync can tell no-opinion from explicitly empty.
    static func decodeResearchQuestions(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    static func encodeResearchQuestions(_ questions: [String]) -> String {
        guard let data = try? JSONEncoder().encode(questions),
              let encoded = String(data: data, encoding: .utf8) else { return "[]" }
        return encoded
    }

    func loadLearningGoalGaps(goalID: String) throws -> [LearningGoalGap] {
        var gaps: [LearningGoalGap] = []
        try queryBind("""
            SELECT id, goal_id, summary, source_id, status, severity, first_seen_at, last_seen_at, resolved_at, session_id
            FROM learning_goal_gaps
            WHERE goal_id = ?
            ORDER BY first_seen_at ASC
        """, bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1),
                  let summary = self.string(stmt, 2),
                  let status = self.string(stmt, 4) else { return }
            gaps.append(
                LearningGoalGap(
                    id: id,
                    goalID: goalID,
                    summary: summary,
                    sourceID: self.string(stmt, 3),
                    status: status,
                    severity: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                    firstSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6)),
                    lastSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
                    resolvedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                    sessionID: self.string(stmt, 9)
                )
            )
        }
        return gaps
    }

    func loadLearningGoalItems(goalID: String) throws -> [LearningGoalItem] {
        var items: [LearningGoalItem] = []
        try queryBind("""
            SELECT id, goal_id, source_id, added_at, completed_at, origin, review_state, relevance, last_quizzed_at, quiz_count, last_score, sequence
            FROM learning_goal_items
            WHERE goal_id = ?
            ORDER BY (sequence IS NULL) ASC, sequence ASC, added_at ASC, source_id ASC
        """, bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1),
                  let sourceID = self.string(stmt, 2) else { return }
            items.append(
                LearningGoalItem(
                    id: id,
                    goalID: goalID,
                    sourceID: sourceID,
                    addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                    completedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                    origin: self.string(stmt, 5),
                    reviewState: self.string(stmt, 6),
                    relevance: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                    lastQuizzedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                    quizCount: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 9)),
                    lastScore: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10),
                    sequence: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11)
                )
            )
        }
        return items
    }

    func insertLearningGoalItem(
        goalID: String,
        sourceID: String,
        addedAt: Date = Date(),
        origin: String? = nil,
        reviewState: String? = nil,
        relevance: Double? = nil
    ) throws {
        let item = LearningGoalItem(
            id: UUID().uuidString,
            goalID: goalID,
            sourceID: sourceID,
            addedAt: addedAt,
            completedAt: nil,
            origin: origin,
            reviewState: reviewState,
            relevance: relevance
        )
        try saveLearningGoalItem(item, goalID: goalID, ignoreDuplicates: true)
    }

    /// A new item takes `orderKey`, or a key after the pool's last, so its Entry has its place
    /// (schema v2 §3.5.8).
    func saveLearningGoalItem(_ item: LearningGoalItem, goalID: String, ignoreDuplicates: Bool = false, orderKey: String? = nil) throws {
        let insertVerb = ignoreDuplicates ? "INSERT OR IGNORE" : "INSERT"
        let key = try orderKey ?? EntryOrderKeys.appendedKey(goalID: goalID, connection: self)
        try execBind("""
            \(insertVerb) INTO learning_goal_items (id, goal_id, source_id, added_at, completed_at, origin, review_state, relevance, last_quizzed_at, quiz_count, last_score, sequence, order_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { stmt in
            bind(stmt, 1, item.id)
            bind(stmt, 2, goalID)
            bind(stmt, 3, item.sourceID)
            sqlite3_bind_double(stmt, 4, item.addedAt.timeIntervalSinceReferenceDate)
            if let completedAt = item.completedAt {
                sqlite3_bind_double(stmt, 5, completedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            bind(stmt, 6, item.origin)
            bind(stmt, 7, item.reviewState)
            if let relevance = item.relevance { sqlite3_bind_double(stmt, 8, relevance) } else { sqlite3_bind_null(stmt, 8) }
            if let lastQuizzedAt = item.lastQuizzedAt { sqlite3_bind_double(stmt, 9, lastQuizzedAt.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 9) }
            if let quizCount = item.quizCount { sqlite3_bind_int64(stmt, 10, Int64(quizCount)) } else { sqlite3_bind_null(stmt, 10) }
            if let lastScore = item.lastScore { sqlite3_bind_double(stmt, 11, lastScore) } else { sqlite3_bind_null(stmt, 11) }
            if let sequence = item.sequence { sqlite3_bind_double(stmt, 12, sequence) } else { sqlite3_bind_null(stmt, 12) }
            bind(stmt, 13, key)
        }
    }

    func learningGoalItemPlannedDate(_ date: Date, order: Int) -> Date {
        let day = Calendar.current.startOfDay(for: date)
        return day.addingTimeInterval(Double(min(max(order, 0), 86_399)))
    }

    func touchLearningGoal(_ goalID: String, at date: Date = Date()) throws {
        try execBind("UPDATE learning_goals SET updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSinceReferenceDate)
            bind(stmt, 2, goalID)
        }
    }

    /// Rename a Notebook or Goal without rewriting any of its semantic settings.
    /// In particular, a display-name edit must not silently change the discovery topic.
    func setLearningGoalTitle(goalID: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KnowledgeStoreError.invalidData("Learning goal title is required.")
        }
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }

        let now = Date()
        try execBind("UPDATE learning_goals SET title = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, trimmed)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
    }

    /// Replace the short user-authored Notebook instructions stored in the
    /// existing description column. Nil or whitespace clears the value.
    func setLearningGoalDescription(goalID: String, description: String?) throws {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed?.isEmpty == false ? trimmed : nil
        let now = Date()
        try execBind("UPDATE learning_goals SET description = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, resolved)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
    }

    /// Replace a Notebook's short description — the gallery card copy. Nil or
    /// whitespace clears it. Single-line by design: newlines collapse to spaces
    /// so the card never grows past its two lines.
    func setLearningGoalSummary(goalID: String, summary: String?) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        let now = Date()
        try execBind("UPDATE learning_goals SET summary = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, Self.normalizedSummary(summary))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
    }

    /// The stored form of a Notebook summary: whitespace runs (including line
    /// breaks) collapsed to one space, trimmed, capped, nil when empty. The
    /// rule lives in Portable so the phone writes the identical form.
    static func normalizedSummary(_ raw: String?) -> String? {
        NotebookSummary.normalized(raw)
    }

    /// Link a Notebook to the GitHub repository it is about, or unlink it. The
    /// value is whatever the learner typed — `owner/repo`, `owner/repo.git`, or
    /// a github.com URL — and is stored in canonical `owner/repo` form; nil or
    /// whitespace unlinks. An entry that does not name a repository is refused
    /// with the accepted forms, and nothing changes. An unlink is stored as ''
    /// rather than NULL so it travels as an explicit clear (the sync upsert's
    /// COALESCE keeps the local value only for NULL, an older device's no-opinion).
    func setNotebookRepository(notebookID: String, repository: String?) throws {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        let trimmed = repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stored: String
        if trimmed.isEmpty {
            stored = ""
        } else if let normalized = LearningGoalRecord.normalizedRepository(trimmed) {
            stored = normalized
        } else {
            throw KnowledgeStoreError.invalidData(Self.repositoryFormatRefusal(trimmed))
        }
        let now = Date()
        try execBind("UPDATE learning_goals SET repository = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, stored)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, notebookID)
        }
    }

    /// Link a Goal to the artifact it is for — the Doc, Site or animation
    /// that is its deliverable — or unlink it with nil or whitespace. The
    /// artifact must be a record in this library; an id that names none is
    /// refused and nothing changes. An unlink is stored as '' rather than
    /// NULL so it travels as an explicit clear (the sync upsert's COALESCE
    /// keeps the local value only for NULL, an older device's no-opinion).
    /// A Notebook is refused: an open-ended pool is not *for* one artifact,
    /// its artifacts are linked the other way round, from the record.
    func setLearningGoalArtifact(goalID: String, artifactID: String?) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isGoal else {
            throw KnowledgeStoreError.invalidData("Timebound Goal not found: \(goalID)")
        }
        let stored = try Self.resolvedGoalArtifactID(artifactID, load: loadArtifact) ?? ""
        let now = Date()
        try execBind("UPDATE learning_goals SET artifact_id = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, stored)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goal.id)
        }
    }

    /// Put the learner's Goals in an order (product owner, 2026-09-20: "allow me to
    /// reshuffle these"). The listed Goals come first, in the order given;
    /// every other open Goal follows in the order it already reads
    /// (`LearningGoalRecord.listOrder`), so a subset — one band of the tab,
    /// or the three the assistant was asked about — places itself without
    /// scrambling the rest. An empty list clears every placement, and the
    /// list reads by deadline again. Each id must name a timebound Goal in
    /// this store; a Notebook, a finished Goal or an unknown id refuses the
    /// whole call and nothing changes. Only a row whose placement actually
    /// moves is written and published, so putting a list back as it was
    /// costs nothing over sync. Returns the ids in their final order.
    @discardableResult
    func reorderLearningGoals(goalIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        let listed = goalIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let goals = try loadLearningGoals().filter { $0.isGoal }
        let byID = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) })
        for id in listed {
            guard let goal = byID[id] else {
                throw KnowledgeStoreError.invalidData("Timebound Goal not found: \(id)")
            }
            guard !(goal.isDone || goal.isArchived) else {
                throw KnowledgeStoreError.invalidData("\(goal.title) is finished; only an open Goal can be placed.")
            }
        }
        let listedSet = Set(listed)
        let rest = goals
            .filter { !listedSet.contains($0.id) && !($0.isDone || $0.isArchived) }
            .map { goal -> LearningGoalRecord in
                // A cleared list forgets every placement, so the order
                // answered is the one the list reads afterwards: by deadline.
                guard listed.isEmpty else { return goal }
                var unplaced = goal
                unplaced.sortOrder = nil
                return unplaced
            }
            .sorted(by: LearningGoalRecord.listOrder)
            .map(\.id)
        let order = listed + rest
        // Placements are the index in the final order; a cleared list is
        // NULL on every open row, which reads by deadline.
        let placements: [(id: String, position: Int?)] = listed.isEmpty
            ? rest.map { ($0, nil) }
            : order.enumerated().map { ($0.element, $0.offset) }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            for (id, position) in placements where byID[id]?.sortOrder != position {
                try execBind("UPDATE learning_goals SET sort_order = ?, updated_at = ? WHERE id = ?") { stmt in
                    if let position { sqlite3_bind_int64(stmt, 1, Int64(position)) } else { sqlite3_bind_null(stmt, 1) }
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, id)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return order
    }

    /// The artifact id a Goal may store: nil for nil or whitespace (no link),
    /// the trimmed id when `load` finds the record, and a refusal naming the
    /// id otherwise. Shared by creation and the setter so both refuse in the
    /// same words.
    static func resolvedGoalArtifactID(
        _ raw: String?,
        load: (String) throws -> ArtifactRecord?
    ) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard try load(trimmed) != nil else {
            throw KnowledgeStoreError.invalidData(goalArtifactRefusal(trimmed))
        }
        return trimmed
    }

    /// The one sentence every surface shows for an artifact id that names no
    /// Doc, Site or animation in the library.
    static func goalArtifactRefusal(_ raw: String) -> String {
        "No Doc, Site or animation with id \(raw). Use list_docs or list_animations to find one."
    }

    /// The one sentence every surface shows for an entry that is not a GitHub
    /// repository, so the app, MCP and the phone refuse in the same words.
    static func repositoryFormatRefusal(_ raw: String) -> String {
        "\"\(raw)\" is not a GitHub repository. Use owner/repo, owner/repo.git, or a github.com URL such as https://github.com/owner/repo."
    }

    /// Replace a Notebook's (learning goal's) synthesis notes markdown.
    /// The Internal Review writes here.
    func setLearningGoalNotes(goalID: String, notes: String) throws {
        let now = Date()
        try execBind("UPDATE learning_goals SET notes = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, notes)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
    }

    /// Replaces the Notebook's defining research questions. An empty list is
    /// stored as "[]" (an explicit clear, distinct from never-set NULL) so the
    /// sync upsert's COALESCE guard lets it propagate.
    func setLearningGoalResearchQuestions(goalID: String, questions: [String]) throws {
        let now = Date()
        try execBind("UPDATE learning_goals SET research_questions = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, Self.encodeResearchQuestions(questions))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try keepNotebookRowsForGeneration2(goalIDs: [goalID])
    }

    func dictUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    func replaceReviewSessionSources(
        sessionID: String,
        sourceIDs: [String],
        allowMissingSources: Bool = false
    ) throws {
        // A memory review's material may be a chat (docs/memory-design.md,
        // "Chats as evidence"), which is review material under its own session
        // id without being a `sources` row. The record's `source_ids` keeps the
        // whole list; the junction, whose foreign key points at `sources`,
        // notebooks only the ids that are sources — the same tolerance an
        // inbound sync record gets for a Source that has not landed yet.
        let notebookOnlyExistingSources = allowMissingSources
            || MemoryReviewSession.isMemorySession(sessionID)
        try execBind("DELETE FROM review_session_sources WHERE session_id = ?", { stmt in
            bind(stmt, 1, sessionID)
        })
        for sourceID in sourceIDs {
            if notebookOnlyExistingSources {
                try execBind("""
                    INSERT OR IGNORE INTO review_session_sources (session_id, source_id)
                    SELECT ?, id FROM sources WHERE id = ?
                """) { stmt in
                    bind(stmt, 1, sessionID)
                    bind(stmt, 2, sourceID)
                }
            } else {
                try execBind("INSERT OR IGNORE INTO review_session_sources (session_id, source_id) VALUES (?, ?)", { stmt in
                    bind(stmt, 1, sessionID)
                    bind(stmt, 2, sourceID)
                })
            }
        }
    }

    /// Complete the junction projection for sessions that arrived before this
    /// Source. The canonical `source_ids` JSON intentionally retained the
    /// relationship while its foreign-key target was unavailable.
    func restoreDeferredReviewSessionSourceLinks(sourceID: String) throws {
        try execBind("""
            INSERT OR IGNORE INTO review_session_sources (session_id, source_id)
            SELECT fs.id, ?
            FROM review_sessions fs,
                 json_each(
                     CASE WHEN json_valid(fs.source_ids)
                          THEN fs.source_ids ELSE '[]' END
                 ) relationship
            WHERE relationship.type = 'text'
              AND relationship.value = ?
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, sourceID)
        }
    }

    func reviewSessionSourceIDsBySessionID() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        try query("""
            SELECT session_id, source_id
            FROM review_session_sources
            ORDER BY session_id, source_id
        """) { stmt in
            guard let sessionID = self.string(stmt, 0),
                  let sourceID = self.string(stmt, 1) else { return }
            result[sessionID, default: []].append(sourceID)
        }
        return result
    }

    func loadReviewExchanges(sessionID: String) throws -> [CloudKitReviewExchangePayload] {
        var exchanges: [CloudKitReviewExchangePayload] = []
        try queryBind("""
            SELECT id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at, context_content,
                   idea_coverage, question_verdict, operation, steer,
                   rating, rating_reason, rating_field, rated_at
            FROM review_exchanges
            WHERE session_id = ?
            ORDER BY sequence_number ASC
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let sessionID = self.string(stmt, 1),
                  let question = self.string(stmt, 3) else { return }
            exchanges.append(
                CloudKitReviewExchangePayload(
                    id: id,
                    sessionID: sessionID,
                    sequenceNumber: Int(sqlite3_column_int(stmt, 2)),
                    question: question,
                    userAnswer: self.string(stmt, 4),
                    evaluation: self.string(stmt, 5),
                    score: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
                    sourceRefs: self.decodeStringArray(json: self.string(stmt, 7)) ?? [],
                    knowledgeNote: self.string(stmt, 8),
                    answeredAt: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 9)),
                    contextContent: self.string(stmt, 10),
                    ideaCoverage: self.string(stmt, 11),
                    questionVerdict: self.string(stmt, 12),
                    operation: self.string(stmt, 13),
                    steer: self.string(stmt, 14),
                    rating: self.string(stmt, 15),
                    ratingReason: self.string(stmt, 16),
                    ratingField: self.string(stmt, 17),
                    ratedAt: sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 18))
                )
            )
        }
        return exchanges
    }

}
