import Foundation
import SQLite3

/// Storage for a textbook's readings in a course (docs/textbook-readings-design.md).
///
/// A reading is an ordinary lecture item with role `reading` pointing at the
/// chapter; pages within the chapter are a `source_units` row the item names.
/// Both travel with the Course record: the items as they always have, and the
/// units they name in the payload's `sourceUnits`, so a receiving Mac never
/// waits on a chapter's own record to show a reading.
extension KnowledgeStore {

    // MARK: - Writing

    /// Replaces the readings a book has in a course with `placements`, in one
    /// transaction: the book's earlier readings in this course go, the new
    /// ones are written after each lecture's existing items, the chapters join
    /// every Notebook that follows the course, and page units no reading names
    /// any more are removed. Returns the items written, in placement order.
    ///
    /// "The book's readings" are the course's `reading` items whose source is
    /// one of `bookChapterIDs`: planning a book again replaces its readings
    /// and leaves everything else — the videos, the quizzes, another book's
    /// readings, a chapter attached as notes — untouched.
    @discardableResult
    func replaceTextbookReadings(
        courseID: String,
        bookChapterIDs: Set<String>,
        placements: [TextbookReadingPlacement],
        at now: Date = Date()
    ) throws -> [CourseLectureItem] {
        let chapterIDs = bookChapterIDs.sorted()
        guard !chapterIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("The book has no chapters to read.")
        }
        let lectureIDs = try courseLectureIDs(courseID)
        guard !lectureIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("The course has no lectures: \(courseID)")
        }
        let lectureSet = Set(lectureIDs)
        for placement in placements {
            guard lectureSet.contains(placement.lectureID) else {
                throw KnowledgeStoreError.invalidData("Lecture \(placement.lectureID) is not in course \(courseID).")
            }
            guard bookChapterIDs.contains(placement.chapterSourceID) else {
                throw KnowledgeStoreError.invalidData("Source \(placement.chapterSourceID) is not a chapter of the book.")
            }
        }

        try exec("BEGIN IMMEDIATE")
        var written: [CourseLectureItem] = []
        do {
            let lecturePlaceholders = Self.placeholders(lectureIDs.count)
            let chapterPlaceholders = Self.placeholders(chapterIDs.count)
            try execBind("""
                DELETE FROM course_lecture_items
                WHERE role = ?
                  AND lecture_id IN (\(lecturePlaceholders))
                  AND source_id IN (\(chapterPlaceholders))
            """) { stmt in
                var index = 1
                bind(stmt, index, CourseLectureItemRole.reading.rawValue)
                for id in lectureIDs { index += 1; bind(stmt, index, id) }
                for id in chapterIDs { index += 1; bind(stmt, index, id) }
            }

            // Readings follow what each lecture already holds: its video,
            // its notes, a reading from another book.
            var nextSortIndex: [String: Int] = [:]
            try queryBind("""
                SELECT lecture_id, MAX(sort_index)
                FROM course_lecture_items
                WHERE lecture_id IN (\(lecturePlaceholders))
                GROUP BY lecture_id
            """, bind: { stmt in
                for (offset, id) in lectureIDs.enumerated() { self.bind(stmt, offset + 1, id) }
            }) { stmt in
                guard let lectureID = self.string(stmt, 0) else { return }
                nextSortIndex[lectureID] = Int(sqlite3_column_int(stmt, 1)) + 1
            }

            for placement in placements {
                let unitID = try placement.pages.map { pages in
                    try upsertTextbookReadingUnit(
                        sourceID: placement.chapterSourceID,
                        pages: pages,
                        title: placement.title
                    )
                }
                let sortIndex = nextSortIndex[placement.lectureID] ?? 0
                nextSortIndex[placement.lectureID] = sortIndex + 1
                var item = TextbookReading.item(for: placement, sortIndex: sortIndex, createdAt: now)
                item.sourceUnitId = unitID
                try execBind("""
                    INSERT INTO course_lecture_items
                        (id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        lecture_id = excluded.lecture_id,
                        source_id = excluded.source_id,
                        source_unit_id = excluded.source_unit_id,
                        role = excluded.role,
                        label = excluded.label,
                        sort_index = excluded.sort_index,
                        created_at = excluded.created_at
                """) { stmt in
                    bind(stmt, 1, item.id)
                    bind(stmt, 2, item.lectureId)
                    bind(stmt, 3, item.sourceId)
                    bind(stmt, 4, item.sourceUnitId)
                    bind(stmt, 5, item.role.rawValue)
                    bind(stmt, 6, item.label)
                    bind(stmt, 7, item.sortIndex)
                    sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSinceReferenceDate)
                }
                written.append(item)
            }

            _ = try addSourcesToNotebooksLinkedToCourseInCurrentTransaction(
                courseID: courseID,
                sourceIDs: Array(Set(placements.map(\.chapterSourceID))),
                addedAt: now
            )
            try deleteUnreferencedPageUnits(sourceIDs: chapterIDs)
            try keepCourseRowsForGeneration2(courseIDs: [courseID])
            try markRecordChanged(entity: .course, logicalKey: courseID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return written
    }

    /// The unit naming `pages` of a source: the row that already names them,
    /// whatever its id, or a new one under the deterministic id. The caller
    /// holds the transaction.
    private func upsertTextbookReadingUnit(sourceID: String, pages: ClosedRange<Int>, title: String) throws -> String {
        let locator = TextbookReading.locator(pages)
        var existingID: String?
        try queryBind("""
            SELECT id FROM source_units
            WHERE source_id = ? AND kind = ? AND locator = ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
            self.bind(stmt, 2, TextbookReading.unitKind)
            self.bind(stmt, 3, locator)
        }) { stmt in
            existingID = self.string(stmt, 0)
        }
        if let existingID {
            try execBind("UPDATE source_units SET title = ? WHERE id = ?") { stmt in
                bind(stmt, 1, title)
                bind(stmt, 2, existingID)
            }
            return existingID
        }
        let id = TextbookReading.unitID(sourceID: sourceID, pages: pages)
        try execBind("""
            INSERT INTO source_units (id, source_id, kind, locator, title)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title
        """) { stmt in
            bind(stmt, 1, id)
            bind(stmt, 2, sourceID)
            bind(stmt, 3, TextbookReading.unitKind)
            bind(stmt, 4, locator)
            bind(stmt, 5, title)
        }
        return id
    }

    /// Page units of these sources that no lecture item names. Units are
    /// addresses, not content: one no reading uses is removed rather than kept
    /// to be carried in the chapter's record for nothing. The caller holds the
    /// transaction.
    private func deleteUnreferencedPageUnits(sourceIDs: [String]) throws {
        guard !sourceIDs.isEmpty else { return }
        try execBind("""
            DELETE FROM source_units
            WHERE kind = ?
              AND source_id IN (\(Self.placeholders(sourceIDs.count)))
              AND NOT EXISTS (
                    SELECT 1 FROM course_lecture_items cli
                    WHERE cli.source_unit_id = source_units.id
              )
        """) { stmt in
            bind(stmt, 1, TextbookReading.unitKind)
            for (offset, id) in sourceIDs.enumerated() { bind(stmt, offset + 2, id) }
        }
    }

    // MARK: - Reading

    /// The units course items name, by id: what the sidebar draws a reading
    /// with and what the Course record carries.
    func loadCourseSourceUnits() throws -> [String: SourceUnit] {
        var units: [String: SourceUnit] = [:]
        try query("""
            SELECT su.id, su.source_id, su.kind, su.locator, su.title
            FROM source_units su
            WHERE EXISTS (
                SELECT 1 FROM course_lecture_items cli WHERE cli.source_unit_id = su.id
            )
        """) { stmt in
            guard let unit = self.sourceUnitRow(stmt) else { return }
            units[unit.id] = unit
        }
        return units
    }

    func loadSourceUnits(ids: [String]) throws -> [SourceUnit] {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return [] }
        var units: [SourceUnit] = []
        try queryBind("""
            SELECT id, source_id, kind, locator, title
            FROM source_units
            WHERE id IN (\(Self.placeholders(unique.count)))
            ORDER BY source_id, locator, id
        """, bind: { stmt in
            for (offset, id) in unique.enumerated() { self.bind(stmt, offset + 1, id) }
        }) { stmt in
            if let unit = self.sourceUnitRow(stmt) { units.append(unit) }
        }
        return units
    }

    private func sourceUnitRow(_ stmt: OpaquePointer?) -> SourceUnit? {
        guard let id = string(stmt, 0),
              let sourceID = string(stmt, 1),
              let kind = string(stmt, 2),
              let locator = string(stmt, 3) else { return nil }
        return SourceUnit(id: id, sourceId: sourceID, kind: kind, locator: locator, title: string(stmt, 4))
    }

    /// Book chapters, in reading order, with the order the chapter files
    /// carry. Hidden chapters and archived ones are left out unless
    /// `includingUnavailable`: the planner offers only what the learner can
    /// open, while replacing a book's readings reaches every chapter it has.
    /// Every chapter's book, by chapter source id: the `group_members` rows whose group
    /// is a `books` row. One query for the whole shelf, for callers that map many
    /// chapters at once rather than asking book by book.
    func bookIDsByChapterSourceID() throws -> [String: String] {
        var result: [String: String] = [:]
        try query("""
            SELECT gm.source_id, gm.group_id
            FROM group_members gm
            JOIN books b ON b.id = gm.group_id
        """) { stmt in
            guard let sourceID = self.string(stmt, 0), let bookID = self.string(stmt, 1) else { return }
            result[sourceID] = bookID
        }
        return result
    }

    func bookChapterSourceIDs(
        bookID: String,
        includingUnavailable: Bool = false
    ) throws -> [(sourceID: String, title: String, sortIndex: Int?)] {
        var chapters: [(sourceID: String, title: String, sortIndex: Int?)] = []
        let availability = includingUnavailable ? "" : "AND sp.status = 'active' AND sp.is_hidden = 0"
        try queryBind("""
            SELECT sp.id, sp.title, gm.sort_index
            FROM group_members gm
            JOIN source_projection sp ON sp.id = gm.source_id
            WHERE gm.group_id = ?
              AND sp.source_type = 'book'
              \(availability)
        """, bind: { stmt in
            self.bind(stmt, 1, bookID)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            chapters.append((id, self.string(stmt, 1) ?? id, self.optionalInt(stmt, 2)))
        }
        return chapters.sorted { lhs, rhs in
            switch (lhs.sortIndex, rhs.sortIndex) {
            case let (l?, r?) where l != r: return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    /// The Notebooks a course serves, as the tailoring context reads them: each
    /// active Notebook linked to the course, its standing instructions and
    /// questions, and the open Goals tagged to it.
    func learnerContextNotebooks(courseID: String) throws -> [CourseLearnerContext.Notebook] {
        let notebookIDs = try notebookIDsLinkedToCourse(courseID)
        guard !notebookIDs.isEmpty else { return [] }
        let goals = try loadLearningGoals()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return notebookIDs.compactMap { notebookID in
            guard let notebook = goals.first(where: { $0.id == notebookID }),
                  notebook.isNotebook,
                  notebook.status == "active" else { return nil }
            let tagged = goals
                .filter { $0.parentNotebookID == notebookID && $0.status == "active" && !$0.isOpenEnded }
                .sorted { $0.endAt < $1.endAt }
                .map { "\($0.title) (by \(formatter.string(from: $0.endAt)))" }
            return CourseLearnerContext.Notebook(
                title: notebook.title,
                instructions: notebook.displayDescription,
                researchQuestions: notebook.researchQuestions ?? [],
                goals: tagged
            )
        }
    }

    /// The Notebooks that follow a course (`notebook_course_links`).
    func notebookIDsLinkedToCourse(_ courseID: String) throws -> [String] {
        var notebookIDs: [String] = []
        try queryBind("""
            SELECT goal_id FROM notebook_course_links WHERE course_id = ? ORDER BY goal_id
        """, bind: { stmt in
            self.bind(stmt, 1, courseID)
        }) { stmt in
            if let id = self.string(stmt, 0) { notebookIDs.append(id) }
        }
        return notebookIDs
    }

    // MARK: - Sync

    /// Units a Course record carries, applied before its items so a reading's
    /// unit is always there when the item naming it lands. Upserts only: a
    /// record that does not name a unit says nothing about it, because another
    /// course, or this course's next reading, may still use it.
    func upsertSourceUnitsFromSync(_ units: [SourceUnit]) throws {
        for unit in units {
            try execBind("""
                INSERT INTO source_units (id, source_id, kind, locator, title)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    kind = excluded.kind,
                    locator = excluded.locator,
                    title = excluded.title
            """) { stmt in
                bind(stmt, 1, unit.id)
                bind(stmt, 2, unit.sourceId)
                bind(stmt, 3, unit.kind)
                bind(stmt, 4, unit.locator)
                bind(stmt, 5, unit.title)
            }
        }
    }

    // MARK: - Helpers

    private func courseLectureIDs(_ courseID: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT id FROM course_lectures WHERE course_id = ? ORDER BY lecture_number
        """, bind: { stmt in
            self.bind(stmt, 1, courseID)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
