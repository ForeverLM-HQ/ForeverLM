import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers
import Vision

private let scannedPagesLogger = Logger(subsystem: "com.foreverlm.mobile", category: "ScannedPagesPDF")

/// Pages from the document camera or Photos made into one PDF whose words
/// can be read, the way a scanner app's searchable PDF is made: each page is
/// its picture with the words Vision reads on it laid under it as invisible
/// text, where Vision found them.
///
/// The words are read here because the Mac would not read them. The Mac files
/// a PDF the phone captures as a paper, and paper ingestion asks the PDF's own
/// text for the paper's details (`StudioViewModel.frontMatterText(fromPDFPath:)`
/// reads `PDFPage.string`, with no OCR): a PDF of pictures alone stops there,
/// "no readable PDF or full-text paper content", and never reaches a chat.
/// With the text under the pictures it ingests as any PDF does, and the
/// Readers' find and selection work on it too. Vision is asked as the Mac's
/// own OCR asks it (`PDFTextExtractor.recognizedText(in:)`).
///
/// No UIKit, so it runs off the main actor and checks on any Apple platform.
enum MobileScannedPagesPDF {
    /// One page as it arrives: a camera page's picture, or a photo's file.
    enum Picture: @unchecked Sendable {
        case image(CGImage)
        case encoded(Data)
    }

    /// A line Vision read: its words, and where it sits in Vision's
    /// normalized coordinates (0…1, origin bottom left, as on a PDF page).
    struct Line: Equatable, Sendable {
        let text: String
        let box: CGRect
    }

    /// The longest side a page's picture keeps, in pixels: the size the Mac
    /// renders a page at for its own OCR (`PDFTextExtractor.renderedImage`).
    static let maximumPixelLength = 2_400
    /// A page's longest side in points: a US Letter page's eleven inches, so
    /// a scanned Letter page is one again.
    static let pageLongSide: CGFloat = 792
    static let jpegQuality: CGFloat = 0.8

    /// The PDF of `pictures`, a page each, in order, every page's words read.
    /// Nil when a picture cannot be read or drawn: a PDF that silently lost a
    /// page would be filed as though it were whole.
    static func pdf(from pictures: [Picture]) -> Data? {
        guard !pictures.isEmpty else { return nil }
        let writer = Writer()
        for picture in pictures {
            let drawn: Bool = autoreleasepool {
                guard let image = preparedImage(picture) else { return false }
                let lines = recognizedLines(in: image)
                guard let embedded = jpegBacked(image) else { return false }
                return writer.addPage(image: embedded, lines: lines)
            }
            guard drawn else { return nil }
        }
        return writer.finish()
    }

    /// The PDF of pages whose lines are already known.
    static func pdf(pages: [(image: CGImage, lines: [Line])]) -> Data? {
        guard !pages.isEmpty else { return nil }
        let writer = Writer()
        for page in pages {
            guard writer.addPage(image: page.image, lines: page.lines) else { return nil }
        }
        return writer.finish()
    }

    // MARK: Pictures

    /// The picture upright, opaque on white, and no longer than
    /// `maximumPixelLength`: a photo's orientation applied, a screenshot's
    /// transparency flattened (a JPEG has none), a 48-megapixel photo brought
    /// down to what reads well.
    static func preparedImage(_ picture: Picture) -> CGImage? {
        let source: CGImage?
        switch picture {
        case .image(let image):
            source = image
        case .encoded(let data):
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelLength,
            ]
            source = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        }
        guard let source, source.width > 0, source.height > 0 else { return nil }
        let longest = max(source.width, source.height)
        let scale = min(1, CGFloat(maximumPixelLength) / CGFloat(longest))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        return context.makeImage()
    }

    /// The picture as a JPEG-backed image, which a PDF keeps as the JPEG
    /// itself rather than as raw pixels many times its size.
    static func jpegBacked(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            jpegDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: Reading the words

    /// The lines Vision reads on `image`, in its reading order. A page with
    /// no words (a diagram, a photo) reads as none.
    static func recognizedLines(in image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The page's own script, not the reader's locale: Japanese and
        // Chinese come back empty from a Latin-only model
        // (`PDFTextExtractor.recognizedText(in:)`, measured 2026-08-19).
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            scannedPagesLogger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return Line(text: text, box: observation.boundingBox)
        }
    }

    // MARK: Writing the PDF

    /// A page's size in points for a picture of `width` × `height` pixels.
    static func pageSize(width: Int, height: Int) -> CGSize {
        let longest = CGFloat(max(width, height, 1))
        return CGSize(
            width: (CGFloat(width) / longest * pageLongSide).rounded(),
            height: (CGFloat(height) / longest * pageLongSide).rounded()
        )
    }

    /// Writes pages into one PDF as they come, so a long scan holds one
    /// page's pixels at a time.
    private final class Writer {
        private let data = NSMutableData()
        private var context: CGContext?
        private var pageCount = 0

        init() {
            if let consumer = CGDataConsumer(data: data as CFMutableData) {
                context = CGContext(consumer: consumer, mediaBox: nil, nil)
            }
        }

        func addPage(image: CGImage, lines: [Line]) -> Bool {
            guard let context else { return false }
            var mediaBox = CGRect(origin: .zero, size: MobileScannedPagesPDF.pageSize(width: image.width, height: image.height))
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.draw(image, in: mediaBox)
            Self.drawInvisibly(lines, in: mediaBox, context: context)
            context.endPDFPage()
            pageCount += 1
            return true
        }

        func finish() -> Data? {
            guard let context, pageCount > 0 else { return nil }
            context.closePDF()
            self.context = nil
            return data as Data
        }

        /// Each line set in the box Vision found it in: its height the
        /// font's size, its width stretched to the box, so a selection or a
        /// find lands on the words in the picture. Invisible: the picture is
        /// what the page shows.
        private static func drawInvisibly(_ lines: [Line], in page: CGRect, context: CGContext) {
            guard !lines.isEmpty else { return }
            context.saveGState()
            context.setTextDrawingMode(.invisible)
            for line in lines {
                let box = CGRect(
                    x: page.minX + line.box.minX * page.width,
                    y: page.minY + line.box.minY * page.height,
                    width: line.box.width * page.width,
                    height: line.box.height * page.height
                )
                guard box.width > 0, box.height > 0 else { continue }
                let font = CTFontCreateWithName("Helvetica" as CFString, box.height, nil)
                let attributed = NSAttributedString(
                    string: line.text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                let typeset = CTLineCreateWithAttributedString(attributed)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(typeset, &ascent, &descent, &leading))
                guard width > 0 else { continue }
                let lineHeight = ascent + descent
                let verticalScale = lineHeight > 0 ? box.height / lineHeight : 1
                context.textMatrix = CGAffineTransform(scaleX: box.width / width, y: verticalScale)
                context.textPosition = CGPoint(x: box.minX, y: box.minY + descent * verticalScale)
                CTLineDraw(typeset, context)
            }
            context.restoreGState()
        }
    }
}
