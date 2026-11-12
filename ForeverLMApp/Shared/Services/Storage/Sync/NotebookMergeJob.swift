import Foundation

// MARK: - Notebook merge, split and stubs under generation 2 (docs/cloudkit-schema-design.md §5.2, D17, D48)

/// A notebook that a merge or an emptying split folded into another stays as a stub: its row is kept,
/// archived, with `merged_into` (the notebook that took its place) and `fold_kind` (`merge` or
/// `split`), and its Notebook record is a permanent redirect (`status = merged`, `mergedInto`,
/// `foldKind`, both S, written in one save). Nothing belongs to it any more: its Entries are deleted
/// once their twins exist, every child is re-pointed, and whatever still names it later (a late Entry,
/// a late child, a late edit of the stub) is moved on by any Mac that sees it (`NotebookStubUpkeep`).
enum NotebookStubs {
    /// Over a `learning_goals` row: a stub a merge or an emptying split left.
    static let isStubSQL = "COALESCE(merged_into, '') <> ''"

    enum FoldKind: String, Sendable {
        case merge
        case split
    }

    /// Makes `id` a stub of `kind` leading to `survivorID`, in one statement, so its record goes out as
    /// one save (§5.2 step 1); every stamp of the record the replica holds is recorded as forwarded,
    /// since the fold that follows carries those values (`NotebookStubForwarding`).
    static func write(_ id: String, into survivorID: String, kind: FoldKind, connection: SQLiteConnection, now: Date) throws {
        try connection.execute(
            "UPDATE learning_goals SET merged_into = ?, fold_kind = ?, status = ?, updated_at = ? WHERE id = ?",
            [.text(survivorID), .text(kind.rawValue), .text(LearningGoalStatus.archived.rawValue), .real(now.timeIntervalSinceReferenceDate), .text(id)]
        )
        try NotebookStubForwarding.recordBaseline(notebookID: id, envelope: nil, connection: connection)
    }

    /// The stubs this Mac holds: id, where it leads, and how it was made.
    static func held(_ connection: SQLiteConnection) throws -> [(id: String, mergedInto: String, kind: FoldKind)] {
        var stubs: [(id: String, mergedInto: String, kind: FoldKind)] = []
        try connection.query(
            "SELECT id, merged_into, fold_kind FROM learning_goals WHERE entity_kind = ? AND \(isStubSQL) ORDER BY id",
            [.text(LearningGoalEntityKind.notebook)]
        ) { row in
            guard let id = row.text(0), let into = row.text(1) else { return }
            stubs.append((id, into, FoldKind(rawValue: row.text(2) ?? "") ?? .merge))
        }
        return stubs
    }
}

// MARK: - The fold (§5.2, D48)

/// A notebook's own words as the fold reads and writes them: columns of its row, which the Notebook
/// record and the Notes Doc carry (the notes are `learning_goals.notes` until the Artifact projection
/// publishes them as the Notes Doc's body).
struct NotebookWords: Equatable, Sendable {
    let id: String
    var title: String
    var notes: String?
    var instructions: String?
    var summary: String?
    var topic: String?
    var repository: String?
    /// The generation-1 array, in order; nil when the row never had one.
    var researchQuestions: [String]?

    static func load(_ id: String, connection: SQLiteConnection) throws -> NotebookWords? {
        var words: NotebookWords?
        try connection.query(
            "SELECT title, notes, description, summary, topic, repository, research_questions FROM learning_goals WHERE id = ?", [.text(id)]
        ) { row in
            words = NotebookWords(
                id: id, title: row.text(0) ?? "", notes: row.text(1), instructions: row.text(2), summary: row.text(3),
                topic: row.text(4), repository: row.text(5), researchQuestions: KnowledgeStore.decodeResearchQuestions(row.text(6))
            )
        }
        return words
    }
}

/// The fold of a notebook's own words, shared by a merge and an emptying split, and
/// by the forwarding of late edits to a stub: the target's words win; a blank Instructions, summary,
/// topic or repository is filled; research questions and open questions are unioned (trimmed,
/// case-insensitive, the target's first); the links are unioned, minus both notebooks; and the notes
/// are concatenated, each under `## <its title>`, the target's first.
enum NotebookFold {
    /// Which of the folded notebooks' words travel: all of them for a merge or a split, only the
    /// fields of late edits when a stub's are forwarded.
    struct Fields: OptionSet, Sendable {
        let rawValue: Int
        static let instructions = Fields(rawValue: 1 << 0)
        static let summary = Fields(rawValue: 1 << 1)
        static let topic = Fields(rawValue: 1 << 2)
        static let repository = Fields(rawValue: 1 << 3)
        static let researchQuestions = Fields(rawValue: 1 << 4)
        static let openQuestions = Fields(rawValue: 1 << 5)
        static let relatedNotebooks = Fields(rawValue: 1 << 6)
        static let notes = Fields(rawValue: 1 << 7)
        static let all: Fields = [.instructions, .summary, .topic, .repository, .researchQuestions, .openQuestions, .relatedNotebooks, .notes]

        /// The fold field a Notebook record field feeds; nil for one the fold never carries (the title
        /// above all: a late rename of a merged notebook never renames its survivor).
        static func of(recordField field: String) -> Fields? {
            switch field {
            case "instructions": return .instructions
            case "summary": return .summary
            case "topic": return .topic
            case "repository": return .repository
            case "researchQuestions": return .researchQuestions
            case "openQuestions": return .openQuestions
            case "relatedNotebookIDs": return .relatedNotebooks
            default: return nil
            }
        }
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    /// The target's words after the fold: pure, so the rule is pinned without a store.
    static func folded(_ target: NotebookWords, from folded: [NotebookWords], fields: Fields = .all, title: String? = nil, mergeNotes: Bool = true) -> NotebookWords {
        var result = target
        if let title { result.title = title }
        if fields.contains(.notes), mergeNotes {
            let sections = ([target] + folded).compactMap { notebook -> String? in
                guard let notes = notebook.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return nil }
                return "## \(notebook.title)\n\n\(notes)"
            }
            if !sections.isEmpty { result.notes = sections.joined(separator: "\n\n") }
        }
        var questions = target.researchQuestions ?? []
        for notebook in folded {
            if fields.contains(.researchQuestions) {
                for question in notebook.researchQuestions ?? [] {
                    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !questions.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
                    questions.append(trimmed)
                }
            }
            if fields.contains(.instructions), isBlank(result.instructions), !isBlank(notebook.instructions) { result.instructions = notebook.instructions }
            if fields.contains(.summary), isBlank(result.summary), !isBlank(notebook.summary) { result.summary = notebook.summary }
            if fields.contains(.topic), isBlank(result.topic), !isBlank(notebook.topic) { result.topic = notebook.topic }
            if fields.contains(.repository), isBlank(result.repository), !isBlank(notebook.repository) { result.repository = notebook.repository }
        }
        if questions != (target.researchQuestions ?? []) { result.researchQuestions = questions }
        return result
    }

    /// Folds `foldedIDs` into `targetID` in the store, inside the caller's transaction: the target's row
    /// and research questions, the open questions the target lacks (re-pointed under their own ids) and
    /// the links. Returns how many open questions moved.
    @discardableResult
    static func run(
        into targetID: String, from foldedIDs: [String], fields: Fields = .all, title: String? = nil, mergeNotes: Bool = true,
        connection: SQLiteConnection, now: Date
    ) throws -> Int {
        guard let target = try NotebookWords.load(targetID, connection: connection) else { return 0 }
        let folded = try foldedIDs.compactMap { try NotebookWords.load($0, connection: connection) }
        let result = Self.folded(target, from: folded, fields: fields, title: title, mergeNotes: mergeNotes)
        if result != target {
            let questions = result.researchQuestions.map(KnowledgeStore.encodeResearchQuestions)
            try connection.execute("""
                UPDATE learning_goals
                SET title = ?, notes = ?, description = ?, summary = ?, topic = ?, repository = ?, research_questions = ?, updated_at = ?
                WHERE id = ?
            """, [
                .text(result.title), .text(result.notes), .text(result.instructions), .text(result.summary), .text(result.topic),
                .text(result.repository), .text(questions), .real(now.timeIntervalSinceReferenceDate), .text(targetID),
            ])
            if let questions = result.researchQuestions, questions != (target.researchQuestions ?? []) {
                try NotebookResearchQuestions.syncRows(notebookID: targetID, questions: questions, at: now.timeIntervalSinceReferenceDate, connection: connection)
            }
        }
        var moved = 0
        if fields.contains(.openQuestions) {
            var held = Set<String>()
            try connection.query("SELECT summary FROM learning_goal_gaps WHERE goal_id = ?", [.text(targetID)]) { row in
                held.insert(normalized(row.text(0)))
            }
            for foldedID in foldedIDs {
                var gaps: [(id: String, summary: String)] = []
                try connection.query("SELECT id, summary FROM learning_goal_gaps WHERE goal_id = ? ORDER BY id", [.text(foldedID)]) { row in
                    if let id = row.text(0) { gaps.append((id, row.text(1) ?? "")) }
                }
                for gap in gaps where held.insert(normalized(gap.summary)).inserted {
                    try connection.execute("UPDATE learning_goal_gaps SET goal_id = ? WHERE id = ? AND goal_id = ?", [.text(targetID), .text(gap.id), .text(foldedID)])
                    moved += 1
                }
            }
        }
        if fields.contains(.relatedNotebooks) {
            for foldedID in foldedIDs {
                try connection.execute("""
                    INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at)
                    SELECT ?, related_notebook_id, linked_at FROM notebook_related_notebook_links
                    WHERE notebook_id = ? AND related_notebook_id <> ? AND related_notebook_id NOT IN (SELECT value FROM json_each(?))
                    ON CONFLICT(notebook_id, related_notebook_id) DO NOTHING
                """, [.text(targetID), .text(foldedID), .text(targetID), .text(jsonArray(foldedIDs))])
            }
        }
        return moved
    }

    private static func normalized(_ summary: String?) -> String {
        (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func jsonArray(_ ids: [String]) -> String {
        String(decoding: SyncJSON.array(ids.map(SyncJSON.string)).serialized(), as: UTF8.self)
    }
}

// MARK: - Entries into the container that takes them (§5.2 step 2, §3.5.8)

/// One Entry of a container that is going (a notebook merged away, the part of a split's parent a
/// child takes, a late Entry under a stub) moved to the container that takes its place.
enum NotebookEntryTwins {
    enum Rule: Equatable, Sendable {
        /// Merge step 2: when the target has no Entry for the item, a twin copies the Entry's values and
        /// its `state`, `approval` and `origin` stamps verbatim; when it has one, it is kept, an
        /// `approved` Entry winning over a pending or rejected one and the higher relevance kept (today's
        /// `preferredCompanionGoalItem`), with fresh stamps. A removed target Entry is active again.
        case twin
        /// A local write to an Entry of a notebook that was merged meanwhile (it met `unknownItem`, or
        /// the deletion while it waited): the changed values land on the survivor's Entry of the same
        /// item, with fresh stamps (§6.2).
        case pendingWrite(columns: Set<String>)
    }

    struct PoolRow {
        let id: String
        let addedAt: Double
        let completedAt: Double?
        let origin: String?
        let reviewState: String?
        let relevance: Double?
        let lastQuizzedAt: Double?
        let quizCount: Int64?
        let lastScore: Double?

        var isApproved: Bool { reviewState == nil || reviewState == "approved" }

        static func load(goalID: String, sourceID: String, connection: SQLiteConnection) throws -> PoolRow? {
            var found: PoolRow?
            try connection.query("""
                SELECT id, added_at, completed_at, origin, review_state, relevance, last_quizzed_at, quiz_count, last_score
                FROM learning_goal_items WHERE goal_id = ? AND source_id = ?
            """, [.text(goalID), .text(sourceID)]) { row in
                found = PoolRow(
                    id: row.text(0) ?? "", addedAt: row.real(1) ?? 0, completedAt: row.real(2), origin: row.text(3), reviewState: row.text(4),
                    relevance: row.real(5), lastQuizzedAt: row.real(6), quizCount: row.integer(7), lastScore: row.real(8)
                )
            }
            return found
        }
    }

    /// The Entry paths a twin copies stamps of (§5.2 step 2).
    static let verbatimPaths = [StampedPath("state"), StampedPath("approval"), StampedPath("origin")]

    /// How a pool row left behind under a stub is moved on: a twin, unless the row holds a local write
    /// that is not a create (it has changed columns and no `__row`), which lands as a pending write.
    static func rule(forRow rowID: String, connection: SQLiteConnection) throws -> Rule {
        var columns = Set<String>()
        try connection.query(
            "SELECT column FROM ck_outbox_fields WHERE source_table = 'learning_goal_items' AND local_key = ?", [.text(rowID)]
        ) { row in if let column = row.text(0) { columns.insert(column) } }
        guard !columns.isEmpty, !columns.contains(OutboxFeeder.rowColumn) else { return .twin }
        return .pendingWrite(columns: columns)
    }

    /// Moves the source `sourceID` from `fromID`'s pool to `toID`'s. Returns whether the target gained it.
    @discardableResult
    static func moveSource(_ sourceID: String, from fromID: String, to toID: String, rule: Rule, feeder: OutboxFeeder) throws -> Bool {
        let connection = feeder.connection
        guard let from = try PoolRow.load(goalID: fromID, sourceID: sourceID, connection: connection) else { return false }
        let fromEntry = SyncIdentity.entryID(containerID: fromID, itemKind: "source", itemID: sourceID)
        let toEntry = SyncIdentity.entryID(containerID: toID, itemKind: "source", itemID: sourceID)
        let stamps = try feeder.heldStamps(type: .entry, wireID: fromEntry, paths: verbatimPaths, mint: false)
        var added = false
        if let to = try PoolRow.load(goalID: toID, sourceID: sourceID, connection: connection) {
            var assignments: [String] = []
            var values: [SQLiteValue] = []
            func set(_ column: String, _ value: SQLiteValue) { assignments.append("\(column) = ?"); values.append(value) }
            switch rule {
            case .twin:
                if from.isApproved, to.reviewState == "pending" || to.reviewState == "rejected" { set("review_state", .text("approved")) }
                if let relevance = from.relevance, relevance > (to.relevance ?? 0) { set("relevance", .real(relevance)) }
                // Local study history, never on the record: the better of the two, as the merge rule keeps it.
                if from.addedAt < to.addedAt { set("added_at", .real(from.addedAt)) }
                if let done = from.completedAt, done > (to.completedAt ?? 0) { set("completed_at", .real(done)) }
                if let quizzed = from.lastQuizzedAt, quizzed > (to.lastQuizzedAt ?? 0) { set("last_quizzed_at", .real(quizzed)) }
                if let count = from.quizCount, count > (to.quizCount ?? 0) { set("quiz_count", .integer(count)) }
                if let score = from.lastScore, score > (to.lastScore ?? -1) { set("last_score", .real(score)) }
            case .pendingWrite(let columns):
                if columns.contains("review_state") { set("review_state", .text(from.reviewState)) }
                if columns.contains("relevance") { set("relevance", .real(from.relevance)) }
            }
            if !assignments.isEmpty {
                try connection.execute(
                    "UPDATE learning_goal_items SET \(assignments.joined(separator: ", ")) WHERE id = ?", values + [.text(to.id)]
                )
            }
        } else {
            try connection.execute("""
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, completed_at, origin, review_state, relevance,
                                                 last_quizzed_at, quiz_count, last_score, order_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(UUID().uuidString), .text(toID), .text(sourceID), .real(from.addedAt), .real(from.completedAt), .text(from.origin),
                .text(from.reviewState), .real(from.relevance), .real(from.lastQuizzedAt), .integer(from.quizCount), .real(from.lastScore),
                .text(try EntryOrderKeys.appendedKey(goalID: toID, connection: connection)),
            ])
            // A new Entry the server does not hold copies the stamps; one it holds (removed in the
            // target) is active again with fresh ones (`pinVerbatim` pins nothing for it).
            try feeder.pinVerbatim(type: .entry, wireID: toEntry, stamps: stamps)
            added = true
        }
        try connection.execute("DELETE FROM learning_goal_items WHERE id = ?", [.text(from.id)])
        return added
    }

    /// Moves a followed course from `fromID` to `toID`, its Entry's stamps copied when the target
    /// does not follow it yet.
    static func moveCourse(_ courseID: String, from fromID: String, to toID: String, feeder: OutboxFeeder) throws {
        let connection = feeder.connection
        let fromEntry = SyncIdentity.entryID(containerID: fromID, itemKind: "course", itemID: courseID)
        let stamps = try feeder.heldStamps(type: .entry, wireID: fromEntry, paths: [StampedPath("state"), StampedPath("origin")], mint: false)
        let followed = try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM notebook_course_links WHERE goal_id = ? AND course_id = ?)", [.text(toID), .text(courseID)]
        ) == 1
        if !followed {
            try connection.execute("INSERT INTO notebook_course_links (goal_id, course_id) VALUES (?, ?)", [.text(toID), .text(courseID)])
            try feeder.pinVerbatim(type: .entry, wireID: SyncIdentity.entryID(containerID: toID, itemKind: "course", itemID: courseID), stamps: stamps)
        }
        try connection.execute("DELETE FROM notebook_course_links WHERE goal_id = ? AND course_id = ?", [.text(fromID), .text(courseID)])
    }

    /// Moves every Entry `fromID` still holds to `toID`: its pool in study order, then its followed
    /// courses. Returns how many sources the target gained.
    @discardableResult
    static func moveAll(from fromID: String, to toID: String, rule: ((String) throws -> Rule)? = nil, feeder: OutboxFeeder) throws -> Int {
        let connection = feeder.connection
        var pool: [(rowID: String, sourceID: String)] = []
        try connection.query("""
            SELECT id, source_id FROM learning_goal_items WHERE goal_id = ?
            ORDER BY (order_key IS NULL) ASC, order_key ASC, (sequence IS NULL) ASC, sequence ASC, added_at ASC, source_id ASC
        """, [.text(fromID)]) { row in
            if let id = row.text(0), let source = row.text(1) { pool.append((id, source)) }
        }
        var added = 0
        for item in pool {
            let itemRule = try rule?(item.rowID) ?? .twin
            if try moveSource(item.sourceID, from: fromID, to: toID, rule: itemRule, feeder: feeder) { added += 1 }
        }
        var courses: [String] = []
        try connection.query("SELECT course_id FROM notebook_course_links WHERE goal_id = ? ORDER BY course_id", [.text(fromID)]) { row in
            if let id = row.text(0) { courses.append(id) }
        }
        for course in courses { try moveCourse(course, from: fromID, to: toID, feeder: feeder) }
        if !pool.isEmpty { try EntryOrderKeys.deriveSequence(goalID: toID, connection: connection) }
        return added
    }
}

// MARK: - Children, through the back-pointer index (§5.2 step 3)

/// What a notebook holds by id, moved to another: every row `ck_notebook_children` lists, each table
/// in its own way, plus the local rows no record carries that file things under a notebook, as
/// a merge moves them. Entries are twinned (`NotebookEntryTwins`), and the member's NotebookState
/// is per-member state that is handed over, never re-pointed (D18).
enum NotebookChildren {
    /// Each child table of the back-pointer index, and the statements that move its rows from `?2` to `?1`.
    static let repoints: [String: [String]] = [
        "review_sessions": ["UPDATE review_sessions SET goal_id = ?1 WHERE goal_id = ?2"],
        "global_artifacts": ["UPDATE global_artifacts SET home_notebook_id = ?1 WHERE home_notebook_id = ?2"],
        "global_artifact_notebook_links": [
            """
            INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
            SELECT artifact_id, ?1, linked_at FROM global_artifact_notebook_links WHERE notebook_id = ?2
            ON CONFLICT(artifact_id, notebook_id) DO NOTHING
            """,
            "DELETE FROM global_artifact_notebook_links WHERE notebook_id = ?2",
        ],
        "notebook_files": ["UPDATE notebook_files SET notebook_id = ?1 WHERE notebook_id = ?2"],
        "learning_goals": ["UPDATE learning_goals SET parent_notebook_id = ?1 WHERE parent_notebook_id = ?2"],
        "notebook_tasks": ["UPDATE notebook_tasks SET notebook_id = ?1, team_id = (SELECT team_id FROM learning_goals WHERE id = ?1) WHERE notebook_id = ?2"],
        "scheduled_tasks": ["UPDATE scheduled_tasks SET notebook_id = ?1 WHERE notebook_id = ?2"],
        "idea_links": [
            """
            INSERT INTO idea_links (idea_id, kind, target_id, added_at)
            SELECT idea_id, 'notebook', ?1, MIN(added_at) FROM idea_links WHERE target_id = ?2 AND kind = 'notebook' GROUP BY idea_id
            ON CONFLICT(idea_id, kind, target_id) DO NOTHING
            """,
            "DELETE FROM idea_links WHERE target_id = ?2 AND kind = 'notebook'",
        ],
        "research_directions": ["UPDATE research_directions SET home_id = ?1 WHERE home_id = ?2 AND home_kind = 'notebook'"],
        "memory_items": ["UPDATE memory_items SET goal_id = ?1 WHERE goal_id = ?2"],
        "learning_bouts": ["UPDATE learning_bouts SET notebook_id = ?1 WHERE notebook_id = ?2"],
    ]

    /// Child tables of the index that are not re-pointed: Entries are twinned, NotebookStates handed over.
    static let notRepointed: Set<String> = ["learning_goal_items", "notebook_course_links", "notebook_states"]

    /// Local rows the index does not list, moved as a merge moves them: Planner blocks, Schedule
    /// placements' tags, journal matches, and the links other notebooks hold to the old one (a notebook
    /// never links to itself, so a link that would collapse onto the target goes).
    static let localRepoints: [String] = [
        """
        UPDATE time_blocks SET notebook_id = CASE WHEN notebook_id = ?2 THEN ?1 ELSE notebook_id END,
                               goal_id = CASE WHEN goal_id = ?2 THEN ?1 ELSE goal_id END
        WHERE notebook_id = ?2 OR goal_id = ?2
        """,
        """
        INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
        SELECT scheduled_source_id, ?1, added_at FROM scheduled_source_goals WHERE goal_id = ?2
        ON CONFLICT(scheduled_source_id, goal_id) DO NOTHING
        """,
        "DELETE FROM scheduled_source_goals WHERE goal_id = ?2",
        """
        INSERT INTO journal_article_matches (item_url, notebook_id, reason, matched_at, state, decided_at, source_id)
        SELECT item_url, ?1, reason, matched_at, state, decided_at, source_id FROM journal_article_matches WHERE notebook_id = ?2
        ON CONFLICT(item_url, notebook_id) DO NOTHING
        """,
        "DELETE FROM journal_article_matches WHERE notebook_id = ?2",
        """
        INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at)
        SELECT notebook_id, ?1, linked_at FROM notebook_related_notebook_links WHERE related_notebook_id = ?2 AND notebook_id <> ?1
        ON CONFLICT(notebook_id, related_notebook_id) DO NOTHING
        """,
        "DELETE FROM notebook_related_notebook_links WHERE related_notebook_id = ?2",
    ]

    /// What moved, for the counts a merge reports.
    struct Moved: Equatable, Sendable {
        var chats = 0
        var goals = 0
        var tasks = 0
        var docs = 0
    }

    /// Re-points every child the index lists for `fromID` to `toID`, inside the caller's transaction;
    /// with `includingLocal`, the local rows the index does not list too (a merge and a split do; a
    /// late child found later is always one the index lists).
    @discardableResult
    static func repoint(from fromID: String, to toID: String, includingLocal: Bool, connection: SQLiteConnection) throws -> Moved {
        var counts: [String: Int] = [:]
        try connection.query(
            "SELECT child_table, COUNT(DISTINCT child_id) FROM ck_notebook_children WHERE notebook_id = ? GROUP BY child_table", [.text(fromID)]
        ) { row in
            if let table = row.text(0) { counts[table] = Int(row.integer(1) ?? 0) }
        }
        // A Doc homed in the notebook and linked to it too is one Doc.
        let docs = Int(try connection.scalarInteger("""
            SELECT COUNT(DISTINCT child_id) FROM ck_notebook_children
            WHERE notebook_id = ? AND child_table IN ('global_artifacts', 'global_artifact_notebook_links')
        """, [.text(fromID)]) ?? 0)
        for table in counts.keys.sorted() where !notRepointed.contains(table) {
            for statement in repoints[table] ?? [] {
                try connection.execute(statement, [.text(toID), .text(fromID)])
            }
        }
        if includingLocal {
            for statement in localRepoints {
                try connection.execute(statement, [.text(toID), .text(fromID)])
            }
        }
        return Moved(chats: counts["review_sessions"] ?? 0, goals: counts["learning_goals"] ?? 0, tasks: counts["notebook_tasks"] ?? 0, docs: docs)
    }
}

// MARK: - The jobs (§5.2 Merge, Split)

/// `NotebookMergeJob`, its `merge` and `split` (§5.2): run on the Mac, in one transaction of the
/// caller's, on the store's own connection, so every row they write goes out through the outbox. The
/// redirect is written first; the job does not wait for its acknowledgement, so a merge works
/// offline. When another device folded the same notebook first, its fold stands (`mergedInto` and
/// `foldKind` are S), and whatever this job moved stays where it moved it (`NotebookFoldNotices`).
struct NotebookMergeJob {
    let feeder: OutboxFeeder
    let now: Date

    init(connection: SQLiteConnection, registry: ProjectionRegistry, now: Date = Date()) {
        self.feeder = OutboxFeeder(connection: connection, registry: registry)
        self.now = now
    }

    var connection: SQLiteConnection { feeder.connection }

    struct Merged: Equatable, Sendable {
        var sourcesAdded = 0
        var gapsAdded = 0
        var children = NotebookChildren.Moved()
    }

    /// Folds each of `mergeeIDs` into `survivorID`: (1) the redirect, (2) the Entries, (3) the children,
    /// (4) the fold of every mergee's words into the survivor, then this Mac's own hand-over of the
    /// member's NotebookState sets (6). The Notes Doc of a mergee goes once the survivor's folded body
    /// is acknowledged (5), which is the Artifact projection's.
    func merge(_ mergeeIDs: [String], into survivorID: String, title: String?, mergeNotes: Bool) throws -> Merged {
        var merged = Merged()
        for mergee in mergeeIDs where mergee != survivorID {
            try NotebookStubs.write(mergee, into: survivorID, kind: .merge, connection: connection, now: now)
            merged.sourcesAdded += try NotebookEntryTwins.moveAll(from: mergee, to: survivorID, feeder: feeder)
            let moved = try NotebookChildren.repoint(from: mergee, to: survivorID, includingLocal: true, connection: connection)
            merged.children.chats += moved.chats
            merged.children.goals += moved.goals
            merged.children.tasks += moved.tasks
            merged.children.docs += moved.docs
        }
        merged.gapsAdded = try NotebookFold.run(
            into: survivorID, from: mergeeIDs.filter { $0 != survivorID }, title: title, mergeNotes: mergeNotes, connection: connection, now: now
        )
        try connection.execute("UPDATE learning_goals SET updated_at = ? WHERE id = ?", [.real(now.timeIntervalSinceReferenceDate), .text(survivorID)])
        try NotebookCoverFold.queue(into: survivorID, from: mergeeIDs, connection: connection, now: now)
        try LearningGoalEntityKind.classifyUnclassified(connection)
        try NotebookResolutionTable.refresh(connection)
        try NotebookStubUpkeep(feeder: feeder, now: now).handOverEveryStub()
        return merged
    }

    struct Child: Equatable, Sendable {
        let title: String
        let topic: String?
        let sourceIDs: [String]
        let gapIDs: [String]
    }

    struct Split: Equatable, Sendable {
        let childIDs: [String]
        /// The child that took an emptied parent's place; nil when the parent is kept.
        let heirID: String?
    }

    /// Splits `parentID` (§5.2 Split): each child is created in the parent's zone (a team's split stays
    /// in the team) with its sources' Entries copied verbatim and their open questions; the parent's
    /// Entries of those sources are removed. With `keepParent` false and nothing left in the parent, the
    /// split empties it: the child that took the most sources (the first listed of equals) is the heir,
    /// the parent becomes a `merged` stub with `foldKind = split` (written first), and everything else it
    /// held moves to the heir, its words by the fold. The caller has checked the specs.
    func split(_ parentID: String, into children: [Child], keepParent: Bool) throws -> Split {
        var parent: (startAt: Double, endAt: Double, discovery: Int64, dailyTarget: Int64?, parentNotebookID: String?, teamID: String?, isNotebook: Bool)?
        try connection.query(
            "SELECT start_at, end_at, discovery_enabled, daily_target, parent_notebook_id, team_id, entity_kind FROM learning_goals WHERE id = ?",
            [.text(parentID)]
        ) { row in
            parent = (row.real(0) ?? 0, row.real(1) ?? 0, row.integer(2) ?? 0, row.integer(3), row.text(4), row.text(5),
                      row.text(6) == LearningGoalEntityKind.notebook)
        }
        guard let parent, !children.isEmpty else { return Split(childIDs: [], heirID: nil) }
        var pool = Set<String>()
        try connection.query("SELECT source_id FROM learning_goal_items WHERE goal_id = ?", [.text(parentID)]) { row in
            if let id = row.text(0) { pool.insert(id) }
        }
        let emptying = !keepParent && pool.subtracting(children.flatMap(\.sourceIDs)).isEmpty
        let parentZone = try connection.scalarText(
            "SELECT zone_key FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key LIMIT 1",
            [.text(SyncRecordType.notebook.rawValue), .text(parentID)]
        )

        var childIDs: [String] = []
        let stamp = now.timeIntervalSinceReferenceDate
        for child in children {
            let childID = UUID().uuidString.lowercased()
            try connection.execute("""
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, topic, discovery_enabled,
                                            daily_target, parent_notebook_id, team_id)
                VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
            """, [
                .text(childID), .text(child.title), .real(parent.startAt), .real(parent.endAt), .real(stamp), .real(stamp),
                .text(LearningGoalShape.companionKind), .text(child.topic ?? child.title), .integer(parent.discovery != 0 ? 1 : 0),
                .integer(max(1, parent.dailyTarget ?? 3)), .text(parent.parentNotebookID), .text(parent.teamID),
            ])
            // A team's child lives where its parent does (§5.2: a split stays in the parent's zone).
            if let parentZone {
                try connection.execute("""
                    INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
                    ON CONFLICT DO NOTHING
                """, [.text(parentZone), .text(SyncRecordType.notebook.rawValue), .text(childID), .text(childID)])
            }
            childIDs.append(childID)
        }
        try LearningGoalEntityKind.classifyUnclassified(connection)

        var heirID: String?
        if emptying {
            // The child that took the most sources; of equals, the first listed.
            var best = 0
            for (index, child) in children.enumerated() where child.sourceIDs.count > children[best].sourceIDs.count { best = index }
            heirID = childIDs[best]
            // A Goal has no redirect (§3.5.7): an emptied Goal goes once its contents moved, as today.
            if parent.isNotebook {
                try NotebookStubs.write(parentID, into: childIDs[best], kind: .split, connection: connection, now: now)
            }
        }

        for (index, child) in children.enumerated() {
            let childID = childIDs[index]
            for sourceID in child.sourceIDs {
                try NotebookEntryTwins.moveSource(sourceID, from: parentID, to: childID, rule: .twin, feeder: feeder)
            }
            try EntryOrderKeys.deriveSequence(goalID: childID, connection: connection)
            var gapIDs = Set(child.gapIDs)
            try connection.query(
                "SELECT id FROM learning_goal_gaps WHERE goal_id = ? AND source_id IN (SELECT value FROM json_each(?))",
                [.text(parentID), .text(NotebookFold.jsonArray(child.sourceIDs))]
            ) { row in if let id = row.text(0) { gapIDs.insert(id) } }
            for gapID in gapIDs.sorted() {
                try connection.execute("UPDATE learning_goal_gaps SET goal_id = ? WHERE id = ? AND goal_id = ?", [.text(childID), .text(gapID), .text(parentID)])
            }
        }

        if let heirID {
            try NotebookEntryTwins.moveAll(from: parentID, to: heirID, feeder: feeder)
            try NotebookChildren.repoint(from: parentID, to: heirID, includingLocal: true, connection: connection)
            try NotebookFold.run(into: heirID, from: [parentID], connection: connection, now: now)
            try NotebookCoverFold.queue(into: heirID, from: [parentID], connection: connection, now: now)
            if !parent.isNotebook {
                try connection.execute("DELETE FROM learning_goals WHERE id = ?", [.text(parentID)])
            }
        } else {
            try connection.execute("UPDATE learning_goals SET updated_at = ? WHERE id = ?", [.real(stamp), .text(parentID)])
        }
        try NotebookResolutionTable.refresh(connection)
        if heirID != nil { try NotebookStubUpkeep(feeder: feeder, now: now).handOverEveryStub() }
        return Split(childIDs: childIDs, heirID: heirID)
    }
}

// MARK: - What still names a stub, moved on by any Mac that sees it (§5.2)

/// Run before each feeder pass, outside any apply (what it writes must go out), and at the end of a
/// merge or a split. For every stub this Mac holds whose survivor it holds too:
/// - a late Entry under the stub (a stale device's `en:A:…` create, applied here like any Entry) is
///   twinned into the survivor and deleted; a local write to one of the stub's Entries that met the
///   merge on its way lands on the survivor's Entry of the same item;
/// - a late child that names the stub (a chat, a Goal, a Doc… written by a device that had not seen the
///   merge) is re-pointed to the survivor;
/// - the member's sets on the stub's NotebookState are handed over once: for `foldKind = merge` its
///   context-notebook ticks and collections are unioned into the survivor's, never its exclusions
///   (R6-m2); for `foldKind = split` its exclusions of sources in the heir's pool, its ticks and its
///   collections are copied to the heir's unchanged. The iPhone and the web hand nothing over, so a
///   member with no Mac keeps these sets on the stub's NotebookState until one of their Macs gets
///   here, however long after (R7-m6);
/// - late edits to the stub's fields are forwarded to the survivor through the fold, once each
///   (`ck_forwarded`): a late rename never renames the survivor, a late Instructions edit still fills a
///   blank one.
struct NotebookStubUpkeep {
    let feeder: OutboxFeeder
    let now: Date

    init(feeder: OutboxFeeder, now: Date = Date()) {
        self.feeder = feeder
        self.now = now
    }

    var connection: SQLiteConnection { feeder.connection }

    struct Report: Equatable, Sendable {
        var entriesMoved = 0
        var childrenRepointed = 0
        var handedOver: [String] = []
        var forwardedFields = 0
    }

    /// The survivor a stub leads to, when this Mac holds it as a live notebook.
    private func survivor(of stubID: String) throws -> String? {
        let resolved = try NotebookResolutionTable.resolve(stubID, connection: connection)
        guard resolved.id != stubID, !resolved.zone.isSpace else { return nil }
        let live = try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ? AND entity_kind = ? AND NOT (\(NotebookStubs.isStubSQL)))",
            [.text(resolved.id), .text(LearningGoalEntityKind.notebook)]
        ) == 1
        return live ? resolved.id : nil
    }

    func run() throws -> Report {
        var report = Report()
        let stubs = try NotebookStubs.held(connection)
        guard !stubs.isEmpty else { return report }
        // The stubs something still names, from one read of the index (usually none), with their Entries.
        var named: [String: Int] = [:]
        try connection.query("""
            SELECT notebook_id, SUM(child_type = 'Entry') FROM ck_notebook_children
            WHERE notebook_id IN (SELECT value FROM json_each(?)) AND child_table <> 'notebook_states' GROUP BY notebook_id
        """, [.text(NotebookFold.jsonArray(stubs.map(\.id)))]) { row in
            if let id = row.text(0) { named[id] = Int(row.integer(1) ?? 0) }
        }
        // `notebook_resolution` is current: every Notebook apply and every job refreshes it.
        for stub in stubs {
            guard let target = try survivor(of: stub.id) else { continue }
            if let entries = named[stub.id] {
                if entries > 0 {
                    try NotebookEntryTwins.moveAll(from: stub.id, to: target, rule: { try NotebookEntryTwins.rule(forRow: $0, connection: connection) }, feeder: feeder)
                    report.entriesMoved += entries
                }
                let moved = try NotebookChildren.repoint(from: stub.id, to: target, includingLocal: false, connection: connection)
                report.childrenRepointed += moved.chats + moved.goals + moved.tasks + moved.docs
            }
            if try handOver(stub.id, to: target, kind: stub.kind) { report.handedOver.append(stub.id) }
            report.forwardedFields += try NotebookStubForwarding.forward(stub.id, to: target, connection: connection, now: now)
        }
        return report
    }

    /// Hands every stub's NotebookState sets over, where that is still owed (the end of a merge or a split).
    func handOverEveryStub() throws {
        for stub in try NotebookStubs.held(connection) {
            guard let target = try survivor(of: stub.id) else { continue }
            try handOver(stub.id, to: target, kind: stub.kind)
        }
    }

    static func handOverScope(_ stubID: String) -> String { "notebook.handedOver.\(stubID)" }

    /// Hands the member's sets on `stubID`'s NotebookState to `targetID`'s, once. Nothing is owed while
    /// the stub has no NotebookState here: a member's other devices may write it later, and the first
    /// of this member's Macs to hold both hands it over then. Returns whether it handed over now.
    @discardableResult
    func handOver(_ stubID: String, to targetID: String, kind: NotebookStubs.FoldKind) throws -> Bool {
        let replica = ReplicaStore(connection: connection)
        let scope = Self.handOverScope(stubID)
        guard try replica.engineState(scope) == nil, let stub = try NotebookStateRow.load(stubID, connection: connection) else { return false }
        let held = try NotebookStateRow.load(targetID, connection: connection)
        var target = held ?? NotebookStateRow(notebookID: targetID)
        for id in stub.contextNotebooks.sorted() {
            // A tick of the notebook it leads to now would make it draw on itself.
            guard try NotebookResolutionTable.resolve(id, connection: connection).id != targetID else { continue }
            target.contextNotebooks.insert(id)
        }
        target.collections.formUnion(stub.collections)
        if kind == .split {
            // The heir's Entries carry the parent's stamps, so each pair still names what it named.
            var pool = Set<String>()
            try connection.query("SELECT source_id FROM learning_goal_items WHERE goal_id = ?", [.text(targetID)]) { row in
                if let id = row.text(0) { pool.insert(id) }
            }
            for (source, pair) in stub.excluded where pool.contains(source) && target.excluded[source] == nil {
                target.excluded[source] = pair
            }
        }
        if target != held, held != nil || target != NotebookStateRow(notebookID: targetID) {
            try target.save(connection)
        }
        try replica.setEngineState(scope, Data(targetID.utf8), now: now)
        return true
    }
}

// MARK: - Late edits to a stub (§5.2 "Late edits to a stub")

/// A device that had not seen a merge or an emptying split may still write fields of the stub, with
/// stamps of any age. A Mac that holds the survivor forwards each such field once, through the fold:
/// `ck_forwarded(record_name, field, stamp)` lists every stamp of the stub's record that needs no
/// forwarding, those the stub held when this Mac first knew it as a stub (the fold carried them, or
/// the fold of the Mac that merged it did) and those already forwarded. This Mac's own writes are never
/// forwarded: its fold already wrote them.
enum NotebookStubForwarding {
    /// Fields of a stub's record that are the redirect itself, or no notebook's words.
    static let notForwarded: Set<String> = ["status", "mergedInto", "foldKind", "movedTo", "movingTo", "createdAt", "createdBy", "editedAt", "copiedFrom"]

    private static func paths(_ envelope: SyncEnvelope) -> [(field: String, key: String, stamp: SyncStamp)] {
        var paths: [(field: String, key: String, stamp: SyncStamp)] = []
        for (field, stamps) in envelope.stamps.sorted(by: { $0.key < $1.key }) where !notForwarded.contains(field) {
            switch stamps {
            case .value(let stamp):
                paths.append((field, field, stamp))
            case .elements(let elements):
                for (element, stamp) in elements.sorted(by: { $0.key < $1.key }) {
                    paths.append((field, OutboxFeeder.pathKey(StampedPath(field, element: element)), stamp))
                }
            }
        }
        return paths
    }

    private static func heldRecord(_ notebookID: String, connection: SQLiteConnection) throws -> ReplicaRecord? {
        try ReplicaStore(connection: connection).record(
            zoneKey: ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue),
            recordType: SyncRecordType.notebook.rawValue, wireID: notebookID
        )
    }

    /// Records every stamp `envelope` (else the replica's record of the notebook) holds as needing no
    /// forwarding: what this Mac knows of the notebook at the moment it becomes a stub here.
    static func recordBaseline(notebookID: String, envelope: SyncEnvelope?, connection: SQLiteConnection) throws {
        guard let record = try heldRecord(notebookID, connection: connection),
              let held = envelope ?? (try? SyncEnvelope(storedPayload: record.payload))
        else { return }
        for path in paths(held) {
            try connection.execute(
                "INSERT INTO ck_forwarded (record_name, field, stamp) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                [.text(record.recordName), .text(path.key), .text(path.stamp.rawValue)]
            )
        }
    }

    /// Forwards the stub's late edits to `targetID` through the fold. Returns how many paths it
    /// forwarded (the title's included, which the fold never carries).
    static func forward(_ stubID: String, to targetID: String, connection: SQLiteConnection, now: Date) throws -> Int {
        guard let record = try heldRecord(stubID, connection: connection),
              let envelope = try? SyncEnvelope(storedPayload: record.payload)
        else { return 0 }
        var known = Set<String>()
        try connection.query("SELECT field, stamp FROM ck_forwarded WHERE record_name = ?", [.text(record.recordName)]) { row in
            known.insert((row.text(0) ?? "") + "\u{1F}" + (row.text(1) ?? ""))
        }
        let ownDevice = try connection.scalarText("SELECT clock_json FROM ck_clock WHERE id = 1")
            .flatMap { try? JSONDecoder().decode(StampClock.self, from: Data($0.utf8)) }?.deviceID
        let late = paths(envelope).filter { !known.contains($0.key + "\u{1F}" + $0.stamp.rawValue) }
        guard !late.isEmpty else { return 0 }
        var fields: NotebookFold.Fields = []
        for path in late where path.stamp.deviceID != ownDevice {
            if let field = NotebookFold.Fields.of(recordField: path.field) { fields.insert(field) }
        }
        if !fields.isEmpty {
            try NotebookFold.run(into: targetID, from: [stubID], fields: fields, mergeNotes: false, connection: connection, now: now)
        }
        for path in late {
            try connection.execute(
                "INSERT INTO ck_forwarded (record_name, field, stamp) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                [.text(record.recordName), .text(path.key), .text(path.stamp.rawValue)]
            )
        }
        return late.filter { $0.stamp.deviceID != ownDevice }.count
    }
}

// MARK: - A fold that lost (§5.2 step 1)

/// When another device folded the same notebook first, its `mergedInto` and `foldKind` stand (S): the
/// inbound record redirects the stub there, and what this Mac's fold moved stays in the notebook it
/// moved it into. The Notebook projection records that here (`ck_engine_state`), and the learner is
/// told once.
enum NotebookFoldNotices {
    static let scopePrefix = "notebook.foldLost."
    static let didArrive = Notification.Name("foreverlmNotebookFoldWasOverruled")
    static let messageKey = "message"

    /// Records that the fold this Mac made of `notebookID` into `lostTo` lost to one into `standsIn`.
    static func record(_ notebookID: String, lostTo: String, standsIn: String, connection: SQLiteConnection) throws {
        let value = SyncJSON.object(["lost": .string(lostTo), "stands": .string(standsIn)]).serialized()
        try ReplicaStore(connection: connection).setEngineState(scopePrefix + notebookID, value)
    }

    /// The sentences of every fold that lost since the last call, which it forgets.
    static func take(_ connection: SQLiteConnection) throws -> [String] {
        var notices: [(id: String, lost: String, stands: String)] = []
        try connection.query("SELECT scope, state FROM ck_engine_state WHERE scope LIKE ? ORDER BY scope", [.text(scopePrefix + "%")]) { row in
            guard let scope = row.text(0), let object = row.blob(1).flatMap({ try? SyncJSON(parsing: $0) })?.objectValue,
                  let lost = object["lost"]?.stringValue, let stands = object["stands"]?.stringValue else { return }
            notices.append((String(scope.dropFirst(scopePrefix.count)), lost, stands))
        }
        guard !notices.isEmpty else { return [] }
        func title(_ id: String) throws -> String {
            let resolved = try NotebookResolutionTable.resolve(id, connection: connection).id
            return try connection.scalarText("SELECT title FROM learning_goals WHERE id = ?", [.text(resolved)])
                ?? connection.scalarText("SELECT title FROM learning_goals WHERE id = ?", [.text(id)]) ?? "a notebook"
        }
        var sentences: [String] = []
        for notice in notices {
            let notebook = try connection.scalarText("SELECT title FROM learning_goals WHERE id = ?", [.text(notice.id)]) ?? "A notebook"
            let stands = try title(notice.stands)
            let lost = try title(notice.lost)
            sentences.append(
                "“\(notebook)” was already merged into “\(stands)” on another device, so it leads there now. "
                    + "What this Mac moved into “\(lost)” stays there."
            )
            try ReplicaStore(connection: connection).setEngineState(scopePrefix + notice.id, nil)
        }
        return sentences
    }
}

// MARK: - The store's entry points

extension KnowledgeStore {
    /// Merge under generation 2 (§5.2): `NotebookMergeJob` in one transaction. The caller checked the
    /// notebooks (companion Notebooks of one library).
    func mergeNotebooksUnderGeneration2(survivorID: String, mergeeIDs: [String], title: String?, mergeNotes: Bool) throws -> CompanionGoalMergeResult {
        try refuseStubs([survivorID] + mergeeIDs)
        var merged = NotebookMergeJob.Merged()
        try inDerivationTransaction { store in
            merged = try NotebookMergeJob(connection: store, registry: Self.projectionRegistry)
                .merge(mergeeIDs, into: survivorID, title: title, mergeNotes: mergeNotes)
        }
        return CompanionGoalMergeResult(
            survivorGoalID: survivorID, mergedGoalIDs: mergeeIDs.filter { $0 != survivorID }, sourcesAdded: merged.sourcesAdded,
            gapsAdded: merged.gapsAdded, chatsMoved: merged.children.chats, childGoalsMoved: merged.children.goals,
            tasksMoved: merged.children.tasks, docsMoved: merged.children.docs
        )
    }

    /// Split under generation 2 (§5.2): `NotebookMergeJob.split` in one transaction. The caller checked the
    /// specs (titles, sources of the parent's pool, each named once).
    func splitNotebookUnderGeneration2(parentID: String, splits: [CompanionGoalSplitSpec], keepParent: Bool) throws -> CompanionGoalSplitResult {
        try refuseStubs([parentID])
        var result = NotebookMergeJob.Split(childIDs: [], heirID: nil)
        try inDerivationTransaction { store in
            result = try NotebookMergeJob(connection: store, registry: Self.projectionRegistry).split(
                parentID, into: splits.map { NotebookMergeJob.Child(title: $0.title, topic: $0.topic, sourceIDs: $0.sourceIDs, gapIDs: $0.gapIDs) },
                keepParent: keepParent
            )
        }
        return CompanionGoalSplitResult(parentGoalID: result.heirID == nil ? parentID : nil, childGoalIDs: result.childIDs, heirGoalID: result.heirID)
    }

    /// Moves on what still names a stub (`NotebookStubUpkeep`), in a transaction of its own, before each
    /// feeder pass. Nothing to do without a stub. Returns the sentences of folds that
    /// lost since the last pass, for the learner.
    @discardableResult
    func keepNotebookStubs() throws -> [String] {
        guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE \(NotebookStubs.isStubSQL))") == 1
        else { return [] }
        var notices: [String] = []
        try inDerivationTransaction { store in
            _ = try NotebookStubUpkeep(feeder: OutboxFeeder(connection: store, registry: Self.projectionRegistry)).run()
            notices = try NotebookFoldNotices.take(store)
        }
        return notices
    }

    /// A stub is a redirect, never a notebook to merge or split: the request names one by an old id.
    private func refuseStubs(_ ids: [String]) throws {
        for id in ids {
            guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ? AND \(NotebookStubs.isStubSQL))", [.text(id)]) == 1 else { continue }
            let survivor = try NotebookResolutionTable.resolve(id, connection: self).id
            throw KnowledgeStoreError.invalidData("Notebook \(id) was merged into \(survivor); use that notebook instead.")
        }
    }
}
