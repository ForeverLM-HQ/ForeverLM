import Foundation

// MARK: - A PDF book is one file (schema 169)

/// A chapter of a PDF book as the merge reads it: where its file is and, once
/// merged, which pages of the book's file it is.
struct BookFileChapterRow: Equatable, Sendable {
    let sourceID: String
    let title: String
    /// As stored: relative to the content roots, or absolute.
    let localFilePath: String?
    let pages: Range<Int>?
}

extension KnowledgeStore {

    /// The books whose chapters are still files of their own, one row a book,
    /// until `BookFileMerge` has put the book back into one file. Local-only:
    /// what the merge changes reaches other devices as the chapters' pages and
    /// the book's file, and a Mac that holds no chapter files has nothing to
    /// merge.
    func createBookFileMergeQueue() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS book_file_merge_queue (
                book_id TEXT PRIMARY KEY,
                enqueued_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
    }

    func holdsBookFileSchema() throws -> Bool {
        let columns = try tableColumnNamesIncludingGenerated("book_sources")
        guard columns.contains("page_start"), columns.contains("page_count") else { return false }
        return try scalarInteger(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'book_file_merge_queue'"
        ) == 1
    }

    /// A chapter's pages from a row's `page_start` column and the
    /// `page_count` column after it; nil when either is missing or makes no
    /// run.
    func bookPages(_ stmt: OpaquePointer?, startColumn: Int) -> Range<Int>? {
        guard let start = optionalInt(stmt, startColumn), let count = optionalInt(stmt, startColumn + 1),
              start >= 0, count > 0 else { return nil }
        return start..<(start + count)
    }

    // MARK: The merge's queue

    /// Books still to merge, oldest first; one that failed three times waits
    /// for a build that fixes what failed.
    func dueBookFileMerges(limit: Int) throws -> [String] {
        guard try holdsBookFileSchema() else { return [] }
        var books: [String] = []
        try query(
            "SELECT book_id FROM book_file_merge_queue WHERE attempts < 3 ORDER BY attempts, enqueued_at, book_id LIMIT ?",
            [.integer(Int64(limit))]
        ) { row in
            if let id = row.text(0) { books.append(id) }
        }
        return books
    }

    /// A book's active chapters of the learner's own library, in reading order.
    func bookFileChapters(bookID: String) throws -> [BookFileChapterRow] {
        var chapters: [BookFileChapterRow] = []
        try query("""
            SELECT s.id, COALESCE(bs.title, ''), bs.local_file_path, bs.page_start, bs.page_count
            FROM group_members gm
            JOIN sources s ON s.id = gm.source_id
            JOIN book_sources bs ON bs.source_id = s.id
            WHERE gm.group_id = ? AND s.team_id IS NULL AND s.status = 'active'
            ORDER BY gm.sort_index IS NULL, gm.sort_index, bs.title COLLATE NOCASE, s.id
        """, [.text(bookID)]) { row in
            guard let id = row.text(0) else { return }
            var pages: Range<Int>?
            if let start = row.integer(3), let count = row.integer(4), start >= 0, count > 0 {
                pages = Int(start)..<Int(start + count)
            }
            chapters.append(BookFileChapterRow(sourceID: id, title: row.text(1) ?? "", localFilePath: row.text(2), pages: pages))
        }
        return chapters
    }

    /// Where every active chapter of a book, a team's copy included, is
    /// addressed: what finds an EPUB book's folder.
    func bookChapterPaths(bookID: String) throws -> [String] {
        var paths: [String] = []
        try query("""
            SELECT bs.local_file_path FROM group_members gm
            JOIN sources s ON s.id = gm.source_id
            JOIN book_sources bs ON bs.source_id = s.id
            WHERE gm.group_id = ? AND s.status = 'active' AND COALESCE(bs.local_file_path, '') != ''
            ORDER BY gm.sort_index IS NULL, gm.sort_index, s.id
        """, [.text(bookID)]) { row in
            if let path = row.text(0) { paths.append(path) }
        }
        return paths
    }

    /// Points each chapter at its pages of the book's file, queues it to be
    /// published again (the book's bytes go up once, under the book's id, and
    /// each chapter's record names them with its pages), and takes the book
    /// off the queue, in one transaction. `bookFilePath` is stored relative to
    /// the content roots, as every source path is.
    func pointBookChapters(bookID: String, bookFilePath: String, pages: [(sourceID: String, pages: Range<Int>)]) throws {
        let stored = StorageService.relativeSourcePath(bookFilePath)
        try exec("BEGIN IMMEDIATE")
        do {
            for chapter in pages {
                // The chapter's text is unchanged, so its search index stays: the index
                // records the file it was made beside, and a new path alone would have
                // every chapter of the library embedded again.
                try execute("""
                    UPDATE source_index_state SET file_path = ?
                    WHERE source_id = ?
                      AND file_path = COALESCE((SELECT local_file_path FROM book_sources WHERE source_id = ?), '')
                """, [.text(stored), .text(chapter.sourceID), .text(chapter.sourceID)])
                // So does its figure index, whose figures count pages from the chapter's
                // first page as they did: it is filed under the chapter's pages of the book.
                let indexedPath = SourcePDFPages.stored(path: stored, pages: chapter.pages)
                for table in ["paper_figure_index_state", "paper_figure_index_queue"] {
                    try execute("""
                        UPDATE \(table) SET pdf_path = ?
                        WHERE source_id = ?
                          AND pdf_path = (SELECT local_file_path FROM book_sources WHERE source_id = ?)
                    """, [.text(indexedPath), .text(chapter.sourceID), .text(chapter.sourceID)])
                }
                try execute("""
                    UPDATE book_sources SET local_file_path = ?, page_start = ?, page_count = ?
                    WHERE source_id = ?
                """, [
                    .text(stored), .integer(Int64(chapter.pages.lowerBound)), .integer(Int64(chapter.pages.count)),
                    .text(chapter.sourceID),
                ])
                try queueSourceFilesRefresh(sourceID: chapter.sourceID)
            }
            try execute("DELETE FROM book_file_merge_queue WHERE book_id = ?", [.text(bookID)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func failBookFileMerge(bookID: String, message: String) throws {
        try execute(
            "UPDATE book_file_merge_queue SET attempts = attempts + 1, last_error = ? WHERE book_id = ?",
            [.text(message), .text(bookID)]
        )
    }

    /// The archived chapter of `bookID` titled `title` (ignoring case), the
    /// most recently archived first: what a re-import of the book revives for
    /// a chapter whose address changed. A chapter revived earlier in the same
    /// import is active again, so it is never taken twice.
    func archivedBookChapter(bookID: String, title: String) -> (id: String, status: SourceStatus)? {
        var match: (id: String, status: SourceStatus)?
        try? query("""
            SELECT s.id FROM group_members gm
            JOIN sources s ON s.id = gm.source_id
            JOIN book_sources bs ON bs.source_id = s.id
            WHERE gm.group_id = ? AND s.status = 'archived' AND s.team_id IS NULL
              AND bs.title = ? COLLATE NOCASE
            ORDER BY s.archived_at DESC, s.id
            LIMIT 1
        """, [.text(bookID), .text(title)]) { row in
            if let id = row.text(0) { match = (id, .archived) }
        }
        return match
    }

    /// Takes a book off the queue with nothing done: no chapter of it is a
    /// file of its own any more, or this Mac does not hold them.
    func dropBookFileMerge(bookID: String) throws {
        try execute("DELETE FROM book_file_merge_queue WHERE book_id = ?", [.text(bookID)])
    }
}

// MARK: - A book reads the moment it is added (schema 171)

/// A book added on this Mac whose chapters are still to be found. Until they
/// are, the book reads as one entry over its whole file (`wholeBookSourceID`),
/// and `StudioViewModel.finishBookImport` does the work Add Book would otherwise make
/// the learner wait for: the metadata and paper checks, reading scanned pages,
/// and the chapter split.
struct BookImportFinishJob: Equatable, Sendable {
    let bookID: String
    /// The library's copy of the book, as stored: relative to the content
    /// roots, or absolute.
    let bookFilePath: String
    /// The entry the book reads as until its chapters are found, which the
    /// first chapter takes over; nil when the book already had chapters (a
    /// re-import), which the new ones replace.
    let wholeBookSourceID: String?
    /// The kind the learner gave the book when adding it.
    let kind: String?
    let attempts: Int
    let lastError: String?
}

extension KnowledgeStore {
    /// The books added on this Mac that are still to be finished, one row a
    /// book. Local-only: the Mac that added a book finishes it, and what the
    /// work changes (the chapters, the book's details, its file's text) reaches
    /// other devices as those records.
    func createBookImportFinishQueue() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS book_import_finish_queue (
                book_id TEXT PRIMARY KEY,
                book_file_path TEXT NOT NULL,
                whole_book_source_id TEXT,
                kind TEXT,
                enqueued_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
    }

    func holdsBookImportFinishQueue() throws -> Bool {
        try scalarInteger(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'book_import_finish_queue'"
        ) == 1
    }

    /// Puts a book on the queue, or puts it back at the start of its attempts
    /// when the learner adds it again.
    func enqueueBookImportFinish(bookID: String, bookFilePath: String, wholeBookSourceID: String?, kind: String?) throws {
        try execute("""
            INSERT INTO book_import_finish_queue (book_id, book_file_path, whole_book_source_id, kind, enqueued_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                book_file_path = excluded.book_file_path,
                whole_book_source_id = COALESCE(excluded.whole_book_source_id, book_import_finish_queue.whole_book_source_id),
                kind = COALESCE(excluded.kind, book_import_finish_queue.kind),
                enqueued_at = excluded.enqueued_at,
                attempts = 0,
                last_error = NULL
        """, [
            .text(bookID), .text(StorageService.relativeSourcePath(bookFilePath)), .text(wholeBookSourceID),
            .text(kind), .real(Date().timeIntervalSinceReferenceDate),
        ])
    }

    /// Books still to finish, oldest first. One whose finishing failed three
    /// times waits until the learner adds it again.
    func dueBookImportFinishes(limit: Int) throws -> [BookImportFinishJob] {
        guard try holdsBookImportFinishQueue() else { return [] }
        var jobs: [BookImportFinishJob] = []
        try query("""
            SELECT book_id, book_file_path, whole_book_source_id, kind, attempts, last_error
            FROM book_import_finish_queue
            WHERE attempts < 3
            ORDER BY enqueued_at, book_id
            LIMIT ?
        """, [.integer(Int64(limit))]) { row in
            guard let bookID = row.text(0), let path = row.text(1) else { return }
            jobs.append(BookImportFinishJob(
                bookID: bookID,
                bookFilePath: path,
                wholeBookSourceID: row.text(2),
                kind: row.text(3),
                attempts: Int(row.integer(4) ?? 0),
                lastError: row.text(5)
            ))
        }
        return jobs
    }

    func failBookImportFinish(bookID: String, message: String) throws {
        try execute(
            "UPDATE book_import_finish_queue SET attempts = attempts + 1, last_error = ? WHERE book_id = ?",
            [.text(message), .text(bookID)]
        )
    }

    func dropBookImportFinish(bookID: String) throws {
        try execute("DELETE FROM book_import_finish_queue WHERE book_id = ?", [.text(bookID)])
    }
}

// MARK: - Which book a file is (schema 173)

extension KnowledgeStore {
    /// The sha256 of every file a book was added from on this Mac, one row a
    /// file: what tells the same file added again from another book that has
    /// the same title. The library's copy cannot say it, since the import
    /// rewrites that copy (a scan's text layer, an EPUB's chapters); the file
    /// as it was added can. Local-only and never synced: it decides which book
    /// a file added on this Mac is, and what that changes travels as the
    /// book's own records.
    func createBookFileDigests() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS book_file_digests (
                sha256 TEXT PRIMARY KEY,
                book_id TEXT NOT NULL,
                recorded_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_book_file_digests_book ON book_file_digests(book_id)")
    }

    /// Records that the file with `sha256` is the book `bookID`. A file that
    /// named a book since removed names this one from now on.
    func recordBookFileDigest(_ sha256: String, bookID: String) throws {
        try execute("""
            INSERT INTO book_file_digests (sha256, book_id, recorded_at) VALUES (?, ?, ?)
            ON CONFLICT(sha256) DO UPDATE SET book_id = excluded.book_id, recorded_at = excluded.recorded_at
        """, [.text(sha256), .text(bookID), .real(Date().timeIntervalSinceReferenceDate)])
    }

    /// The book the file with `sha256` was added as, or nil.
    func bookID(forFileDigest sha256: String) throws -> String? {
        try scalarText("SELECT book_id FROM book_file_digests WHERE sha256 = ?", [.text(sha256)])
    }

    /// Forgets the files of a book the learner removed.
    func dropBookFileDigests(bookID: String) throws {
        try execute("DELETE FROM book_file_digests WHERE book_id = ?", [.text(bookID)])
    }

    /// Every folder under `Books/` that a book chapter's file or address, or a
    /// book's cover, names, removed chapters included, lowercased. A new book
    /// never takes one: the chapters it saved there would carry the
    /// addresses, and so the ids, of another book's chapters.
    func bookFolderNamesInUse() throws -> Set<String> {
        var names: Set<String> = []
        try query("SELECT local_file_path, url FROM book_sources", []) { row in
            for path in [row.text(0), row.text(1)] {
                if let folder = Self.bookFolderName(inStoredPath: path) { names.insert(folder.lowercased()) }
            }
        }
        try query("SELECT cover_path FROM books", []) { row in
            if let folder = Self.bookFolderName(inStoredPath: row.text(0)) { names.insert(folder.lowercased()) }
        }
        return names
    }
}
