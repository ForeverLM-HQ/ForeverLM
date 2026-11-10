import Foundation
import SQLite3

/// One paper whose title waits to be checked against the title its DOI is
/// registered under (schema 144, `paper_registered_title_queue`).
struct RegisteredPaperTitleCandidate: Sendable, Equatable {
    let sourceID: String
    let doi: String
    let title: String
}

extension KnowledgeStore {

    /// A DOI no agency could be asked about this many times running is left
    /// alone. Its row stays in the queue as the record of what was tried.
    static let maximumRegisteredPaperTitleAttempts = 5

    /// The next papers to check, least-tried first.
    func registeredPaperTitleCandidates(limit: Int) throws -> [RegisteredPaperTitleCandidate] {
        guard limit > 0 else { return [] }
        var candidates: [RegisteredPaperTitleCandidate] = []
        try queryBind("""
            SELECT q.source_id, COALESCE(p.doi, ''), COALESCE(p.title, '')
            FROM paper_registered_title_queue q
            JOIN papers p ON p.source_id = q.source_id
            WHERE q.attempt_count < ?
            ORDER BY q.attempt_count ASC, q.enqueued_at ASC, q.source_id ASC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(Self.maximumRegisteredPaperTitleAttempts))
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }) { stmt in
            guard let sourceID = self.string(stmt, 0) else { return }
            candidates.append(RegisteredPaperTitleCandidate(
                sourceID: sourceID,
                doi: self.string(stmt, 1) ?? "",
                title: self.string(stmt, 2) ?? ""
            ))
        }
        return candidates
    }

    /// Rows still worth asking about.
    func registeredPaperTitleQueueCount() throws -> Int {
        var count = 0
        try queryBind(
            "SELECT COUNT(*) FROM paper_registered_title_queue WHERE attempt_count < ?",
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(Self.maximumRegisteredPaperTitleAttempts))
            }
        ) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// A staged source that is no longer a paper (moved to Articles, say) has
    /// no DOI title to check; its row would otherwise never leave.
    func dropRegisteredPaperTitleChecksWithoutPapers() throws {
        try exec("""
            DELETE FROM paper_registered_title_queue
            WHERE NOT EXISTS (
                SELECT 1 FROM papers p WHERE p.source_id = paper_registered_title_queue.source_id
            )
        """)
    }

    func completeRegisteredPaperTitleCheck(sourceID: String) throws {
        try execBind("DELETE FROM paper_registered_title_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    func recordRegisteredPaperTitleCheckFailure(sourceID: String, message: String) throws {
        try execBind("""
            UPDATE paper_registered_title_queue
            SET attempt_count = attempt_count + 1, last_error = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, String(message.prefix(500)))
            bind(stmt, 2, sourceID)
        }
    }

    /// Give a paper the title its DOI is registered under and take it off the
    /// queue, in one transaction. The title is written only while the stored
    /// one is still `checkedTitle`, the one the check compared: a title the
    /// learner or a fresh ingestion wrote since is theirs. A change is marked
    /// for CloudKit, which the phone and the other Mac read titles from, and
    /// drops the full-text state so the indexer rewrites the row. Returns
    /// whether the title changed.
    @discardableResult
    func restoreRegisteredPaperTitle(
        sourceID: String,
        checkedTitle: String,
        registeredTitle: String
    ) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("UPDATE papers SET title = ? WHERE source_id = ? AND title = ?") { stmt in
                bind(stmt, 1, registeredTitle)
                bind(stmt, 2, sourceID)
                bind(stmt, 3, checkedTitle)
            }
            let changed = sqlite3_changes(db) > 0
            if changed {
                noteStoreChanged()
                try execBind("DELETE FROM source_fts_state WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
            }
            try execBind("DELETE FROM paper_registered_title_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            try exec("COMMIT")
            return changed
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
