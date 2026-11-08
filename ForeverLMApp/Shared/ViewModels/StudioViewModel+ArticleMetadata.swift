import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    // MARK: - Article Metadata Editing

    func renameArticle(id: String, newTitle: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return }
        var article = articles[idx]
        article.title = newTitle
        guard await persistSource(article, context: "Save title") else { return }
        // Re-apply in case a concurrent refresh replaced the articles array during
        // the await above.
        if let idx2 = articles.firstIndex(where: { $0.id == id }) {
            articles[idx2] = article
        }
    }

    @discardableResult
    func updateSourceDetails(
        id: String,
        title: String,
        author: String,
        journal: String,
        publishedYear: String
    ) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }

        func optionalValue(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var article = articles[idx]
        article.title = trimmedTitle
        article.author = optionalValue(author)
        article.journal = optionalValue(journal)
        article.publishedYear = optionalValue(publishedYear)

        // An unchanged save still reconciles: a paper the learner filled in
        // under an older build kept its stale extraction error, and reopening
        // the editor and pressing Save is the obvious way to clear it.
        guard article != articles[idx] else {
            await completePaperIngestionAfterManualMetadata(id: id)
            return true
        }
        guard await persistSource(article, context: "Save source details") else { return false }
        if let latestIndex = articles.firstIndex(where: { $0.id == id }) {
            articles[latestIndex] = article
        }
        await completePaperIngestionAfterManualMetadata(id: id)
        return true
    }

    /// Returns the editable book display title for a stable book ID.
    func bookDisplayName(_ groupName: String) -> String {
        storedBookDisplayTitle(for: groupName) ?? groupName
    }

    func displayTitle(for article: StudioArticle) -> String {
        return article.title
    }

    nonisolated static func loadEPUBChapterContent(path: String) async -> String? {
        await Task.detached(priority: .utility) {
            // A file on disk, or a chapter of an EPUB book kept as one file.
            guard let raw = EPUBBookFiles.text(atPath: path), !raw.isEmpty else {
                return nil
            }
            let lower = path.lowercased()
            if lower.hasSuffix(".htm") || lower.hasSuffix(".html") || lower.hasSuffix(".xhtml") {
                return EPUBParser.stripHTML(raw)
            }
            return raw
        }.value
    }


    /// Resolves a source's original EPUB for the sidebar's "Open EPUB in Apple
    /// Books" menu item. Answers from caches only and never stats or enumerates the
    /// filesystem; the filesystem half runs off-main in `resolveOriginalEPUBURL`.
    ///
    /// There is deliberately no main-actor blocking variant. The one that existed
    /// enumerated an iCloud-backed book directory from a `.contextMenu` builder —
    /// which macOS evaluates eagerly with the row body — and beachballed the app in
    /// `stat()` against evicted CloudDocs placeholders.
    func cachedOriginalEPUBURL(for article: StudioArticle) -> URL? {
        guard article.cachedIsEPUBChapter,
              let groupName = article.parentGroup else { return nil }
        return cachedOriginalEPUBURL(forBookGroup: groupName)
    }

    /// A book group's EPUB, answered from `bookEPUBURLs` alone. An unresolved group
    /// answers `nil` and kicks off the real lookup off-main, which publishes into
    /// `bookEPUBURLs` and re-renders the row.
    func cachedOriginalEPUBURL(forBookGroup groupName: String) -> URL? {
        if let cached = bookEPUBURLs[groupName] { return cached }
        scheduleEPUBURLResolution(forBookGroup: groupName)
        return nil
    }

    /// The main-actor half: the raw strings the off-main lookup needs. Sendable so
    /// it can cross to a detached task; `StudioArticle` is not.
    private struct EPUBLookupInputs: Sendable {
        let coverPath: String?
        let chapterRawPaths: [String]
    }

    private func epubLookupInputs(forBookGroup groupName: String) -> EPUBLookupInputs {
        let byId = articlesById
        let rawPaths = sourceIDsForGroupInOrder(groupName).compactMap { id -> String? in
            guard let article = byId[id] else { return nil }
            return article.localFilePath ?? article.url
        }
        return EPUBLookupInputs(coverPath: bookCoverPaths[groupName], chapterRawPaths: rawPaths)
    }

    /// Resolve one book group's EPUB off the main actor and publish the result.
    private func scheduleEPUBURLResolution(forBookGroup groupName: String) {
        guard !epubURLResolutionsInFlight.contains(groupName) else { return }
        epubURLResolutionsInFlight.insert(groupName)
        // Must be detached — a plain Task inherits @MainActor and would put the
        // directory enumeration back on the thread this is trying to keep clear.
        Task.detached(priority: .utility) { [weak self] in
            guard let inputs = await self?.epubLookupInputs(forBookGroup: groupName) else { return }
            let resolved = Self.resolveOriginalEPUBURL(
                coverPath: inputs.coverPath,
                chapterRawPaths: inputs.chapterRawPaths
            )
            await self?.publishEPUBURL(resolved, forBookGroup: groupName)
        }
    }

    private func publishEPUBURL(_ url: URL?, forBookGroup groupName: String) {
        bookEPUBURLs[groupName] = url
        epubURLResolutionsInFlight.remove(groupName)
    }

    /// The filesystem half of the EPUB lookup, off the main actor. Stats and
    /// enumerates directories — never call this from a view body.
    nonisolated static func resolveOriginalEPUBURL(
        coverPath: String?,
        chapterRawPaths: [String]
    ) -> URL? {
        if let coverPath,
           let coverURL = SourceService.resolveLocalFileURL(coverPath),
           let epubURL = originalEPUBURL(inBookDirectory: coverURL.deletingLastPathComponent()) {
            return epubURL
        }
        for raw in chapterRawPaths {
            guard let chapterPath = StudioArticle.resolvedLocalPath(forRawPath: raw),
                  let epubURL = originalEPUBURL(nearChapterPath: chapterPath) else { continue }
            return epubURL
        }
        return nil
    }

    func storedBookDisplayTitle(for groupName: String) -> String? {
        guard let title = bookTitles[groupName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    nonisolated static func originalEPUBURL(nearChapterPath chapterPath: String) -> URL? {
        let chapterURL = URL(fileURLWithPath: chapterPath)
        var current = chapterURL.deletingLastPathComponent()
        while current.path != "/" {
            if current.lastPathComponent == "Chapters" || current.lastPathComponent.hasSuffix("_Chapters") {
                return originalEPUBURL(inBookDirectory: current.deletingLastPathComponent())
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    nonisolated static func originalEPUBURL(inBookDirectory bookDirectory: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: bookDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return entries
            .filter { $0.pathExtension.lowercased() == "epub" }
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    static func normalizedBookMetadataValue(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bookFolderName(fromStoredPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let booksIndex = parts.firstIndex(of: "Books"),
              parts.indices.contains(booksIndex + 1) else { return nil }
        return parts[booksIndex + 1].lowercased()
    }

    /// Rename a book without changing its stable identity. Two books may
    /// share a title: a book is its id, never its name.
    func renameBook(groupName: String, newTitle: String) async {
        let value = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldTitle = bookDisplayName(groupName)
        guard !value.isEmpty, value != oldTitle else { return }

        let ids = sourceIdsForGroup(groupName)
        let oldParentGroups = Dictionary(uniqueKeysWithValues: articles
            .filter { ids.contains($0.id) }
            .map { ($0.id, $0.parentGroup) })
        bookTitles[groupName] = value

        for idx in articles.indices where ids.contains(articles[idx].id) {
            articles[idx].parentGroup = groupName
            if articles[idx].title.hasPrefix(oldTitle) {
                articles[idx].title = value + articles[idx].title.dropFirst(oldTitle.count)
            }
        }

        do {
            try await storage.renameBookGroup(from: groupName, to: value)
            for article in articles where ids.contains(article.id) {
                try? await storage.saveSource(article)
            }
        } catch {
            logger.error("Failed to rename book: \(error.localizedDescription)")
            bookTitles[groupName] = oldTitle
            for idx in articles.indices where ids.contains(articles[idx].id) {
                if let oldParentGroup = oldParentGroups[articles[idx].id] {
                    articles[idx].parentGroup = oldParentGroup
                }
                if articles[idx].title.hasPrefix(value) {
                    articles[idx].title = oldTitle + articles[idx].title.dropFirst(value.count)
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Returns the display author for a book group.
    func bookDisplayAuthor(_ groupName: String) -> String? {
        guard let author = bookAuthors[groupName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else { return nil }
        return author
    }

    /// Returns the subtitle for a book group.
    func bookDisplaySubtitle(_ groupName: String) -> String? {
        guard let subtitle = bookSubtitles[groupName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else { return nil }
        return subtitle
    }

    /// Returns the edition for a book group.
    func bookDisplayEdition(_ groupName: String) -> String? {
        guard let edition = bookEditions[groupName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !edition.isEmpty else { return nil }
        return edition
    }

    /// Returns the kind/category for a book group.
    func bookDisplayKind(_ groupName: String) -> String? {
        bookKinds[groupName]
    }

    /// All distinct book categories currently in use, sorted alphabetically.
    var allBookKinds: [String] {
        Set(allBookGroupNames.compactMap { bookKinds[$0] }).sorted()
    }

    /// Returns "PDF" or "EPUB" for a book group based on its first chapter.
    /// Cached-only: read from the sidebar's group label and from the book search
    /// filter, both of which run during body evaluation.
    func bookFormat(_ groupName: String) -> String? {
        guard let first = bookSourceArticles(for: groupName).first else { return nil }
        if first.isPDF { return "PDF" }
        if first.cachedIsEPUBChapter { return "EPUB" }
        return nil
    }

    /// Set or clear a book's author.
    func updateBookAuthor(groupName: String, author: String) async {
        await updateBookField(.author, of: groupName, to: author)
    }

    /// Set or clear a book's subtitle.
    func updateBookSubtitle(groupName: String, subtitle: String) async {
        await updateBookField(.subtitle, of: groupName, to: subtitle)
    }

    /// Set or clear a book's edition.
    func updateBookEdition(groupName: String, edition: String) async {
        await updateBookField(.edition, of: groupName, to: edition)
    }

    /// Set or clear a book's kind/category.
    func updateBookKind(groupName: String, kind: String) async {
        await updateBookField(.kind, of: groupName, to: kind)
    }

    /// Writes the one field of the one book, then shows what was stored. Only
    /// that row's column is written, so a book this view model has not loaded
    /// yet (one that arrived by sync a moment ago) is never touched, and a
    /// failed write leaves the book showing what is stored.
    private func updateBookField(_ field: KnowledgeStore.BookField, of groupName: String, to value: String) async {
        let stored: String?
        do {
            stored = try await storage.setBookField(field, of: groupName, to: value)
        } catch {
            logger.error("Failed to save the \(field.rawValue) of book \(groupName): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }
        switch field {
        case .subtitle: bookSubtitles[groupName] = stored
        case .author: bookAuthors[groupName] = stored
        case .edition: bookEditions[groupName] = stored
        case .kind: bookKinds[groupName] = stored
        }
    }
}
