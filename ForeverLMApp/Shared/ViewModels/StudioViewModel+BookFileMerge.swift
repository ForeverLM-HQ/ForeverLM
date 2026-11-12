import Foundation

// MARK: - A book is one file (schemas 169 and 170)

extension StudioViewModel {
    /// Puts each book that is split into files back into one file, a
    /// book at a time, off the main actor, once the library has loaded: a PDF
    /// book's chapter files (`BookFileMerge`), an EPUB book's unpacked folder
    /// (`EPUBBookFiles.pack`). A no-op once the queue is empty.
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
            let paths = try await storage.bookChapterPaths(bookID: bookID)
            if paths.contains(where: Self.isUnpackedEPUBChapterPath) {
                try await packEPUBBook(bookID, chapterPaths: paths)
                return
            }
            let rows = try await storage.bookFileChapters(bookID: bookID)
            let split = rows.filter { $0.pages == nil && $0.localFilePath?.lowercased().hasSuffix(".pdf") == true }
            // Nothing is split, or not every chapter is a file here: a chapter
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
            do {
                try await storage.failBookFileMerge(bookID: bookID, message: error.localizedDescription)
            } catch {
                logger.error("failBookFileMerge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A chapter addressed inside an EPUB book's `Chapters` folder.
    nonisolated static func isUnpackedEPUBChapterPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return path.contains("/\(EPUBBookFiles.rootName)/")
            && (lowered.hasSuffix(".xhtml") || lowered.hasSuffix(".html") || lowered.hasSuffix(".htm"))
    }

    /// Packs the EPUB book whose chapters are addressed in `chapterPaths` into
    /// its one file and removes the unpacked folder. The chapters keep their
    /// addresses, which now name entries of the file (`EPUBBookFiles`), so no
    /// record changes. A folder already gone, or never on this Mac, leaves
    /// nothing to do.
    private func packEPUBBook(_ bookID: String, chapterPaths: [String]) async throws {
        let folders = Set(chapterPaths.filter(Self.isUnpackedEPUBChapterPath).compactMap {
            EPUBBookFiles.split(StorageService.absoluteSourcePath($0))?.chapters
        })
        let packed = try await Task.detached(priority: .utility) { () -> Int in
            var packed = 0
            for chapters in folders.sorted() {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: chapters, isDirectory: &directory), directory.boolValue else { continue }
                let target = EPUBBookFiles.packingTarget(inFolder: (chapters as NSString).deletingLastPathComponent)
                try EPUBBookFiles.pack(
                    URL(fileURLWithPath: chapters, isDirectory: true),
                    original: target.original,
                    to: target.destination,
                    skipping: [EPUBBookDocument.fileName]
                )
                try FileManager.default.removeItem(atPath: chapters)
                packed += 1
            }
            return packed
        }.value
        try await storage.dropBookFileMerge(bookID: bookID)
        guard packed > 0 else { return }
        StudioArticle.invalidateResolvedPathCache(forRawPaths: chapterPaths)
        logger.notice("[BookImport] Packed EPUB book \(bookID, privacy: .public) into one file")
    }

    /// The loaded chapters take their new file and pages. Assigned once:
    /// mutating `articles[index]` runs the array's didSet and rebuilds the
    /// sidebar indexes for every element touched.
    private func refreshMergedChapters(_ sourceIDs: [String]) async {
        let refreshed = (await loggedRead("persisted sources") { try await storage.loadPersistedSources(ids: sourceIDs) }) ?? []
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
