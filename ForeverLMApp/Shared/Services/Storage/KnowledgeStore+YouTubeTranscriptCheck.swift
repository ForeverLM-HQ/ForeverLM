import Foundation
import SQLite3

/// One YouTube video whose stored transcript waits to be held to its captions
/// (schema 148, `youtube_transcript_check_queue`).
struct YouTubeTranscriptCheckCandidate: Sendable, Equatable {
    let sourceID: String
    let url: String
}

extension KnowledgeStore {

    /// A video whose captions could not be fetched this many times running is
    /// left alone. Its row stays in the queue as the record of what was tried.
    static let maximumYouTubeTranscriptCheckAttempts = 5

    /// The next videos to check, least-tried first.
    func youTubeTranscriptCheckCandidates(limit: Int) throws -> [YouTubeTranscriptCheckCandidate] {
        guard limit > 0 else { return [] }
        var candidates: [YouTubeTranscriptCheckCandidate] = []
        try queryBind("""
            SELECT q.source_id, v.url
            FROM youtube_transcript_check_queue q
            JOIN videos v ON v.source_id = q.source_id
            WHERE q.attempt_count < ?
            ORDER BY q.attempt_count ASC, q.enqueued_at ASC, q.source_id ASC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(Self.maximumYouTubeTranscriptCheckAttempts))
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }) { stmt in
            guard let sourceID = self.string(stmt, 0), let url = self.string(stmt, 1) else { return }
            candidates.append(YouTubeTranscriptCheckCandidate(sourceID: sourceID, url: url))
        }
        return candidates
    }

    /// Rows still worth checking.
    func youTubeTranscriptCheckQueueCount() throws -> Int {
        var count = 0
        try queryBind(
            "SELECT COUNT(*) FROM youtube_transcript_check_queue WHERE attempt_count < ?",
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(Self.maximumYouTubeTranscriptCheckAttempts))
            }
        ) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// A staged source that is no longer a video has no captions to check
    /// against; its row would otherwise never leave.
    func dropYouTubeTranscriptChecksWithoutVideos() throws {
        try exec("""
            DELETE FROM youtube_transcript_check_queue
            WHERE NOT EXISTS (
                SELECT 1 FROM videos v WHERE v.source_id = youtube_transcript_check_queue.source_id
            )
        """)
    }

    func completeYouTubeTranscriptCheck(sourceID: String) throws {
        try execBind("DELETE FROM youtube_transcript_check_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    func recordYouTubeTranscriptCheckFailure(sourceID: String, message: String) throws {
        try execBind("""
            UPDATE youtube_transcript_check_queue
            SET attempt_count = attempt_count + 1, last_error = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, String(message.prefix(500)))
            bind(stmt, 2, sourceID)
        }
    }

    /// The excerpts Memory items are anchored to in one source's text.
    func memoryAnchorExcerpts(sourceID: String) throws -> [String] {
        var excerpts: [String] = []
        try queryBind(
            "SELECT excerpt FROM memory_item_sources INDEXED BY idx_memory_item_sources_source WHERE source_id = ?",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { stmt in
            if let excerpt = self.string(stmt, 0) { excerpts.append(excerpt) }
        }
        return excerpts
    }

    /// Give a video the transcript held to its captions and take it off the
    /// queue, in one transaction. The text is written only while the stored
    /// one is still `checkedContent`, the one the check read: a transcript
    /// re-downloaded, reformatted or edited since is newer than the check. A
    /// change is marked for CloudKit, which the phone and the other Mac read
    /// the transcript from, and drops the full-text and embedding state so the
    /// indexer rewrites them. Returns whether the text changed.
    @discardableResult
    func replaceCheckedYouTubeTranscript(
        sourceID: String,
        checkedContent: String,
        content: String
    ) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("UPDATE source_content SET content = ? WHERE source_id = ? AND content = ?") { stmt in
                bind(stmt, 1, content)
                bind(stmt, 2, sourceID)
                bind(stmt, 3, checkedContent)
            }
            let changed = sqlite3_changes(db) > 0
            if changed {
                try execBind("UPDATE videos SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(content.split(separator: " ").count))
                    bind(stmt, 2, sourceID)
                }
                try invalidateCanonicalContentIndexes(sourceID: sourceID)
                try retireSourceReviewGuidePreparation(sourceID: sourceID)
                try markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            try execBind("DELETE FROM youtube_transcript_check_queue WHERE source_id = ?") { stmt in
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
