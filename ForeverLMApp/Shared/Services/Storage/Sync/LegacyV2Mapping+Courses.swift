import Foundation

// MARK: - Courses (docs/cloudkit-schema-design.md §10, the `Course` row; §5.5)

extension LegacyV2Mapping {
    /// An old Course: its Course, its lectures as Lessons and their items as lesson Entries, and its
    /// quizzes. Each takes what the activation derives (`CourseUpkeep.keep`) over the rows this Mac
    /// holds: order keys keep the ones in order, a span takes its first free slot, a page reading's
    /// span comes from its unit. A course lives in no notebook: `homeNotebookID` gives nothing, and the
    /// follow is the LearningGoal's (revision 9). An omitted key says nothing (R6-m4): no `quizzes` (an
    /// older client) is silent on Quizzes, and an empty `lectures` list, which generation 1 never applies,
    /// is silent on Lessons and their Entries.
    static func mapCourse(_ payload: CloudKitCoursePayload, record: LegacyRecord, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        let courseID = try context.wireID(.course, oldID: payload.id, teamID: record.teamID)
        let lectures = payload.lectures.filter { !$0.id.isEmpty }
        let quizzes = payload.quizzes?.filter { $0.courseID == payload.id }
        let earliest = (lectures.map(\.createdAt) + (quizzes ?? []).map(\.createdAt)).min()
        let createdAt = try context.heldCourseCreatedAt(payload.id)
            ?? (earliest ?? record.modifiedAt).timeIntervalSinceReferenceDate
        let course = CourseRows(
            id: payload.id, title: payload.title ?? payload.id, institution: payload.institution, playlistURL: payload.playlistURL,
            isHidden: payload.isHidden, createdAt: createdAt
        )
        mapping.records.append(LegacyV2Record(type: .course, id: courseID, fields: CourseProjection.encodeRows(course), giving: .owns))

        if lectures.isEmpty {
            mapping.silentChildren.insert(LegacyChildScope(type: .lesson))
            mapping.silentChildren.insert(LegacyChildScope(type: .entry, itemKind: "source"))
        } else {
            mapping.records += try lessons(lectures, courseID: courseID, payload: payload, context: context)
        }

        if let quizzes {
            for quiz in quizzes {
                mapping.records.append(try courseQuiz(quiz, context: context))
            }
        } else {
            mapping.silentChildren.insert(LegacyChildScope(type: .quiz))
        }
    }

    /// The Lessons and lesson Entries of a course's outline, as `saveCourseOutline` writes it and
    /// `CourseUpkeep.keep` keys it.
    static func lessons(_ lectures: [CourseSession], courseID: String, payload: CloudKitCoursePayload, context: LegacyMappingContext) throws -> [LegacyV2Record] {
        var records: [LegacyV2Record] = []
        let heldLessons = try context.heldLessonOrderKeys(courseID: payload.id)
        let ordered = lectures.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        let lessonKeys = OrderKeyPlanner.plan(ordered.map { (id: $0.id, key: heldLessons[$0.id]) })
        for lecture in ordered {
            let rows = LessonRows(
                id: lecture.id, courseID: courseID, title: lecture.title, createdAt: lecture.createdAt.timeIntervalSinceReferenceDate,
                orderKey: lessonKeys[lecture.id] ?? heldLessons[lecture.id]
            )
            var lesson = LegacyV2Record(type: .lesson, id: lecture.id, fields: LessonProjection.encodeRows(rows), giving: .owns)
            lesson.createOnlyFields = ["orderKey"]  // planned against this Mac's held keys: a creation's alone (F4)
            records.append(lesson)
        }

        let lectureIDs = Set(ordered.map(\.id))
        let units = Dictionary((payload.sourceUnits ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let items = Dictionary(grouping: payload.lectureItems.filter { lectureIDs.contains($0.lectureId) }, by: \.lectureId)
        for lectureID in items.keys.sorted() {
            let lectureItems = items[lectureID] ?? []
            let held = try context.heldLessonItems(lectureID: lectureID)

            // Slots: held ones stay; the rest take the lowest free slot of their source, oldest first.
            var slots: [String: Int] = [:]
            var taken: [String: Set<Int>] = [:]
            let withSource = lectureItems.filter { $0.sourceId != nil }
                .sorted { (held[$0.id]?.slot == nil ? 1 : 0, $0.createdAt, $0.id) < (held[$1.id]?.slot == nil ? 1 : 0, $1.createdAt, $1.id) }
            for item in withSource {
                guard let source = item.sourceId else { continue }
                if let slot = held[item.id]?.slot {
                    taken[source, default: []].insert(slot)
                    slots[item.id] = slot
                    continue
                }
                var slot = 1
                while taken[source, default: []].contains(slot) { slot += 1 }
                taken[source, default: []].insert(slot)
                slots[item.id] = slot
            }
            let byOrder = lectureItems.sorted { ($0.sortIndex, $0.createdAt, $0.id) < ($1.sortIndex, $1.createdAt, $1.id) }
            let itemKeys = OrderKeyPlanner.plan(byOrder.map { (id: $0.id, key: held[$0.id]?.orderKey) })
            for item in byOrder {
                // An item that names only a unit and no source is not projected.
                guard let source = item.sourceId, let slot = slots[item.id] else { continue }
                var span = held[item.id]?.spanJSON
                if let unitID = item.sourceUnitId {
                    let unit = try units[unitID].map { (kind: $0.kind, locator: $0.locator) } ?? context.sourceUnit(unitID)
                    if let unit, unit.kind == LessonItemSpan.pageUnitKind, let pages = LessonItemSpan.json(pageLocator: unit.locator) {
                        span = pages
                    }
                }
                let rows = LessonItemRows(
                    lectureID: lectureID, sourceID: source, slot: slot, role: item.role.rawValue, label: item.label,
                    orderKey: itemKeys[item.id] ?? held[item.id]?.orderKey, spanJSON: span, createdAt: item.createdAt.timeIntervalSinceReferenceDate
                )
                var entry = LegacyV2Record(
                    type: .entry, id: SyncIdentity.entryID(containerID: lectureID, itemKind: "source", itemID: source, span: slot),
                    fields: LessonEntryProjection.encodeRows(rows), giving: .owns
                )
                entry.createOnlyFields = ["orderKey"]  // F4
                records.append(entry)
            }
        }
        return records
    }

    /// A course's quiz, as `replaceCourseQuizzesFromSync` writes its row: its questions and drawing are
    /// laid out as the projection lays them out, and its revision is the one this Mac holds, one more
    /// when the old record changed the questions (`saveCourseQuiz` under generation 2).
    static func courseQuiz(_ quiz: CourseQuiz, context: LegacyMappingContext) throws -> LegacyV2Record {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let questions = String(decoding: try encoder.encode(quiz.questions), as: UTF8.self)
        let held = try context.heldQuiz(quiz.id)
        let revision = held.map { $0.questionsJSON == questions ? $0.revision : $0.revision + 1 } ?? 1
        let rows = QuizRows(
            id: quiz.id, courseID: quiz.courseID, kind: quiz.kind.rawValue, title: quiz.title, lectureIDs: quiz.lectureIDs,
            afterLectureID: quiz.afterLectureID, questionsJSON: questions, author: quiz.author.rawValue,
            createdAt: quiz.createdAt.timeIntervalSinceReferenceDate, symbol: quiz.symbol, artwork: quiz.artwork, revision: revision,
            waiting: []
        )
        var record = LegacyV2Record(type: .quiz, id: quiz.id, fields: QuizProjection.encodeRows(rows), giving: .owns)
        // The revision moves with the questions alone: hashed by them, a later old write of the Course whose
        // questions are unchanged does not raise the revision of a quiz the new world edited (F34).
        record.hashOverrides["revision"] = LegacyFieldHashes.hash(.string(questions))
        return record
    }
}
