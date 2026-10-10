import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ForeverLM

/// Scanned pages and photos become one PDF whose words can be read
/// (`MobileScannedPagesPDF`). The Mac's paper ingestion reads a phone PDF's
/// own text layer (`PDFPage.string`) and stops at a PDF of pictures alone, so
/// these pin that the words land in the text layer, out of sight, where the
/// picture shows them.
final class MobileScannedPagesPDFTests: XCTestCase {
    private let pageText = [
        "Mitochondria make most of the cell's ATP",
        "through oxidative phosphorylation.",
    ]

    /// A white page with black lines of type on it, as a camera page arrives.
    private func printedPage(_ lines: [String], width: Int = 1700, height: Int = 2200) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        var baseline = CGFloat(height) - 200
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 120, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            baseline -= 90
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// The first page drawn into pixels, as a reader shows it.
    private func pixels(ofFirstPageOf data: Data) throws -> [UInt8] {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let page = try XCTUnwrap(CGPDFDocument(provider)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width), height = Int(box.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.drawPDFPage(page)
        }
        return bytes
    }

    func testTheWordsAreTheTextLayerWhereThePictureShowsThem() throws {
        let image = try XCTUnwrap(MobileScannedPagesPDF.jpegBacked(try printedPage(pageText)))
        let line = MobileScannedPagesPDF.Line(
            text: "Krebs cycle intermediates",
            box: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.03)
        )
        let data = try XCTUnwrap(MobileScannedPagesPDF.pdf(pages: [(image, [line])]))
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.string, "Krebs cycle intermediates", "What the Mac's paper ingestion reads off the page.")

        let found = try XCTUnwrap(document.findString("Krebs", withOptions: []).first)
        let bounds = found.bounds(for: page)
        let mediaBox = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.minX, 0.1 * mediaBox.width, accuracy: 1, "A find lands on the line in the picture.")
        XCTAssertEqual(bounds.minY, 0.5 * mediaBox.height, accuracy: 3)
    }

    func testTheTextLayerDrawsNothingOverThePicture() throws {
        let image = try XCTUnwrap(MobileScannedPagesPDF.jpegBacked(try printedPage(pageText)))
        let lines = [MobileScannedPagesPDF.Line(text: "Hidden words", box: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.04))]
        let withWords = try XCTUnwrap(MobileScannedPagesPDF.pdf(pages: [(image, lines)]))
        let pictureOnly = try XCTUnwrap(MobileScannedPagesPDF.pdf(pages: [(image, [])]))
        XCTAssertEqual(try pixels(ofFirstPageOf: withWords), try pixels(ofFirstPageOf: pictureOnly))
    }

    func testAScannedPageCarriesTheWordsVisionReadsOnIt() throws {
        let image = try printedPage(pageText)
        let lines = MobileScannedPagesPDF.recognizedLines(in: image)
        #if targetEnvironment(simulator)
        try XCTSkipIf(lines.isEmpty, "Vision found no text model in this simulator.")
        #endif
        let data = try XCTUnwrap(MobileScannedPagesPDF.pdf(from: [.image(image), .image(image)]))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2, "One page a picture, in order.")
        let text = try XCTUnwrap(document.page(at: 0)?.string).lowercased()
        XCTAssertTrue(text.contains("oxidative phosphorylation"), "Read: \(text)")
    }

    func testAPageKeepsItsPictureAsAJPEG() throws {
        let data = try XCTUnwrap(MobileScannedPagesPDF.pdf(pages: [(
            try XCTUnwrap(MobileScannedPagesPDF.jpegBacked(try printedPage(pageText))),
            []
        )]))
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self).contains("DCTDecode"),
            "The picture is stored as the JPEG, not as raw pixels many times its size."
        )
    }

    func testAPhotoIsDrawnUprightAndNoLargerThanTheMacReadsAt() throws {
        let page = try printedPage(["Upright"], width: 1700, height: 2200)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        // EXIF orientation 6: the camera was turned; the photo shows upright.
        CGImageDestinationAddImage(destination, page, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let upright = try XCTUnwrap(MobileScannedPagesPDF.preparedImage(.encoded(encoded as Data)))
        XCTAssertEqual(upright.width, 2200)
        XCTAssertEqual(upright.height, 1700)

        let large = try printedPage(["Large"], width: 6000, height: 8000)
        let smaller = try XCTUnwrap(MobileScannedPagesPDF.preparedImage(.image(large)))
        XCTAssertEqual(max(smaller.width, smaller.height), MobileScannedPagesPDF.maximumPixelLength)
        XCTAssertEqual(smaller.width, 1800)
    }

    func testAPageIsSizedLikeTheSheetItWas() {
        XCTAssertEqual(MobileScannedPagesPDF.pageSize(width: 1700, height: 2200), CGSize(width: 612, height: 792))
        XCTAssertEqual(MobileScannedPagesPDF.pageSize(width: 4000, height: 3000), CGSize(width: 792, height: 594))
    }

    func testAPictureThatCannotBeReadMakesNoPDF() throws {
        let page = try printedPage(pageText)
        XCTAssertNil(
            MobileScannedPagesPDF.pdf(from: [.image(page), .encoded(Data("not a picture".utf8))]),
            "A PDF short of a page would be filed as though it were whole."
        )
        XCTAssertNil(MobileScannedPagesPDF.pdf(from: []))
    }
}
