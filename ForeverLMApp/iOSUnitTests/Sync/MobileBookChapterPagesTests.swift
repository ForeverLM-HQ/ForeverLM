import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

/// A PDF book is one file, and each chapter a run of its pages (`Source.meta.pageStart`, 0-based, and
/// `meta.pageCount`; its `files.pdf` the whole book's FileRef on every chapter). The phone reads the run
/// into the row, knows such a chapter by its run rather than a `.pdf` url (its url ends in `#page=N`),
/// fetches the book's file once by its hash however many chapters open it, and shows only the
/// chapter's pages, numbered from the chapter's first, so every stored page index keeps its meaning. A
/// run the book does not hold is refused, never shown on other pages.
@Suite("iPhone book chapters as runs of one file", .serialized)
struct MobileBookChapterPagesTests {
    typealias F = MobileReadModelFixture

    /// A book of `pageCount` pages, each printing "Book page N" (N from 0), as PDF bytes.
    static func bookPDF(pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Book page \(index)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            context.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The book's bytes in a scratch file.
    static func bookFile(pageCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString).pdf")
        try bookPDF(pageCount: pageCount).write(to: url)
        return url
    }

    static func text(_ document: PDFDocument, page index: Int) -> String? {
        document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("A book chapter's run is read from its Source's meta into the row; a paper's meta names none")
    func readsTheRun() async throws {
        let replica = try await F.replica()
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("ch-run", "Membranes", added: 3, type: "book", [
                "url": .string("Books/The Cell/The Cell.pdf#page=17"), "collectionID": .string("bk1"), "collectionOrder": .string("b"),
                "meta": .object(["pageStart": SyncJSON(16), "pageCount": SyncJSON(12)]),
            ])),
            (F.catalog, try F.source("ch-split", "Cells", added: 2, type: "book", [
                "url": .string("Books/The Cell/Chapters/01 Cells.pdf"), "collectionID": .string("bk1"), "collectionOrder": .string("a"),
            ])),
            (F.catalog, try F.source("ch-epub", "Deep focus", added: 1, type: "book", ["url": .string("Books/Deep Work/Chapters/ch03.xhtml")])),
            (F.catalog, try F.source("ch-half", "Half a run", added: 4, type: "book", [
                "url": .string("Books/The Cell/The Cell.pdf#page=3"), "meta": .object(["pageStart": SyncJSON(2)]),
            ])),
            (F.catalog, try F.source("paper", "Fission", added: 5, [
                "meta": .object(["pageStart": SyncJSON(3), "pageCount": SyncJSON(4), "journal": .string("Nature Metabolism")]),
            ])),
        ], to: replica)
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })

        let run = try #require(byID["ch-run"])
        #expect(run.pageStart == 16 && run.pageCount == 12)
        #expect(run.isPageRangeBookChapter && run.isPDFBackedBookChapter, "its url ends in #page=17, not .pdf: the run says it")
        let split = try #require(byID["ch-split"])
        #expect(split.pageStart == nil && split.pageCount == nil)
        #expect(!split.isPageRangeBookChapter && split.isPDFBackedBookChapter, "a chapter split the old way is still its own PDF")
        #expect(byID["ch-epub"]?.isPDFBackedBookChapter == false)
        let half = try #require(byID["ch-half"])
        #expect(half.pageStart == 2 && half.pageCount == nil)
        #expect(half.isPDFBackedBookChapter, "half a run still reads as a PDF chapter, whose document then refuses it")
        let paper = try #require(byID["paper"])
        #expect(paper.pageStart == nil && paper.pageCount == nil && !paper.isPageRangeBookChapter, "only a book's meta names a run")
    }

    @Test("A #page= url is never a file path: without a run such a chapter is not a PDF chapter")
    func pageFragmentIsNoPath() {
        let url = "Books/The Cell/The Cell.pdf#page=17"
        #expect(MobileSourceFilePath.relativePDFPath(localFilePath: nil, url: url) == nil)
        #expect(MobileSourceFilePath.relativePDFPath(localFilePath: nil, url: "Books/The Cell/Chapters/02 Part #2.pdf")
            == "Books/The Cell/Chapters/02 Part #2.pdf", "a # in a split chapter's file name is still its name")

        func chapter(_ type: String = "book", pageStart: Int? = nil, pageCount: Int? = nil) -> MobileCloudSource {
            var source = MobileCloudSource(id: "ch", title: "Membranes", subtitle: nil, sourceType: type, dateAdded: .distantPast,
                                           hasAudio: false, isArchived: false, url: url)
            source.pageStart = pageStart
            source.pageCount = pageCount
            return source
        }
        #expect(!chapter().isPDFBackedBookChapter)
        #expect(chapter(pageStart: 16, pageCount: 12).isPDFBackedBookChapter)
        #expect(chapter(pageCount: 12).isPDFBackedBookChapter)
        #expect(!chapter("paper", pageStart: 16, pageCount: 12).isPDFBackedBookChapter)
    }

    @Test("The run a record names is the whole file, a run, or refused")
    func runs() {
        #expect(MobileBookChapterPages(pageStart: nil, pageCount: nil) == .wholeFile)
        #expect(MobileBookChapterPages(pageStart: 16, pageCount: 12) == .run(16..<28))
        #expect(MobileBookChapterPages(pageStart: 0, pageCount: 1) == .run(0..<1))
        #expect(MobileBookChapterPages(pageStart: 2, pageCount: nil) == .invalid)
        #expect(MobileBookChapterPages(pageStart: nil, pageCount: 3) == .invalid)
        #expect(MobileBookChapterPages(pageStart: -1, pageCount: 3) == .invalid)
        #expect(MobileBookChapterPages(pageStart: 4, pageCount: 0) == .invalid)
        #expect(MobileBookChapterPages(pageStart: Int.max, pageCount: 2) == .invalid)

        #expect(MobileBookChapterPages(meta: nil) == .wholeFile)
        #expect(MobileBookChapterPages(meta: .object(["isbn": .string("978-0")])) == .wholeFile)
        #expect(MobileBookChapterPages(meta: .object(["pageStart": .null, "pageCount": .null])) == .wholeFile)
        #expect(MobileBookChapterPages(meta: .object(["pageStart": SyncJSON(16), "pageCount": SyncJSON(12)])) == .run(16..<28))
        #expect(MobileBookChapterPages(meta: .object(["pageStart": .string("16"), "pageCount": SyncJSON(12)])) == .invalid,
                "a key that is there but no whole number is refused, never read as absent")
        #expect(MobileBookChapterPages(meta: .object(["pageStart": .number(1.5), "pageCount": SyncJSON(2)])) == .invalid)

        #expect(MobileBookChapterPages.pages(2..<5, inBookOf: 6) == 2..<5)
        #expect(MobileBookChapterPages.pages(0..<6, inBookOf: 6) == 0..<6)
        #expect(MobileBookChapterPages.pages(4..<8, inBookOf: 6) == nil)
        #expect(MobileBookChapterPages.pages(6..<7, inBookOf: 6) == nil)
    }

    @Test("A chapter's document is only its pages, its page 0 the chapter's first page")
    func chapterDocument() throws {
        let url = try Self.bookFile(pageCount: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        let chapter = try MobileSourcePDF(url: url, pages: 2..<5).document()
        #expect(chapter.pageCount == 3)
        #expect(Self.text(chapter, page: 0) == "Book page 2")
        #expect(Self.text(chapter, page: 2) == "Book page 4")
        #expect(chapter.page(at: 3) == nil)
        #expect(chapter.findString("Book page 5", withOptions: .caseInsensitive).isEmpty, "find sees only the chapter")

        let whole = try MobileSourcePDF(url: url, pages: nil).document()
        #expect(whole.pageCount == 6 && Self.text(whole, page: 0) == "Book page 0", "a source's own PDF is shown whole")
    }

    @Test("A run the book does not hold is refused, never shown on other pages")
    func outOfRange() throws {
        let url = try Self.bookFile(pageCount: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: MobileSourceFileError.chapterPagesUnavailable) {
            try MobileSourcePDF(url: url, pages: 4..<8).document()
        }
        #expect(throws: MobileSourceFileError.chapterPagesUnavailable) {
            try MobileSourcePDF(url: url, pages: 6..<7).document()
        }
        let book = try #require(PDFDocument(url: url))
        #expect(MobileChapterPDFDocument(4..<8, of: book) == nil)
        #expect(MobileChapterPDFDocument(5..<6, of: book)?.pageCount == 1)
    }

    @Test("Every chapter names its book's one file: fetched once by its hash, kept once however many chapters are saved")
    func oneFilePerBook() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let bytes = try Self.bookPDF(pageCount: 6)
        let book = try await phone.blobs.upload(bytes, owner: "bk1", ownerType: .collection, role: "pdf", mime: "application/pdf",
                                                encoding: .identity, into: phone.personal)
        func chapter(_ id: String, start: Int, count: SyncJSON) throws -> SyncEnvelope {
            try F.source(id, id, added: 1, type: "book", [
                "url": .string("Books/The Cell/The Cell.pdf#page=\(start + 1)"), "collectionID": .string("bk1"),
                "files": .object(["pdf": book.value]), "meta": .object(["pageStart": SyncJSON(start), "pageCount": count]),
            ])
        }
        try await MobileSyncFixture.apply([
            (F.catalog, try chapter("ch-1", start: 0, count: SyncJSON(2))),
            (F.catalog, try chapter("ch-2", start: 2, count: SyncJSON(4))),
            (F.catalog, try chapter("ch-bad", start: 2, count: .string("four"))),
            (F.catalog, try F.source("paper", "Fission", added: 1, [
                "files": .object(["pdf": book.value]), "meta": .object(["pageStart": SyncJSON(2), "pageCount": SyncJSON(1)]),
            ])),
        ], to: phone.device.replica)

        let first = try #require(try await phone.satellites.sourcePDF("ch-1"))
        let second = try #require(try await phone.satellites.sourcePDF("ch-2"))
        #expect(first.pages == .run(0..<2) && second.pages == .run(2..<6))
        #expect(first.satellite.file.hash == second.satellite.file.hash, "every chapter names the book's one FileRef")
        #expect(try await phone.satellites.sourcePDF("ch-bad")?.pages == .invalid)
        #expect(try await phone.satellites.sourcePDF("paper")?.pages == .wholeFile, "only a book's meta names a run")

        let firstURL = try await phone.satellites.url(first.satellite)
        let secondURL = try await phone.satellites.url(second.satellite)
        #expect(firstURL == secondURL)
        #expect(phone.fetches() == 1, "the second chapter opens the file the first fetched")
        let shown = try MobileSourcePDF(url: secondURL, pages: 2..<6).document()
        #expect(shown.pageCount == 4 && Self.text(shown, page: 0) == "Book page 2")

        let holders = ["ch-1", "ch-2"].map(MobileSatelliteHolder.source)
        try await phone.satellites.keep(first.satellite, for: holders[0])
        try await phone.satellites.keep(second.satellite, for: holders[1])
        #expect(phone.fetches() == 1)
        let size = Int64(bytes.count)
        #expect(await phone.satellites.byteCount(holder: holders[0]) == size)
        #expect(await phone.satellites.sharedByteCount(holders: holders) == size, "two chapters saved keep the book once")
        #expect(await phone.satellites.sharedByteCount(holders: [holders[0]]) == 0)
    }
}
