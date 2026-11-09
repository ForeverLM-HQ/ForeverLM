import Foundation

// MARK: - What generation 2 keeps beside generation 1's notebook writes (§12.7 v156)

extension KnowledgeStore {
    /// After a write to notebooks' or Goals' rows, under generation 2 only: a new row gets its kind
    /// (`entity_kind`, b1), the research questions' rows follow the generation-1 array, and each
    /// Entry's order key follows the study order the write left. Runs inside the writer's
    /// transaction; generation 1 writes exactly what build 177 does (D40).
    func keepNotebookRowsForGeneration2(goalIDs: [String]) throws {
        try LearningGoalEntityKind.classifyUnclassified(self)
        let now = Date().timeIntervalSinceReferenceDate
        for goalID in Set(goalIDs).sorted() {
            if let raw = try scalarText("SELECT research_questions FROM learning_goals WHERE id = ? AND entity_kind = ?", [.text(goalID), .text(LearningGoalEntityKind.notebook)]),
               let questions = Self.decodeResearchQuestions(raw) {
                try NotebookResearchQuestions.syncRows(notebookID: goalID, questions: questions, at: now, connection: self)
            }
            try EntryOrderKeys.replan(goalID: goalID, connection: self)
        }
        // A space notebook's Entries are named by wire ids (§4.3, WP15).
        let spaceNotebooks = try goalIDs.filter { try scalarText("SELECT team_id FROM learning_goals WHERE id = ?", [.text($0)]) != nil }
        if !spaceNotebooks.isEmpty {
            try SpaceRows.recordEntryIdentities(notebookIDs: spaceNotebooks, teamZones: try teamZoneKeys(), connection: self)
        }
    }
}
