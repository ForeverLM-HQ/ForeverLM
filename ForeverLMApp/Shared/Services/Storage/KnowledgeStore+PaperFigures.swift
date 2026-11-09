import CryptoKit
import Foundation
import SQLite3

/// Index metadata that connects a structural figure label to the PDF page a
/// multimodal model must inspect. Everything here is portable and syncs; the
/// pixels are not stored at all, because the PDF already holds them and every
/// client renders `pageIndex` on demand.
struct PaperFigureRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let figureLabel: String
    /// Zero-based PDFKit page index. `pageNumber` is the one-based display value.
    let pageIndex: Int
    let caption: String
    let analysis: PaperFigureAnalysis?

    var pageNumber: Int { pageIndex + 1 }
}

struct PaperFigureIndexCandidate: Equatable, Sendable {
    let sourceID: String
    let title: String
    let pdfPath: String
    let targetVersion: Int
    let attemptCount: Int
}

enum PaperFigureIndexContract {
    /// Bumped when the structural read of a PDF changes what it indexes, so a
    /// paper indexed under an older version is read again the next time
    /// anything prepares its figures (`enqueuePaperFigureIndexIfNeeded`
    /// re-queues a state row below this number). The re-read happens per
    /// paper, on use, and once for the whole library at launch since
    /// 2026-11-08 (`runDeferredPaperFigureIndexBackfill`, so every paper's
    /// figure mentions link): both are the structure-only read
    /// (`prepareStructure`), which runs no vision. Existing analyses survive by
    /// figure id, so only figures new to the index are ever analysed.
    ///
    /// 1: main figures ("Figure 3", "Fig. S2").
    /// 2 (2026-09-20): Extended Data and Supplementary captions are figures
    ///   too ("Extended Data Figure 1", "Supplementary Figure 2").
    /// 3 (2026-09-20): a caption that opens a page, under nothing but the
    ///   running head, belongs to the figure that filled the page before it
    ///   — Nature's layout for a full-page figure — so the figure is indexed
    ///   on that page, where the Reader can outline it, rather than on the
    ///   caption's, where the vision pass found only the running head.
    /// 4 (2026-09-21): a caption is its whole printed paragraph, not the line
    ///   its label opens. Fig. 1 of the cardiac-sodium paper was titled by its
    ///   first line alone, cut where the column wrapped.
    /// 5 (2026-09-28): one row a figure, on the page that shows it, with its
    ///   caption's words wherever they are printed. A label printed alone
    ///   ("Figure 1.", "See next page for caption") marks the figure's page,
    ///   a legend on a page with no figure is paired with a nearby figure
    ///   page, and a caption behind an arrow ("◀ Figure 2.") is read. The EMBO
    ///   cristae paper had Figures 1 and 5 on their legends' pages of prose,
    ///   and six figures with no words at all.
    /// 6 (2026-09-28): a legend on a page that shows a figure is that page's
    ///   only when a figure stands beside it
    ///   (`PaperFigureRectRefiner.legendStandsBesideFigure`): JBC prints
    ///   Figure 4's legend at the foot of Figure 5's page, and Cell a legend
    ///   overleaf on a page with its logo. A page a legend is paired with is
    ///   drawn dark somewhere, not only with a pale watermark, and a caption
    ///   label is read on each printed line, past a watermark the page's text
    ///   runs into it.
    /// 7 (2026-09-28): a figure's words come from its legend, not from a
    ///   line of the running text that opens with its label — the line
    ///   above it set in the same size at the text's pitch, as wide, and
    ///   broken off mid-sentence (`PDFTextExtractor.FigureCaption.isRunningText`).
    ///   The Biophysical Journal's Figure 5 was titled "The measured
    ///   fluorescence both inside and outside…".
    /// 8 (2026-10-23): an entry in a list of figures is no figure — a
    ///   caption with a run of leader dots (`PaperFigureCaptionTitle.isContentsEntry`).
    ///   A thesis's List of Figures held 76 rows, each a box over its contents
    ///   page, beside the real ones; a paper indexed before this is read again
    ///   on use and the rows go.
    static let currentVersion = 8

    static func figureID(sourceID: String, figureLabel: String, pageIndex: Int) -> String {
        let material = "\(sourceID)\u{1F}\(pageIndex)\u{1F}\(figureLabel.lowercased())"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "fig_\(digest)"
    }
}

/// The `## Figures` block that PDF extraction appended to canonical text before
/// schema 75.
///
/// Every line in it was an `![caption](file:///…)` link to a rendered page JPEG
/// sitting beside the PDF. The path was absolute, so it named the one Mac that
/// did the extraction and resolved nowhere else — not on a second Mac, not on
/// the phone, and not for a model reading the text, which is where most of this
/// content is actually consumed.
///
/// The block is removed rather than rewritten in place. Its captions are already
/// present verbatim in the extracted page text above it, and the authoritative
/// label-to-page index is `paper_figures`, which any paper can refill from its
/// own PDF through the durable index queue. Reconstructing labels by parsing our
/// own escaped alt text would be a lossy guess at data that is already stored
/// properly elsewhere.
enum LegacyPaperFigureMarkdown {
    static let heading = "## Figures"

    /// The content with the stale block removed, or `nil` when there is nothing
    /// of this exact shape to remove.
    ///
    /// Conservative by construction: it strips only a trailing run whose every
    /// non-empty line is one of these generated image links. Anything else after
    /// the heading means this is not our block — a paper of its own with a
    /// "Figures" section, or text a later cleanup pass reshaped — and it is left
    /// untouched.
    static func stripping(_ content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard let headingIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == heading
        }) else { return nil }

        var sawImageLink = false
        for line in lines[(headingIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("!["),
                  trimmed.hasSuffix(")"),
                  trimmed.contains("](file://") else { return nil }
            sawImageLink = true
        }
        guard sawImageLink else { return nil }

        let stripped = lines[..<headingIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped == content ? nil : stripped
    }
}

extension KnowledgeStore {
    /// Queue a paper only when its path/version is not already indexed. A fresh
    /// PDF attachment may force the same path back through indexing because the
    /// bytes can have changed without changing the portable filename.
    func enqueuePaperFigureIndexIfNeeded(
        sourceID: String,
        pdfPath: String,
        force: Bool
    ) throws {
        let portablePath = StorageService.relativeSourcePath(pdfPath)
        guard !portablePath.isEmpty else { return }
        let target = PaperFigureIndexContract.currentVersion

        if !force {
            var isCurrent = false
            try queryBind("""
                SELECT 1
                FROM paper_figure_index_state
                WHERE source_id = ? AND pdf_path = ? AND index_version >= ?
                LIMIT 1
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
                bind(stmt, 2, portablePath)
                sqlite3_bind_int(stmt, 3, Int32(target))
            }) { _ in isCurrent = true }
            if isCurrent {
                try execBind("DELETE FROM paper_figure_index_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
                return
            }
        }

        try execBind("""
            INSERT INTO paper_figure_index_queue
                (source_id, target_version, enqueued_at, attempt_count, last_error, pdf_path)
            VALUES (?, ?, ?, 0, NULL, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = excluded.target_version,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL,
                pdf_path = excluded.pdf_path
            WHERE paper_figure_index_queue.target_version < excluded.target_version
               OR paper_figure_index_queue.pdf_path != excluded.pdf_path
               OR ? = 1
        """) { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(target))
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 4, portablePath)
            sqlite3_bind_int(stmt, 5, force ? 1 : 0)
        }
    }

    /// The sources whose file can carry a figure index: a paper's row and a
    /// book chapter's, which hold the PDF's path and a title. Book chapters
    /// joined the figure index on 2026-09-19 so a chapter's walkthrough can
    /// outline its figures; the historical migration staging
    /// (`enqueueHistoricalPaperFigureIndex`) stays papers-only on purpose, so
    /// no launch indexes a library's books unasked — a chapter is indexed when
    /// something asks for its figures. A chapter of a book kept as one file is
    /// its pages of the book's file, in the stored form `SourcePDFPages`
    /// reads (`Books/…/Book.pdf#pages=12..<40`): the index's figures count
    /// pages from the chapter's first, and a chapter whose pages change is a
    /// new path, so it is indexed again.
    static let figureIndexableSourcesSQL = """
        (SELECT source_id, title, local_file_path FROM papers
         UNION ALL
         SELECT source_id, title,
                CASE WHEN page_start IS NULL OR page_count IS NULL THEN local_file_path
                     ELSE local_file_path || '#pages=' || page_start || '..<' || (page_start + page_count)
                END
         FROM book_sources)
        """

    func nextPaperFigureIndexCandidate() throws -> PaperFigureIndexCandidate? {
        var result: PaperFigureIndexCandidate?
        try query("""
            SELECT q.source_id, COALESCE(p.title, 'Untitled Paper'), q.pdf_path,
                   q.target_version, q.attempt_count
            FROM paper_figure_index_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN \(Self.figureIndexableSourcesSQL) p ON p.source_id = q.source_id
            WHERE s.status = 'active'
              AND q.attempt_count < 3
            ORDER BY q.attempt_count ASC, q.enqueued_at ASC, q.source_id ASC
            LIMIT 1
        """) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let title = self.string(stmt, 1),
                  let pdfPath = self.string(stmt, 2) else { return }
            result = PaperFigureIndexCandidate(
                sourceID: sourceID,
                title: title,
                pdfPath: pdfPath,
                targetVersion: Int(sqlite3_column_int(stmt, 3)),
                attemptCount: Int(sqlite3_column_int(stmt, 4))
            )
        }
        return result
    }

    /// Resolve the exact paper requested by an explicit review. Unlike the
    /// maintenance-oriented oldest-first query, this never lets unrelated queue
    /// rows cause work for sources the learner did not choose.
    func paperFigureIndexCandidate(sourceID: String) throws -> PaperFigureIndexCandidate? {
        var result: PaperFigureIndexCandidate?
        try queryBind("""
            SELECT q.source_id, COALESCE(p.title, 'Untitled Paper'), q.pdf_path,
                   q.target_version, q.attempt_count
            FROM paper_figure_index_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN \(Self.figureIndexableSourcesSQL) p ON p.source_id = q.source_id
            WHERE q.source_id = ?
              AND s.status = 'active'
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let title = self.string(stmt, 1),
                  let pdfPath = self.string(stmt, 2) else { return }
            result = PaperFigureIndexCandidate(
                sourceID: sourceID,
                title: title,
                pdfPath: pdfPath,
                targetVersion: Int(sqlite3_column_int(stmt, 3)),
                attemptCount: Int(sqlite3_column_int(stmt, 4))
            )
        }
        return result
    }

    /// The paper an already-built index belongs to.
    ///
    /// `paperFigureIndexCandidate` only sees papers still sitting in the queue,
    /// and a successful index deletes its queue row. Explaining one more figure
    /// of a paper that is already indexed still needs the PDF, and this is what
    /// finds it — the path the index was built from, falling back to the paper's
    /// own file when no state row survives.
    func paperFigureIndexTarget(sourceID: String) throws -> PaperFigureIndexCandidate? {
        var result: PaperFigureIndexCandidate?
        try queryBind("""
            SELECT COALESCE(p.title, 'Untitled Paper'),
                   COALESCE(st.pdf_path, p.local_file_path),
                   COALESCE(st.index_version, ?)
            FROM \(Self.figureIndexableSourcesSQL) p
            JOIN sources s ON s.id = p.source_id
            LEFT JOIN paper_figure_index_state st ON st.source_id = p.source_id
            WHERE p.source_id = ?
              AND s.status = 'active'
              AND COALESCE(st.pdf_path, p.local_file_path) IS NOT NULL
              AND TRIM(COALESCE(st.pdf_path, p.local_file_path)) != ''
            LIMIT 1
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(PaperFigureIndexContract.currentVersion))
            bind(stmt, 2, sourceID)
        }) { stmt in
            guard let title = self.string(stmt, 0), let pdfPath = self.string(stmt, 1) else { return }
            result = PaperFigureIndexCandidate(
                sourceID: sourceID,
                title: title,
                pdfPath: pdfPath,
                targetVersion: Int(sqlite3_column_int(stmt, 2)),
                attemptCount: 0
            )
        }
        return result
    }

    /// Repair a missing queue row for one explicitly requested review. A
    /// current empty index remains current unless `force` is true; an empty
    /// result can legitimately mean that the PDF contains no labelled figures.
    func ensurePaperFigureIndexQueuedForReview(sourceID: String, force: Bool) throws {
        var pdfPath: String?
        try queryBind("""
            SELECT p.local_file_path
            FROM \(Self.figureIndexableSourcesSQL) p
            JOIN sources s ON s.id = p.source_id
            WHERE p.source_id = ?
              AND s.status = 'active'
              AND p.local_file_path IS NOT NULL
              AND TRIM(p.local_file_path) != ''
              AND (LOWER(p.local_file_path) LIKE '%.pdf' OR LOWER(p.local_file_path) LIKE '%.pdf#pages=%')
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            pdfPath = self.string(stmt, 0)
        }
        guard let pdfPath else { return }
        try enqueuePaperFigureIndexIfNeeded(sourceID: sourceID, pdfPath: pdfPath, force: force)
    }

    /// Whether the paper's figure index was built under the current rules, so
    /// it can be read as stored rather than read out of the PDF again.
    func paperFigureIndexIsCurrent(sourceID: String) throws -> Bool {
        var isCurrent = false
        try queryBind("""
            SELECT 1 FROM paper_figure_index_state
            WHERE source_id = ? AND index_version >= ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(PaperFigureIndexContract.currentVersion))
        }) { _ in isCurrent = true }
        return isCurrent
    }

    /// The papers whose figure index is missing or was built under older
    /// rules: what the library's one backfill reads (product owner, 2026-11-08:
    /// "backfill that in our library of papers"), so every paper's figure
    /// mentions open their figures. Papers only, as the historical staging is;
    /// a paper whose read failed three times is left alone.
    func papersNeedingFigureIndex() throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT p.source_id
            FROM papers p
            JOIN sources s ON s.id = p.source_id
            LEFT JOIN paper_figure_index_state st ON st.source_id = p.source_id
            LEFT JOIN paper_figure_index_queue q ON q.source_id = p.source_id
            WHERE s.status = 'active'
              AND p.local_file_path IS NOT NULL
              AND TRIM(p.local_file_path) != ''
              AND LOWER(p.local_file_path) LIKE '%.pdf'
              AND (st.source_id IS NULL OR st.index_version < ?)
              AND COALESCE(q.attempt_count, 0) < 3
            ORDER BY p.source_id
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(PaperFigureIndexContract.currentVersion))
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func paperFigureIndexQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM paper_figure_index_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func recordPaperFigureIndexFailure(sourceID: String, message: String) throws {
        try execBind("""
            UPDATE paper_figure_index_queue
            SET attempt_count = attempt_count + 1,
                last_error = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, String(message.prefix(2_000)))
            bind(stmt, 2, sourceID)
        }
    }

    /// Atomically replace the complete index for one PDF. An empty figure list
    /// is still a successful index result: it prevents rescanning a paper that
    /// simply contains no structurally labelled figures.
    func replacePaperFigureIndex(
        sourceID: String,
        pdfPath: String,
        pageCount: Int,
        figures: [PaperFigureRecord],
        indexVersion: Int
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM paper_figures WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            for figure in figures {
                guard figure.sourceID == sourceID, figure.pageIndex >= 0 else {
                    throw KnowledgeStoreError.invalidData("Paper figure index contained an invalid source or page.")
                }
                let analysisJSON = try figure.analysis.map {
                    String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
                }
                try execBind("""
                    INSERT INTO paper_figures
                        (figure_id, source_id, figure_label, page_index, caption, analysis_json)
                    VALUES (?, ?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, figure.id)
                    bind(stmt, 2, sourceID)
                    bind(stmt, 3, figure.figureLabel)
                    sqlite3_bind_int(stmt, 4, Int32(figure.pageIndex))
                    bind(stmt, 5, figure.caption)
                    bind(stmt, 6, analysisJSON)
                }
            }
            try execBind("""
                INSERT INTO paper_figure_index_state
                    (source_id, pdf_path, index_version, page_count, indexed_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    pdf_path = excluded.pdf_path,
                    index_version = excluded.index_version,
                    page_count = excluded.page_count,
                    indexed_at = excluded.indexed_at
            """) { stmt in
                bind(stmt, 1, sourceID)
                bind(stmt, 2, StorageService.relativeSourcePath(pdfPath))
                sqlite3_bind_int(stmt, 3, Int32(indexVersion))
                sqlite3_bind_int(stmt, 4, Int32(pageCount))
                sqlite3_bind_double(stmt, 5, Date().timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM paper_figure_index_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            try markRecordChanged(entity: .source, logicalKey: sourceID)
            try queueSourceFilesRefresh(sourceID: sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Store one figure's vision analysis without disturbing the rest of the
    /// index.
    ///
    /// `replacePaperFigureIndex` is all-or-nothing by design: it is how a full
    /// pass over a paper lands, and a partial one would leave the index and its
    /// state row disagreeing. But a chat that inspects a single figure should
    /// pay for that one figure and keep it, rather than paying for every figure
    /// in the paper to see one of them. This is that write.
    ///
    /// The row has to exist already. The structural pass is what decides a
    /// figure is real, and an analysis for a label nobody found is not a figure.
    /// Returns whether a row was actually updated so the caller can tell a
    /// stale figure ID from a successful write.
    @discardableResult
    func updatePaperFigureAnalysis(
        sourceID: String,
        figureID: String,
        analysis: PaperFigureAnalysis
    ) throws -> Bool {
        let analysisJSON = String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self)
        var updated = false
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE paper_figures
                SET analysis_json = ?
                WHERE figure_id = ? AND source_id = ?
            """) { stmt in
                bind(stmt, 1, analysisJSON)
                bind(stmt, 2, figureID)
                bind(stmt, 3, sourceID)
            }
            updated = sqlite3_changes(db) > 0
            // The figures travel to the phone inside the source record, so a
            // rect this write improves is only better everywhere if the record
            // is republished.
            if updated {
                try markRecordChanged(entity: .source, logicalKey: sourceID)
                try queueSourceFilesRefresh(sourceID: sourceID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return updated
    }

    func paperFigures(sourceID: String) throws -> [PaperFigureRecord] {
        var result: [PaperFigureRecord] = []
        try queryBind("""
            SELECT figure_id, source_id, figure_label, page_index, caption, analysis_json
            FROM paper_figures
            WHERE source_id = ?
            ORDER BY page_index ASC, figure_label COLLATE NOCASE ASC
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let sourceID = self.string(stmt, 1),
                  let label = self.string(stmt, 2),
                  let caption = self.string(stmt, 4) else { return }
            let analysis = self.string(stmt, 5).flatMap { json in
                try? JSONDecoder().decode(PaperFigureAnalysis.self, from: Data(json.utf8))
            }
            result.append(PaperFigureRecord(
                id: id,
                sourceID: sourceID,
                figureLabel: label,
                pageIndex: Int(sqlite3_column_int(stmt, 3)),
                caption: caption,
                analysis: analysis
            ))
        }
        return result
    }

    func syncedPaperFigures(sourceID: String) throws -> [SyncedPaperFigure] {
        try paperFigures(sourceID: sourceID).map {
            SyncedPaperFigure(
                id: $0.id,
                sourceID: $0.sourceID,
                figureLabel: $0.figureLabel,
                pageIndex: $0.pageIndex,
                caption: $0.caption,
                analysis: $0.analysis
            )
        }
    }

    /// Replace the portable synced projection. Every column here travels, so a
    /// receiving device needs nothing local beyond the PDF it renders from.
    func savePaperFiguresFromSync(sourceID: String, figures: [SyncedPaperFigure]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let incomingIDs = Set(
                figures.lazy
                    .filter { $0.sourceID == sourceID && $0.pageIndex >= 0 }
                    .map(\.id)
            )
            let existing = try paperFigures(sourceID: sourceID)
            for figure in existing where !incomingIDs.contains(figure.id) {
                try execBind("DELETE FROM paper_figures WHERE figure_id = ?") { stmt in
                    bind(stmt, 1, figure.id)
                }
            }
            for figure in figures where figure.sourceID == sourceID && figure.pageIndex >= 0 {
                let analysisJSON = try figure.analysis.map {
                    String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
                }
                try execBind("""
                    INSERT INTO paper_figures
                        (figure_id, source_id, figure_label, page_index, caption, analysis_json)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(figure_id) DO UPDATE SET
                        figure_label = excluded.figure_label,
                        page_index = excluded.page_index,
                        caption = excluded.caption,
                        analysis_json = excluded.analysis_json
                """) { stmt in
                    bind(stmt, 1, figure.id)
                    bind(stmt, 2, sourceID)
                    bind(stmt, 3, figure.figureLabel)
                    sqlite3_bind_int(stmt, 4, Int32(figure.pageIndex))
                    bind(stmt, 5, figure.caption)
                    bind(stmt, 6, analysisJSON)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Version-41 migration staging. This is one indexed, set-based metadata
    /// insert: no PDF is opened, hashed, or rendered in the migration.
    func enqueueHistoricalPaperFigureIndex() throws -> Int {
        try execBind("""
            INSERT INTO paper_figure_index_queue
                (source_id, target_version, enqueued_at, attempt_count, last_error, pdf_path)
            SELECT p.source_id, ?, ?, 0, NULL, p.local_file_path
            FROM papers p
            JOIN sources s ON s.id = p.source_id
            WHERE s.status = 'active'
              AND p.local_file_path IS NOT NULL
              AND TRIM(p.local_file_path) != ''
              AND LOWER(p.local_file_path) LIKE '%.pdf'
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(paper_figure_index_queue.target_version, excluded.target_version),
                pdf_path = excluded.pdf_path
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(PaperFigureIndexContract.currentVersion))
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM paper_figure_index_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Strip the stale figure image links from a bounded slice of stored source
    /// text and republish those sources.
    ///
    /// After launch rather than in the schema transaction: this reads and
    /// rewrites content, which is proportional to the library. Each batch commits
    /// on its own, so quitting midway leaves the rest durable, and re-running is
    /// harmless — the strip is idempotent on text that no longer holds a block,
    /// and the row leaves the queue either way.
    ///
    /// Returns the sources whose text actually changed.
    func drainPaperFigureMarkdownRepairBatch(limit: Int) throws -> [String] {
        let boundedLimit = max(1, min(limit, 100))
        var candidates: [(sourceID: String, content: String)] = []
        try query("""
            SELECT q.source_id, sc.content
            FROM paper_figure_markdown_repair_queue q
            JOIN source_content sc ON sc.source_id = q.source_id
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let content = self.string(stmt, 1) else { return }
            candidates.append((sourceID, content))
        }

        // A queued source whose content row has since gone (archived, deleted)
        // has no repair left to do, but its queue row would otherwise block the
        // batch window forever.
        var orphanedIDs: [String] = []
        try query("""
            SELECT q.source_id
            FROM paper_figure_markdown_repair_queue q
            WHERE NOT EXISTS (
                SELECT 1 FROM source_content sc WHERE sc.source_id = q.source_id
            )
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            if let sourceID = self.string(stmt, 0) { orphanedIDs.append(sourceID) }
        }

        guard !candidates.isEmpty || !orphanedIDs.isEmpty else { return [] }

        try exec("BEGIN IMMEDIATE")
        var repairedIDs: [String] = []
        do {
            let now = Date()
            for candidate in candidates {
                if let stripped = LegacyPaperFigureMarkdown.stripping(candidate.content) {
                    try execBind("UPDATE source_content SET content = ? WHERE source_id = ?") { stmt in
                        bind(stmt, 1, stripped)
                        bind(stmt, 2, candidate.sourceID)
                    }
                    try upsertSyncSave(entity: .source, logicalKey: candidate.sourceID, at: now)
                    // The text other devices read is published again (generation 2).
                    try queueSourceFilesRefresh(sourceID: candidate.sourceID)
                    repairedIDs.append(candidate.sourceID)
                }
                try execBind(
                    "DELETE FROM paper_figure_markdown_repair_queue WHERE source_id = ?"
                ) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            }
            for sourceID in orphanedIDs {
                try execBind(
                    "DELETE FROM paper_figure_markdown_repair_queue WHERE source_id = ?"
                ) { stmt in
                    bind(stmt, 1, sourceID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return repairedIDs
    }

    /// The PDF this source's figure index was built from, as a portable path.
    ///
    /// Clients render figures straight out of it, so this is the one lookup that
    /// stands between a stored figure row and its pixels.
    func paperFigureIndexedPDFPath(sourceID: String) throws -> String? {
        var path: String?
        try queryBind(
            "SELECT pdf_path FROM paper_figure_index_state WHERE source_id = ?",
            bind: { stmt in bind(stmt, 1, sourceID) }
        ) { stmt in
            path = self.string(stmt, 0)
        }
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return path
    }

    /// Whether this device still owes the one-time removal of rendered figure
    /// JPEGs. False once the sweep has finished, and false for a database that
    /// was created after schema 75 and never had any.
    func paperFigureImageSweepIsPending() throws -> Bool {
        var pending = false
        try query("""
            SELECT 1 FROM paper_figure_image_sweep_state
            WHERE singleton = 1 AND completed_at IS NULL
        """) { _ in
            pending = true
        }
        return pending
    }

    func completePaperFigureImageSweep(removedDirectoryCount: Int) throws {
        try execBind("""
            UPDATE paper_figure_image_sweep_state
            SET completed_at = ?, removed_directory_count = ?, last_error = NULL
            WHERE singleton = 1
        """) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 2, Int32(removedDirectoryCount))
        }
    }

    /// Records why a sweep stopped without marking it done, so the next launch
    /// picks the remaining directories up rather than declaring victory.
    func recordPaperFigureImageSweepFailure(message: String) throws {
        try execBind("""
            UPDATE paper_figure_image_sweep_state
            SET last_error = ?
            WHERE singleton = 1
        """) { stmt in
            bind(stmt, 1, String(message.prefix(500)))
        }
    }

    func paperFigureMarkdownRepairQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM paper_figure_markdown_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }
}
