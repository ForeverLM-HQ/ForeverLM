import Foundation

// MARK: - What this Mac's rows hold of an old record (docs/cloudkit-schema-design.md §13.3, R5-4, R6-1, R6-2)

/// The deferred catch-up has no snapshot to diff against, so for what an old record dropped, or everything
/// it owned when it was deleted, this Mac's store stands in for the base: the v2 records the old record owns
/// in the store, found by back-pointer. They are the old record's previous children, apart from local
/// changes, which the pass keeps.
///
/// - the record that carries the old record's id (a Source, a Notebook or Goal, a Course, a Chat, a
///   Collection, a Doc, a Comment, a Task, a Card, an Automation);
/// - an old notebook's Entries by `containerID` (its pool and the courses it follows), a chat's Exchanges
///   by `chatID`, a course's Lessons, Quizzes and lesson Entries by `courseID`;
/// - a Source's playlist Entry by `itemID` with `containerKind = playlist`, never by the playlist's
///   back-pointer: an old Mac's playlist refresh then removes none, and a video that left a playlist loses
///   only its own Entry (§10, R6-2).
///
/// Every candidate is listed as owned with no hashes, so a changed old record applies every field it gives
/// and a candidate its new mapping no longer gives is removed by type. A Team's records, which this Mac
/// holds as space copies under other ids, give no candidate here: the importer removes them against the
/// shared base. Per-member state and history are never candidates (§10, R5-1).
enum MigrationLocalChildren {
    static func candidates(
        entity: CloudKitSyncEntity, logicalKey: String, connection: SQLiteConnection, registry: ProjectionRegistry = KnowledgeStore.projectionRegistry
    ) throws -> [String: MigrationBaseRecord] {
        var found: [String: MigrationBaseRecord] = [:]
        func add(_ type: SyncRecordType, _ id: String) {
            found[MigrationRecordKey(type, id).baseKey] = MigrationBaseRecord(owned: true, hashes: [:])
        }
        func addIfHeld(_ type: SyncRecordType, _ id: String) throws {
            if try holds(type, id, registry: registry, connection: connection) { add(type, id) }
        }
        func each(_ sql: String, _ value: String, _ body: (SQLiteRow) -> Void) throws {
            try connection.query(sql, [.text(value)], body)
        }

        switch entity {
        case .source:
            try addIfHeld(.source, logicalKey)
            try each("SELECT group_id FROM group_members WHERE source_id = ? AND group_id LIKE 'playlist!_%' ESCAPE '!'", logicalKey) { row in
                if let group = row.text(0) { add(.entry, PlaylistEntryProjection.entryID(playlistID: group, sourceID: logicalKey)) }
            }
        case .book, .videoPlaylist, .meetingGroup:
            try addIfHeld(.collection, logicalKey)
        case .learningGoal:
            // The kind this Mac classified the row as, else the one its shape gives (as the mapping reads it).
            var kind: String?
            try each("SELECT entity_kind, kind, parent_notebook_id, end_at FROM learning_goals WHERE id = ?", logicalKey) { row in
                kind = row.text(0) ?? LearningGoalEntityKind.kind(kind: row.text(1), parentNotebookID: row.text(2), endAt: row.real(3) ?? 0)
            }
            guard let kind else { return found }
            add(kind == LearningGoalEntityKind.notebook ? .notebook : .goal, logicalKey)
            try each("SELECT source_id FROM learning_goal_items WHERE goal_id = ?", logicalKey) { row in
                if let source = row.text(0) { add(.entry, SyncIdentity.entryID(containerID: logicalKey, itemKind: "source", itemID: source)) }
            }
            try each("SELECT course_id FROM notebook_course_links WHERE goal_id = ?", logicalKey) { row in
                if let course = row.text(0) { add(.entry, SyncIdentity.entryID(containerID: logicalKey, itemKind: "course", itemID: course)) }
            }
        case .course:
            try addIfHeld(.course, logicalKey)
            var lessons: [String] = []
            try each("SELECT id FROM course_lectures WHERE course_id = ?", logicalKey) { if let id = $0.text(0) { lessons.append(id) } }
            for lesson in lessons {
                add(.lesson, lesson)
                try each("SELECT source_id, COALESCE(span_slot, 1) FROM course_lecture_items WHERE lecture_id = ?", lesson) { row in
                    guard let source = row.text(0) else { return }
                    add(.entry, SyncIdentity.entryID(containerID: lesson, itemKind: "source", itemID: source, span: Int(row.integer(1) ?? 1)))
                }
            }
            try each("SELECT id FROM course_quizzes WHERE course_id = ?", logicalKey) { if let id = $0.text(0) { add(.quiz, id) } }
        case .reviewSession:
            try addIfHeld(.chat, logicalKey)
            try each("SELECT id FROM review_exchanges WHERE session_id = ?", logicalKey) { if let id = $0.text(0) { add(.exchange, id) } }
        case .artifact:
            try addIfHeld(.artifact, logicalKey)
        case .artifactComment:
            try addIfHeld(.comment, logicalKey)
        case .notebookTask:
            try addIfHeld(.task, logicalKey)
        case .scheduledTask:
            try addIfHeld(.automation, logicalKey)
        case .memoryItem:
            try addIfHeld(.card, logicalKey)
        default:
            break
        }
        return found
    }

    /// Whether this Mac's rows hold the record (the projection reads it back).
    private static func holds(_ type: SyncRecordType, _ id: String, registry: ProjectionRegistry, connection: SQLiteConnection) throws -> Bool {
        guard let projection = registry.projection(for: type) else { return false }
        let reference = ProjectionRecordRef(zoneKey: PrivateSyncZones.libraryKey, zone: .library, type: type, wireID: id, localID: id)
        return try projection.encode(reference, connection: connection) != nil
    }
}
