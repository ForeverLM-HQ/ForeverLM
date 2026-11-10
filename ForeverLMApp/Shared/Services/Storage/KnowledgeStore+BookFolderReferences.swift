import Foundation

extension KnowledgeStore {
    /// Book folder names, as stored under `Books/<name>/` in chapter URLs and
    /// cover paths, that still carry the archive tag `BookFolderNaming` strips.
    ///
    /// This is the database half of the rename's bookkeeping. The disk half
    /// lists the `Books/` directory; this lists what the rows point at, so a
    /// launch that renamed a folder and then died before rewriting its rows
    /// still finds the work on the next run. Bounded by the number of book
    /// chapters, and only ever run from the one-time adoption, off-main.
    func referencedTaggedBookFolderNames() throws -> Set<String> {
        var names = Set<String>()
        func collect(_ path: String?) {
            guard let folder = Self.bookFolderName(inStoredPath: path),
                  BookFolderNaming.isArchiveTaggedName(folder) else { return }
            names.insert(folder)
        }
        try query("SELECT url, local_file_path FROM book_sources") { stmt in
            collect(self.string(stmt, 0))
            collect(self.string(stmt, 1))
        }
        try query("SELECT cover_path FROM books WHERE cover_path IS NOT NULL") { stmt in
            collect(self.string(stmt, 0))
        }
        return names
    }

    /// The `<name>` in a stored `…/Books/<name>/…` path, or nil when the path
    /// does not run through a book folder.
    static func bookFolderName(inStoredPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let booksIndex = components.lastIndex(of: "Books"),
              booksIndex + 2 < components.count else { return nil }
        let name = components[booksIndex + 1]
        return name.isEmpty ? nil : name
    }

    /// Rewrite every stored path under `Books/<oldName>/` to `Books/<newName>/`
    /// after that folder was renamed on disk, and queue the affected records
    /// for CloudKit so every device sees the same paths.
    ///
    /// A book chapter's path is not only where its file lives: it is the
    /// source's `url`, its `normalized_url`, its `local_file_path`, and — for
    /// books imported before the private container was retired — its `domain`.
    /// The book row points at its cover through the same folder, the embedding
    /// index fingerprints the chapter file path, and a scheduled chapter carries
    /// the URL again. All of those move together or the book breaks: a folder
    /// renamed without this leaves six books with no cover and no readable
    /// chapters, and a database rewritten without the rename does the same.
    ///
    /// The book's original file, which the importer names after the folder, is
    /// rewritten first (`/old/old.ext` → `/new/new.ext`), then the folder
    /// segment itself. Source ids are content hashes of the *original* URL and
    /// are stored, never recomputed on read, so they survive unchanged.
    ///
    /// `dismissed_sources` is left alone on purpose. Book chapters are exempt
    /// from dismissal (`dismissSource(url:title:)`), and the rows that predate
    /// that exemption become inert once the URLs they name no longer exist.
    ///
    /// - Returns: the number of chapter sources whose paths were rewritten.
    @discardableResult
    func rewriteBookFolderReferences(from oldName: String, to newName: String) throws -> Int {
        guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return 0 }

        let oldSegment = "/\(oldName)/"
        let newSegment = "/\(newName)/"
        let rewrites: [(from: String, to: String)] = [
            ("/\(oldName)/\(oldName).", "/\(newName)/\(newName)."),
            (oldSegment, newSegment),
        ]

        let sourceIDs = try matchingIDs(
            "SELECT source_id FROM book_sources",
            columns: ["url", "normalized_url", "local_file_path", "domain"],
            containing: oldSegment
        )
        let bookIDs = try matchingIDs("SELECT id FROM books", columns: ["cover_path"], containing: oldSegment)
        let scheduledIDs = try matchingIDs(
            "SELECT id FROM scheduled_sources",
            columns: ["source_url", "source_normalized_url"],
            containing: oldSegment
        )
        guard !sourceIDs.isEmpty || !bookIDs.isEmpty || !scheduledIDs.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        do {
            try rewritePathColumns(
                table: "book_sources",
                columns: ["url", "normalized_url", "local_file_path", "domain"],
                containing: oldSegment,
                rewrites: rewrites
            )
            try rewritePathColumns(table: "books", columns: ["cover_path"], containing: oldSegment, rewrites: rewrites)
            try rewritePathColumns(
                table: "source_index_state",
                columns: ["file_path"],
                containing: oldSegment,
                rewrites: rewrites
            )
            try rewritePathColumns(
                table: "scheduled_sources",
                columns: ["source_url", "source_normalized_url"],
                containing: oldSegment,
                rewrites: rewrites
            )
            if !sourceIDs.isEmpty {
                noteStoreChanged()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return sourceIDs.count
    }

    private func matchingIDs(_ select: String, columns: [String], containing needle: String) throws -> [String] {
        let predicate = columns
            .map { "instr(COALESCE(\($0), ''), ?) > 0" }
            .joined(separator: " OR ")
        var ids: [String] = []
        try queryBind("\(select) WHERE \(predicate)", bind: { stmt in
            for index in columns.indices {
                self.bind(stmt, index + 1, needle)
            }
        }) { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    private func rewritePathColumns(
        table: String,
        columns: [String],
        containing needle: String,
        rewrites: [(from: String, to: String)]
    ) throws {
        // Each column becomes REPLACE(REPLACE(col, ?, ?), ?, ?) — innermost first.
        let assignments = columns.map { column -> String in
            var expression = column
            for _ in rewrites {
                expression = "REPLACE(\(expression), ?, ?)"
            }
            return "\(column) = \(expression)"
        }.joined(separator: ", ")
        let predicate = columns
            .map { "instr(COALESCE(\($0), ''), ?) > 0" }
            .joined(separator: " OR ")
        try execBind("UPDATE \(table) SET \(assignments) WHERE \(predicate)") { stmt in
            var index = 1
            for _ in columns {
                for rewrite in rewrites {
                    self.bind(stmt, index, rewrite.from)
                    self.bind(stmt, index + 1, rewrite.to)
                    index += 2
                }
            }
            for _ in columns {
                self.bind(stmt, index, needle)
                index += 1
            }
        }
    }
}
