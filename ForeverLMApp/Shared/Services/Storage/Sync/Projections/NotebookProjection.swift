import Foundation

// MARK: - Notebook or Goal: one local table, two record types (docs/cloudkit-schema-design.md §3.5.6, §3.5.7)

/// Which record a `learning_goals` row is (`entity_kind`, D14): a Notebook or a Goal, decided once by
/// `LearningGoalShape` when the row is first classified, never inferred from its deadline again
/// (bug b1). The activation classifies every row; under generation 2 every write that adds a row
/// classifies it at once, and an inbound record writes its own type.
enum LearningGoalEntityKind {
    static let notebook = "notebook"
    static let goal = "goal"

    /// The kind `LearningGoalShape` gives a row: an open-ended companion record with no parent is a
    /// notebook; everything else (a dated Goal, a legacy schedule goal) is a Goal.
    static func kind(kind: String?, parentNotebookID: String?, endAt: Double) -> String {
        LearningGoalShape.isNotebook(kind: kind, parentNotebookID: parentNotebookID, endAtReferenceSeconds: endAt) ? notebook : goal
    }

    /// Classifies every row that has no kind yet. Bounded by the library's notebooks and Goals.
    @discardableResult
    static func classifyUnclassified(_ connection: SQLiteConnection) throws -> Int {
        var rows: [(id: String, kind: String)] = []
        try connection.query("SELECT id, kind, parent_notebook_id, end_at FROM learning_goals WHERE entity_kind IS NULL", []) { row in
            guard let id = row.text(0) else { return }
            rows.append((id, Self.kind(kind: row.text(1), parentNotebookID: row.text(2), endAt: row.real(3) ?? 0)))
        }
        for row in rows {
            try connection.execute("UPDATE learning_goals SET entity_kind = ? WHERE id = ? AND entity_kind IS NULL", [.text(row.kind), .text(row.id)])
        }
        return rows.count
    }
}

// MARK: - Order keys that move as little as possible

/// Fractional keys (§3.5.8 `orderKey`) for a list in a new order, changing as few as possible: the
/// longest run of items whose keys already ascend in the new order keeps them, and each other item
/// gets a key between its neighbours. Moving one item rewrites one key, so a reorder sends one record.
enum OrderKeyPlanner {
    /// The new key of each item that needs one, by id. `ordered` is the list in its new order with each
    /// item's current key, if any.
    static func plan(_ ordered: [(id: String, key: String?)]) -> [String: String] {
        let keys = ordered.map { $0.key.flatMap { FractionalIndex.isValid($0) ? $0 : nil } }
        let kept = Set(longestAscending(keys))
        var result: [String: String] = [:]
        var index = 0
        while index < ordered.count {
            guard !kept.contains(index) else { index += 1; continue }
            // A run of items to key, between the kept keys around it.
            var end = index
            while end < ordered.count, !kept.contains(end) { end += 1 }
            let lower = (0..<index).reversed().first { kept.contains($0) }.flatMap { keys[$0] }
                ?? (0..<index).reversed().compactMap { result[ordered[$0].id] }.first
            let upper = end < ordered.count ? keys[end] : nil
            let fresh = (try? FractionalIndex.keys(between: lower, and: upper, count: end - index)) ?? []
            for (offset, key) in fresh.enumerated() { result[ordered[index + offset].id] = key }
            index = end
        }
        return result
    }

    /// The positions of a longest strictly ascending run of keys (nil keys never take part).
    private static func longestAscending(_ keys: [String?]) -> [Int] {
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: keys.count)
        for (index, key) in keys.enumerated() {
            guard let key else { continue }
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if let held = keys[tails[middle]], held < key { low = middle + 1 } else { high = middle }
            }
            previous[index] = low > 0 ? tails[low - 1] : -1
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(cursor)
            cursor = previous[cursor]
        }
        return run.reversed()
    }
}

// MARK: - Research questions (§3.5.6 `researchQuestions`)

/// A notebook's research questions as `notebook_research_questions` rows. Generation 1 keeps them as a
/// JSON array of strings in `learning_goals.research_questions`, which every generation-1 reader still
/// reads, so under generation 2 the two are kept together: a local edit of the array is diffed into
/// the rows, and an inbound record writes the rows and the array.
enum NotebookResearchQuestions {
    /// A question's id from its notebook and its text, trimmed and lowercased: two Macs deriving one
    /// list mint one map, and a question asked again comes back under its old id.
    static func questionID(notebookID: String, text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "rq_" + SyncIdentity.sha256Hex(Data("researchQuestion:v1:\(notebookID):\(normalized)".utf8)).prefix(24)
    }

    struct Row: Equatable, Sendable {
        let id: String
        var text: String
        var status: String
        var orderKey: String
        var createdAt: Double?
    }

    static func rows(notebookID: String, connection: SQLiteConnection) throws -> [Row] {
        var rows: [Row] = []
        try connection.query(
            "SELECT id, text, status, order_key, created_at FROM notebook_research_questions WHERE notebook_id = ? ORDER BY order_key, id",
            [.text(notebookID)]
        ) { row in
            rows.append(Row(id: row.text(0) ?? "", text: row.text(1) ?? "", status: row.text(2) ?? "open", orderKey: row.text(3) ?? "", createdAt: row.real(4)))
        }
        return rows
    }

    /// Makes the rows match `questions`, the generation-1 list in its order: a question no longer
    /// listed goes, a new one is added, a dropped one asked again is open again, and the order moves
    /// as few keys as it can. A question the record marks dropped is not in the list and stays.
    static func syncRows(notebookID: String, questions: [String], at now: Double, connection: SQLiteConnection) throws {
        var seen = Set<String>()
        let wanted = questions.compactMap { text -> (id: String, text: String)? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = questionID(notebookID: notebookID, text: trimmed)
            guard !trimmed.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, trimmed)
        }
        let held = Dictionary(try rows(notebookID: notebookID, connection: connection).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in held.values where row.status != "dropped" && !seen.contains(row.id) {
            try connection.execute("DELETE FROM notebook_research_questions WHERE notebook_id = ? AND id = ?", [.text(notebookID), .text(row.id)])
        }
        let keys = OrderKeyPlanner.plan(wanted.map { (id: $0.id, key: held[$0.id]?.orderKey) })
        for question in wanted {
            let key = keys[question.id] ?? held[question.id]?.orderKey ?? ""
            try connection.execute("""
                INSERT INTO notebook_research_questions (notebook_id, id, text, status, order_key, created_at)
                VALUES (?, ?, ?, 'open', ?, ?)
                ON CONFLICT(notebook_id, id) DO UPDATE SET
                    text = excluded.text, status = 'open', order_key = excluded.order_key
            """, [.text(notebookID), .text(question.id), .text(question.text), .text(key), .real(now)])
        }
    }

    /// The generation-1 array the rows give: the questions not dropped, in their order.
    static func legacyJSON(notebookID: String, connection: SQLiteConnection) throws -> String {
        let texts = try rows(notebookID: notebookID, connection: connection).filter { $0.status != "dropped" }.map(\.text)
        return KnowledgeStore.encodeResearchQuestions(texts)
    }
}

// MARK: - The Notebook record

/// A notebook's local rows: its `learning_goals` row (a notebook's), its research questions, open
/// questions (`learning_goal_gaps`) and the notebooks it draws on (`notebook_related_notebook_links`).
struct NotebookRows: Equatable, Sendable {
    var columns: [String: SQLiteValue]
    var researchQuestions: [NotebookResearchQuestions.Row]
    var openQuestions: [(id: String, summary: String, status: String, sourceID: String?, firstSeenAt: Double?)]
    var relatedNotebookIDs: [String]

    static func == (lhs: NotebookRows, rhs: NotebookRows) -> Bool {
        lhs.columns == rhs.columns && lhs.researchQuestions == rhs.researchQuestions && lhs.relatedNotebookIDs == rhs.relatedNotebookIDs
            && lhs.openQuestions.map(\.id) == rhs.openQuestions.map(\.id)
    }
}

/// The Notebook record's projection (§3.5.6). The notes are not on it: they are the Notes Doc's body
/// (`NotesDoc`, §3.5.15). Membership, ticks and order are not on it either: they are Entries and the
/// member's NotebookState. A row of a Goal never feeds it, and it never writes a Goal's row (b1).
struct NotebookProjection: RecordProjection {
    var recordType: SyncRecordType { .notebook }

    static let columns = [
        "title", "description", "summary", "topic", "discovery_enabled", "last_discovery_at", "repository", "artifact_id",
        "status", "merged_into", "fold_kind", "moving_to", "moved_to", "created_at",
    ]

    /// `learning_goals` as each of its two record types reads it: the row's kind is a key column, so
    /// a row routes to its own type only.
    static func learningGoalsTable(kind: String, type: SyncRecordType, syncedColumns: [String]) -> ProjectedTable {
        ProjectedTable(
            "learning_goals", localKey: ["id"], keyColumns: ["id", "entity_kind"], syncedColumns: syncedColumns,
            recordTypes: [type],
            record: { values in
                guard values["entity_kind"]?.textValue == kind, let id = values["id"]?.textValue else { return nil }
                return RowRecord(type: type, localID: id, personalID: id)
            },
            localIDSQL: { "\($0).id" }, personalIDSQL: { "\($0).id" }
        )
    }

    /// A table whose rows are elements of the notebook's map or set field, keyed by `element`.
    private static func elementTable(_ name: String, localKey: [String], notebookColumn: String, element: String, syncedColumns: [String]) -> ProjectedTable {
        ProjectedTable(
            name, localKey: localKey, keyColumns: [notebookColumn], syncedColumns: syncedColumns,
            parents: [LocalParent(notebookColumn, references: "learning_goals", type: .notebook, role: .container)],
            elementColumn: element, recordTypes: [.notebook],
            record: { values in values[notebookColumn]?.textValue.map { RowRecord(type: .notebook, localID: $0, personalID: $0) } },
            localIDSQL: { "\($0).\(notebookColumn)" }, personalIDSQL: { "\($0).\(notebookColumn)" }
        )
    }

    var tables: [ProjectedTable] {
        [
            Self.learningGoalsTable(kind: LearningGoalEntityKind.notebook, type: .notebook, syncedColumns: Self.columns),
            Self.elementTable("notebook_research_questions", localKey: ["notebook_id", "id"], notebookColumn: "notebook_id", element: "id",
                              syncedColumns: ["text", "status", "order_key", "created_at"]),
            Self.elementTable("learning_goal_gaps", localKey: ["id"], notebookColumn: "goal_id", element: "id",
                              syncedColumns: ["summary", "status", "source_id", "first_seen_at"]),
            Self.elementTable("notebook_related_notebook_links", localKey: ["notebook_id", "related_notebook_id"], notebookColumn: "notebook_id",
                              element: "related_notebook_id", syncedColumns: []),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "learning_goals", names) }

    var feeds: [String: FieldFeed] {
        [
            "title": Self.column("title"), "instructions": Self.column("description"), "summary": Self.column("summary"),
            "topic": Self.column("topic"), "discovery": Self.column("discovery_enabled", "last_discovery_at"),
            "repository": Self.column("repository"), "homeArtifactID": Self.column("artifact_id"),
            "status": Self.column("status", "merged_into", "moved_to"), "mergedInto": Self.column("merged_into"),
            "foldKind": Self.column("fold_kind"), "movingTo": Self.column("moving_to"), "movedTo": Self.column("moved_to"),
            "createdAt": Self.column("created_at"),
            "researchQuestions": .elementRows(table: "notebook_research_questions"),
            "openQuestions": .elementRows(table: "learning_goal_gaps"),
            "relatedNotebookIDs": .elementRows(table: "notebook_related_notebook_links"),
        ]
    }

    /// A deleted notebook row deletes the record; its Entries go with it (§5.2).
    var missingRow: MissingRowOutcome { .delete }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> NotebookRows? {
        try Self.loadRows(localID: record.localID, connection: connection)
    }

    static func loadRows(localID: String, connection: SQLiteConnection) throws -> NotebookRows? {
        var columns: [String: SQLiteValue]?
        try connection.query(
            "SELECT entity_kind, \(Self.columns.joined(separator: ", ")) FROM learning_goals WHERE id = ?", [.text(localID)]
        ) { row in
            guard row.text(0) == LearningGoalEntityKind.notebook else { return }
            var read: [String: SQLiteValue] = [:]
            for (index, column) in Self.columns.enumerated() { read[column] = OutboxFeeder.value(row, Int32(index + 1)) }
            columns = read
        }
        guard let columns else { return nil }
        var gaps: [(id: String, summary: String, status: String, sourceID: String?, firstSeenAt: Double?)] = []
        try connection.query("SELECT id, summary, status, source_id, first_seen_at FROM learning_goal_gaps WHERE goal_id = ? ORDER BY id", [.text(localID)]) { row in
            gaps.append((row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? "open", row.text(3), row.real(4)))
        }
        var related: [String] = []
        try connection.query("SELECT related_notebook_id FROM notebook_related_notebook_links WHERE notebook_id = ? ORDER BY related_notebook_id", [.text(localID)]) { row in
            if let id = row.text(0) { related.append(id) }
        }
        return NotebookRows(
            columns: columns,
            researchQuestions: try NotebookResearchQuestions.rows(notebookID: localID, connection: connection),
            openQuestions: gaps, relatedNotebookIDs: related
        )
    }

    static func encodeRows(_ rows: NotebookRows) -> [String: SyncJSON] {
        func text(_ column: String) -> String? { rows.columns[column]?.textValue }
        /// A column NULL is no opinion (absent); an empty string is an explicit clear.
        func optional(_ column: String) -> SyncJSON? {
            guard let value = text(column) else { return nil }
            return value.isEmpty ? .null : .string(value)
        }
        var fields: [String: SyncJSON] = ["title": .string(text("title") ?? "")]
        for (field, column) in [("instructions", "description"), ("summary", "summary"), ("topic", "topic")] {
            fields[field] = text(column).map { $0.isEmpty ? .null : .string($0) } ?? .null
        }
        if let enabled = rows.columns["discovery_enabled"].flatMap({ if case .integer(let flag) = $0 { return flag } else { return nil } }) {
            var discovery: [String: SyncJSON] = ["enabled": .bool(enabled != 0)]
            if let lastRun = rows.columns["last_discovery_at"].flatMap({ if case .real(let time) = $0 { return time } else { return nil } }) {
                discovery["lastRunAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: lastRun))
            }
            fields["discovery"] = .object(discovery)
        }
        if let repository = text("repository") {
            fields["repository"] = GitHubRepositoryName.normalized(repository).map { .object(["url": .string("https://github.com/" + $0)]) } ?? .null
        }
        if let home = optional("artifact_id") { fields["homeArtifactID"] = home }
        let mergedInto = text("merged_into").flatMap { $0.isEmpty ? nil : $0 }
        let movedTo = text("moved_to").flatMap { $0.isEmpty ? nil : $0 }
        fields["status"] = .string(mergedInto != nil ? "merged" : movedTo != nil ? "moved" : text("status") == LearningGoalStatus.archived.rawValue ? "archived" : "active")
        if let mergedInto { fields["mergedInto"] = .string(mergedInto) }
        if let foldKind = text("fold_kind"), !foldKind.isEmpty { fields["foldKind"] = .string(foldKind) }
        fields["movingTo"] = text("moving_to").flatMap { $0.isEmpty ? nil : SyncJSON.string($0) } ?? .null
        if let movedTo { fields["movedTo"] = .string(movedTo) }
        if case .real(let created)? = rows.columns["created_at"] { fields["createdAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: created)) }

        var questions: [String: SyncJSON] = [:]
        for question in rows.researchQuestions {
            var value: [String: SyncJSON] = ["text": .string(question.text), "status": .string(question.status), "orderKey": .string(question.orderKey)]
            if let created = question.createdAt { value["createdAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: created)) }
            questions[question.id] = .object(value)
        }
        fields["researchQuestions"] = .object(questions)
        var gaps: [String: SyncJSON] = [:]
        for gap in rows.openQuestions {
            var value: [String: SyncJSON] = ["text": .string(gap.summary), "status": .string(gap.status == "resolved" ? "resolved" : "open")]
            if let created = gap.firstSeenAt { value["createdAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: created)) }
            if let source = gap.sourceID, !source.isEmpty { value["sourceIDs"] = .array([.string(source)]) }
            gaps[gap.id] = .object(value)
        }
        fields["openQuestions"] = .object(gaps)
        fields["relatedNotebookIDs"] = .object(Dictionary(rows.relatedNotebookIDs.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first }))
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // A space notebook lands on a row of its space's team id (WP15); a moved stub projects only into
        // `notebook_resolution` (§5.2).
        defer { try? NotebookResolutionTable.refresh(connection) }
        let fields = envelope.fields
        guard fields["status"]?.stringValue != "moved" else { return .projected }
        let space = try SpaceRows.placement(of: record, table: "learning_goals", connection: connection)
        let id = space?.localID ?? record.localID
        // A notebook moved back to My Library takes its row out of the space it left (WP15b).
        if space == nil { try SpaceMoveLocal.comeBack(record, fields: fields, connection: connection) }
        let heldKind = try connection.scalarText("SELECT COALESCE(entity_kind, '') FROM learning_goals WHERE id = ?", [.text(id)])
        // b1: a Notebook never lands on a Goal's row.
        guard heldKind == nil || heldKind == LearningGoalEntityKind.notebook || heldKind == "" else { return .projected }

        // The first acknowledged fold stands (§5.2): when this Mac's own fold of the notebook lost, what
        // it moved stays where it went and the learner is told. A notebook that becomes a stub here
        // records what it held, so only edits that arrive later are forwarded (`NotebookStubForwarding`).
        if let incoming = fields["mergedInto"]?.stringValue, !incoming.isEmpty {
            let heldRedirect = try connection.scalarText("SELECT COALESCE(merged_into, '') FROM learning_goals WHERE id = ?", [.text(id)]) ?? ""
            if heldRedirect.isEmpty {
                try NotebookStubForwarding.recordBaseline(notebookID: id, envelope: envelope, connection: connection)
            } else if heldRedirect != incoming {
                try NotebookFoldNotices.record(id, lostTo: heldRedirect, standsIn: incoming, connection: connection)
            }
        }

        var values: [String: SQLiteValue] = [:]
        if let title = fields["title"]?.stringValue { values["title"] = .text(title) }
        for (field, column) in [("instructions", "description"), ("summary", "summary"), ("topic", "topic")] {
            if let value = fields[field] { values[column] = .text(value.stringValue) }
        }
        if let discovery = fields["discovery"] {
            values["discovery_enabled"] = .integer(discovery["enabled"]?.boolValue.map { $0 ? 1 : 0 })
            values["last_discovery_at"] = .real(discovery["lastRunAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) })
        }
        if let repository = fields["repository"] {
            values["repository"] = .text(repository["url"]?.stringValue.flatMap(GitHubRepositoryName.normalized) ?? "")
        }
        if let home = fields["homeArtifactID"] { values["artifact_id"] = .text(home.stringValue ?? "") }
        if let status = fields["status"]?.stringValue {
            values["status"] = .text(status == "archived" || status == "merged" ? LearningGoalStatus.archived.rawValue : LearningGoalStatus.active.rawValue)
        }
        for (field, column) in [("mergedInto", "merged_into"), ("foldKind", "fold_kind"), ("movingTo", "moving_to"), ("movedTo", "moved_to")] {
            if let value = fields[field] { values[column] = .text(value.stringValue) }
        }
        let created = fields["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        if let created { values["created_at"] = .real(created) }
        let edited = fields["editedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }

        if heldKind == nil {
            let createdAt = created ?? Date().timeIntervalSinceReferenceDate
            values["title"] = values["title"] ?? .text("")
            values["start_at"] = .real(createdAt)
            values["end_at"] = .real(LearningGoalShape.openEndedEndAtReferenceSeconds)
            values["created_at"] = .real(createdAt)
            values["updated_at"] = .real(edited ?? createdAt)
            values["kind"] = .text(LearningGoalShape.companionKind)
            values["entity_kind"] = .text(LearningGoalEntityKind.notebook)
            values["wire_id"] = .text(record.wireID)
            if let space { values["team_id"] = .text(space.teamID) }
            let names = ["id"] + values.keys.sorted()
            try connection.execute(
                "INSERT INTO learning_goals (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + values.keys.sorted().compactMap { values[$0] }
            )
        } else {
            values["entity_kind"] = .text(LearningGoalEntityKind.notebook)
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE learning_goals SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(id)]
            )
            if let edited {
                try connection.execute("UPDATE learning_goals SET updated_at = MAX(updated_at, ?) WHERE id = ?", [.real(edited), .text(id)])
            }
        }
        try applyResearchQuestions(fields["researchQuestions"], notebookID: id, connection: connection)
        try applyOpenQuestions(fields["openQuestions"], notebookID: id, connection: connection)
        // A cover that arrived (D53): the cover pictures read the replica again. The notice goes out after
        // the open transaction, on the main queue.
        if fields["files"]?["cover"] != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .notebookCoversDidChange, object: nil, userInfo: ["notebookID": id])
            }
        }
        if let related = fields["relatedNotebookIDs"]?.objectValue {
            for (other, member) in related.sorted(by: { $0.key < $1.key }) where other != id {
                if member.boolValue == true {
                    try connection.execute("""
                        INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at) VALUES (?, ?, ?)
                        ON CONFLICT(notebook_id, related_notebook_id) DO NOTHING
                    """, [.text(id), .text(other), .real(edited ?? Date().timeIntervalSinceReferenceDate)])
                } else {
                    try connection.execute("DELETE FROM notebook_related_notebook_links WHERE notebook_id = ? AND related_notebook_id = ?", [.text(id), .text(other)])
                }
            }
        }
        return .projected
    }

    private func applyResearchQuestions(_ value: SyncJSON?, notebookID: String, connection: SQLiteConnection) throws {
        guard let elements = value?.objectValue else { return }
        for (questionID, element) in elements.sorted(by: { $0.key < $1.key }) {
            guard let object = element.objectValue, let text = object["text"]?.stringValue else {
                try connection.execute("DELETE FROM notebook_research_questions WHERE notebook_id = ? AND id = ?", [.text(notebookID), .text(questionID)])
                continue
            }
            let orderKey = object["orderKey"]?.stringValue ?? ((try? FractionalIndex.key(between: nil, and: nil)) ?? "a0")
            try connection.execute("""
                INSERT INTO notebook_research_questions (notebook_id, id, text, status, order_key, created_at) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(notebook_id, id) DO UPDATE SET
                    text = excluded.text, status = excluded.status, order_key = excluded.order_key,
                    created_at = COALESCE(excluded.created_at, notebook_research_questions.created_at)
            """, [
                .text(notebookID), .text(questionID), .text(text), .text(object["status"]?.stringValue ?? "open"), .text(orderKey),
                .real(object["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }),
            ])
        }
        // Generation-1 readers read the array.
        try connection.execute(
            "UPDATE learning_goals SET research_questions = ? WHERE id = ?",
            [.text(try NotebookResearchQuestions.legacyJSON(notebookID: notebookID, connection: connection)), .text(notebookID)]
        )
    }

    private func applyOpenQuestions(_ value: SyncJSON?, notebookID: String, connection: SQLiteConnection) throws {
        guard let elements = value?.objectValue else { return }
        for (gapID, element) in elements.sorted(by: { $0.key < $1.key }) {
            guard let object = element.objectValue, let text = object["text"]?.stringValue else {
                try connection.execute("DELETE FROM learning_goal_gaps WHERE id = ? AND goal_id = ?", [.text(gapID), .text(notebookID)])
                continue
            }
            let seen = object["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? Date().timeIntervalSinceReferenceDate
            let status = object["status"]?.stringValue == "resolved" ? "resolved" : "open"
            try connection.execute("""
                INSERT INTO learning_goal_gaps (id, goal_id, summary, source_id, status, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    summary = excluded.summary, source_id = excluded.source_id, status = excluded.status,
                    first_seen_at = excluded.first_seen_at, last_seen_at = MAX(learning_goal_gaps.last_seen_at, excluded.last_seen_at)
            """, [
                .text(gapID), .text(notebookID), .text(text), .text(object["sourceIDs"]?.arrayValue?.first?.stringValue), .text(status),
                .real(seen), .real(seen),
            ])
        }
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        defer { try? NotebookResolutionTable.refresh(connection) }
        // Its items, questions and links go with the row; children elsewhere resolve to "unfiled" on
        // read (§5.2), and the member's own NotebookState stays (D18). A space notebook's identity goes too.
        try connection.execute("DELETE FROM learning_goals WHERE id = ? AND entity_kind = ?", [.text(record.localID), .text(LearningGoalEntityKind.notebook)])
        if record.zone.isSpace {
            try connection.execute("DELETE FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
                                   [.text(record.zoneKey), .text(SyncRecordType.notebook.rawValue), .text(record.wireID)])
        }
    }
}

// MARK: - The Goal record

/// The Goal record's projection (§3.5.7): a learner's dated plan, private to the member. Its sources
/// are Entries (`containerKind = goal`).
struct GoalProjection: RecordProjection {
    struct Rows: Equatable, Sendable {
        let columns: [String: SQLiteValue]
    }

    var recordType: SyncRecordType { .goal }

    static let columns = ["title", "description", "parent_notebook_id", "start_at", "end_at", "daily_target", "status", "created_at"]

    var tables: [ProjectedTable] {
        [NotebookProjection.learningGoalsTable(kind: LearningGoalEntityKind.goal, type: .goal, syncedColumns: Self.columns)]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "learning_goals", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "title": Self.column("title"), "description": Self.column("description"), "notebookID": Self.column("parent_notebook_id"),
            "startAt": Self.column("start_at"), "dueAt": Self.column("end_at"), "dailyTarget": Self.column("daily_target"),
            "status": Self.column("status"), "createdAt": Self.column("created_at"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }
    var priority: OutboxPriority { .personal }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows? {
        var rows: Rows?
        try connection.query(
            "SELECT entity_kind, \(Self.columns.joined(separator: ", ")) FROM learning_goals WHERE id = ?", [.text(record.localID)]
        ) { row in
            guard row.text(0) == LearningGoalEntityKind.goal else { return }
            var read: [String: SQLiteValue] = [:]
            for (index, column) in Self.columns.enumerated() { read[column] = OutboxFeeder.value(row, Int32(index + 1)) }
            rows = Rows(columns: read)
        }
        return rows
    }

    static func encodeRows(_ rows: Rows) -> [String: SyncJSON] {
        func text(_ column: String) -> String? { rows.columns[column]?.textValue }
        func milliseconds(_ column: String) -> SyncJSON? {
            if case .real(let time)? = rows.columns[column] { return SyncJSON(SyncTime.milliseconds(cocoaSeconds: time)) }
            if case .integer(let time)? = rows.columns[column] { return SyncJSON(SyncTime.milliseconds(cocoaSeconds: Double(time))) }
            return nil
        }
        var fields: [String: SyncJSON] = [
            "title": .string(text("title") ?? ""),
            "description": text("description").map { $0.isEmpty ? .null : .string($0) } ?? .null,
            "notebookID": text("parent_notebook_id").map { $0.isEmpty ? .null : .string($0) } ?? .null,
            "status": .string(LearningGoalStatus.parse(text("status")).rawValue),
        ]
        fields["startAt"] = milliseconds("start_at")
        fields["dueAt"] = milliseconds("end_at")
        fields["createdAt"] = milliseconds("created_at")
        if case .integer(let target)? = rows.columns["daily_target"] { fields["dailyTarget"] = SyncJSON(target) } else { fields["dailyTarget"] = .null }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        let fields = envelope.fields
        let id = record.localID
        let heldKind = try connection.scalarText("SELECT COALESCE(entity_kind, '') FROM learning_goals WHERE id = ?", [.text(id)])
        // b1: a Goal never lands on a notebook's row.
        guard heldKind == nil || heldKind == LearningGoalEntityKind.goal || heldKind == "" else { return .projected }
        func seconds(_ field: String) -> Double? { fields[field]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } }
        var values: [String: SQLiteValue] = [:]
        if let title = fields["title"]?.stringValue { values["title"] = .text(title) }
        if let description = fields["description"] { values["description"] = .text(description.stringValue) }
        if let notebook = fields["notebookID"] { values["parent_notebook_id"] = .text(notebook.stringValue) }
        if let start = seconds("startAt") { values["start_at"] = .real(start) }
        if let due = seconds("dueAt") { values["end_at"] = .real(due) }
        if let target = fields["dailyTarget"] { values["daily_target"] = .integer(target.int64Value) }
        if let status = fields["status"]?.stringValue { values["status"] = .text(LearningGoalStatus.parse(status).rawValue) }
        if let created = seconds("createdAt") { values["created_at"] = .real(created) }
        let edited = seconds("editedAt")
        values["entity_kind"] = .text(LearningGoalEntityKind.goal)

        if heldKind == nil {
            let createdAt = seconds("createdAt") ?? Date().timeIntervalSinceReferenceDate
            values["title"] = values["title"] ?? .text("")
            values["start_at"] = values["start_at"] ?? .real(createdAt)
            values["end_at"] = values["end_at"] ?? .real(createdAt)
            values["created_at"] = .real(createdAt)
            values["updated_at"] = .real(edited ?? createdAt)
            values["kind"] = .text(LearningGoalShape.companionKind)
            values["wire_id"] = .text(record.wireID)
            let names = ["id"] + values.keys.sorted()
            try connection.execute(
                "INSERT INTO learning_goals (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + values.keys.sorted().compactMap { values[$0] }
            )
        } else {
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE learning_goals SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(id)]
            )
            if let edited {
                try connection.execute("UPDATE learning_goals SET updated_at = MAX(updated_at, ?) WHERE id = ?", [.real(edited), .text(id)])
            }
        }
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM learning_goals WHERE id = ? AND entity_kind = ?", [.text(record.localID), .text(LearningGoalEntityKind.goal)])
    }
}

// MARK: - Where a notebook id leads (§5.2 `resolveNotebook()`)

/// The Mac's materialized `notebook_resolution`: every notebook id it knows (its rows, and the
/// notebooks and stubs its replica holds) with the last live notebook its redirects lead to and that
/// notebook's zone, as `NotebookResolution` walks them. Refreshed on every Notebook apply and at the
/// activation; bounded by the library's notebooks. WP8b's jobs and WP15b's moves read it.
enum NotebookResolutionTable {
    static func refresh(_ connection: SQLiteConnection) throws {
        var held: [SyncRecordLocation: NotebookRedirects] = [:]
        var ids = Set<String>()
        // The replica's Notebook records, in the zones this device holds.
        try connection.query("""
            SELECT record.zone_key, record.wire_id, record.payload FROM ck_records AS record
            WHERE record.record_type = 'Notebook' AND record.zone_key IN (SELECT zone_key FROM ck_zones)
        """, []) { row in
            guard let zone = row.text(0).flatMap(ProjectionZones.zone(ofKey:)), let id = row.text(1),
                  let payload = row.blob(2), let envelope = try? SyncEnvelope(storedPayload: payload) else { return }
            held[SyncRecordLocation(zone: zone, id: id)] = NotebookRedirects(
                mergedInto: envelope.fields["mergedInto"]?.stringValue, movedTo: envelope.fields["movedTo"]?.stringValue,
                movingTo: envelope.fields["movingTo"]?.stringValue
            )
            if !zone.isSpace { ids.insert(id) }
        }
        // The local notebooks, a redirect written here and not sent yet included.
        try connection.query(
            "SELECT wire_key, merged_into, moved_to, moving_to FROM learning_goals WHERE entity_kind = ? AND team_id IS NULL",
            [.text(LearningGoalEntityKind.notebook)]
        ) { row in
            guard let id = row.text(0) else { return }
            let location = SyncRecordLocation(zone: .library, id: id)
            let local = NotebookRedirects(
                mergedInto: row.text(1).flatMap { $0.isEmpty ? nil : $0 }, movedTo: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                movingTo: row.text(3).flatMap { $0.isEmpty ? nil : $0 }
            )
            let replica = held[location]
            held[location] = NotebookRedirects(
                mergedInto: local.mergedInto ?? replica?.mergedInto, movedTo: local.movedTo ?? replica?.movedTo,
                movingTo: local.movingTo ?? replica?.movingTo
            )
            ids.insert(id)
        }
        var rows: [(id: String, resolved: SyncRecordLocation)] = []
        for id in ids.sorted() {
            rows.append((id, NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: id)) { held[$0] }))
        }
        try connection.execute("DELETE FROM notebook_resolution", [])
        for row in rows {
            try connection.execute(
                "INSERT INTO notebook_resolution (id, resolved_id, resolved_zone) VALUES (?, ?, ?)",
                [.text(row.id), .text(row.resolved.id), .text(row.resolved.zone.name)]
            )
        }
    }

    /// The live notebook `id` leads to, and its zone; `id` itself in `Library` when no row names it.
    static func resolve(_ id: String, connection: SQLiteConnection) throws -> SyncRecordLocation {
        var found: SyncRecordLocation?
        try connection.query("SELECT resolved_id, resolved_zone FROM notebook_resolution WHERE id = ?", [.text(id)]) { row in
            if let resolved = row.text(0), let zone = row.text(1).flatMap(SyncZoneName.init) {
                found = SyncRecordLocation(zone: zone, id: resolved)
            }
        }
        return found ?? SyncRecordLocation(zone: .library, id: id)
    }
}

// MARK: - The notebook's Notes Doc (§3.5.6, §3.5.15)

/// A notebook's notes as its Notes Doc, `Artifact(kind notes, id notes:<notebookID>)`, made from
/// `learning_goals.notes`: the body is the notes' Markdown, trimmed, gzip, `bodyFormat` markdown,
/// owned by the Doc, laid out as `BlobStore` lays it out; the title "Notes", as the web's
/// `setNotebookNotes` writes one, so a Notes body hashes the same on every client (§13.6). Empty notes
/// have no body. This is the encoding only: the Artifact projection, which publishes a body on idle and
/// three-way merges it (D44, §6.2 step 4), is WP11's, and no notes base is ever taken from the local
/// text (§13.6, R8-1).
enum NotesDoc {
    static let title = "Notes"
    static let bodyFormat = "markdown"
    static let previewLimit = 280

    static func id(notebookID: String) -> String { "notes:\(notebookID)" }

    /// The notebook a Notes Doc id names.
    static func notebookID(of artifactID: String) -> String? {
        artifactID.hasPrefix("notes:") ? String(artifactID.dropFirst(6)) : nil
    }

    static func text(_ notes: String?) -> String {
        (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body's FileRef and its stored bytes; nil for notes that are empty.
    static func body(notebookID: String, notes: String?) throws -> (file: FileRef, stored: Data)? {
        let text = text(notes)
        guard !text.isEmpty else { return nil }
        return try SourceSatelliteLayout.layout(SourceLocalSatellite(
            map: .files, role: "body", mime: "text/markdown", encoding: .gzip, body: Data(text.utf8), localPath: nil, input: nil
        ), owner: id(notebookID: notebookID))
    }

    /// The Notes Doc's fields for a notebook's notes, `createdAt` the notebook's.
    static func fields(notebookID: String, notes: String?, createdAt: Int64) throws -> [String: SyncJSON] {
        let text = text(notes)
        let preview = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(previewLimit)
        return [
            "kind": .string("notes"), "title": .string(title), "notebookID": .string(notebookID), "status": .string("active"),
            "createdAt": SyncJSON(createdAt), "bodyFormat": .string(bodyFormat),
            "body": try body(notebookID: notebookID, notes: notes)?.file.value ?? .null,
            "preview": preview.isEmpty ? .null : .string(String(preview)),
        ]
    }
}
