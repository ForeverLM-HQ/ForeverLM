import Foundation
#if os(macOS)
import AppKit
import CoreText
import OSLog
import PDFKit
import Vision

private let scannedLayerLogger = Logger(subsystem: "com.foreverlm", category: "ScannedPDFTextLayer")

/// One line of print that OCR read off a page: its words, and where they sit
/// on the page as it is shown (rotation applied), as fractions of the page's
/// width and height measured from its bottom-left corner — Vision's own frame.
struct RecognizedPDFLine: Codable, Equatable, Sendable {
    var text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// The pages of a book PDF that carry no text of their own, read by OCR. Each
/// page's picture waits in `pictureDirectory` for the proofreading pass, which
/// reads the lines against it; `discardPictures()` removes them.
struct ScannedPDFPages: Sendable {
    let pageCount: Int
    /// Recognized lines by zero-based page index. A page OCR found no print on
    /// (a blank page, a photograph) is not listed.
    let lines: [Int: [RecognizedPDFLine]]
    let pictureDirectory: URL

    func pictureURL(forPage pageIndex: Int) -> URL {
        pictureDirectory.appendingPathComponent("page-\(pageIndex).jpg")
    }

    func discardPictures() {
        try? FileManager.default.removeItem(at: pictureDirectory)
    }
}

/// A scanned book is pictures of pages: PDFKit finds no text in it, so the
/// chapter splitter, a chapter's text, search and highlights all came up
/// empty, and Add Book failed with "did not identify any chapters". This reads
/// those pages with OCR and writes what it read back into the PDF as a text
/// layer: invisible text set over the print, line by line, which PDFKit reads
/// as the page's own. Only the pages that needed reading are replaced; every
/// other page keeps its original drawing, and the outline is kept.
enum ScannedPDFTextLayer {
    /// The long side of the picture the proofreading model reads.
    static let pictureMaxDimension: CGFloat = 1_600

    /// The share of a book's pages that carry no text of their own when the
    /// book is a scan. A scan is pictures of pages, so nearly every page is
    /// textless; a book made as a PDF (an ebook, a publisher's file) has text
    /// on nearly every page, and its few pages without any are pictures — a
    /// cover, a photograph, a sponsor's page — whose words are not the book's
    /// text. Read page by page, a 156-page abstract book sent its cover and
    /// four picture pages to Scanned Page Proofreading (2026-10-13).
    static let scannedPageShare = 0.5

    /// The pages OCR reads: in a scanned book, those with fewer embedded words
    /// than `PDFTextExtractor`'s OCR threshold; in a book made as a PDF, none.
    static func pageIndicesNeedingOCR(in document: PDFDocument) -> [Int] {
        let textless = (0..<document.pageCount).filter { index in
            PDFTextExtractor.shouldOCR(document.page(at: index)?.string ?? "")
        }
        return isScan(pageCount: document.pageCount, textlessPageCount: textless.count) ? textless : []
    }

    /// Whether a book of `pageCount` pages, `textlessPageCount` of them with
    /// no text of their own, is a scan.
    static func isScan(pageCount: Int, textlessPageCount: Int) -> Bool {
        pageCount > 0 && Double(textlessPageCount) >= Double(pageCount) * scannedPageShare
    }

    /// Reads every page that needs it, keeping a JPEG of each page that has
    /// print it does not already carry as text, for the proofreading pass.
    /// `progress` gets (pages read, pages to read).
    static func recognizeUnreadablePages(
        pdfPath: String,
        progress: (Int, Int) -> Void
    ) throws -> ScannedPDFPages {
        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw SourceError.pdfReadFailed
        }
        let indices = pageIndicesNeedingOCR(in: document)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannedPages-\(UUID().uuidString)", isDirectory: true)
        var lines: [Int: [RecognizedPDFLine]] = [:]
        guard !indices.isEmpty else {
            return ScannedPDFPages(pageCount: document.pageCount, lines: [:], pictureDirectory: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = ScannedPDFPages(pageCount: document.pageCount, lines: [:], pictureDirectory: directory)
        do {
            for (offset, pageIndex) in indices.enumerated() {
                try Task.checkCancellation()
                progress(offset + 1, indices.count)
                try autoreleasepool {
                    guard let page = document.page(at: pageIndex),
                          let image = PDFTextExtractor.renderedImage(for: page) else { return }
                    let pageLines = recognizedLines(in: image)
                    // A typeset page with few words (a chapter opener, a short
                    // last page) is under the threshold too, and OCR reads back
                    // what it already carries; a layer would say it twice. A
                    // scan's own text, when it has any, is a watermark or a
                    // running head, a sliver of what OCR reads off its print.
                    let embeddedWords = wordCount(page.string ?? "")
                    guard wordCount(pageLines.map(\.text).joined(separator: " ")) > 2 * embeddedWords else { return }
                    guard let jpeg = jpegData(image, maxDimension: pictureMaxDimension) else {
                        throw SourceError.pdfReadFailed
                    }
                    try jpeg.write(to: pages.pictureURL(forPage: pageIndex))
                    lines[pageIndex] = pageLines
                }
            }
        } catch {
            pages.discardPictures()
            throw error
        }
        scannedLayerLogger.info("Read \(lines.count) of \(indices.count) textless pages by OCR")
        return ScannedPDFPages(pageCount: document.pageCount, lines: lines, pictureDirectory: directory)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    static func recognizedLines(in image: CGImage) -> [RecognizedPDFLine] {
        let request = PDFTextExtractor.textRecognitionRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            scannedLayerLogger.error("OCR failed: \(error.localizedDescription)")
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedPDFLine(
                text: text,
                x: Double(box.minX),
                y: Double(box.minY),
                width: Double(box.width),
                height: Double(box.height)
            )
        }
    }

    private static func jpegData(_ image: CGImage, maxDimension: CGFloat) -> Data? {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        )
    }

    /// Writes `lines` into the PDF at `url` as each page's text, replacing
    /// the file. A listed page is redrawn as itself with its lines set over
    /// it in invisible text, so it looks the same and reads as text; its
    /// links and other annotations move with it, and the outline is rebuilt
    /// on the same pages.
    static func writeTextLayer(_ lines: [Int: [RecognizedPDFLine]], intoPDFAt url: URL) throws {
        guard !lines.isEmpty else { return }
        guard let document = PDFDocument(url: url) else { throw SourceError.pdfReadFailed }
        let pageIndices = lines.keys.sorted().filter { $0 >= 0 && $0 < document.pageCount }

        let layered = NSMutableData()
        guard let consumer = CGDataConsumer(data: layered as CFMutableData) else {
            throw SourceError.pdfReadFailed
        }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw SourceError.pdfReadFailed
        }
        for pageIndex in pageIndices {
            guard let page = document.page(at: pageIndex), let original = page.pageRef else {
                throw SourceError.pdfReadFailed
            }
            var mediaBox = original.getBoxRect(.mediaBox)
            var cropBox = original.getBoxRect(.cropBox)
            let pageInfo = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size),
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            // The original drawing, unchanged, in the page's own space.
            context.saveGState()
            context.drawPDFPage(original)
            context.restoreGState()
            drawInvisibleLines(
                lines[pageIndex] ?? [],
                in: context,
                mediaBox: mediaBox,
                rotation: page.rotation
            )
            context.endPDFPage()
        }
        context.closePDF()
        guard let layeredDocument = PDFDocument(data: layered as Data),
              layeredDocument.pageCount == pageIndices.count else {
            throw SourceError.pdfReadFailed
        }

        let outline = OutlineNode.read(document)
        for (layeredIndex, pageIndex) in pageIndices.enumerated() {
            guard let old = document.page(at: pageIndex),
                  let new = layeredDocument.page(at: layeredIndex) else { continue }
            new.rotation = old.rotation
            for annotation in old.annotations {
                old.removeAnnotation(annotation)
                new.addAnnotation(annotation)
            }
            document.removePage(at: pageIndex)
            document.insert(new, at: pageIndex)
        }
        OutlineNode.write(outline, to: document)

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-text-\(UUID().uuidString).pdf")
        guard document.write(to: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            throw SourceError.pdfReadFailed
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Sets each line in invisible text over the print it was read from,
    /// stretched to the line's width so a selection covers the printed words.
    private static func drawInvisibleLines(
        _ lines: [RecognizedPDFLine],
        in context: CGContext,
        mediaBox: CGRect,
        rotation: Int
    ) {
        let shown = shownSize(of: mediaBox, rotation: rotation)
        context.saveGState()
        context.concatenate(shownToPageTransform(mediaBox: mediaBox, rotation: rotation))
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = CGRect(
                x: line.x * shown.width,
                y: line.y * shown.height,
                width: line.width * shown.width,
                height: line.height * shown.height
            )
            guard box.width > 0, box.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.85, nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let typographicWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard typographicWidth > 0 else { continue }
            context.saveGState()
            context.textMatrix = .identity
            // The baseline sits about a fifth of the way up a line's box.
            context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
            context.scaleBy(x: box.width / typographicWidth, y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    static func shownSize(of mediaBox: CGRect, rotation: Int) -> CGSize {
        normalizedRotation(rotation) % 180 == 0
            ? mediaBox.size
            : CGSize(width: mediaBox.height, height: mediaBox.width)
    }

    /// Maps a point on the page as shown (rotation applied, origin at the
    /// bottom-left of what the reader sees) to the page's own space. PDF
    /// rotation turns the page clockwise for display.
    static func shownToPageTransform(mediaBox: CGRect, rotation: Int) -> CGAffineTransform {
        let w = mediaBox.width, h = mediaBox.height
        let x = mediaBox.minX, y = mediaBox.minY
        switch normalizedRotation(rotation) {
        case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: x + w, ty: y)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: x + w, ty: y + h)
        case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: x, ty: y + h)
        default: return CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
        }
    }

    private static func normalizedRotation(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }

    /// An outline held by page index, so it survives its pages being replaced.
    private struct OutlineNode {
        let label: String?
        let pageIndex: Int?
        let point: CGPoint?
        let isOpen: Bool
        let children: [OutlineNode]

        static func read(_ document: PDFDocument) -> [OutlineNode]? {
            guard let root = document.outlineRoot else { return nil }
            return children(of: root, in: document)
        }

        private static func children(of item: PDFOutline, in document: PDFDocument) -> [OutlineNode] {
            (0..<item.numberOfChildren).compactMap { index in
                guard let child = item.child(at: index) else { return nil }
                let destination = child.destination
                let pageIndex = destination?.page.map { document.index(for: $0) }
                return OutlineNode(
                    label: child.label,
                    pageIndex: pageIndex,
                    point: destination?.point,
                    isOpen: child.isOpen,
                    children: children(of: child, in: document)
                )
            }
        }

        static func write(_ nodes: [OutlineNode]?, to document: PDFDocument) {
            guard let nodes else { return }
            let root = PDFOutline()
            insert(nodes, into: root, document: document)
            document.outlineRoot = root
        }

        private static func insert(_ nodes: [OutlineNode], into parent: PDFOutline, document: PDFDocument) {
            for node in nodes {
                let item = PDFOutline()
                item.label = node.label
                if let pageIndex = node.pageIndex, let page = document.page(at: pageIndex) {
                    item.destination = PDFDestination(
                        page: page,
                        at: node.point ?? CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)
                    )
                }
                parent.insertChild(item, at: parent.numberOfChildren)
                insert(node.children, into: item, document: document)
                item.isOpen = node.isOpen
            }
        }
    }
}
#endif
