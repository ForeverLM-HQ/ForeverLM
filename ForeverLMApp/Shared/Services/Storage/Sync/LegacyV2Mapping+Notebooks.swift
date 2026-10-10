import Foundation

// MARK: - Notebooks and Goals (docs/cloudkit-schema-design.md §10, the `LearningGoal` row)

extension LegacyV2Mapping {
    /// The Notebook fields generation 1 has no column for: a merge's, a fold's and a move's marks are
    /// generation 2's own (§5.2, §5.3), so an old record never gives or clears them.
    static let notebookFieldsNotGiven: Set<String> = ["mergedInto", "foldKind", "movingTo", "movedTo"]

    /// An old LearningGoal: its Notebook or Goal (the kind this Mac classified it as, else
    /// `LearningGoalShape`, b1), its source Entries in study order, a notebook's followed courses from
    /// `linkedCourseIDs` (the follow's only source, revision 9; nil is an older client with no opinion,
    /// R6-m4), and a notebook's Notes Doc.
    static func mapLearningGoal(_ payload: CloudKitLearningGoalPayload, record: LegacyRecord, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        let goal = payload.goal
        let id = try context.wireID(.notebook, oldID: goal.id, teamID: record.teamID)
        let kind = try context.heldEntityKind(goal.id) ?? LearningGoalEntityKind.kind(
            kind: goal.kind, parentNotebookID: goal.parentNotebookID, endAt: goal.endAt.timeIntervalSinceReferenceDate
        )
        let isNotebook = kind == LearningGoalEntityKind.notebook

        if isNotebook {
            var notebook = LegacyV2Record(type: .notebook, id: id, fields: try notebookFields(goal, context: context), giving: .owns)
            notebook.wholeFields = Set(["researchQuestions", "openQuestions", "relatedNotebookIDs"].filter { notebook.fields[$0] != nil })
            // A question is hashed without its order key, which is planned against this Mac's held keys (F4).
            for (question, row) in notebook.fields["researchQuestions"]?.objectValue ?? [:] {
                guard var object = row.objectValue else { continue }
                object["orderKey"] = nil
                notebook.hashOverrides["researchQuestions/\(question)"] = LegacyFieldHashes.hash(.object(object))
            }
            mapping.records.append(notebook)
            mapping.records.append(LegacyV2Record(type: .artifact, id: NotesDoc.id(notebookID: id), fields: try notesFields(goal, notebookID: id), giving: .owns))
        } else {
            mapping.records.append(LegacyV2Record(type: .goal, id: id, fields: GoalProjection.encodeRows(goalRows(goal)), giving: .owns))
        }

        // The pool, as `saveLearningGoalRecord` keeps it: an item of a source this Mac holds archived is
        // left out, and order keys follow the study order, keeping the keys this Mac holds in it.
        let held = try context.heldEntryOrderKeys(goalID: goal.id)
        var items: [LearningGoalItem] = []
        var seen = Set<String>()
        for item in goal.items where seen.insert(item.sourceID).inserted {
            if try context.isArchivedSource(item.sourceID) { continue }
            items.append(item)
        }
        items.sort { lhs, rhs in
            switch (lhs.sequence, rhs.sequence) {
            case (nil, .some): return false
            case (.some, nil): return true
            case let (left?, right?) where left != right: return left < right
            default: return (lhs.addedAt, lhs.sourceID) < (rhs.addedAt, rhs.sourceID)
            }
        }
        let keys = OrderKeyPlanner.plan(items.map { (id: $0.sourceID, key: held[$0.sourceID]) })
        for item in items {
            let sourceID = try context.wireID(.source, oldID: item.sourceID, teamID: record.teamID)
            let rows = EntryRows.poolItem(EntryRows.PoolItem(
                containerKind: kind, containerID: id, sourceID: sourceID, addedAt: item.addedAt.timeIntervalSinceReferenceDate,
                origin: item.origin, reviewState: item.reviewState, relevance: item.relevance,
                orderKey: keys[item.sourceID] ?? held[item.sourceID]
            ))
            var entry = LegacyV2Record(
                type: .entry, id: SyncIdentity.entryID(containerID: id, itemKind: "source", itemID: sourceID),
                fields: EntryProjection.encodeRows(rows), giving: .owns
            )
            // The place in the pool is planned against the keys this Mac holds, so it differs between Macs and
            // after a reorder here: only a creation takes it, and an unrelated old write never moves the Entry (F4).
            entry.createOnlyFields = ["orderKey"]
            mapping.records.append(entry)
        }

        mapping.records += try completionStates(goal, record: record, context: context)

        // The follow: a notebook follows only the courses its own payload lists (revision 9); a Course's
        // `homeNotebookID` gives nothing.
        if let courses = payload.linkedCourseIDs {
            guard isNotebook else { return }
            for courseID in Set(courses).sorted() {
                mapping.records.append(LegacyV2Record(
                    type: .entry, id: SyncIdentity.entryID(containerID: id, itemKind: "course", itemID: courseID),
                    fields: EntryProjection.encodeRows(.followedCourse(notebookID: id, courseID: courseID)), giving: .owns
                ))
            }
        } else {
            mapping.silentChildren.insert(LegacyChildScope(type: .entry, itemKind: "course"))
        }
    }

    /// The `learning_goals` columns a notebook's record reads, as `saveLearningGoalRecord` writes them,
    /// and its research questions, open questions and related notebooks. A list the payload leaves out
    /// (nil: an older client) gives nothing.
    static func notebookFields(_ goal: LearningGoalRecord, context: LegacyMappingContext) throws -> [String: SyncJSON] {
        var columns: [String: SQLiteValue] = [
            "title": .text(goal.title), "description": .text(goal.description), "summary": .text(goal.summary), "topic": .text(goal.topic),
            "discovery_enabled": .integer(goal.discoveryEnabled.map { $0 ? 1 : 0 }),
            "last_discovery_at": .real(goal.lastDiscoveryAt?.timeIntervalSinceReferenceDate),
            "repository": .text(goal.repository), "artifact_id": .text(goal.artifactID), "status": .text(goal.status),
            "created_at": .real(goal.createdAt.timeIntervalSinceReferenceDate),
        ]
        for column in ["merged_into", "fold_kind", "moving_to", "moved_to"] { columns[column] = .null }
        let questions = try goal.researchQuestions.map { list in
            researchQuestionRows(
                notebookID: goal.id, questions: list, held: try context.heldResearchQuestions(notebookID: goal.id),
                createdAt: goal.createdAt.timeIntervalSinceReferenceDate
            )
        }
        let rows = NotebookRows(
            columns: columns, researchQuestions: questions ?? [],
            openQuestions: (goal.gaps ?? []).sorted { $0.id < $1.id }.map {
                (id: $0.id, summary: $0.summary, status: $0.status, sourceID: $0.sourceID, firstSeenAt: $0.firstSeenAt.timeIntervalSinceReferenceDate)
            },
            relatedNotebookIDs: (goal.relatedNotebookIDs ?? []).sorted()
        )
        var fields = NotebookProjection.encodeRows(rows)
        for field in notebookFieldsNotGiven { fields.removeValue(forKey: field) }
        // `repository` and `artifact_id` are tri-state in generation 1: nil is no opinion.
        if goal.repository == nil { fields.removeValue(forKey: "repository") }
        if goal.artifactID == nil { fields.removeValue(forKey: "homeArtifactID") }
        if goal.researchQuestions == nil { fields.removeValue(forKey: "researchQuestions") }
        if goal.gaps == nil { fields.removeValue(forKey: "openQuestions") }
        if goal.relatedNotebookIDs == nil { fields.removeValue(forKey: "relatedNotebookIDs") }
        return fields
    }

    /// The research questions' rows `NotebookResearchQuestions.syncRows` leaves for `questions` over the
    /// rows this Mac holds: a question no longer listed goes unless it was dropped, a new one is added
    /// open and dated by the notebook's creation, one asked again is open again, and the order moves as
    /// few keys as it can.
    static func researchQuestionRows(notebookID: String, questions: [String], held: [NotebookResearchQuestions.Row], createdAt: Double) -> [NotebookResearchQuestions.Row] {
        var seen = Set<String>()
        let wanted = questions.compactMap { text -> (id: String, text: String)? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = NotebookResearchQuestions.questionID(notebookID: notebookID, text: trimmed)
            guard !trimmed.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, trimmed)
        }
        let byID = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = held.filter { $0.status == "dropped" && !seen.contains($0.id) }
        let keys = OrderKeyPlanner.plan(wanted.map { (id: $0.id, key: byID[$0.id]?.orderKey) })
        for question in wanted {
            rows.append(NotebookResearchQuestions.Row(
                id: question.id, text: question.text, status: "open",
                orderKey: keys[question.id] ?? byID[question.id]?.orderKey ?? "", createdAt: byID[question.id]?.createdAt ?? createdAt
            ))
        }
        return rows.sorted { ($0.orderKey, $0.id) < ($1.orderKey, $1.id) }
    }

    /// A notebook's Notes Doc from the old record's notes (WP8's `NotesDoc`): its body hashes by the
    /// hash of its encoded text, and empty notes clear it.
    static func notesFields(_ goal: LearningGoalRecord, notebookID: String) throws -> [String: SyncJSON] {
        var rows = ArtifactRows(shape: .notes(
            notebookID: notebookID, createdAt: goal.createdAt.timeIntervalSinceReferenceDate,
            editedAt: goal.updatedAt.timeIntervalSinceReferenceDate, notes: goal.notes
        ))
        if let body = try NotesDoc.body(notebookID: notebookID, notes: goal.notes) {
            rows.files[ArtifactBody.notesKey] = ArtifactBody.text(body.file)
        }
        return ArtifactProjection.encodeRows(rows)
    }

    /// A Goal's `learning_goals` columns, as `saveLearningGoalRecord` writes them.
    static func goalRows(_ goal: LearningGoalRecord) -> GoalProjection.Rows {
        GoalProjection.Rows(columns: [
            "title": .text(goal.title), "description": .text(goal.description), "parent_notebook_id": .text(goal.parentNotebookID),
            "start_at": .real(goal.startAt.timeIntervalSinceReferenceDate), "end_at": .real(goal.endAt.timeIntervalSinceReferenceDate),
            "daily_target": .integer(goal.dailyTarget.map(Int64.init)), "status": .text(goal.status),
            "created_at": .real(goal.createdAt.timeIntervalSinceReferenceDate),
        ])
    }
}
