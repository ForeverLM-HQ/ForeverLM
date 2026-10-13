import Foundation
#if canImport(PDFKit)
import CoreGraphics
import PDFKit

/// Puts a PDF book that an older build split into chapter files back into one
/// file (schema 169; docs/backend-storage-sync.md, "A PDF book is one file").
///
/// A chapter keeps its id and everything stored about it, all of which counts
/// pages from the chapter's first page; only where its pages are changes. So
/// the book's file must hold each chapter's pages exactly as its chapter file
/// did, in a run of the same length:
///
/// - When the book's own file is still in its folder (every import copied it
///   there) and every chapter's pages are a run of it, that file is the book.
///   It is the smaller one by far: Apple's PDF writers re-encode a scan's
///   JBIG2 and CCITT images as Flate, so the chapter files of a scanned book
///   are up to thirty times its size. Every page is compared as a small render
///   (`PageRender`), never by its text, since a book's text layer may have
///   been proofread after its chapters were written, and a scan's chapter
///   files may hold no text at all.
/// - Otherwise the chapter files are joined into the book's file, in reading
///   order, each chapter a bookmark with the sections its file had under it.
///
/// Runs off the main thread and reads every chapter file; nothing is deleted
/// here (`removeChapterFiles` does that once the chapters point at the book).
enum BookFileMerge {
    struct Chapter: Sendable {
        let sourceID: String
        let title: String
        /// The chapter's file, absolute.
        let path: String
    }

    struct Merged: Sendable {
        /// The book's one file, absolute.
        let bookPath: String
        /// Each chapter's pages of it, in the order the chapters were given.
        let pages: [(sourceID: String, pages: Range<Int>)]
        /// True when the book's own file held every chapter's pages, false when
        /// the chapter files were joined.
        let keptBookFile: Bool
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// A chapter's file is not on this Mac: nothing to merge here.
        case chapterFileMissing(String)
        case chapterFileUnreadable(String)
        case chaptersInDifferentFolders
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .chapterFileMissing(let path): return "A chapter file is not on this Mac: \(path)"
            case .chapterFileUnreadable(let path): return "A chapter file could not be read: \(path)"
            case .chaptersInDifferentFolders: return "The book's chapter files are in more than one folder."
            case .writeFailed(let path): return "Could not write the book's file: \(path)"
            }
        }
    }

    static func merge(_ chapters: [Chapter]) throws -> Merged {
        let fileManager = FileManager.default
        var documents: [PDFDocument] = []
        for chapter in chapters {
            guard fileManager.fileExists(atPath: chapter.path) else { throw Failure.chapterFileMissing(chapter.path) }
            guard let document = PDFDocument(url: URL(fileURLWithPath: chapter.path)), document.pageCount > 0 else {
                throw Failure.chapterFileUnreadable(chapter.path)
            }
            documents.append(document)
        }
        let folders = Set(chapters.map { bookFolder(ofChapterAt: $0.path) })
        guard folders.count == 1, let folder = folders.first else { throw Failure.chaptersInDifferentFolders }
        let target = (folder as NSString).appendingPathComponent((folder as NSString).lastPathComponent + ".pdf")

        for candidate in bookFileCandidates(in: folder, preferring: target) {
            guard let book = PDFDocument(url: URL(fileURLWithPath: candidate)),
                  let runs = matchedPages(of: documents, in: book) else { continue }
            return Merged(
                bookPath: candidate,
                pages: zip(chapters, runs).map { ($0.sourceID, $1) },
                keptBookFile: true
            )
        }

        let joined = joined(zip(chapters, documents).map { (title: $0.title, document: $1) })
        let staging = (folder as NSString).appendingPathComponent(".\(UUID().uuidString).merging.pdf")
        defer { try? fileManager.removeItem(atPath: staging) }
        guard joined.document.write(to: URL(fileURLWithPath: staging)),
              PDFDocument(url: URL(fileURLWithPath: staging))?.pageCount == joined.document.pageCount else {
            throw Failure.writeFailed(target)
        }
        if fileManager.fileExists(atPath: target) {
            _ = try fileManager.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: staging))
        } else {
            try fileManager.moveItem(atPath: staging, toPath: target)
        }
        return Merged(
            bookPath: target,
            pages: zip(chapters, joined.runs).map { ($0.sourceID, $1) },
            keptBookFile: false
        )
    }

    /// The folder a chapter file's book lives in: the one holding its
    /// `Chapters` folder, or the file's own folder for a chapter kept anywhere
    /// else.
    static func bookFolder(ofChapterAt path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == "Chapters" else { return parent }
        return (parent as NSString).deletingLastPathComponent
    }

    /// The PDFs directly in the book's folder, the one named after the folder
    /// (as import names the book's copy) first.
    static func bookFileCandidates(in folder: String, preferring target: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let pdfs = names
            .filter { $0.lowercased().hasSuffix(".pdf") && !$0.hasPrefix(".") }
            .map { (folder as NSString).appendingPathComponent($0) }
            .sorted()
        return pdfs.filter { $0 == target } + pdfs.filter { $0 != target }
    }

    /// Each chapter's pages as a run of `book`'s, in order, or nil when any
    /// chapter is not one. A chapter's run starts where the previous one ended
    /// when it fits there, else at the first later page it fits, so front
    /// matter and pages between chapters are passed over. A chapter fits when
    /// every one of its pages renders as the book's page at the same distance
    /// from the run's start. Book pages are rendered as the search reaches them,
    /// once each.
    static func matchedPages(of chapters: [PDFDocument], in book: PDFDocument) -> [Range<Int>]? {
        var bookRenders: [Int: PageRender?] = [:]
        func bookRender(_ index: Int) -> PageRender? {
            if let held = bookRenders[index] { return held }
            let render = book.page(at: index).flatMap(PageRender.init)
            bookRenders[index] = render
            return render
        }
        var runs: [Range<Int>] = []
        var next = 0
        for chapter in chapters {
            let count = chapter.pageCount
            guard count > 0 else { return nil }
            var renders: [PageRender] = []
            for index in 0..<count {
                guard let render = chapter.page(at: index).flatMap(PageRender.init) else { return nil }
                renders.append(render)
            }
            func fits(at start: Int) -> Bool {
                guard start >= 0, start + count <= book.pageCount else { return false }
                for (offset, render) in renders.enumerated() {
                    guard let page = bookRender(start + offset), page.matches(render) else { return false }
                }
                return true
            }
            var found: Int?
            if fits(at: next) {
                found = next
            } else if next + count <= book.pageCount {
                found = (next...(book.pageCount - count)).first { start in
                    guard let page = bookRender(start), page.matches(renders[0]) else { return false }
                    return fits(at: start)
                }
            }
            guard let start = found else { return nil }
            runs.append(start..<(start + count))
            next = start + count
        }
        return runs
    }

    /// The chapters' pages in one document, each chapter a bookmark at its
    /// first page with the bookmarks its own file had beneath it.
    static func joined(_ chapters: [(title: String, document: PDFDocument)]) -> (document: PDFDocument, runs: [Range<Int>]) {
        let book = PDFDocument()
        let root = PDFOutline()
        var runs: [Range<Int>] = []
        for chapter in chapters {
            let start = book.pageCount
            for index in 0..<chapter.document.pageCount {
                guard let page = chapter.document.page(at: index)?.copy() as? PDFPage else { continue }
                book.insert(page, at: book.pageCount)
            }
            runs.append(start..<book.pageCount)
            guard let first = book.page(at: start) else { continue }
            let item = PDFOutline()
            item.label = chapter.title
            item.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .mediaBox).maxY))
            if let outline = chapter.document.outlineRoot {
                for childIndex in 0..<outline.numberOfChildren {
                    guard let child = outline.child(at: childIndex),
                          let label = child.label,
                          let target = child.destination?.page else { continue }
                    let pageIndex = chapter.document.index(for: target)
                    guard pageIndex >= 0, let page = book.page(at: start + pageIndex) else { continue }
                    let section = PDFOutline()
                    section.label = label
                    section.destination = PDFDestination(page: page, at: child.destination?.point ?? .zero)
                    item.insertChild(section, at: item.numberOfChildren)
                }
            }
            root.insertChild(item, at: root.numberOfChildren)
        }
        // A fresh document keeps the outline it is given on write (a reopened
        // file without one would drop it).
        book.outlineRoot = root
        return (book, runs)
    }

    /// Deletes the chapter files the book's file now stands in for, and their
    /// `Chapters` folder once nothing else is in it.
    static func removeChapterFiles(_ paths: [String]) {
        let fileManager = FileManager.default
        var folders = Set<String>()
        for path in paths {
            try? fileManager.removeItem(atPath: path)
            let parent = (path as NSString).deletingLastPathComponent
            if (parent as NSString).lastPathComponent == "Chapters" { folders.insert(parent) }
        }
        for folder in folders {
            let left = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".DS_Store" }
            if left.isEmpty { try? fileManager.removeItem(atPath: folder) }
        }
    }

    /// Deletes the PDFs left in a book folder's `Chapters` folder once every
    /// chapter of the book reads the book's one file, and the folder once
    /// nothing else is in it. An EPUB book's chapters are other files and stay.
    static func removeLeftoverChapterFiles(inBookFolder folder: String) {
        let chapters = (folder as NSString).appendingPathComponent("Chapters")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: chapters)) ?? []
        removeChapterFiles(names.filter { $0.lowercased().hasSuffix(".pdf") }.map { (chapters as NSString).appendingPathComponent($0) })
    }

    /// A page drawn small in grey: two pages that render alike are the same
    /// page, whatever their text layer or how their images are encoded.
    ///
    /// Drawn at twice `longSide` with no smoothing and averaged down, and
    /// compared by how much the two differ against how much ink they hold:
    /// the same page measured at most 0.005 over every page of the books
    /// merged here (a JBIG2 scan beside the Flate copy Apple's writers made of
    /// it), a run shifted by a page 0.12 or more on average.
    struct PageRender: Equatable {
        static let longSide = 64
        static let tolerance = 0.05

        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ page: PDFPage) {
            guard let pageRef = page.pageRef else { return nil }
            let box = pageRef.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            // Drawn as a reader sees it: a page turned a quarter is as wide as it is tall.
            let turned = (pageRef.rotationAngle / 90) % 2 != 0
            let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
            let scale = CGFloat(Self.longSide * 2) / max(shown.width, shown.height)
            let drawnWidth = max(2, Int((shown.width * scale).rounded()) / 2 * 2)
            let drawnHeight = max(2, Int((shown.height * scale).rounded()) / 2 * 2)
            var drawn = [UInt8](repeating: 255, count: drawnWidth * drawnHeight)
            let ok = drawn.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: drawnWidth, height: drawnHeight, bitsPerComponent: 8,
                    bytesPerRow: drawnWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: drawnWidth, height: drawnHeight))
                // Sampled, not smoothed: Quartz smooths a JBIG2 image and the Flate image
                // Apple's writers made of it differently, and sampled they render alike.
                context.interpolationQuality = .none
                context.setShouldAntialias(false)
                context.setAllowsAntialiasing(false)
                context.concatenate(pageRef.getDrawingTransform(
                    .mediaBox, rect: CGRect(x: 0, y: 0, width: drawnWidth, height: drawnHeight), rotate: 0,
                    preserveAspectRatio: true
                ))
                context.drawPDFPage(pageRef)
                return true
            }
            guard ok else { return nil }
            let width = drawnWidth / 2
            let height = drawnHeight / 2
            var pixels = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let top = (2 * y) * drawnWidth + 2 * x
                    let bottom = top + drawnWidth
                    let sum = Int(drawn[top]) + Int(drawn[top + 1]) + Int(drawn[bottom]) + Int(drawn[bottom + 1])
                    pixels[y * width + x] = UInt8(sum / 4)
                }
            }
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// The two differ by under `tolerance` of the ink they hold. Two blank
        /// pages match.
        func matches(_ other: PageRender) -> Bool {
            guard width == other.width, height == other.height, !pixels.isEmpty else { return false }
            var difference = 0
            var ink = 0
            for index in pixels.indices {
                let mine = Int(pixels[index])
                let theirs = Int(other.pixels[index])
                difference += abs(mine - theirs)
                ink += (255 - mine) + (255 - theirs)
            }
            guard ink > 0 else { return true }
            return Double(difference) / Double(ink) < Self.tolerance
        }
    }
}
#endif
