import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// The pages of a source's PDF: a whole file, or, for a chapter of a PDF book,
/// the run of the book's one file that is the chapter.
///
/// A PDF book is kept as one file, and each chapter is a run of its pages
/// (`StudioArticle.bookPages`). Everything stored about a chapter — its
/// highlights, reading position, figures and walkthrough anchors — counts
/// pages from the chapter's first page, as it did when every chapter was a
/// file of its own. So code that reads a source's PDF opens it here:
/// `document()` is the file itself for a paper or an unsplit chapter, and for
/// a chapter an in-memory document holding only the chapter's pages, numbered
/// from 0. Nothing is written to disk.
struct SourcePDFPages: Hashable, Sendable {
    /// The file, as an absolute path.
    let path: String
    /// The chapter's pages in the file; nil when the whole file is the source.
    let pages: Range<Int>?

    init(path: String, pages: Range<Int>? = nil) {
        self.path = path
        self.pages = pages
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// What a cache keyed by a file must key on: two chapters of one book are
    /// one file and two entries.
    var cacheKey: String { Self.stored(path: path, pages: pages) }

    /// A source's pages where only a path fits — the figure index's
    /// `pdf_path`, the file a walkthrough or a picture is read from: the file's
    /// path, with `#pages=<start>..<<end>` after it for a chapter of a book kept
    /// as one file.
    static func stored(path: String, pages: Range<Int>?) -> String {
        guard let pages else { return path }
        return "\(path)\(storedMarker)\(pages.lowerBound)..<\(pages.upperBound)"
    }

    /// That form read back; `path` is as it was stored, relative or absolute.
    /// A path without the ending is a whole file.
    init(stored: String) {
        guard let marker = stored.range(of: Self.storedMarker, options: .backwards) else {
            self.init(path: stored)
            return
        }
        let bounds = stored[marker.upperBound...].components(separatedBy: "..<").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] >= 0, bounds[1] > bounds[0] else {
            self.init(path: stored)
            return
        }
        self.init(path: String(stored[..<marker.lowerBound]), pages: bounds[0]..<bounds[1])
    }

    private static let storedMarker = "#pages="

    /// The same pages with `path` made absolute against this Mac's content
    /// roots; nil when the file is not here.
    func resolved() -> SourcePDFPages? {
        guard let url = SourceService.resolveLocalFileURL(path),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return SourcePDFPages(path: url.path, pages: pages)
    }

    /// The page of the file a page of the source is, or nil when the source
    /// has no such page.
    func filePage(_ sourcePage: Int) -> Int? {
        guard let pages else { return sourcePage >= 0 ? sourcePage : nil }
        let page = pages.lowerBound + sourcePage
        return sourcePage >= 0 && pages.contains(page) ? page : nil
    }

    #if canImport(PDFKit)
    /// The source's pages as a document numbered from its first page: the file
    /// itself, or a chapter's pages copied out of its book. Nil when the file
    /// cannot be read or does not hold the chapter's pages.
    func document() -> PDFDocument? {
        guard let file = PDFDocument(url: url) else { return nil }
        return Self.pages(pages, of: file)
    }

    /// The document a stored form names (`stored(path:pages:)`), its path
    /// resolved against the content roots; nil when it is not here or cannot
    /// be read.
    static func document(atStored stored: String) -> PDFDocument? {
        SourcePDFPages(stored: stored).resolved()?.document()
    }

    /// `pages` of `document` as a document of their own, or `document` itself
    /// when `pages` is nil. Nil when the range is empty or runs past the end:
    /// a chapter whose pages the file does not hold is never shown as other
    /// pages of the book.
    static func pages(_ pages: Range<Int>?, of document: PDFDocument) -> PDFDocument? {
        guard let pages else { return document }
        guard !pages.isEmpty, pages.lowerBound >= 0, pages.upperBound <= document.pageCount else { return nil }
        let chapter = PDFDocument()
        for index in pages {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { return nil }
            chapter.insert(page, at: chapter.pageCount)
        }
        return chapter
    }
    #endif
}

extension StudioArticle {
    /// Where this source's PDF pages are on this Mac, nil when it has no PDF
    /// here. Off the main thread it checks the file exists, as
    /// `resolvedPDFPath` does.
    var pdfPages: SourcePDFPages? {
        resolvedPDFPath.map { SourcePDFPages(path: $0, pages: bookPages) }
    }

    /// The file this source is read from on this Mac, as a path, for code
    /// that carries a source's file as one (`SourceImageCatalog`, the figure
    /// crops): `resolvedLocalPath`, and for a chapter of a book kept as one
    /// file its pages of the book in the form `SourcePDFPages(stored:)` reads.
    var resolvedFileLocation: String? {
        guard let bookPages else { return resolvedLocalPath }
        return resolvedPDFPath.map { SourcePDFPages.stored(path: $0, pages: bookPages) }
    }

    /// The address a new chapter of a PDF book is stored under: the book's
    /// file opened at the chapter's first page. Every chapter of a book shares
    /// the file, and a source's id is minted from its address
    /// (`SourceIdentity.stableID`), so the page is what makes the address the
    /// chapter's own.
    static func bookChapterURL(bookFilePath: String, pages: Range<Int>) -> String {
        "\(bookFilePath)#page=\(pages.lowerBound + 1)"
    }
}
