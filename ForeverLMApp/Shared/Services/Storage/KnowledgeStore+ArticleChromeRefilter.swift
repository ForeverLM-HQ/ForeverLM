import SQLite3

/// One archived article whose reader document predates `ArticleChromeFilter`.
struct ArticleChromeRefilterCandidate: Sendable {
    let sourceID: String
    let title: String
    let url: String
}

extension KnowledgeStore {

    /// An article that has failed this many times is left alone. The reader
    /// document it already has is readable; a page that cannot be refetched
    /// four times running is paywalled, moved, or gone, and retrying it forever
    /// would spend the learner's credit on nothing.
    static let maximumArticleChromeRefilterAttempts = 4

    func articleChromeRefilterCandidates(limit: Int) throws -> [ArticleChromeRefilterCandidate] {
        guard limit > 0 else { return [] }
        var candidates: [ArticleChromeRefilterCandidate] = []
        try queryBind("""
            SELECT q.source_id, COALESCE(a.title, ''), a.url
            FROM article_chrome_refilter_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN articles a ON a.source_id = q.source_id
            WHERE q.attempt_count < ?
              AND s.status = 'active'
              AND (a.url LIKE 'http://%' OR a.url LIKE 'https://%')
            ORDER BY q.attempt_count ASC, q.enqueued_at ASC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(Self.maximumArticleChromeRefilterAttempts))
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let url = self.string(stmt, 2) else { return }
            candidates.append(
                ArticleChromeRefilterCandidate(
                    sourceID: sourceID,
                    title: self.string(stmt, 1) ?? "",
                    url: url
                )
            )
        }
        return candidates
    }

    /// Rows still worth attempting. Exhausted rows stay in the table as a record
    /// of what was tried, so a later build can look at them instead of guessing.
    func articleChromeRefilterQueueCount() throws -> Int {
        var count = 0
        try queryBind(
            "SELECT COUNT(*) FROM article_chrome_refilter_queue WHERE attempt_count < ?",
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(Self.maximumArticleChromeRefilterAttempts))
            }
        ) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func completeArticleChromeRefilter(sourceID: String) throws {
        try execBind("DELETE FROM article_chrome_refilter_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    func recordArticleChromeRefilterFailure(sourceID: String, message: String) throws {
        try execBind("""
            UPDATE article_chrome_refilter_queue
            SET attempt_count = attempt_count + 1, last_error = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, String(message.prefix(500)))
            bind(stmt, 2, sourceID)
        }
    }
}
