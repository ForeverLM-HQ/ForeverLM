import Foundation
import PDFKit

/// Lays a library book out for the textbook reading planner
/// (docs/textbook-readings-design.md): its chapters in reading order, each
/// with the sections the chapter file carries, its pages, and what the learner
/// has done with it.
///
/// Sections are the reader's own Contents entries (`BookSectionIndex`): the
/// chapter file's bookmarks, or its headings read off the page. A chapter
/// whose file is not a PDF, or cannot be brought down from iCloud, is offered
/// whole; its pages are counted from its stored text when that has them.
enum TextbookOutlineReader {
    static func outline(bookID: String, storage: StorageService) async throws -> TextbookOutline {
        let books = try await storage.loadBooks()
        let chapters = try await storage.textbookChapterSources(bookID: bookID)
        guard books.titles[bookID] != nil || !chapters.isEmpty else {
            throw TextbookReadingError.bookNotFound(bookID)
        }
        let title = books.titles[bookID] ?? bookID
        let articles = Dictionary(
            try await storage.loadPersistedSources(ids: chapters.map(\.sourceID)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let reviewedAt = try await storage.sourceReviewDates()

        var laidOut: [TextbookOutline.Chapter] = []
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            let article = articles[chapter.sourceID]
            let text = await storage.loadSourceContent(chapter.sourceID)
            let file = await chapterFile(article)

            let pageCount = file?.pageCount ?? text.flatMap(TextbookOutline.pageCount(ofText:))
            let sections = file.map {
                TextbookOutline.sections(
                    chapterNumber: number,
                    entries: $0.sections,
                    pageCount: $0.pageCount,
                    text: text
                )
            } ?? []
            let progress: TextbookOutline.Chapter.Progress
            if reviewedAt[chapter.sourceID] != nil {
                progress = .reviewed
            } else if article?.isRead == true {
                progress = .read
            } else if article?.hasSavedReadingPosition == true {
                progress = .started
            } else {
                progress = .unread
            }
            laidOut.append(TextbookOutline.Chapter(
                handle: TextbookOutline.chapterHandle(number),
                number: number,
                sourceID: chapter.sourceID,
                title: article?.title ?? chapter.title,
                pageCount: pageCount,
                sections: sections,
                excerpt: sections.isEmpty ? TextbookOutline.chapterExcerpt(text) : "",
                progress: progress
            ))
        }
        return TextbookOutline(
            bookID: bookID,
            title: title,
            author: books.authors[bookID],
            edition: books.editions[bookID],
            chapters: laidOut
        )
    }

    /// A chapter file's page count and its sections, as zero-based pages.
    private struct ChapterFile: Sendable {
        let pageCount: Int
        let sections: [(title: String, pageIndex: Int)]
    }

    /// Reads the chapter's PDF off the main actor, downloading it from iCloud
    /// first when it was evicted. Nil for a chapter that is not a PDF here.
    private static func chapterFile(_ article: StudioArticle?) async -> ChapterFile? {
        guard let article else { return nil }
        var rawPaths = [article.url]
        if let localFilePath = article.localFilePath { rawPaths.append(localFilePath) }
        _ = await Task.detached(priority: .utility) {
            StudioArticle.warmResolvedLocalPathCache(forRawPaths: rawPaths)
        }.value
        guard let path = article.cachedResolvedPDFPath else { return nil }
        let url = URL(fileURLWithPath: path)
        if !(await AsyncPDFDocumentLoader.isLocallyAvailable(url: url)) {
            guard case .success = await AsyncPDFDocumentLoader.ensureDownloaded(url: url) else { return nil }
        }
        guard let document = await AsyncPDFDocumentLoader.load(url: url) else { return nil }
        let sendable = UncheckedPDFDocument(document: document)
        return await Task.detached(priority: .utility) {
            let sections = BookSectionIndex.sections(of: sendable.document)
            return ChapterFile(
                pageCount: sendable.document.pageCount,
                sections: sections.map { (title: $0.title, pageIndex: $0.pageInChapter) }
            )
        }.value
    }

    /// PDFKit documents are not Sendable; this one is read, never written,
    /// on the one detached task it is handed to.
    private struct UncheckedPDFDocument: @unchecked Sendable {
        let document: PDFDocument
    }
}
