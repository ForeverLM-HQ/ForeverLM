import Foundation

// MARK: - A PDF book is one file (schema 169)

extension StudioViewModel {
    /// Puts each PDF book an older build split into chapter files back into one
    /// file (`BookFileMerge`), a book at a time, off the main actor, once the
    /// library has loaded. A no-op once schema 169's queue is empty.
    func runDeferredBookFileMerge() async {
        guard hasCompletedInitialQueueLoad else { return }
        do {
            for bookID in try await storage.dueBookFileMerges() {
                guard !Task.isCancelled else { return }
                await mergeBookFile(bookID)
            }
        } catch {
            logger.error("Book file merge paused: \(error.localizedDescription)")
        }
    }

    private func mergeBookFile(_ bookID: String) async {
        do {
            let rows = try await storage.bookFileChapters(bookID: bookID)
            let split = rows.filter { $0.pages == nil && $0.localFilePath?.lowercased().hasSuffix(".pdf") == true }
            // Nothing is split any more, or not every chapter is a file here: a chapter
            // that already names pages came by sync from the Mac that merged the book,
            // and the book's file follows it (`InboundSourceFiles`).
            guard !split.isEmpty, split.count == rows.count else {
                // Every chapter names pages of the book's file, which sync brought: the chapter files
                // this Mac held for the book are no one's now.
                if !rows.isEmpty, rows.allSatisfy({ $0.pages != nil }), let cover = bookCoverPaths[bookID] {
                    let folder = (StorageService.absoluteSourcePath(cover) as NSString).deletingLastPathComponent
                    await Task.detached(priority: .utility) {
                        BookFileMerge.removeLeftoverChapterFiles(inBookFolder: folder)
                    }.value
                }
                try await storage.dropBookFileMerge(bookID: bookID)
                return
            }
            let chapters = split.compactMap { row -> BookFileMerge.Chapter? in
                guard let path = row.localFilePath else { return nil }
                return BookFileMerge.Chapter(sourceID: row.sourceID, title: row.title, path: StorageService.absoluteSourcePath(path))
            }
            let merged: BookFileMerge.Merged
            do {
                merged = try await Task.detached(priority: .utility) {
                    try BookFileMerge.merge(chapters)
                }.value
            } catch BookFileMerge.Failure.chapterFileMissing {
                // This Mac does not hold the book's chapter files; the Mac that does merges it.
                try await storage.dropBookFileMerge(bookID: bookID)
                return
            }
            try await storage.pointBookChapters(bookID: bookID, bookFilePath: merged.bookPath, pages: merged.pages)
            let chapterFiles = chapters.map(\.path)
            let bookPath = merged.bookPath
            await Task.detached(priority: .utility) {
                BookFileMerge.removeChapterFiles(chapterFiles)
                _ = StudioArticle.warmResolvedLocalPathCache(forRawPaths: [bookPath])
            }.value
            await refreshMergedChapters(merged.pages.map(\.sourceID))
            logger.notice(
                "[BookImport] Put \(chapters.count) chapter files of book \(bookID, privacy: .public) back into one file (\(merged.keptBookFile ? "the book's own" : "joined", privacy: .public))"
            )
        } catch {
            logger.error("Could not put book \(bookID, privacy: .public) back into one file: \(error.localizedDescription)")
            try? await storage.failBookFileMerge(bookID: bookID, message: error.localizedDescription)
        }
    }

    /// The loaded chapters take their new file and pages. Assigned once:
    /// mutating `articles[index]` runs the array's didSet and rebuilds the
    /// sidebar indexes for every element touched.
    private func refreshMergedChapters(_ sourceIDs: [String]) async {
        let refreshed = (try? await storage.loadPersistedSources(ids: sourceIDs)) ?? []
        let byID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updated = articles
        var changed = false
        for index in updated.indices {
            guard let source = byID[updated[index].id] else { continue }
            if updated[index].localFilePath != source.localFilePath {
                updated[index].localFilePath = source.localFilePath
                changed = true
            }
            if updated[index].bookPages != source.bookPages {
                updated[index].bookPages = source.bookPages
                changed = true
            }
        }
        if changed { articles = updated }
    }
}
