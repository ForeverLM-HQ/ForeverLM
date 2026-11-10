import AppKit
import Foundation
import PDFKit
import SQLite3
import Testing
@testable import ForeverLM

/// A PDF book kept as one file (schema 169; docs/backend-storage-sync.md, "A PDF book is one
/// file"): a chapter is a run of the book file's pages, everything stored about it still counts
/// pages from its first, and a book an older build split into chapter files is put back into one.
enum BookFileFixture {
    /// A PDF whose every page shows its own label and a box of its own size and place, so no two
    /// pages render alike.
    static func book(_ labels: [String], at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for (index, label) in labels.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(
                x: 20 + CGFloat(index % 5) * 40, y: 40 + CGFloat(index / 5) * 50,
                width: 60, height: 30 + CGFloat(index) * 4
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 28)])
                .draw(at: CGPoint(x: 30, y: 300))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// `pages` of the book at `book`, written as a chapter file the way builds before 169 split a
    /// book: a fresh document, written by PDFKit, with `sections` as its own bookmarks.
    static func chapter(_ pages: Range<Int>, of book: URL, to url: URL, sections: [(String, Int)] = []) throws {
        let document = try #require(PDFDocument(url: book))
        let chapter = PDFDocument()
        for index in pages {
            chapter.insert(try #require(document.page(at: index)?.copy() as? PDFPage), at: chapter.pageCount)
        }
        if !sections.isEmpty {
            let root = PDFOutline()
            for (title, page) in sections {
                let item = PDFOutline()
                item.label = title
                item.destination = PDFDestination(page: try #require(chapter.page(at: page)), at: .zero)
                root.insertChild(item, at: root.numberOfChildren)
            }
            chapter.outlineRoot = root
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(chapter.write(to: url))
    }

    static func folder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookFile-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static let labels = ["cover", "contents", "a one", "a two", "a three", "b one", "b two", "index"]
}

@Suite("SourcePDFPages")
struct SourcePDFPagesTests {
    @Test("A chapter is its pages of the book's file, numbered from its first")
    func chapterDocument() throws {
        let folder = try BookFileFixture.folder("pages")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Book.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: url)

        let chapter = SourcePDFPages(path: url.path, pages: 5..<7)
        let document = try #require(chapter.document())
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("b one") == true)
        #expect(document.page(at: 1)?.string?.contains("b two") == true)
        #expect(chapter.filePage(0) == 5)
        #expect(chapter.filePage(1) == 6)
        #expect(chapter.filePage(2) == nil)
        #expect(SourcePDFPages(path: url.path).document()?.pageCount == 8)
        // Pages the file does not hold are never shown as other pages of the book.
        #expect(SourcePDFPages(path: url.path, pages: 6..<10).document() == nil)
    }

    @Test("The stored form names the file and the chapter's pages, and reads back")
    func storedForm() {
        let stored = SourcePDFPages.stored(path: "Books/Foo/Foo.pdf", pages: 12..<40)
        #expect(stored == "Books/Foo/Foo.pdf#pages=12..<40")
        #expect(SourcePDFPages(stored: stored) == SourcePDFPages(path: "Books/Foo/Foo.pdf", pages: 12..<40))
        #expect(SourcePDFPages(stored: "Books/Foo/Chapters/01 One.pdf") == SourcePDFPages(path: "Books/Foo/Chapters/01 One.pdf"))
        #expect(SourcePDFPages(stored: "Books/Foo/Foo.pdf#pages=9..<3").pages == nil)
        #expect(SourcePDFPages(path: "/b.pdf", pages: 0..<4).cacheKey != SourcePDFPages(path: "/b.pdf", pages: 4..<9).cacheKey)
    }

    @Test("A new chapter is addressed by its book's file at its first page, one address and one id a chapter")
    func chapterAddress() {
        let first = StudioArticle.bookChapterURL(bookFilePath: "Books/Foo/Foo.pdf", pages: 2..<5)
        let second = StudioArticle.bookChapterURL(bookFilePath: "Books/Foo/Foo.pdf", pages: 5..<7)
        #expect(first == "Books/Foo/Foo.pdf#page=3")
        #expect(URLNormalizer.normalize(first) == first)
        #expect(SourceIdentity.stableID(for: first) != SourceIdentity.stableID(for: second))
    }
}

@Suite("BookFileMerge", .serialized)
struct BookFileMergeTests {
    /// `Books/Foo/` with chapter files cut from `cut` (pages 2..<5 and 5..<7), and `Foo.pdf`
    /// holding `bookLabels` when given.
    private func splitBook(_ name: String, bookLabels: [String]?) throws -> (folder: URL, chapters: [BookFileMerge.Chapter]) {
        let root = try BookFileFixture.folder(name)
        let folder = root.appendingPathComponent("Books/Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cut = root.appendingPathComponent("cut.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: cut)
        let first = folder.appendingPathComponent("Chapters/01 A.pdf")
        let second = folder.appendingPathComponent("Chapters/02 B.pdf")
        try BookFileFixture.chapter(2..<5, of: cut, to: first, sections: [("A.1", 0), ("A.2", 2)])
        try BookFileFixture.chapter(5..<7, of: cut, to: second)
        if let bookLabels {
            try BookFileFixture.book(bookLabels, at: folder.appendingPathComponent("Foo.pdf"))
        }
        return (folder, [
            BookFileMerge.Chapter(sourceID: "a", title: "A", path: first.path),
            BookFileMerge.Chapter(sourceID: "b", title: "B", path: second.path),
        ])
    }

    @Test("A book whose own file holds every chapter keeps that file, front matter and all")
    func keepsTheBookFile() throws {
        let (folder, chapters) = try splitBook("kept", bookLabels: BookFileFixture.labels)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let bookPath = folder.appendingPathComponent("Foo.pdf").path
        let before = try Data(contentsOf: URL(fileURLWithPath: bookPath))

        let merged = try BookFileMerge.merge(chapters)

        #expect(merged.keptBookFile)
        #expect(merged.bookPath == bookPath)
        #expect(merged.pages.map(\.sourceID) == ["a", "b"])
        #expect(merged.pages.map(\.pages) == [2..<5, 5..<7])
        #expect(try Data(contentsOf: URL(fileURLWithPath: bookPath)) == before, "the book's file is untouched")
    }

    @Test("Chapters that are no run of the book's file are joined into it, each a bookmark over its own")
    func joinsWhenTheBookFileDiffers() throws {
        let (folder, chapters) = try splitBook("joined", bookLabels: ["other one", "other two", "other three"])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }

        let merged = try BookFileMerge.merge(chapters)

        #expect(!merged.keptBookFile)
        #expect(merged.pages.map(\.pages) == [0..<3, 3..<5])
        let book = try #require(PDFDocument(url: URL(fileURLWithPath: merged.bookPath)))
        #expect(merged.bookPath == folder.appendingPathComponent("Foo.pdf").path)
        #expect(book.pageCount == 5)
        #expect(book.page(at: 3)?.string?.contains("b one") == true)
        let outline = try #require(book.outlineRoot)
        #expect(outline.numberOfChildren == 2)
        #expect(outline.child(at: 0)?.label == "A")
        #expect(outline.child(at: 0)?.numberOfChildren == 2, "the chapter file's own bookmarks stay under it")
        #expect(outline.child(at: 1)?.destination?.page.map { book.index(for: $0) } == 3)
        // The reader reads a chapter's sections off the book's bookmarks inside its pages.
        #expect(BookSectionIndex.sections(of: book, pages: 0..<3).map(\.title) == ["A.1", "A.2"])
        #expect(BookSectionIndex.sections(of: book, pages: 0..<3).map(\.pageInChapter) == [0, 2])
    }

    @Test("A book with no file of its own is joined")
    func joinsWithoutABookFile() throws {
        let (folder, chapters) = try splitBook("no-book", bookLabels: nil)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let merged = try BookFileMerge.merge(chapters)
        #expect(!merged.keptBookFile)
        #expect(merged.pages.map(\.pages) == [0..<3, 3..<5])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Foo.pdf").path))
    }

    @Test("A chapter file this Mac does not hold is nothing to merge here")
    func missingChapter() throws {
        let (folder, chapters) = try splitBook("missing", bookLabels: BookFileFixture.labels)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.removeItem(atPath: chapters[1].path)
        #expect(throws: BookFileMerge.Failure.chapterFileMissing(chapters[1].path)) { try BookFileMerge.merge(chapters) }
    }

    @Test("The same page renders alike whoever wrote it; a neighbouring page does not")
    func pageRenders() throws {
        let (folder, chapters) = try splitBook("renders", bookLabels: BookFileFixture.labels)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let book = try #require(PDFDocument(url: folder.appendingPathComponent("Foo.pdf")))
        let chapter = try #require(PDFDocument(url: URL(fileURLWithPath: chapters[0].path)))
        let fromChapter = try #require(chapter.page(at: 0).flatMap(BookFileMerge.PageRender.init))
        let same = try #require(book.page(at: 2).flatMap(BookFileMerge.PageRender.init))
        let next = try #require(book.page(at: 3).flatMap(BookFileMerge.PageRender.init))
        #expect(fromChapter.matches(same))
        #expect(!fromChapter.matches(next))
    }

    @Test("The chapter files go once the chapters read the book, and their folder with them")
    func removesChapterFiles() throws {
        let (folder, chapters) = try splitBook("remove", bookLabels: BookFileFixture.labels)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        BookFileMerge.removeChapterFiles(chapters.map(\.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Chapters").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Foo.pdf").path))
    }
}

@Suite("BookPageMap placed in one file")
struct BookPageMapPlacedTests {
    @Test("A book kept as one file is shown as that file, front matter and all, with nothing copied")
    func oneFile() throws {
        let folder = try BookFileFixture.folder("placed")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Book.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: url)
        let book = try #require(PDFDocument(url: url))

        let assembly = try #require(BookPDFAssembly.assemble([
            .init(sourceID: "a", title: "A", path: url.path, document: book, pages: 2..<5),
            .init(sourceID: "b", title: "B", path: url.path, document: book, pages: 5..<7),
        ]))
        #expect(assembly.document === book)
        #expect(assembly.map.pageCount == 8)
        #expect(assembly.map.position(ofPage: 0) == nil, "the cover is no chapter's")
        #expect(assembly.map.position(ofPage: 6)?.chapter.sourceID == "b")
        #expect(assembly.map.position(ofPage: 6)?.pageInChapter == 1)
        #expect(assembly.map.page(forSourceID: "b", chapterPage: 1) == 6)
        #expect(assembly.map.page(forSourceID: "a") == 2)
    }

    @Test("Runs that overlap or leave the file are no placement, and the chapters' pages are copied")
    func badRunsAreCopied() throws {
        #expect(BookPageMap(placed: [
            BookPDFChapterRange(sourceID: "a", title: "A", path: "/b.pdf", pageRange: 0..<4),
            BookPDFChapterRange(sourceID: "b", title: "B", path: "/b.pdf", pageRange: 3..<6),
        ], pageCount: 8) == nil)
        #expect(BookPageMap(placed: [
            BookPDFChapterRange(sourceID: "a", title: "A", path: "/b.pdf", pageRange: 6..<9),
        ], pageCount: 8) == nil)

        let folder = try BookFileFixture.folder("overlap")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Book.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: url)
        let book = try #require(PDFDocument(url: url))
        let assembly = try #require(BookPDFAssembly.assemble([
            .init(sourceID: "a", title: "A", path: url.path, document: book, pages: 2..<5),
            .init(sourceID: "b", title: "B", path: url.path, document: book, pages: 4..<7),
        ]))
        #expect(assembly.document !== book)
        #expect(assembly.document.pageCount == 6)
        #expect(assembly.map.chapters.map(\.pageRange) == [0..<3, 3..<6])
    }
}

@Suite("Book file storage", .serialized)
struct BookFileStorageTests {
    private static let bookID = "BOOK-0001"

    private static func addChapter(
        _ store: KnowledgeStore, _ id: String, book: String = bookID, path: String, pages: Range<Int>? = nil,
        status: String = "active", sortIndex: Int = 0, title: String? = nil
    ) throws {
        let start = pages.map { "\($0.lowerBound)" } ?? "NULL"
        let count = pages.map { "\($0.count)" } ?? "NULL"
        try store.execForTesting("""
            INSERT OR IGNORE INTO books (id, title) VALUES ('\(book)', 'A Book');
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('\(id)', 0, 'ready', 'book', '\(status)');
            INSERT INTO book_sources (source_id, url, local_file_path, title, page_start, page_count)
            VALUES ('\(id)', '\(path)', '\(path)', '\(title ?? id)', \(start), \(count));
            INSERT INTO group_members (source_id, group_id, sort_index) VALUES ('\(id)', '\(book)', \(sortIndex));
        """)
    }

    @Test("A fresh store has the chapters' page columns and the merge queue")
    func freshStore() throws {
        let store = try KnowledgeStore(inMemory: true)
        #expect(try store.holdsBookFileSchema())
        #expect(try store.dueBookFileMerges(limit: 10).isEmpty)
    }

    @Test("A merged book's chapters point at their pages, keeping their search and figure indexes, and leave the queue")
    func pointsChapters() throws {
        let store = try KnowledgeStore(inMemory: true)
        try Self.addChapter(store, "c1", path: "Books/Foo/Chapters/01 A.pdf", sortIndex: 0)
        try Self.addChapter(store, "c2", path: "Books/Foo/Chapters/02 B.pdf", sortIndex: 1)
        try store.execForTesting("""
            INSERT INTO source_index_state (source_id, model, content_length, file_path, indexed_at)
            VALUES ('c1', 'model', 10, 'Books/Foo/Chapters/01 A.pdf', 0);
            INSERT INTO paper_figure_index_state (source_id, pdf_path, index_version, page_count, indexed_at)
            VALUES ('c2', 'Books/Foo/Chapters/02 B.pdf', 1, 2, 0);
        """)
        try store.enqueueSplitBookMerge()
        #expect(try store.bookFileChapters(bookID: Self.bookID).map(\.sourceID) == ["c1", "c2"])

        try store.pointBookChapters(bookID: Self.bookID, bookFilePath: "Books/Foo/Foo.pdf", pages: [("c1", 2..<5), ("c2", 5..<7)])

        let c2 = try #require(try store.loadSourceForSync("c2"))
        #expect(c2.bookPages == 5..<7)
        #expect(c2.localFilePath?.hasSuffix("Books/Foo/Foo.pdf") == true)
        #expect(try store.scalarText("SELECT file_path FROM source_index_state WHERE source_id = 'c1'") == "Books/Foo/Foo.pdf")
        #expect(try store.scalarText("SELECT pdf_path FROM paper_figure_index_state WHERE source_id = 'c2'") == "Books/Foo/Foo.pdf#pages=5..<7")
        #expect(try store.dueBookFileMerges(limit: 10).isEmpty)
        // The figure index reads a chapter as its pages of the book's file.
        #expect(try store.scalarText("""
            SELECT p.local_file_path FROM \(KnowledgeStore.figureIndexableSourcesSQL) p WHERE p.source_id = 'c1'
        """) == "Books/Foo/Foo.pdf#pages=2..<5")
    }

    @Test("A chapter's pages are saved and read back with it")
    func pagesRoundTrip() throws {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(
            url: StudioArticle.bookChapterURL(bookFilePath: "Books/Foo/Foo.pdf", pages: 12..<40),
            title: "Water", sourceType: .book, localFilePath: "Books/Foo/Foo.pdf"
        )
        // A ready source holds its text.
        article.content = "Water is a polar molecule."
        article.state = .ready
        article.bookPages = 12..<40
        try store.saveSource(article)
        #expect(try store.loadSourceForSync(article.id)?.bookPages == 12..<40)
    }

    @Test("Two chapters of one book's file are two sources, and neither takes the file's key")
    func chaptersShareTheFile() throws {
        let (root, store) = try SourceSyncFixture.makeStore("book-file-keys")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Foo.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: book)
        var ids: [String] = []
        for pages in [2..<5, 5..<7] {
            var article = StudioArticle(
                url: StudioArticle.bookChapterURL(bookFilePath: book.path, pages: pages),
                title: "Chapter \(pages.lowerBound)", sourceType: .book, localFilePath: book.path
            )
            article.content = "Chapter text."
            article.state = .ready
            article.bookPages = pages
            #expect(try store.insertSourceIfNew(&article))
            ids.append(article.id)
        }
        #expect(Set(ids).count == 2)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_work_keys WHERE work_key LIKE 'file:%'") == 0)
        // A chapter that is a file of its own is still found by its file; one of a book's file is not.
        #expect(store.sourceExistsByBookLocalFilePath(book.path) == nil)
    }

    @Test("Unarchiving a PDF book's chapter never makes the PDF's bytes its text; a text file still gives its text")
    func unarchiveKeepsPDFBytesOut() throws {
        let folder = try BookFileFixture.folder("unarchive-pdf")
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = folder.appendingPathComponent("Book.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: book)
        let store = try KnowledgeStore(inMemory: true)
        var chapter = StudioArticle(
            url: StudioArticle.bookChapterURL(bookFilePath: book.path, pages: 2..<5),
            title: "Water", sourceType: .book, localFilePath: book.path
        )
        chapter.content = "Water is a polar molecule."
        chapter.state = .ready
        chapter.bookPages = 2..<5
        #expect(try store.insertSourceIfNew(&chapter))
        try store.archiveSource(chapter.id)

        let outcome = try store.unarchiveSourceRestoringContent(chapter.id)
        #expect(outcome?.rebuiltContent == false)
        #expect(try store.loadSourceForSync(chapter.id)?.content?.hasPrefix("%PDF") != true)
        #expect(KnowledgeStore.textOfLocalFile(atPath: book.path) == nil)

        let notes = folder.appendingPathComponent("notes.txt")
        try Data("Plain notes".utf8).write(to: notes)
        #expect(KnowledgeStore.textOfLocalFile(atPath: notes.path) == "Plain notes")
        let page = folder.appendingPathComponent("page.xhtml")
        try Data([0x3C, 0x70, 0x3E, 0x63, 0x61, 0x66, 0xE9, 0x3C, 0x2F, 0x70, 0x3E]).write(to: page)
        #expect(KnowledgeStore.textOfLocalFile(atPath: page.path) == "<p>café</p>", "a Latin-1 EPUB document still reads")
    }

    @Test("A re-import finds a chapter by its title among the ones it archived, and takes each once")
    func reimportByTitle() throws {
        let store = try KnowledgeStore(inMemory: true)
        try Self.addChapter(store, "old-water", path: "Books/Foo/Chapters/01 Water.pdf", status: "archived", title: "Water")
        try Self.addChapter(store, "old-ions", path: "Books/Foo/Chapters/02 Ions.pdf", status: "archived", title: "Ions")
        #expect(store.archivedBookChapter(bookID: Self.bookID, title: "water")?.id == "old-water")
        try store.execForTesting("UPDATE sources SET status = 'active' WHERE id = 'old-water'")
        #expect(store.archivedBookChapter(bookID: Self.bookID, title: "Water") == nil)
        #expect(store.archivedBookChapter(bookID: "another-book", title: "Ions") == nil)
    }
}

@Suite("Book chapter sync")
struct BookChapterSyncTests {
    private typealias Fixture = SourceSyncFixture
    private static let bookID = "BOOK-SYNC-0001"

    private static let bookBytes = Data("%PDF-book".utf8)

    /// The book's file as its record names it: the hash and size of `bookBytes`, which the reader checks
    /// before it installs anything.
    private static func bookFile(owner: String = bookID) -> FileRef {
        FileRef(owner: owner, role: "pdf", hash: SyncIdentity.sha256Hex(bookBytes), size: Int64(bookBytes.count),
                mime: "application/pdf", encoding: "identity", storedParts: [bookBytes])
    }

    private static func chapter(_ pages: Range<Int>?, url: String = "Books/Foo/Foo.pdf#page=13") -> [String: SyncJSON] {
        var meta: [String: SyncJSON] = ["bookID": .string(bookID)]
        if let pages {
            meta["pageStart"] = SyncJSON(pages.lowerBound)
            meta["pageCount"] = SyncJSON(pages.count)
        }
        return [
            "type": "book", "title": "Water", "url": .string(url), "status": "active",
            "ingest": .object(["ord": .array([0, 1]), "state": "ready"]),
            "collectionID": .string(bookID), "collectionOrder": .string(SourceOrderKeys.key(forIndex: 0) ?? ""),
            "files": .object(["pdf": bookFile().value]),
            "meta": .object(meta), "addedAt": SyncJSON(Int64(1_759_000_000_000)),
        ]
    }

    @Test("A chapter's pages of its book's file travel in meta and land in its columns")
    func pagesRoundTrip() throws {
        let (root, store) = try Fixture.makeStore("book-pages")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try store.execForTesting("INSERT INTO books (id, title) VALUES ('\(Self.bookID)', 'Foo')")
        try Fixture.apply(store, [try Fixture.record(.source, "src-water", Self.chapter(12..<32))])

        #expect(try Fixture.text(store, "SELECT page_start || '|' || page_count FROM book_sources WHERE source_id = 'src-water'") == "12|20")
        let rows = try #require(try SourceProjection.loadRows(localID: "src-water", connection: store))
        let meta = SourceProjection.encodeRows(rows)["meta"]?.objectValue ?? [:]
        #expect(meta["pageStart"] == SyncJSON(12))
        #expect(meta["pageCount"] == SyncJSON(20))
        #expect(try Fixture.pending(store)["Source:src-water"] == nil, "an applied record has nothing to send back")

        // A local change of the pages sends them.
        try store.execForTesting("UPDATE book_sources SET page_start = 13 WHERE source_id = 'src-water'")
        let change = try #require(try Fixture.pending(store)["Source:src-water"])
        #expect(Fixture.savedFields(change)?["meta"]?["pageStart"] == SyncJSON(13))
    }

    @Test("A file this Mac held as the chapter's own is let go once the record names pages of the book")
    func releasesTheChapterFile() throws {
        let (root, store) = try Fixture.makeStore("book-release")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try store.execForTesting("INSERT INTO books (id, title) VALUES ('\(Self.bookID)', 'Foo')")
        try Fixture.apply(store, [try Fixture.record(.source, "src-water", Self.chapter(nil, url: "Books/Foo/Chapters/01 Water.pdf"))])
        try store.execForTesting("UPDATE book_sources SET local_file_path = 'Books/Foo/Chapters/01 Water.pdf' WHERE source_id = 'src-water'")

        try Fixture.apply(store, [try Fixture.record(.source, "src-water", Self.chapter(12..<32, url: "Books/Foo/Chapters/01 Water.pdf"))])
        #expect(try Fixture.text(store, "SELECT COALESCE(local_file_path, 'none') FROM book_sources WHERE source_id = 'src-water'") == "none")

        // The book's file once here, the same pages again leave it be.
        try store.execForTesting("UPDATE book_sources SET local_file_path = 'Books/synced-book.pdf' WHERE source_id = 'src-water'")
        try Fixture.apply(store, [try Fixture.record(.source, "src-water", Self.chapter(12..<32, url: "Books/Foo/Chapters/01 Water.pdf"))])
        #expect(try Fixture.text(store, "SELECT local_file_path FROM book_sources WHERE source_id = 'src-water'") == "Books/synced-book.pdf")
    }

    @Test("A chapter arriving after another of its book reads the file that one brought, with nothing fetched")
    func pointsAtTheInstalledBook() throws {
        let (root, store) = try Fixture.makeStore("book-installed")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try store.execForTesting("INSERT INTO books (id, title) VALUES ('\(Self.bookID)', 'Foo')")
        try Fixture.apply(store, [try Fixture.record(.source, "src-water", Self.chapter(12..<32))])
        // The first chapter's book file is wanted, then installed.
        #expect(try InboundSourceFiles.waiting(sourceID: "src-water", connection: store)[InboundSourceFiles.pdfRole] != nil)
        try store.replica.apply { _ in
            _ = try InboundSourceFiles.receivedPDF(
                Self.bookBytes, installedPath: "Books/synced-book.pdf", sourceID: "src-water", connection: store
            )
        }
        #expect(try Fixture.text(store, "SELECT local_file_path FROM book_sources WHERE source_id = 'src-water'") == "Books/synced-book.pdf")

        try Fixture.apply(store, [try Fixture.record(.source, "src-ions", Self.chapter(32..<50, url: "Books/Foo/Foo.pdf#page=33"))])
        #expect(try Fixture.text(store, "SELECT local_file_path FROM book_sources WHERE source_id = 'src-ions'") == "Books/synced-book.pdf")
        #expect(try InboundSourceFiles.waiting(sourceID: "src-ions", connection: store).isEmpty)
    }

    @Test("A chapter's PDF goes up as its book's file under the book, and gives no chapter its key")
    func publishesUnderTheBook() throws {
        let (root, store) = try Fixture.makeStore("book-publish")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Foo.pdf")
        try BookFileFixture.book(BookFileFixture.labels, at: book)
        try store.execForTesting("""
            INSERT INTO books (id, title) VALUES ('\(Self.bookID)', 'Foo');
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('src-water', 0, 'ready', 'book', 'active');
            INSERT INTO book_sources (source_id, url, local_file_path, title, page_start, page_count)
            VALUES ('src-water', 'Books/Foo/Foo.pdf#page=3', 'Books/Foo/Foo.pdf', 'Water', 2, 3);
            INSERT INTO group_members (source_id, group_id, sort_index) VALUES ('src-water', '\(Self.bookID)', 0);
        """)
        let plan = try KnowledgeStore.$sourceFileLocationOverride.withValue({ _ in book }) {
            try store.sourcePublishPlan(sourceID: "src-water")
        }
        let pdf = try #require(plan?.items.first { $0.role == "pdf" })
        #expect(pdf.owner?.id == Self.bookID)
        #expect(pdf.owner?.type == .collection)

        try store.pointPublishedSourceFiles(sourceID: "src-water", files: [(.files, Self.bookFile(), "Books/Foo/Foo.pdf")])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_work_keys WHERE source_id = 'src-water' AND work_key LIKE 'file:%'") == 0)
        // A paper's own file keeps its key, as before.
        try store.pointPublishedSourceFiles(sourceID: "src-water", files: [(.files, Self.bookFile(owner: "src-water"), "Books/Foo/Foo.pdf")])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_work_keys WHERE source_id = 'src-water' AND work_key LIKE 'file:%'") == 1)
    }
}

/// A book reads the moment it is added (schema 171): Add Book saves it as one entry over its whole
/// file and queues the rest — its details, the paper check, a scan's text, the chapter split — in
/// `book_import_finish_queue`, which a quit does not lose.
@Suite("Book import finish queue", .serialized)
struct BookImportFinishQueueTests {
    @Test("A book waits until it is dropped; three failures park it until it is added again")
    func queueKeepsABookUntilFinished() throws {
        let root = try Schema154Fixture.temporaryRoot("book-import-finish-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)

        try store.enqueueBookImportFinish(bookID: "older", bookFilePath: "/tmp/Books/Older/Older.pdf", wholeBookSourceID: nil, kind: nil)
        try store.enqueueBookImportFinish(bookID: "book", bookFilePath: "/tmp/Books/Book/Book.pdf", wholeBookSourceID: "whole", kind: "Textbook")
        var due = try store.dueBookImportFinishes(limit: 10)
        #expect(due.map(\.bookID) == ["older", "book"])
        #expect(due[1].wholeBookSourceID == "whole" && due[1].kind == "Textbook" && due[1].attempts == 0)

        for _ in 0..<3 { try store.failBookImportFinish(bookID: "book", message: "The split failed.") }
        #expect(try store.dueBookImportFinishes(limit: 10).map(\.bookID) == ["older"])

        // Added again: its attempts start over, and it keeps the entry it reads as.
        try store.enqueueBookImportFinish(bookID: "book", bookFilePath: "/tmp/Books/Book/Book.pdf", wholeBookSourceID: nil, kind: nil)
        due = try store.dueBookImportFinishes(limit: 10)
        let again = try #require(due.first { $0.bookID == "book" })
        #expect(again.attempts == 0 && again.lastError == nil && again.wholeBookSourceID == "whole")

        try store.dropBookImportFinish(bookID: "book")
        try store.dropBookImportFinish(bookID: "older")
        #expect(try store.dueBookImportFinishes(limit: 10).isEmpty)
        // Local work: nothing here reaches another device.
    }

    @Test("The split's chapters stretch to hold a page marked or reached before they were found")
    func chaptersHoldTheLearnersPages() {
        let split: [(title: String, pageIndex: Int, endPageIndexExclusive: Int)] = [
            ("One", 10, 40), ("Two", 40, 90),
        ]
        let untouched = StudioViewModel.chapters(split, reachingPages: [12, 60], pageCount: 120)
        #expect(untouched.map(\.pageIndex) == [10, 40] && untouched.map(\.endPageIndexExclusive) == [40, 90])
        // A mark in the preface and the index the split left out.
        let stretched = StudioViewModel.chapters(split, reachingPages: [3, 101], pageCount: 120)
        #expect(stretched.map(\.pageIndex) == [3, 40] && stretched.map(\.endPageIndexExclusive) == [40, 102])
        #expect(stretched.map(\.title) == ["One", "Two"])
        // A page outside the file changes nothing.
        let outside = StudioViewModel.chapters(split, reachingPages: [500], pageCount: 120)
        #expect(outside.map(\.endPageIndexExclusive) == [40, 90])
    }

    @Test("A mark moves to its chapter as the same mark, its page counted from the chapter's first")
    func markMovesToItsChapter() {
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        let mark = SourceHighlight(
            id: "mark",
            sourceID: "whole",
            quote: "the membrane holds a charge",
            note: "Why a charge?",
            color: .default,
            anchor: ReaderTextAnchor(exact: "the membrane holds a charge", prefix: "so ", suffix: ".", offset: 4_000),
            pdfAnchor: ReaderPDFAnchor(pageIndex: 57, rects: [CGRect(x: 20, y: 100, width: 60, height: 14)]),
            chatSessionID: "chat",
            createdAt: made,
            updatedAt: made
        )
        let moved = StudioViewModel.highlight(mark, movedTo: "chapter-3", page: 17)
        #expect(moved.id == "mark" && moved.sourceID == "chapter-3")
        #expect(moved.pdfAnchor?.pageIndex == 17)
        #expect(moved.pdfAnchor?.rects == mark.pdfAnchor?.rects)
        #expect(moved.quote == mark.quote && moved.note == mark.note && moved.anchor == mark.anchor)
        #expect(moved.chatSessionID == "chat" && moved.createdAt == made && moved.updatedAt > made)
    }
}

/// A book is the same book only when it is the same file (schema 173): Add Book matched a book by
/// its title, so a second book called "Bioenergetics" took the first one's row and archived its
/// chapters. Which book a file is now comes from its bytes (`BookFilePlacement`), remembered by
/// sha256 in `book_file_digests`, and a new book gets a folder no other book's chapters name.
@Suite("Which book a file is", .serialized)
struct BookFileIdentityTests {
    /// A library folder and a folder of downloads, each file in a folder of its own so two can
    /// share a name, as two downloads of two books called the same do.
    private struct Library {
        let root: URL
        var books: URL { root.appendingPathComponent("Books", isDirectory: true) }

        init(_ name: String) throws {
            root = try BookFileFixture.folder(name)
            try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        }

        func download(_ name: String, labels: [String]) throws -> URL {
            let folder = root.appendingPathComponent("Downloads-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            try BookFileFixture.book(labels, at: file)
            return file
        }

        /// What Add Book does with the file: decides which book it is and puts the library's copy
        /// where that says.
        func add(
            _ file: URL,
            recordedBookID: String? = nil,
            replacingBookID: String? = nil,
            bookFolders: [String: String] = [:],
            foldersInUse: Set<String> = []
        ) throws -> (placement: BookFilePlacement, digest: String) {
            let digest = try BookFilePlacement.sha256Hex(ofBookAt: file.path)
            let placement = BookFilePlacement.decide(
                importPath: file.path,
                digest: digest,
                booksDir: books.path,
                recordedBookID: recordedBookID,
                replacingBookID: replacingBookID,
                bookFolders: bookFolders,
                foldersInUse: foldersInUse
            )
            _ = try StudioViewModel.copyBookFileAndExtractMetadata(sourcePath: file.path, placement: placement)
            return (placement, digest)
        }
    }

    private static func pageCount(_ path: String) -> Int? {
        PDFDocument(url: URL(fileURLWithPath: path))?.pageCount
    }

    @Test("Two books with one title are two books in two folders, both readable, and the second changes nothing of the first")
    func sameTitleDifferentFiles() throws {
        let library = try Library("same-title")
        defer { try? FileManager.default.removeItem(at: library.root) }
        let store = try KnowledgeStore(inMemory: true)
        let textbook = try library.download("Bioenergetics.pdf", labels: BookFileFixture.labels)
        let monograph = try library.download("Bioenergetics.pdf", labels: ["cover", "one", "two"])

        let first = try library.add(textbook)
        #expect(first.placement.bookID == nil && first.placement.copy == .new)
        #expect((first.placement.bookDir as NSString).lastPathComponent == "Bioenergetics")
        try store.recordBookFileDigest(first.digest, bookID: "TEXTBOOK")
        try store.execForTesting("""
            INSERT INTO books (id, title, cover_path) VALUES ('TEXTBOOK', 'Bioenergetics', 'Books/Bioenergetics/cover.jpg');
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('tb-1', 0, 'ready', 'book', 'active');
            INSERT INTO book_sources (source_id, url, local_file_path, title, page_start, page_count)
            VALUES ('tb-1', 'Books/Bioenergetics/Bioenergetics.pdf#page=1', 'Books/Bioenergetics/Bioenergetics.pdf', 'Chapter 1', 0, 8);
            INSERT INTO group_members (source_id, group_id, sort_index) VALUES ('tb-1', 'TEXTBOOK', 0);
        """)
        let textbookBytes = try Data(contentsOf: URL(fileURLWithPath: first.placement.destPath))

        // The second file has the same name and makes a book with the same title.
        #expect(try store.bookID(forFileDigest: try BookFilePlacement.sha256Hex(ofBookAt: monograph.path)) == nil)
        let second = try library.add(
            monograph,
            bookFolders: ["TEXTBOOK": first.placement.bookDir],
            foldersInUse: try store.bookFolderNamesInUse()
        )
        #expect(second.placement.bookID == nil, "a new book, never the textbook")
        #expect(second.placement.copy == .new)
        #expect(second.placement.bookDir != first.placement.bookDir)
        #expect((second.placement.bookDir as NSString).lastPathComponent == "Bioenergetics \(second.digest.prefix(8))")
        try store.recordBookFileDigest(second.digest, bookID: "MONOGRAPH")

        // Both read: each folder holds its own book's file.
        #expect(Self.pageCount(first.placement.destPath) == BookFileFixture.labels.count)
        #expect(Self.pageCount(second.placement.destPath) == 3)
        // Nothing of the first changed: its file, its folder, its record.
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.placement.destPath)) == textbookBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.placement.bookDir) == ["Bioenergetics.pdf"])
        #expect(try store.bookID(forFileDigest: first.digest) == "TEXTBOOK")
        #expect(try store.bookID(forFileDigest: second.digest) == "MONOGRAPH")
    }

    @Test("The same file added twice is one book, even after the library rewrote its copy")
    func sameFileTwice() throws {
        let library = try Library("same-file")
        defer { try? FileManager.default.removeItem(at: library.root) }
        let store = try KnowledgeStore(inMemory: true)
        let download = try library.download("Scanned Book.pdf", labels: BookFileFixture.labels)

        let first = try library.add(download)
        try store.recordBookFileDigest(first.digest, bookID: "BOOK")
        // The import writes a scan's text layer into its copy: those bytes are no longer the file's.
        try BookFileFixture.book(BookFileFixture.labels + ["text layer"], at: URL(fileURLWithPath: first.placement.destPath))
        let rewritten = try Data(contentsOf: URL(fileURLWithPath: first.placement.destPath))

        let again = try library.add(
            download,
            recordedBookID: try store.bookID(forFileDigest: try BookFilePlacement.sha256Hex(ofBookAt: download.path)),
            bookFolders: ["BOOK": first.placement.bookDir],
            foldersInUse: ["scanned book"]
        )
        #expect(again.placement == BookFilePlacement(
            bookID: "BOOK", bookDir: first.placement.bookDir, destPath: first.placement.destPath, copy: .none
        ))
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.placement.destPath)) == rewritten, "the library's copy stays as the import left it")
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.books.path) == ["Scanned Book"])
    }

    @Test("A book added before sha256s were kept is found by its copy's bytes; another file of its name is not")
    func bookFromBeforeTheRecord() throws {
        let library = try Library("before-record")
        defer { try? FileManager.default.removeItem(at: library.root) }
        let download = try library.download("Old Book.pdf", labels: BookFileFixture.labels)
        let folder = library.books.appendingPathComponent("Old Book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("Old Book.pdf")
        try FileManager.default.copyItem(at: download, to: copy)

        let again = try library.add(download, bookFolders: ["OLD": folder.path], foldersInUse: ["old book"])
        #expect(again.placement.bookID == "OLD" && again.placement.copy == .none)
        #expect(URL(fileURLWithPath: again.placement.destPath).standardizedFileURL == copy.standardizedFileURL)

        let other = try library.download("Old Book.pdf", labels: ["another", "book"])
        let added = try library.add(other, bookFolders: ["OLD": folder.path], foldersInUse: ["old book"])
        #expect(added.placement.bookID == nil && added.placement.bookDir != folder.path)
        #expect(Self.pageCount(copy.path) == BookFileFixture.labels.count, "the old book's file is not written over")
    }

    @Test("Replace Book File makes the picked file that book's file, in its folder")
    func replaceBookFile() throws {
        let library = try Library("replace")
        defer { try? FileManager.default.removeItem(at: library.root) }
        let damaged = try library.download("Some Book.pdf", labels: ["cover", "one"])
        let first = try library.add(damaged)
        let fresh = try library.download("some-book-fresh.pdf", labels: BookFileFixture.labels)

        let replaced = try library.add(fresh, replacingBookID: "BOOK", bookFolders: ["BOOK": first.placement.bookDir])
        #expect(replaced.placement == BookFilePlacement(
            bookID: "BOOK", bookDir: first.placement.bookDir, destPath: first.placement.destPath, copy: .replace
        ))
        #expect(Self.pageCount(first.placement.destPath) == BookFileFixture.labels.count)
    }

    @Test("A file already in the library's folder is the book whose folder it is")
    func fileInTheLibrary() throws {
        let library = try Library("in-place")
        defer { try? FileManager.default.removeItem(at: library.root) }
        let folder = library.books.appendingPathComponent("Kept", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Kept.pdf")
        try BookFileFixture.book(["cover", "one"], at: file)

        let added = try library.add(file, bookFolders: ["KEPT": folder.path], foldersInUse: ["kept"])
        #expect(added.placement.bookID == "KEPT" && added.placement.copy == .none)
        let unknown = try library.add(file, foldersInUse: ["kept"])
        #expect(unknown.placement.bookID == nil && unknown.placement.copy == .none, "a new book where the file is")
    }

    @Test("A new book's folder is its file's name, else that name and its sha256's start, never one in use")
    func freeFolderNames() {
        let digest = "4545308bfd30cebc94eb33c2b9d933d431c4fa9bfae996ee975c425dd99a81a9"
        #expect(BookFilePlacement.freeFolderName("Bioenergetics", digest: digest) { _ in false } == "Bioenergetics")
        #expect(BookFilePlacement.freeFolderName("Bioenergetics", digest: digest) { $0 == "Bioenergetics" }
            == "Bioenergetics 4545308b")
        #expect(BookFilePlacement.freeFolderName("Bioenergetics", digest: digest) { !$0.hasSuffix(" 3") }
            == "Bioenergetics 4545308b 3")
        #expect(BookFilePlacement.bookFolder(ofFileAt: "/L/Books/Foo/Foo.pdf", booksDir: "/L/Books") == "/L/Books/Foo")
        #expect(BookFilePlacement.bookFolder(ofFileAt: "/L/Books/Foo/Chapters/a/b.xhtml", booksDir: "/L/Books") == "/L/Books/Foo")
        #expect(BookFilePlacement.bookFolder(ofFileAt: "/L/Books/synced-ab12.pdf", booksDir: "/L/Books") == nil)
        #expect(BookFilePlacement.bookFolder(ofFileAt: "/L/Papers/x.pdf", booksDir: "/L/Books") == nil)
    }

    @Test("An EPUB kept as a folder hashes as its files, wherever the folder is")
    func folderEPUBDigest() throws {
        let root = try BookFileFixture.folder("epub-digest")
        defer { try? FileManager.default.removeItem(at: root) }
        func epub(_ name: String, chapter: String) throws -> String {
            let book = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: book.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
            try Data("application/epub+zip".utf8).write(to: book.appendingPathComponent("mimetype"))
            try Data(chapter.utf8).write(to: book.appendingPathComponent("OEBPS/ch1.xhtml"))
            return book.path
        }
        let one = try BookFilePlacement.sha256Hex(ofBookAt: try epub("One.epub", chapter: "<p>One</p>"))
        let copy = try epub("Copy.epub", chapter: "<p>One</p>")
        try Data("Finder".utf8).write(to: URL(fileURLWithPath: copy).appendingPathComponent(".DS_Store"))
        #expect(try BookFilePlacement.sha256Hex(ofBookAt: copy) == one)
        #expect(try BookFilePlacement.sha256Hex(ofBookAt: try epub("Two.epub", chapter: "<p>Two</p>")) != one)
    }

    @Test("A file names one book; a removed book's files are forgotten; folders in use include removed chapters and covers")
    func digestRecord() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.recordBookFileDigest("aaa", bookID: "ONE")
        try store.recordBookFileDigest("bbb", bookID: "ONE")
        #expect(try store.bookID(forFileDigest: "aaa") == "ONE")
        // A file of a book since removed names the book it is added as now.
        try store.recordBookFileDigest("aaa", bookID: "TWO")
        #expect(try store.bookID(forFileDigest: "aaa") == "TWO")
        try store.dropBookFileDigests(bookID: "ONE")
        #expect(try store.bookID(forFileDigest: "bbb") == nil)
        #expect(try store.bookID(forFileDigest: "aaa") == "TWO")

        try store.execForTesting("""
            INSERT INTO books (id, title, cover_path) VALUES ('C', 'Covered', 'Books/Covered/cover.jpg');
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('gone', 0, 'ready', 'book', 'archived');
            INSERT INTO book_sources (source_id, url, local_file_path, title)
            VALUES ('gone', 'Books/Removed Book/Removed Book.pdf#page=3', 'Books/Removed Book/Removed Book.pdf', 'Gone');
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('synced', 0, 'ready', 'book', 'active');
            INSERT INTO book_sources (source_id, url, local_file_path, title)
            VALUES ('synced', 'Books/Elsewhere/Elsewhere.pdf#page=1', 'Books/synced-ab12.pdf', 'Synced');
        """)
        #expect(try store.bookFolderNamesInUse() == ["covered", "removed book", "elsewhere"])
    }
}

/// What schema 169 staged once: every book of the learner's own whose chapters are PDFs of their own,
/// for the merge drain these tests exercise. The step went with schema 174's floor.
extension KnowledgeStore {
    @discardableResult
    func enqueueSplitBookMerge() throws -> Int {
        try execute("""
            INSERT INTO book_file_merge_queue (book_id, enqueued_at)
            SELECT DISTINCT gm.group_id, ?
            FROM group_members gm
            JOIN books b ON b.id = gm.group_id
            JOIN book_sources bs ON bs.source_id = gm.source_id
            JOIN sources s ON s.id = gm.source_id
            WHERE s.team_id IS NULL
              AND s.status = 'active'
              AND bs.page_start IS NULL
              AND LOWER(COALESCE(bs.local_file_path, '')) LIKE '%.pdf'
            ON CONFLICT(book_id) DO NOTHING
        """, [.real(Date().timeIntervalSinceReferenceDate)])
        return Int(try scalarInteger("SELECT COUNT(*) FROM book_file_merge_queue") ?? 0)
    }
}
