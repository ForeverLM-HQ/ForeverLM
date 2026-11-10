import Foundation
import SQLite3

/// Persistence for papers read off a video's slides.
///
/// A candidate carries two source references — the video it came from and, once the
/// learner imports it, the paper source that was created. Both are plain TEXT columns
/// with no foreign key (mirroring `scheduled_sources`), because CloudKit can deliver a
/// candidate before either source row exists locally.
extension KnowledgeStore {

    // MARK: - Local mutations

    /// Upsert a candidate and queue it for CloudKit.
    ///
    /// `updatedAt` is written exactly as the caller set it: it is the field conflict
    /// resolution compares, so silently re-stamping it here would let a stale write
    /// win against a newer one from the other Mac.
    func saveVideoCitedPaper(_ paper: VideoCitedPaper) throws {
        try upsertVideoCitedPaperRow(paper)
    }

    func loadVideoCitedPapers(forSourceID sourceID: String) throws -> [VideoCitedPaper] {
        var papers: [VideoCitedPaper] = []
        try queryBind("""
            \(Self.videoCitedPaperColumns)
            WHERE source_id = ?
            ORDER BY slide_time_seconds IS NULL, slide_time_seconds ASC, created_at ASC
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            if let paper = self.readVideoCitedPaperRow(stmt) { papers.append(paper) }
        }
        return papers
    }

    func loadVideoCitedPaper(id: String) throws -> VideoCitedPaper? {
        var paper: VideoCitedPaper?
        try queryBind("\(Self.videoCitedPaperColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            paper = self.readVideoCitedPaperRow(stmt)
        }
        return paper
    }

    func deleteVideoCitedPaper(id: String) throws {
        try execBind("DELETE FROM video_cited_papers WHERE id = ?") { stmt in
            bind(stmt, 1, id)
        }
    }

    // MARK: - Sync

    // MARK: - Row plumbing

    /// Column order shared by every read, so `readVideoCitedPaperRow` indexes stay honest.
    private static let videoCitedPaperColumns = """
        SELECT id, source_id, title, authors, year, journal, doi, url,
               slide_time_seconds, slide_image_path, status, imported_source_id,
               created_at, updated_at, kind, context
        FROM video_cited_papers
    """

    /// Single INSERT ... ON CONFLICT used by both the local save and the inbound apply,
    /// so the two can never drift on which columns they write.
    private func upsertVideoCitedPaperRow(_ paper: VideoCitedPaper) throws {
        try execBind("""
            INSERT INTO video_cited_papers (
                id, source_id, title, authors, year, journal, doi, url,
                slide_time_seconds, slide_image_path, status, imported_source_id,
                created_at, updated_at, kind, context
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id,
                title = excluded.title,
                authors = excluded.authors,
                year = excluded.year,
                journal = excluded.journal,
                doi = excluded.doi,
                url = excluded.url,
                slide_time_seconds = excluded.slide_time_seconds,
                slide_image_path = excluded.slide_image_path,
                status = excluded.status,
                imported_source_id = excluded.imported_source_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                kind = excluded.kind,
                context = excluded.context
        """) { stmt in
            bind(stmt, 1, paper.id)
            bind(stmt, 2, paper.sourceID)
            bind(stmt, 3, paper.title)
            bind(stmt, 4, paper.authors)
            bind(stmt, 5, paper.year)
            bind(stmt, 6, paper.journal)
            bind(stmt, 7, paper.doi)
            bind(stmt, 8, paper.url)
            bind(stmt, 9, paper.slideTimeSeconds)
            bind(stmt, 10, paper.slideImagePath)
            bind(stmt, 11, paper.status.rawValue)
            bind(stmt, 12, paper.importedSourceID)
            sqlite3_bind_double(stmt, 13, paper.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 14, paper.updatedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 15, paper.kind.rawValue)
            bind(stmt, 16, paper.context)
        }
    }

    func readVideoCitedPaperRow(_ stmt: OpaquePointer?) -> VideoCitedPaper? {
        guard let id = string(stmt, 0),
              let sourceID = string(stmt, 1),
              let title = string(stmt, 2),
              let statusRaw = string(stmt, 10),
              let status = VideoCitedPaper.Status(rawValue: statusRaw) else { return nil }
        return VideoCitedPaper(
            id: id,
            sourceID: sourceID,
            title: title,
            authors: string(stmt, 3),
            year: string(stmt, 4),
            journal: string(stmt, 5),
            doi: string(stmt, 6),
            url: string(stmt, 7),
            slideTimeSeconds: optionalDouble(stmt, 8),
            slideImagePath: string(stmt, 9),
            status: status,
            importedSourceID: string(stmt, 11),
            // A kind this build does not know reads as a paper, the kind every
            // row had before the column existed.
            kind: string(stmt, 14).flatMap(VideoCitedPaper.Kind.init(rawValue:)) ?? .paper,
            context: string(stmt, 15),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 12)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 13))
        )
    }
}
