import Foundation

// MARK: - The Lesson record (docs/cloudkit-schema-design.md §3.5.10)

/// One `course_lectures` row as the Lesson record reads it.
struct LessonRows: Equatable, Sendable {
    let id: String
    let courseID: String
    let title: String?
    let createdAt: Double
    let orderKey: String?
}

/// The Lesson record's projection (§3.5.10): a course's lecture, ordered by its fractional key, which
/// replaces `lecture_number` on the wire (§8d). Every local lecture is a `lecture`; `label`, `summary`
/// and `objectives` have no column and stay as the record holds them. A lecture with no title sends
/// none: the app names it by its place ("Lecture 3"), which a reorder changes, so no place-made name
/// is ever sent.
struct LessonProjection: RecordProjection {
    var recordType: SyncRecordType { .lesson }

    static let columns = ["course_id", "title", "created_at", "order_key"]

    var tables: [ProjectedTable] {
        [ProjectedTable.records(
            "course_lectures", type: .lesson, syncedColumns: Self.columns,
            parents: [LocalParent("course_id", references: "courses", type: .course, role: .container)]
        )]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "course_lectures", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "courseID": .rowExistence(table: "course_lectures"), "kind": .rowExistence(table: "course_lectures"),
            "title": Self.column("title"), "createdAt": Self.column("created_at"), "orderKey": Self.column("order_key"),
        ]
    }

    /// A lecture deleted while its course stays deletes the Lesson; its items' Entries go with it.
    var missingRow: MissingRowOutcome { .delete }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> LessonRows? {
        var rows: LessonRows?
        try connection.query(
            "SELECT course_id, title, created_at, order_key FROM course_lectures WHERE id = ?", [.text(record.localID)]
        ) { row in
            rows = LessonRows(id: record.localID, courseID: row.text(0) ?? "", title: row.text(1), createdAt: row.real(2) ?? 0, orderKey: row.text(3))
        }
        return rows
    }

    static func encodeRows(_ rows: LessonRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "courseID": .string(rows.courseID),
            "kind": .string("lecture"),
            "createdAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.createdAt)),
        ]
        if let title = rows.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { fields["title"] = .string(title) }
        if let key = rows.orderKey { fields["orderKey"] = .string(key) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        guard let courseID = fields["courseID"]?.stringValue else { return .projected }
        guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM courses WHERE id = ?)", [.text(courseID)]) == 1 else {
            return .waiting([WaitingParent(type: .course, wireID: courseID)])
        }
        let id = record.localID
        let created = fields["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        let held = try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM course_lectures WHERE id = ?)", [.text(id)]) == 1
        if held {
            var values: [String: SQLiteValue] = [:]
            if let title = fields["title"] { values["title"] = .text(title.stringValue) }
            if let created { values["created_at"] = .real(created) }
            if let key = fields["orderKey"]?.stringValue { values["order_key"] = .text(key) }
            if !values.isEmpty {
                let names = values.keys.sorted()
                try connection.execute(
                    "UPDATE course_lectures SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                    names.compactMap { values[$0] } + [.text(id)]
                )
            }
        } else {
            // A number after the course's last for now; `deriveNumbers` gives it its place.
            try connection.execute("""
                INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at, order_key)
                VALUES (?, ?, (SELECT COALESCE(MAX(lecture_number), 0) + 1 FROM course_lectures WHERE course_id = ?), ?, ?, ?)
            """, [
                .text(id), .text(courseID), .text(courseID), .text(fields["title"]?.stringValue),
                .real(created ?? Date().timeIntervalSinceReferenceDate), .text(fields["orderKey"]?.stringValue),
            ])
        }
        try LessonOrderKeys.deriveNumbers(courseID: courseID, connection: connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        let courseID = try connection.scalarText("SELECT course_id FROM course_lectures WHERE id = ?", [.text(record.localID)])
        try connection.execute("DELETE FROM course_lectures WHERE id = ?", [.text(record.localID)])
        if let courseID { try LessonOrderKeys.deriveNumbers(courseID: courseID, connection: connection) }
    }
}

// MARK: - Order under generation 2

/// A course's lesson order and a lesson's item order as generation 1 reads them (`lecture_number`,
/// `sort_index`) and as the records carry them (`order_key`, §3.5.10, §3.5.8). Under generation 2 the
/// keys are what syncs: a local write keys only the rows it moved out of order (`OrderKeyPlanner`), and
/// an inbound order rewrites the numbers and indexes so every generation-1 reader shows it. Neither
/// runs under generation 1.
enum LessonOrderKeys {
    /// Keys a course's lectures in their `lecture_number` order, changing only the keys out of that order.
    static func replanLessons(courseID: String, connection: SQLiteConnection) throws {
        var ordered: [(id: String, key: String?)] = []
        try connection.query(
            "SELECT id, order_key FROM course_lectures WHERE course_id = ? ORDER BY lecture_number, id", [.text(courseID)]
        ) { row in
            if let id = row.text(0) { ordered.append((id, row.text(1))) }
        }
        for (id, key) in OrderKeyPlanner.plan(ordered).sorted(by: { $0.key < $1.key }) {
            try connection.execute("UPDATE course_lectures SET order_key = ? WHERE id = ?", [.text(key), .text(id)])
        }
    }

    /// `lecture_number` as each lecture's place in key order, from 1. A lecture with no key yet keeps
    /// its place after the keyed ones. In two steps, every row first to a number of its own below zero
    /// (from its rowid), so the course's `UNIQUE(course_id, lecture_number)` never meets two rows on one
    /// number halfway.
    static func deriveNumbers(courseID: String, connection: SQLiteConnection) throws {
        var ordered: [(id: String, number: Int64?)] = []
        try connection.query("""
            SELECT id, lecture_number FROM course_lectures WHERE course_id = ?
            ORDER BY order_key IS NULL, order_key, lecture_number, id
        """, [.text(courseID)]) { row in
            if let id = row.text(0) { ordered.append((id, row.integer(1))) }
        }
        guard ordered.enumerated().contains(where: { $0.element.number != Int64($0.offset + 1) }) else { return }
        try connection.execute("UPDATE course_lectures SET lecture_number = -1 - rowid WHERE course_id = ?", [.text(courseID)])
        for (offset, lecture) in ordered.enumerated() {
            try connection.execute("UPDATE course_lectures SET lecture_number = ? WHERE id = ?", [.integer(Int64(offset + 1)), .text(lecture.id)])
        }
    }

    /// Keys a lecture's items in their `sort_index` order, changing only the keys out of that order.
    static func replanItems(lectureID: String, connection: SQLiteConnection) throws {
        var ordered: [(id: String, key: String?)] = []
        try connection.query(
            "SELECT id, order_key FROM course_lecture_items WHERE lecture_id = ? ORDER BY sort_index, created_at, id", [.text(lectureID)]
        ) { row in
            if let id = row.text(0) { ordered.append((id, row.text(1))) }
        }
        for (id, key) in OrderKeyPlanner.plan(ordered).sorted(by: { $0.key < $1.key }) {
            try connection.execute("UPDATE course_lecture_items SET order_key = ? WHERE id = ?", [.text(key), .text(id)])
        }
    }

    /// `sort_index` as each item's place in key order, from 0.
    static func deriveSortIndexes(lectureID: String, connection: SQLiteConnection) throws {
        try connection.execute("""
            UPDATE course_lecture_items SET sort_index = (
                SELECT COUNT(*) FROM course_lecture_items AS other
                WHERE other.lecture_id = course_lecture_items.lecture_id AND other.order_key IS NOT NULL
                  AND (other.order_key < course_lecture_items.order_key
                       OR (other.order_key = course_lecture_items.order_key AND other.id < course_lecture_items.id))
            )
            WHERE lecture_id = ? AND order_key IS NOT NULL
        """, [.text(lectureID)])
    }

    /// Gives every item of the lecture with no slot yet the lowest slot its source has free in the
    /// lecture (`#n`, §3.5.8: the first span of a source has none, a second is `#2`), oldest first. A
    /// slot once given never moves, so adding or removing another span of the source renames nothing.
    static func assignSlots(lectureID: String, connection: SQLiteConnection) throws {
        var rows: [(id: String, source: String, slot: Int64?)] = []
        try connection.query("""
            SELECT id, source_id, span_slot FROM course_lecture_items
            WHERE lecture_id = ? AND source_id IS NOT NULL
            ORDER BY span_slot IS NULL, created_at, id
        """, [.text(lectureID)]) { row in
            if let id = row.text(0), let source = row.text(1) { rows.append((id, source, row.integer(2))) }
        }
        var taken: [String: Set<Int64>] = [:]
        for row in rows {
            if let slot = row.slot {
                taken[row.source, default: []].insert(slot)
                continue
            }
            var slot: Int64 = 1
            while taken[row.source, default: []].contains(slot) { slot += 1 }
            taken[row.source, default: []].insert(slot)
            try connection.execute("UPDATE course_lecture_items SET span_slot = ? WHERE id = ?", [.integer(slot), .text(row.id)])
        }
    }

    /// Each item's span from the page unit it names (a textbook reading's pages), so `span_json` is
    /// what syncs. An item with no unit keeps the span it holds: a span another client sent that is
    /// no page range has no unit here.
    static func fillSpans(lectureID: String, connection: SQLiteConnection) throws {
        var rows: [(id: String, locator: String, held: String?)] = []
        try connection.query("""
            SELECT i.id, u.locator, i.span_json FROM course_lecture_items i JOIN source_units u ON u.id = i.source_unit_id
            WHERE i.lecture_id = ? AND u.kind = ?
        """, [.text(lectureID), .text(LessonItemSpan.pageUnitKind)]) { row in
            if let id = row.text(0), let locator = row.text(1) { rows.append((id, locator, row.text(2))) }
        }
        for row in rows {
            guard let span = LessonItemSpan.json(pageLocator: row.locator), span != row.held else { continue }
            try connection.execute("UPDATE course_lecture_items SET span_json = ? WHERE id = ?", [.text(span), .text(row.id)])
        }
    }
}

/// A lesson item's span (§3.3 `Span`) and the textbook page unit it stands for on this Mac
/// (`source_units`, kind `pages`, locator `"3-9"`, one-based and inclusive, `TextbookReading`). On the
/// wire the pages are PDF locators, whose `page` counts from 0 like every PDF locator (§3.3).
enum LessonItemSpan {
    static let pageUnitKind = "pages"

    /// The stored span of a page locator, or nil when the locator names no pages.
    static func json(pageLocator: String) -> String? {
        let parts = pageLocator.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int(parts[0]), let last = Int(parts[1]), first >= 1, last >= first else { return nil }
        let span = LocatorSpan(from: Locator(.pdf, ["page": SyncJSON(first - 1)]), to: Locator(.pdf, ["page": SyncJSON(last - 1)]))
        return String(decoding: span.value.serialized(), as: UTF8.self)
    }

    /// The pages a span names (one-based, inclusive), when it is a range of PDF pages.
    static func pages(_ span: SyncJSON) -> ClosedRange<Int>? {
        guard let span = LocatorSpan(json: span), span.from.kind == .pdf, span.to.kind == .pdf,
              let first = span.from["page"]?.int64Value, let last = span.to["page"]?.int64Value, first >= 0, last >= first
        else { return nil }
        return Int(first) + 1...Int(last) + 1
    }

    /// The unit row naming those pages of a source, by the id `TextbookReading.unitID` gives them.
    static func pageUnit(sourceID: String, pages: ClosedRange<Int>) -> (id: String, locator: String) {
        let locator = "\(pages.lowerBound)-\(pages.upperBound)"
        return (TextbookReading.unitID(sourceID: sourceID, pages: pages), locator)
    }
}

// MARK: - A lesson's items: Entries with a lesson container (§3.5.8)

/// One `course_lecture_items` row as its Entry reads it.
struct LessonItemRows: Equatable, Sendable {
    let lectureID: String
    let sourceID: String
    let slot: Int
    let role: String
    let label: String?
    let orderKey: String?
    let spanJSON: String?
    let createdAt: Double
}

/// A lesson's items as Entries (§3.5.8): `en:<lecture>:source:<source>`, and `#n` for a second span of
/// one source in one lesson (two page ranges of one chapter). The slot is stored (`span_slot`), so an
/// Entry keeps its name whatever spans come and go beside it. An item that names only a unit and no
/// source (no writer makes one, and no library holds one) is not projected. `EntryProjection` reads
/// these for the lesson container; a lesson's quizzes are placed by `Quiz.lessonID`, not by an Entry.
struct LessonEntryProjection {
    static let columns = ["role", "label", "order_key", "span_json", "created_at"]

    /// The Entry id's slot: the `#n` after the source id, 1 when there is none.
    static func slot(ofItemID itemID: String) -> (sourceID: String, slot: Int) {
        if let hash = itemID.lastIndex(of: "#"), let slot = Int(itemID[itemID.index(after: hash)...]), slot > 1 {
            return (String(itemID[..<hash]), slot)
        }
        return (itemID, 1)
    }

    var tables: [ProjectedTable] {
        let idSQL: @Sendable (String) -> String = {
            "'en:' || \($0).lecture_id || ':source:' || \($0).source_id || CASE WHEN \($0).span_slot > 1 THEN '#' || \($0).span_slot ELSE '' END"
        }
        return [ProjectedTable(
            "course_lecture_items", localKey: ["id"], keyColumns: ["lecture_id", "source_id", "span_slot"], syncedColumns: Self.columns,
            parents: [
                LocalParent("lecture_id", references: "course_lectures", type: .lesson, role: .container),
                LocalParent("source_id", references: "sources", type: .source, role: .item),
            ],
            recordTypes: [.entry],
            record: { values in
                guard let lecture = values["lecture_id"]?.textValue, let source = values["source_id"]?.textValue else { return nil }
                let slot = values["span_slot"].flatMap { if case .integer(let slot) = $0 { return Int(slot) } else { return nil } } ?? 1
                let id = SyncIdentity.entryID(containerID: lecture, itemKind: "source", itemID: source, span: slot)
                return RowRecord(type: .entry, localID: id, personalID: id)
            },
            localIDSQL: idSQL, personalIDSQL: idSQL
        )]
    }

    /// The item's rows by its local ids; `wire` names it on the record (a space course's item names its
    /// source's wire id, §4.3).
    func loadRows(_ id: EntryID, wire: EntryID? = nil, connection: SQLiteConnection) throws -> LessonItemRows? {
        let (source, slot) = Self.slot(ofItemID: id.itemID)
        let wireSource = Self.slot(ofItemID: (wire ?? id).itemID).sourceID
        var rows: LessonItemRows?
        try connection.query("""
            SELECT role, label, order_key, span_json, created_at FROM course_lecture_items
            WHERE lecture_id = ? AND source_id = ? AND COALESCE(span_slot, 1) = ?
            ORDER BY id LIMIT 1
        """, [.text(id.containerID), .text(source), .integer(Int64(slot))]) { row in
            rows = LessonItemRows(
                lectureID: (wire ?? id).containerID, sourceID: wireSource, slot: slot, role: row.text(0) ?? "other", label: row.text(1),
                orderKey: row.text(2), spanJSON: row.text(3), createdAt: row.real(4) ?? 0
            )
        }
        return rows
    }

    /// The item's fields. `role` is the local role as it is (today's `article`, `podcast`, `code` and
    /// `other` are outside the schema's list and survive as unknown values, D31); `required` has no
    /// column and stays as the record holds it.
    static func encodeRows(_ rows: LessonItemRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "containerKind": .string("lesson"), "containerID": .string(rows.lectureID), "itemKind": .string("source"),
            "itemID": .string(rows.sourceID), "state": .string("active"), "origin": .string("course"),
            "addedAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.createdAt)),
            "role": .string(rows.role),
            "label": rows.label.flatMap { $0.isEmpty ? nil : SyncJSON.string($0) } ?? .null,
            "span": rows.spanJSON.flatMap { try? SyncJSON(parsing: Data($0.utf8)) } ?? .null,
        ]
        if let key = rows.orderKey { fields["orderKey"] = .string(key) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace, let id = EntryID(record.wireID) else { return .projected }
        let fields = envelope.fields
        // A Doc or a quiz on a lesson's path has no local row (§8d): it stays in the replica.
        guard (fields["itemKind"]?.stringValue ?? id.itemKind) == "source" else { return .projected }
        let lecture = fields["containerID"]?.stringValue ?? id.containerID
        let parsed = Self.slot(ofItemID: id.itemID)
        let source = fields["itemID"]?.stringValue ?? parsed.sourceID
        let slot = Int64(parsed.slot)

        if fields["state"]?.stringValue == "removed" {
            try connection.execute(
                "DELETE FROM course_lecture_items WHERE lecture_id = ? AND source_id = ? AND COALESCE(span_slot, 1) = ?",
                [.text(lecture), .text(source), .integer(slot)]
            )
            try LessonOrderKeys.deriveSortIndexes(lectureID: lecture, connection: connection)
            return .projected
        }
        // Both must be here: the item's row has a foreign key to each (§5.7).
        var waiting: [WaitingParent] = []
        if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM course_lectures WHERE id = ?)", [.text(lecture)]) != 1 {
            waiting.append(WaitingParent(type: .lesson, wireID: lecture))
        }
        if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(source)]) != 1 {
            waiting.append(WaitingParent(type: .source, wireID: source))
        }
        guard waiting.isEmpty else { return .waiting(waiting) }

        let span = fields["span"].flatMap { $0.isNull ? nil : $0 }
        var unitID: String?
        if let span, let pages = LessonItemSpan.pages(span) {
            let unit = LessonItemSpan.pageUnit(sourceID: source, pages: pages)
            // The pages may already be a unit under another id (`UNIQUE(source_id, kind, locator)`, a unit
            // this Mac made or one a source's re-import left): that one is used, never a second.
            try connection.execute("""
                INSERT INTO source_units (id, source_id, kind, locator, title) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT DO NOTHING
            """, [.text(unit.id), .text(source), .text(LessonItemSpan.pageUnitKind), .text(unit.locator), .text(fields["label"]?.stringValue)])
            unitID = try connection.scalarText(
                "SELECT id FROM source_units WHERE source_id = ? AND kind = ? AND locator = ?",
                [.text(source), .text(LessonItemSpan.pageUnitKind), .text(unit.locator)]
            ) ?? unit.id
        }
        let spanJSON = span.map { String(decoding: $0.serialized(), as: UTF8.self) }
        let created = fields["addedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        // The row of this slot, else the row already naming these pages (its slot numbered otherwise
        // here), which `UNIQUE(lecture_id, source_id, source_unit_id)` allows only once.
        var held = try connection.scalarText(
            "SELECT id FROM course_lecture_items WHERE lecture_id = ? AND source_id = ? AND COALESCE(span_slot, 1) = ? ORDER BY id LIMIT 1",
            [.text(lecture), .text(source), .integer(slot)]
        )
        if held == nil, let unitID {
            held = try connection.scalarText(
                "SELECT id FROM course_lecture_items WHERE lecture_id = ? AND source_id = ? AND source_unit_id = ?",
                [.text(lecture), .text(source), .text(unitID)]
            )
        }
        if let held {
            var values: [String: SQLiteValue] = ["span_slot": .integer(slot)]
            if fields["span"] != nil {
                values["span_json"] = .text(spanJSON)
                let unitTaken = try unitID.map { unit in
                    try connection.scalarInteger(
                        "SELECT EXISTS(SELECT 1 FROM course_lecture_items WHERE lecture_id = ? AND source_id = ? AND source_unit_id = ? AND id <> ?)",
                        [.text(lecture), .text(source), .text(unit), .text(held)]
                    ) == 1
                } ?? false
                if !unitTaken { values["source_unit_id"] = .text(unitID) }
            }
            if let role = fields["role"]?.stringValue { values["role"] = .text(role) }
            if let label = fields["label"] { values["label"] = .text(label.stringValue) }
            if let key = fields["orderKey"]?.stringValue { values["order_key"] = .text(key) }
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE course_lecture_items SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(held)]
            )
            if let created {
                try connection.execute("UPDATE course_lecture_items SET created_at = MIN(created_at, ?) WHERE id = ?", [.real(created), .text(held)])
            }
        } else {
            // Named by its Entry, so every Mac that projects the Entry holds one row under one id. The
            // index is a stand-in until `deriveSortIndexes` places it; a role the record does not name
            // is the app's own default, a plain material (`CourseLectureItemRole.other`).
            try connection.execute("""
                INSERT INTO course_lecture_items
                    (id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at, order_key, span_json, span_slot)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
            """, [
                .text("cli-v2-" + String(SyncIdentity.sha256Hex(Data(record.wireID.utf8)).prefix(32))), .text(lecture), .text(source),
                .text(unitID), .text(fields["role"]?.stringValue ?? "other"), .text(fields["label"]?.stringValue),
                .real(created ?? Date().timeIntervalSinceReferenceDate), .text(fields["orderKey"]?.stringValue), .text(spanJSON), .integer(slot),
            ])
        }
        try LessonOrderKeys.deriveSortIndexes(lectureID: lecture, connection: connection)
        return .projected
    }

    func applyDeletion(_ id: EntryID, connection: SQLiteConnection) throws {
        let (source, slot) = Self.slot(ofItemID: id.itemID)
        try connection.execute(
            "DELETE FROM course_lecture_items WHERE lecture_id = ? AND source_id = ? AND COALESCE(span_slot, 1) = ?",
            [.text(id.containerID), .text(source), .integer(Int64(slot))]
        )
    }
}
