import AppKit
import Foundation
import PDFKit

/// One chapter's place in a book that is read as a single PDF document.
struct BookPDFChapterRange: Equatable {
    let sourceID: String
    let title: String
    let path: String
    /// The chapter's pages within the assembled book.
    let pageRange: Range<Int>

    var pageCount: Int { pageRange.count }
}

/// Page arithmetic for a book shown as one document.
///
/// A PDF-imported book is stored as one PDF per chapter, and everything the app
/// remembers about reading it — the resume page, the depth reached, every
/// highlight — is keyed by chapter and numbered in the chapter's own pages. The
/// reader shows the chapters end to end as one document, so this map is how a
/// page of the book turns back into "page 7 of chapter 4", and how a chapter's
/// saved page turns into the page of the book to scroll to.
struct BookPageMap: Equatable {
    struct Chapter: Equatable {
        let sourceID: String
        let title: String
        let path: String
        let pageCount: Int
    }

    /// Where a page of the book falls within its chapter.
    struct Position: Equatable {
        let chapter: BookPDFChapterRange
        /// Zero-based, in the chapter's own numbering.
        let pageInChapter: Int
    }

    /// Chapters in reading order, each occupying a contiguous run of pages.
    /// A chapter without pages is left out: it has nowhere to land.
    let chapters: [BookPDFChapterRange]

    init(chapters: [Chapter]) {
        var ranges: [BookPDFChapterRange] = []
        var next = 0
        for chapter in chapters where chapter.pageCount > 0 {
            ranges.append(BookPDFChapterRange(
                sourceID: chapter.sourceID,
                title: chapter.title,
                path: chapter.path,
                pageRange: next..<(next + chapter.pageCount)
            ))
            next += chapter.pageCount
        }
        self.chapters = ranges
    }

    var pageCount: Int { chapters.last?.pageRange.upperBound ?? 0 }
    var isEmpty: Bool { chapters.isEmpty }

    func chapterIndex(containing page: Int) -> Int? {
        chapters.firstIndex { $0.pageRange.contains(page) }
    }

    func chapter(containing page: Int) -> BookPDFChapterRange? {
        chapterIndex(containing: page).map { chapters[$0] }
    }

    func chapter(forSourceID sourceID: String) -> BookPDFChapterRange? {
        chapters.first { $0.sourceID == sourceID }
    }

    func position(ofPage page: Int) -> Position? {
        guard let chapter = chapter(containing: page) else { return nil }
        return Position(chapter: chapter, pageInChapter: page - chapter.pageRange.lowerBound)
    }

    /// The page of the book to open for a chapter: its saved page when it has
    /// one that still fits, otherwise its first page. `nil` when the chapter is
    /// not in the book.
    func page(forSourceID sourceID: String, chapterPage: Int? = nil) -> Int? {
        guard let chapter = chapter(forSourceID: sourceID) else { return nil }
        guard let chapterPage, chapterPage > 0, chapterPage < chapter.pageCount else {
            return chapter.pageRange.lowerBound
        }
        return chapter.pageRange.lowerBound + chapterPage
    }

    /// The Contents menu and chapter chevrons, with the chapter that holds
    /// `currentPage` marked. A book of one chapter has no contents to show.
    ///
    /// `sections` are each chapter's sections by source id, in the chapter's
    /// own page numbering; they are listed under their chapter at the pages of
    /// the book, and the one `currentPage` falls in is marked. A section whose
    /// page the chapter does not have is dropped.
    func navigation(
        currentPage: Int?,
        sections: [String: [BookChapterSection]] = [:]
    ) -> EPUBKitBookNavigation? {
        guard chapters.count > 1 else { return nil }
        let items = chapters.map { chapter in
            let chapterSections = (sections[chapter.sourceID] ?? [])
                .filter { $0.pageInChapter >= 0 && $0.pageInChapter < chapter.pageCount }
                .enumerated()
                .map { index, section in
                    BookNavigationSection(
                        id: "\(chapter.sourceID)#\(index)",
                        title: section.title,
                        pageIndex: chapter.pageRange.lowerBound + section.pageInChapter
                    )
                }
            return EPUBKitBookNavigationItem(
                id: chapter.sourceID,
                title: chapter.title,
                path: chapter.path,
                sections: chapterSections
            )
        }
        let currentIndex = currentPage.flatMap(chapterIndex(containing:))
        let currentSectionID: String? = currentIndex.flatMap { index in
            guard let currentPage else { return nil }
            return items[index].sections.last { $0.pageIndex <= currentPage }?.id
        }
        return EPUBKitBookNavigation(
            items: items,
            currentIndex: currentIndex,
            currentSectionID: currentSectionID
        )
    }

    /// The chapters as the PDF view's sections, so a note made on a page is
    /// filed against the chapter the page came from.
    var sections: [PDFDocumentSection] {
        chapters.map { PDFDocumentSection(sourceID: $0.sourceID, pageRange: $0.pageRange) }
    }
}

/// A book's chapter PDFs, copied in reading order into one document.
///
/// The document is assembled in memory and never written back; the chapter
/// files on disk stay exactly as ingestion left them. Pages are copied rather
/// than moved so the per-chapter documents the loader caches stay whole.
final class BookPDFAssembly: @unchecked Sendable {
    struct Input: @unchecked Sendable {
        let sourceID: String
        let title: String
        let path: String
        let document: PDFDocument
    }

    let document: PDFDocument
    let map: BookPageMap

    private init(document: PDFDocument, map: BookPageMap) {
        self.document = document
        self.map = map
    }

    /// `nil` when no chapter contributed a page.
    static func assemble(_ inputs: [Input]) -> BookPDFAssembly? {
        let document = PDFDocument()
        var chapters: [BookPageMap.Chapter] = []
        for input in inputs {
            var copied = 0
            for index in 0..<input.document.pageCount {
                guard let page = input.document.page(at: index),
                      let copy = page.copy() as? PDFPage else { continue }
                document.insert(copy, at: document.pageCount)
                copied += 1
            }
            chapters.append(BookPageMap.Chapter(
                sourceID: input.sourceID,
                title: input.title,
                path: input.path,
                pageCount: copied
            ))
        }
        let map = BookPageMap(chapters: chapters)
        guard !map.isEmpty, document.pageCount == map.pageCount else { return nil }
        return BookPDFAssembly(document: document, map: map)
    }

    /// Extracts every page's text ahead of the first search.
    ///
    /// Find runs synchronously over the whole document, and the first time
    /// through PDFKit has to extract each page's text — measured at 1.4 s for a
    /// 384-page book, after which a search takes milliseconds. Extracting off
    /// the main thread while the document is on screen is what PDFKit's own
    /// `beginFindString` does, so the reader is not made to wait for it.
    func warmPageText() {
        Task.detached(priority: .utility) { [document] in
            for index in 0..<document.pageCount {
                guard !Task.isCancelled else { return }
                _ = document.page(at: index)?.string
            }
        }
    }
}

/// A section of one chapter, in the chapter's own page numbering.
struct BookChapterSection: Equatable, Sendable {
    let title: String
    /// Zero-based page of the chapter the section opens on.
    let pageInChapter: Int
}

/// Finds the sections inside a PDF book's chapters, for the Contents menu.
///
/// Import splits a book into one PDF per chapter and keeps no bookmarks below
/// the chapter, so most chapter files carry no outline of their own. Where one
/// does, it is used as written. Otherwise the sections are read off the pages:
/// a section of a book like Cell Biology by the Numbers opens with a heading
/// set well above the body text ("What is the energy of a hydrogen bond?" at
/// 18 pt over 11 pt prose), and those headings, found by font size alone, are
/// the book's own table of contents. A chapter whose headings do not stand out
/// that clearly gets no sections rather than a guessed list.
enum BookSectionIndex {
    /// One line of a page: its text and the font size most of it is set in.
    struct Line: Equatable {
        let text: String
        let pointSize: Double?
    }

    /// A heading must be set at least this much larger than the body text.
    static let headingScale = 1.3

    private final class Entry: NSObject {
        let sections: [BookChapterSection]
        init(_ sections: [BookChapterSection]) { self.sections = sections }
    }

    /// Reading every page's fonts takes about 10 ms a page, so a chapter is
    /// read once per launch; the key carries the file's size and date, which a
    /// re-import that reuses the file name changes.
    private nonisolated(unsafe) static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 200
        return cache
    }()

    /// Each chapter's sections by source id. Chapters without any are left
    /// out. Runs for as long as reading every page takes, so call it off the
    /// main actor.
    static func sections(for inputs: [BookPDFAssembly.Input]) -> [String: [BookChapterSection]] {
        var result: [String: [BookChapterSection]] = [:]
        for input in inputs {
            guard !Task.isCancelled else { break }
            let key = cacheKey(for: input.path) as NSString
            let sections: [BookChapterSection]
            if let cached = cache.object(forKey: key) {
                sections = cached.sections
            } else {
                sections = Self.sections(of: input.document)
                cache.setObject(Entry(sections), forKey: key)
            }
            if !sections.isEmpty { result[input.sourceID] = sections }
        }
        return result
    }

    static func sections(of document: PDFDocument) -> [BookChapterSection] {
        let outlined = outlineSections(of: document)
        if !outlined.isEmpty { return outlined }
        var pages: [[Line]] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return [] }
            pages.append(document.page(at: index).map(lines(on:)) ?? [])
        }
        return headingSections(pages: pages)
    }

    /// The chapter file's own bookmarks. A chapter outline that is a single
    /// entry for the chapter itself lists its sections one level down.
    static func outlineSections(of document: PDFDocument) -> [BookChapterSection] {
        guard var level = document.outlineRoot, level.numberOfChildren > 0 else { return [] }
        if level.numberOfChildren == 1, let only = level.child(at: 0), only.numberOfChildren > 0 {
            level = only
        }
        var sections: [BookChapterSection] = []
        for index in 0..<level.numberOfChildren {
            guard let child = level.child(at: index),
                  let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty,
                  let page = child.destination?.page else { continue }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0, pageIndex < document.pageCount else { continue }
            sections.append(BookChapterSection(title: label, pageInChapter: pageIndex))
        }
        return sections.count > 1 ? sections : []
    }

    /// Section headings among a chapter's lines, page by page.
    ///
    /// The body size is the size most of the chapter's text is set in. A
    /// heading is a run of consecutive lines on one page set at least
    /// `headingScale` times larger. The chapter's first page is skipped: its
    /// large type is the chapter's own title, and a section opening there
    /// opens where the chapter does. Text that recurs on more than two pages
    /// is a running head, not a section. Of the heading sizes left, the
    /// largest that opens at least two sections is the section level — one
    /// level, so a sub-subheading never crowds the list. A chapter with more
    /// such headings than pages is not laid out in a way this reads, and
    /// gets none.
    static func headingSections(pages: [[Line]]) -> [BookChapterSection] {
        var characters: [Double: Int] = [:]
        for line in pages.joined() {
            guard let size = line.pointSize else { continue }
            characters[size, default: 0] += line.text.count
        }
        guard let body = characters.max(by: { $0.value < $1.value })?.key, body > 0 else { return [] }
        let threshold = body * headingScale

        struct Heading {
            let title: String
            let size: Double
            let page: Int
        }
        var headings: [Heading] = []
        for (pageIndex, lines) in pages.enumerated() where pageIndex > 0 {
            var parts: [String] = []
            var size: Double?
            func flush() {
                if let size, !parts.isEmpty {
                    headings.append(Heading(title: parts.joined(separator: " "), size: size, page: pageIndex))
                }
                parts = []
                size = nil
            }
            for line in lines {
                guard let lineSize = line.pointSize, lineSize >= threshold else {
                    flush()
                    continue
                }
                if let size, abs(size - lineSize) > 0.5 { flush() }
                parts.append(line.text)
                size = size ?? lineSize
            }
            flush()
        }

        let cleaned = headings.compactMap { heading -> Heading? in
            let title = heading.title
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count <= 200, title.filter(\.isLetter).count >= 3 else { return nil }
            return Heading(title: title, size: heading.size, page: heading.page)
        }
        var pagesByTitle: [String: Set<Int>] = [:]
        for heading in cleaned { pagesByTitle[heading.title.lowercased(), default: []].insert(heading.page) }
        let distinct = cleaned.filter { (pagesByTitle[$0.title.lowercased()]?.count ?? 0) <= 2 }

        var counts: [Double: Int] = [:]
        for heading in distinct { counts[(heading.size * 2).rounded() / 2, default: 0] += 1 }
        guard let level = counts.filter({ $0.value >= 2 }).keys.max() else { return [] }
        var sections: [BookChapterSection] = []
        for heading in distinct where (heading.size * 2).rounded() / 2 == level {
            // A heading PDFKit split across two runs of one page reads as one.
            if let last = sections.last, last.pageInChapter == heading.page, last.title == heading.title { continue }
            sections.append(BookChapterSection(title: heading.title, pageInChapter: heading.page))
        }
        guard sections.count >= 2, sections.count <= pages.count else { return [] }
        return sections
    }

    /// A page's lines with the size most of each is set in.
    private static func lines(on page: PDFPage) -> [Line] {
        guard let attributed = page.attributedString else { return [] }
        let text = attributed.string as NSString
        var lines: [Line] = []
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let line = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var sizes: [Double: Int] = [:]
            attributed.enumerateAttribute(.font, in: range) { value, fontRange, _ in
                guard let font = value as? NSFont else { return }
                sizes[(font.pointSize * 10).rounded() / 10, default: 0] += fontRange.length
            }
            lines.append(Line(text: line, pointSize: sizes.max { $0.value < $1.value }?.key))
        }
        return lines
    }

    private static func cacheKey(for path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(modified)"
    }
}
