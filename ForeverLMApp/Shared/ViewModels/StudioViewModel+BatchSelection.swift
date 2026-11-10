import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit

extension StudioViewModel {

    // MARK: - Batch Selection Actions

    /// Remove sources with a short undo window.
    ///
    /// The original records are hidden first. The destructive archive/delete
    /// workflow runs only after the Undo banner expires, so an immediate undo
    /// restores the untouched source state.
    func removeSelected(_ ids: Set<String>) async {
        let removed = articles.filter {
            ids.contains($0.id) && !hasPendingDeletion(forSourceID: $0.id)
        }
        guard !removed.isEmpty else { return }
        // Off the sidebar from here; the deferred deletion takes over once it
        // is registered, and the set empties on the way out either way.
        let removingIDs = Set(removed.map(\.id))
        sourceIDsBeingRemoved.formUnion(removingIDs)
        defer { sourceIDsBeingRemoved.subtract(removingIDs) }
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds
        let priorHiddenStates = Dictionary(uniqueKeysWithValues: removed.map { ($0.id, $0.isHidden) })

        // Every selected row disappears with the click; the writes drain
        // behind it. Awaiting the storage actor per source made a multi-select
        // removal vanish one row at a time.
        for article in removed {
            if let index = articles.firstIndex(where: { $0.id == article.id }) {
                articles[index].isHidden = true
            }
        }
        var pendingIDs = Set<String>()
        for article in removed {
            do {
                try await storage.setSourceHidden(article.id, hidden: true)
                pendingIDs.insert(article.id)
            } catch {
                if let index = articles.firstIndex(where: { $0.id == article.id }) {
                    articles[index].isHidden = priorHiddenStates[article.id] ?? false
                }
                logger.error("Failed to remove source \(article.id): \(error.localizedDescription)")
                showToast("Removing “\(article.title)” failed: \(error.localizedDescription)")
            }
        }

        guard !pendingIDs.isEmpty else { return }
        if let sel = selectedArticleId, pendingIDs.contains(sel) {
            selectedArticleId = articles.first(where: { !isSourceHidden($0) })?.id
            currentCardIndex = 0
        }
        deselectSourcesInEveryWindow(pendingIDs)

        let pendingArticles = removed.filter { pendingIDs.contains($0.id) }
        let message = pendingIDs.count == 1
            ? "Removed “\(pendingArticles[0].title)”"
            : "Removed \(pendingIDs.count) sources"
        deferDeletion(
            message: message,
            sourceIDs: pendingIDs,
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                var restoredIDs = Set<String>()
                for id in pendingIDs {
                    let wasHidden = priorHiddenStates[id] ?? false
                    do {
                        try await self.storage.setSourceHidden(id, hidden: wasHidden)
                        if let index = self.articles.firstIndex(where: { $0.id == id }) {
                            self.articles[index].isHidden = wasHidden
                        }
                        restoredIDs.insert(id)
                    } catch {
                        self.logger.error("Failed to undo source removal \(id): \(error.localizedDescription)")
                    }
                }
                if restoredIDs == pendingIDs {
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } else {
                    self.showToast("Undo failed for some sources.")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                var committedIDs = Set<String>()
                for article in pendingArticles {
                    do {
                        try await self.storage.dismissSources([article])
                        if article.sourceType == .paper && article.resolvedPDFPath == nil {
                            try await self.storage.deleteSource(article.id)
                        } else {
                            try await self.storage.setSourceHidden(article.id, hidden: false)
                            try await self.storage.archiveSource(article.id)
                        }
                        committedIDs.insert(article.id)
                    } catch {
                        let wasHidden = priorHiddenStates[article.id] ?? false
                        do {
                            try await self.storage.setSourceHidden(article.id, hidden: wasHidden)
                        } catch {
                            self.logger.error("setSourceHidden failed: \(error.localizedDescription, privacy: .public)")
                        }
                        if let index = self.articles.firstIndex(where: { $0.id == article.id }) {
                            self.articles[index].isHidden = wasHidden
                        }
                        self.logger.error("Failed to finalize source removal \(article.id): \(error.localizedDescription)")
                        self.showToast("Removing “\(article.title)” failed: \(error.localizedDescription)")
                    }
                }
                self.articles.removeAll { committedIDs.contains($0.id) }
            }
        )
    }

    /// What a sidebar removal gesture is aimed at, once book rows are read as
    /// books. On the Books tab a row is tagged with the chapter it would resume,
    /// so the Delete key and the selection menu hand over chapter ids; hiding or
    /// removing that one chapter left the book on screen with its other
    /// chapters. The gesture meant the book, and this resolves it that way.
    struct SidebarRemovalTargets: Equatable {
        /// Book group names, in the order the learner sees them (display name).
        var bookGroups: [String] = []
        /// Sources that stand for themselves, in title order.
        var sourceIDs: [String] = []

        var isEmpty: Bool { bookGroups.isEmpty && sourceIDs.isEmpty }
        var count: Int { bookGroups.count + sourceIDs.count }
    }

    /// Resolve a sidebar selection into the books and loose sources a hide or
    /// remove should act on. `expandingBooks` is true where a row stands for a
    /// whole book (the Books tab); elsewhere a chapter is just a source.
    func sidebarRemovalTargets(for ids: Set<String>, expandingBooks: Bool) -> SidebarRemovalTargets {
        var bookGroups = Set<String>()
        var sources: [StudioArticle] = []
        for id in ids {
            guard let article = articlesById[id] else { continue }
            if expandingBooks, article.sourceType == .book, let group = article.parentGroup {
                bookGroups.insert(group)
            } else {
                sources.append(article)
            }
        }
        return SidebarRemovalTargets(
            bookGroups: bookGroups.sorted { a, b in
                let (da, db) = (bookDisplayName(a), bookDisplayName(b))
                return da == db ? a < b : da.localizedStandardCompare(db) == .orderedAscending
            },
            sourceIDs: sources
                .sorted { a, b in
                    a.title == b.title ? a.id < b.id : a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
                .map(\.id)
        )
    }

    /// Hide everything a removal gesture pointed at: whole books as books, so
    /// every chapter flips together, and loose sources one by one.
    func hideSidebarRemovalTargets(_ targets: SidebarRemovalTargets) async {
        for group in targets.bookGroups {
            await setBookHidden(group, hidden: true)
        }
        await hideSources(targets.sourceIDs)
    }

    /// Remove everything a removal gesture pointed at, with the shared undo
    /// window. A book's files stay in iCloud here; deleting them as well is the
    /// book menu's own "Remove & Delete Files".
    func removeSidebarRemovalTargets(_ targets: SidebarRemovalTargets) async {
        for group in targets.bookGroups {
            await removeBookGroup(group, deleteFiles: false)
        }
        if !targets.sourceIDs.isEmpty {
            await removeSelected(Set(targets.sourceIDs))
        }
    }

    /// Remove a book after the shared undo grace period.
    func removeBookGroup(_ groupName: String, deleteFiles: Bool) async {
        guard !hasPendingDeletion(forDeletionKey: Self.bookRemovalKey(groupName)) else { return }
        let toRemove = articles.filter { $0.sourceType == .book && $0.parentGroup == groupName }
        let ids = Set(toRemove.map(\.id))
        guard !ids.isEmpty else { return }
        sourceIDsBeingRemoved.formUnion(ids)
        defer { sourceIDsBeingRemoved.subtract(ids) }
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds
        let priorHiddenStates = Dictionary(uniqueKeysWithValues: toRemove.map { ($0.id, $0.isHidden) })
        var hiddenIDs = Set<String>()
        for id in ids {
            do {
                try await storage.setSourceHidden(id, hidden: true)
                if let index = articles.firstIndex(where: { $0.id == id }) {
                    articles[index].isHidden = true
                }
                hiddenIDs.insert(id)
            } catch {
                logger.error("Failed to hide book chapter \(id): \(error.localizedDescription)")
            }
        }
        if hiddenIDs.count != ids.count {
            showToast("Some chapters of “\(bookDisplayName(groupName))” could not be removed and were kept.")
        }
        if let sel = selectedArticleId, hiddenIDs.contains(sel) {
            selectedArticleId = articles.first(where: { !isSourceHidden($0) })?.id
            currentCardIndex = 0
        }
        deselectSourcesInEveryWindow(hiddenIDs)

        guard !hiddenIDs.isEmpty else { return }
        let pendingArticles = toRemove.filter { hiddenIDs.contains($0.id) }
        let title = bookDisplayName(groupName)
        deferDeletion(
            message: "Removed “\(title)”",
            sourceIDs: hiddenIDs,
            deletionKey: Self.bookRemovalKey(groupName),
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                var restoredIDs = Set<String>()
                for id in hiddenIDs {
                    let wasHidden = priorHiddenStates[id] ?? false
                    do {
                        try await self.storage.setSourceHidden(id, hidden: wasHidden)
                        if let index = self.articles.firstIndex(where: { $0.id == id }) {
                            self.articles[index].isHidden = wasHidden
                        }
                        restoredIDs.insert(id)
                    } catch {
                        self.logger.error("Failed to undo book removal \(id): \(error.localizedDescription)")
                    }
                }
                if restoredIDs == hiddenIDs {
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } else {
                    self.showToast("Undo failed for some chapters of “\(title)”.")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.dismissSources(pendingArticles)
                    for id in hiddenIDs {
                        try await self.storage.setSourceHidden(id, hidden: false)
                        try await self.storage.archiveSource(id)
                    }
                    self.articles.removeAll { hiddenIDs.contains($0.id) }
                    if deleteFiles {
                        await self.deleteBookFiles(groupName: groupName, sources: pendingArticles)
                    }
                    // Its file, added again, is a new book.
                    do {
                        try await self.storage.dropBookFileDigests(bookID: groupName)
                    } catch {
                        self.logger.error("Could not forget the files of removed book \(groupName): \(error.localizedDescription)")
                    }
                } catch {
                    for id in hiddenIDs {
                        let wasHidden = priorHiddenStates[id] ?? false
                        do {
                            try await self.storage.setSourceHidden(id, hidden: wasHidden)
                        } catch {
                            self.logger.error("setSourceHidden failed: \(error.localizedDescription, privacy: .public)")
                        }
                        if let index = self.articles.firstIndex(where: { $0.id == id }) {
                            self.articles[index].isHidden = wasHidden
                        }
                    }
                    self.logger.error("Failed to finalize book removal \(groupName): \(error.localizedDescription)")
                    self.showToast("Removing “\(title)” failed: \(error.localizedDescription)")
                }
            }
        )
    }

    private func deleteBookFiles(groupName: String, sources: [StudioArticle]) async {
        let booksDir = (knowledgeBasePath as NSString).appendingPathComponent("Books")
        let storedPaths = sources.compactMap { $0.localFilePath ?? $0.url }
        let storedFolderName = storedPaths.first.flatMap { Self.bookFolderName(fromStoredPath: $0) }
        let sanitizedGroupName = groupName
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")

        let deletionError = await Task.detached(priority: .utility) { () -> String? in
            let fileManager = FileManager.default
            do {
                let candidates = (try? fileManager.contentsOfDirectory(atPath: booksDir)) ?? []
                if let storedFolderName,
                   let entry = candidates.first(where: { $0.lowercased() == storedFolderName }) {
                    try fileManager.removeItem(atPath: (booksDir as NSString).appendingPathComponent(entry))
                } else {
                    for entry in candidates {
                        let clean = entry
                            .replacingOccurrences(of: " ", with: "")
                            .replacingOccurrences(of: ":", with: "")
                        if clean.localizedCaseInsensitiveCompare(sanitizedGroupName) == .orderedSame {
                            try fileManager.removeItem(atPath: (booksDir as NSString).appendingPathComponent(entry))
                        }
                    }
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        StudioArticle.invalidateResolvedPathCache(forRawPaths: storedPaths)
        if let deletionError {
            logger.error("Failed to delete iCloud files for book group \(groupName): \(deletionError)")
            showToast("Deleting files for “\(bookDisplayName(groupName))” failed: \(deletionError)")
        }
    }

    /// Reorder an article before another article within the same group.
    /// Used by drop-destination reordering (replaces .onMove to avoid
    /// conflicting with .draggable on group child rows).
    func reorderArticleInGroup(_ sourceId: String, before targetId: String, inGroup groupName: String) async {
        let items = activeArticles.filter { $0.parentGroup == groupName }
            .sorted { ($0.courseSortIndex ?? Int.max) < ($1.courseSortIndex ?? Int.max) }
        guard let sourceIdx = items.firstIndex(where: { $0.id == sourceId }),
              let targetIdx = items.firstIndex(where: { $0.id == targetId }),
              sourceIdx != targetIdx else { return }
        let destination = targetIdx > sourceIdx ? targetIdx + 1 : targetIdx
        await moveBookChapters(in: groupName, from: IndexSet(integer: sourceIdx), to: destination)
    }

    /// Reorder book chapters within a group.
    func moveBookChapters(in groupName: String, from source: IndexSet, to destination: Int) async {
        // Get articles in this book group, sorted by current sort index
        var items = activeArticles.filter { $0.parentGroup == groupName }
            .sorted { ($0.courseSortIndex ?? Int.max) < ($1.courseSortIndex ?? Int.max) }

        // Perform the move
        items.move(fromOffsets: source, toOffset: destination)

        // Update sort indices and save each article
        let ordering = items.enumerated().map { ($0.element.id, $0.offset) }
        do {
            try await storage.updateBookSortOrder(ordering)
            // Update local articles array
            for (id, index) in ordering {
                if let idx = articles.firstIndex(where: { $0.id == id }) {
                    articles[idx].courseSortIndex = index
                }
            }
        } catch {
            logger.error("Failed to reorder book chapters: \(error.localizedDescription)")
        }
    }
}
