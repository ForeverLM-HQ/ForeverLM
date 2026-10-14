import Foundation

// MARK: - The passages highlighted on a day
//
// A daily note's page foot lists what its day held in the library
// (docs/notes-graph-design.md, "Daily Notes"); the day's log has the reading,
// listening, watching, chats and Docs, and this has the marks made that day.

extension KnowledgeStore {
    /// The highlights made in `[start, end)`, oldest first, at most `limit`.
    /// `created_at` is kept in seconds since 1970, as `decodeSourceHighlight`
    /// reads it.
    func sourceHighlights(createdFrom start: Date, to end: Date, limit: Int) throws -> [SourceHighlight] {
        guard limit > 0, end > start else { return [] }
        var ids: [String] = []
        try queryBind("""
            SELECT highlight_id
            FROM source_highlights
            WHERE created_at >= ? AND created_at < ? AND \(Self.notBareSlideMark)
            ORDER BY created_at, highlight_id
            LIMIT ?
        """, bind: { stmt in
            self.bind(stmt, 1, start.timeIntervalSince1970)
            self.bind(stmt, 2, end.timeIntervalSince1970)
            self.bind(stmt, 3, limit)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return try ids.compactMap { try sourceHighlight(id: $0) }
    }
}

extension StorageService {
    /// The highlights made on a day (`YYYY-MM-DD`, the Mac's calendar day),
    /// oldest first.
    func sourceHighlights(madeOn dayKey: String, limit: Int = 200, calendar: Calendar = .current) throws -> [SourceHighlight] {
        guard let start = PlanDate.startOfDay(dayKey, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return try notebookFilesKnowledgeStore().sourceHighlights(createdFrom: start, to: end, limit: limit)
    }
}
