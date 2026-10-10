import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Source image references")
struct SourceImageReferenceTests {
    @Test("A page reference round-trips through its URL, crop included")
    func pageReferenceRoundTrip() {
        let crop = PaperFigureRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        let reference = SourceImageReference(sourceID: "abc123", location: .page(9), crop: crop)
        #expect(reference.urlString == "foreverlm://image/abc123/page/9?crop=0.1000,0.2000,0.5000,0.2500")
        let parsed = SourceImageReference(urlString: reference.urlString)
        #expect(parsed == reference)
        #expect(parsed?.crop == crop)
    }

    @Test("An image ordinal reference parses and renders Markdown with a safe alt")
    func imageReferenceMarkdown() {
        let reference = SourceImageReference(sourceID: "chapter-3", location: .image(2))
        #expect(reference.urlString == "foreverlm://image/chapter-3/img/2")
        #expect(reference.markdown(alt: "Figure [3-4]\nRegeneration") == "![Figure (3-4) Regeneration](foreverlm://image/chapter-3/img/2)")
        #expect(SourceImageReference(urlString: "foreverlm://image/chapter-3/img/2") == reference)
    }

    @Test("Anything that is not a well-formed image reference is rejected")
    func malformedReferencesAreRejected() {
        #expect(SourceImageReference(urlString: "foreverlm://source/abc") == nil)
        #expect(SourceImageReference(urlString: "foreverlm://image/abc/page/0") == nil)
        #expect(SourceImageReference(urlString: "foreverlm://image/abc/page") == nil)
        #expect(SourceImageReference(urlString: "foreverlm://image/abc/slide/0") == nil)
        #expect(SourceImageReference(urlString: "foreverlm://image/abc/frame/3") == nil)
        #expect(SourceImageReference(urlString: "https://example.com/image/abc/page/3") == nil)
        #expect(SourceImageReference(urlString: "file:///Users/someone/page.jpg") == nil)
    }

    @Test("A slide reference names a frame of a video's stored deck")
    func slideReferenceRoundTrip() {
        let reference = SourceImageReference(sourceID: "video-789", location: .slide(4))
        #expect(reference.urlString == "foreverlm://image/video-789/slide/4")
        #expect(SourceImageReference(urlString: "foreverlm://image/video-789/slide/4") == reference)
    }

    @Test("An off-page crop is dropped rather than propagated")
    func invalidCropIsDropped() {
        let reference = SourceImageReference(
            sourceID: "abc",
            location: .page(1),
            crop: PaperFigureRect(x: 0.8, y: 0, width: 0.5, height: 0.5)
        )
        #expect(reference.crop == nil)
        #expect(SourceImageReference(urlString: "foreverlm://image/abc/page/1?crop=0.8,0,0.5,0.5")?.crop == nil)
    }

    @Test("A moment reference counts seconds from the start, zero included, and keeps its crop")
    func momentReferenceRoundTrip() throws {
        let crop = PaperFigureRect(x: 0.5, y: 0.1, width: 0.5, height: 0.8)
        let reference = SourceImageReference(sourceID: "video-789", location: .moment(265), crop: crop)
        #expect(reference.urlString == "foreverlm://image/video-789/at/265?crop=0.5000,0.1000,0.5000,0.8000")
        let parsed = try #require(SourceImageReference(urlString: reference.urlString))
        #expect(parsed.location == .moment(265))
        #expect(parsed.crop == crop)
        #expect(SourceImageReference(urlString: "foreverlm://image/video-789/at/0")?.location == .moment(0))
        #expect(SourceImageReference(urlString: "foreverlm://image/video-789/at/-2") == nil)
        #expect(SourceImageReference(urlString: "foreverlm://image/video-789/slide/0") == nil)
    }

    @Test("A tool call's time reads as seconds, a clock reading, or h/m/s units")
    func timestampArguments() {
        #expect(SourceImageReference.timestampSeconds(265) == 265)
        #expect(SourceImageReference.timestampSeconds(90.7) == 90)
        #expect(SourceImageReference.timestampSeconds("265") == 265)
        #expect(SourceImageReference.timestampSeconds("4:25") == 265)
        #expect(SourceImageReference.timestampSeconds("1:02:03") == 3723)
        #expect(SourceImageReference.timestampSeconds("4m25s") == 265)
        #expect(SourceImageReference.timestampSeconds("1h 2m 3s") == 3723)
        #expect(SourceImageReference.timestampSeconds("0") == 0)
        #expect(SourceImageReference.timestampSeconds(-1) == nil)
        #expect(SourceImageReference.timestampSeconds("4:x5") == nil)
        #expect(SourceImageReference.timestampSeconds("soon") == nil)
        #expect(SourceImageReference.timestampSeconds("25") == 25)
        #expect(SourceImageReference.timestampSeconds(nil) == nil)
    }

    @Test("A tool call's crop reads as an object or the reference's string, and one off the picture is refused")
    func cropArguments() {
        let expected = PaperFigureRect(x: 0.5, y: 0.1, width: 0.5, height: 0.8)
        let object: [String: Any] = ["x": 0.5, "y": 0.1, "width": 0.5, "height": 0.8]
        #expect(SourceImageReference.cropArgument(object) == expected)
        #expect(SourceImageReference.cropArgument("0.5,0.1,0.5,0.8") == expected)
        #expect(SourceImageReference.cropArgument(["x": 0.8, "y": 0, "width": 0.5, "height": 0.5] as [String: Any]) == nil)
        #expect(SourceImageReference.cropArgument(nil) == nil)
    }
}

@Suite("Source image catalog")
struct SourceImageCatalogTests {
    /// A video's stored content the way ingest and the slide capture write it:
    /// timed transcript blocks, then the slide block.
    private static let videoContent = """
    [0:00] Welcome everyone. Tonight we look at the mitochondrion.

    [12:03] So here is the electron transport chain. Complexes I, III, and IV pump protons across the inner membrane.

    [12:40] That gradient is the membrane potential, and ATP synthase spends it.

    [21:00] Now the genetics. Heteroplasmy means normal and mutant copies coexist in one cell.

    [21:30] Replicative segregation distributes them unevenly as cells divide.

    ## Extracted video slide frames

    Representative slide screenshots extracted from this video's frames.

    ### Slide frame 1 [0:00–0:40]
    Image: Videos/video-789/Slides/slide_001_000000s.jpg

    ### Slide frame 2 [12:03–13:10]
    Image: Videos/video-789/Slides/slide_002_000723s.jpg

    ### Slide frame 3 [21:00–21:40]
    Image: Videos/video-789/Slides/slide_003_001260s.jpg
    Non-slide: true

    ### Slide frame 4 [21:00–22:10]
    Image: Videos/video-789/Slides/slide_004_001262s.jpg
    """

    @Test("Video slides are listed with their windows and the words spoken over them")
    func slidesListWithSpokenWords() throws {
        let entries = try SourceImageCatalog.slideEntries(
            sourceID: "video-789",
            content: Self.videoContent,
            query: nil,
            slide: nil
        )
        // The frame the vision pass marked as a camera shot stays out, as it
        // does in the reader.
        #expect(entries.map(\.reference.location) == [.slide(1), .slide(2), .slide(4)])
        #expect(entries[1].caption == "Slide 2 (12:03–13:10)")
        #expect(entries[1].context.contains("electron transport chain"))
        #expect(entries[1].context.contains("ATP synthase"))
        #expect(!entries[1].context.contains("Heteroplasmy"))
        #expect(entries[1].markdown == "![Slide 2 (12:03–13:10)](foreverlm://image/video-789/slide/2)")

        // "The slide that shows X" is the one on screen while X was being said.
        let matched = try SourceImageCatalog.slideEntries(
            sourceID: "video-789",
            content: Self.videoContent,
            query: "heteroplasmy",
            slide: nil
        )
        #expect(matched.map(\.reference.location) == [.slide(4)])

        let pinned = try SourceImageCatalog.slideEntries(
            sourceID: "video-789",
            content: Self.videoContent,
            query: nil,
            slide: 2
        )
        #expect(pinned.map(\.reference.location) == [.slide(2)])

        #expect(throws: SourceImageCatalog.Failure.slideOutOfRange(requested: 9, available: [1, 2, 4])) {
            try SourceImageCatalog.slideEntries(
                sourceID: "video-789",
                content: Self.videoContent,
                query: nil,
                slide: 9
            )
        }
        #expect(throws: SourceImageCatalog.Failure.noImages) {
            try SourceImageCatalog.slideEntries(
                sourceID: "video-789",
                content: "[0:00] A talk with no captured slides.",
                query: nil,
                slide: nil
            )
        }
    }

    private static let chapterHTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>3. Glycolysis</title></head>
    <body>
    <h1>3. Glycolysis</h1>
    <p>Glycolysis converts glucose to pyruvate.</p>
    <figure>
      <img src="../images/fig3-4.png" alt="NAD regeneration" />
      <figcaption>Figure 3–4. Regeneration of NAD<sup>+</sup> by lactate dehydrogenase versus mitochondria.</figcaption>
    </figure>
    <p><img src="../images/fig3-5.jpg" alt="Fermentation in mammals and yeast"/></p>
    <p>Figure 3-5. Fermentation in mammals and yeast.</p>
    <p><img src="../images/ornament.png"/></p>
    <p>Figure 3-40. A much later figure that must not be confused with 3-4.</p>
    </body></html>
    """

    @Test("Markup chapters list every image in document order with the nearest caption")
    func markupListing() throws {
        let entries = try SourceImageCatalog.markupEntries(sourceID: "ch3", html: Self.chapterHTML, query: "")
        #expect(entries.count == 3)
        #expect(entries.map(\.reference.location) == [.image(1), .image(2), .image(3)])
        #expect(entries[0].caption.hasPrefix("Figure 3–4. Regeneration of NAD+"))
        #expect(entries[1].caption == "Fermentation in mammals and yeast")
        #expect(entries[2].caption.isEmpty)
        #expect(entries[2].context.contains("Figure 3-40"))
        #expect(entries[0].markdown.hasPrefix("![Figure 3–4. Regeneration of NAD+ by lactate dehydrogenase versus mitochondria.](foreverlm://image/ch3/img/1)"))
    }

    @Test("A figure label query tolerates dash and abbreviation variants and does not match a longer number")
    func markupQueryMatching() throws {
        for query in ["Figure 3-4", "figure 3–4", "Fig. 3.4", "FIGURE 3 4"] {
            let entries = try SourceImageCatalog.markupEntries(sourceID: "ch3", html: Self.chapterHTML, query: query)
            #expect(entries.map(\.reference.location) == [.image(1)], "query \(query)")
        }
        let words = try SourceImageCatalog.markupEntries(sourceID: "ch3", html: Self.chapterHTML, query: "lactate dehydrogenase")
        #expect(words.map(\.reference.location) == [.image(1)])
        let later = try SourceImageCatalog.markupEntries(sourceID: "ch3", html: Self.chapterHTML, query: "Figure 3-40")
        #expect(later.map(\.reference.location) == [.image(3)])
    }

    @Test("A query nothing matches names what is available instead of returning the first picture")
    func markupNoMatch() {
        #expect(throws: SourceImageCatalog.Failure.self) {
            try SourceImageCatalog.markupEntries(sourceID: "ch3", html: Self.chapterHTML, query: "Figure 9-9")
        }
        do {
            _ = try SourceImageCatalog.markupEntries(sourceID: "ch3", html: Self.chapterHTML, query: "Figure 9-9")
        } catch let failure as SourceImageCatalog.Failure {
            guard case .noMatch(let query, let available) = failure else {
                Issue.record("Unexpected failure \(failure)")
                return
            }
            #expect(query == "Figure 9-9")
            #expect(available.count == 3)
            #expect(available[0].hasPrefix("Figure 3–4"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A chapter without pictures says so")
    func markupWithoutImages() {
        #expect(throws: SourceImageCatalog.Failure.noImages) {
            try SourceImageCatalog.markupEntries(sourceID: "ch3", html: "<html><body><p>Words only.</p></body></html>", query: "")
        }
    }

    @Test("Rendering an image ordinal reads the file beside the chapter and re-encodes only when needed")
    func markupRendering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceImageCatalogTests-\(UUID().uuidString)", isDirectory: true)
        let chapterDir = root.appendingPathComponent("OEBPS/text", isDirectory: true)
        let imagesDir = root.appendingPathComponent("OEBPS/images", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try Self.solidPNG(width: 24, height: 16)
        try png.write(to: imagesDir.appendingPathComponent("fig3-4.png"))
        let chapterPath = chapterDir.appendingPathComponent("chapter3.xhtml").path
        try Self.chapterHTML.write(toFile: chapterPath, atomically: true, encoding: .utf8)

        let rendered = SourceImageCatalog.render(
            SourceImageReference(sourceID: "ch3", location: .image(1)),
            filePath: chapterPath
        )
        #expect(rendered?.mediaType == "image/png")
        #expect(rendered?.data == png)
        #expect(rendered?.dataURL.hasPrefix("data:image/png;base64,") == true)

        // The second picture's file does not exist: nil, never a placeholder.
        #expect(SourceImageCatalog.render(
            SourceImageReference(sourceID: "ch3", location: .image(2)),
            filePath: chapterPath
        ) == nil)
        #expect(SourceImageCatalog.render(
            SourceImageReference(sourceID: "ch3", location: .image(9)),
            filePath: chapterPath
        ) == nil)
    }

    @Test("PDF pages are found by the caption printed on them and rendered as JPEG")
    func pdfListingAndRendering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceImageCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfPath = root.appendingPathComponent("chapter.pdf").path
        try Self.writePDF(
            to: pdfPath,
            pages: [
                "Glycolysis is a central pathway.",
                "Figure 3-4. Regeneration of NAD+ by lactate dehydrogenase versus mitochondria.",
                "Figure 3-5. Fermentation in mammals and yeast.",
            ]
        )

        let listed = try SourceImageCatalog.entries(sourceID: "ch3", filePath: pdfPath, query: nil, page: nil)
        #expect(listed.map(\.reference.location) == [.page(2), .page(3)])
        #expect(listed[0].caption.hasPrefix("Figure 3-4."))

        let found = try SourceImageCatalog.entries(sourceID: "ch3", filePath: pdfPath, query: "Fig. 3–4", page: nil)
        #expect(found.map(\.reference.location) == [.page(2)])
        #expect(found[0].markdown == "![Figure 3-4. Regeneration of NAD+ by lactate dehydrogenase versus mitochondria.](foreverlm://image/ch3/page/2)")

        let pinned = try SourceImageCatalog.entries(sourceID: "ch3", filePath: pdfPath, query: nil, page: 3)
        #expect(pinned.map(\.reference.location) == [.page(3)])
        #expect(pinned[0].caption.hasPrefix("Figure 3-5."))

        #expect(throws: SourceImageCatalog.Failure.pageOutOfRange(requested: 7, pageCount: 3)) {
            try SourceImageCatalog.entries(sourceID: "ch3", filePath: pdfPath, query: nil, page: 7)
        }

        let rendered = SourceImageCatalog.render(
            SourceImageReference(sourceID: "ch3", location: .page(2)),
            filePath: pdfPath
        )
        #expect(rendered?.mediaType == "image/jpeg")
        #expect((rendered?.data.count ?? 0) > 1_000)

        let cropped = SourceImageCatalog.render(
            SourceImageReference(
                sourceID: "ch3",
                location: .page(2),
                crop: PaperFigureRect(x: 0, y: 0, width: 0.5, height: 0.25)
            ),
            filePath: pdfPath
        )
        #expect(cropped != nil)
        #expect((cropped?.data.count ?? 0) < (rendered?.data.count ?? 0))
    }

    @Test("A PDF page with no picture on it is refused, and names the figures that exist")
    func pdfPageWithoutPicture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceImageCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfPath = root.appendingPathComponent("paper.pdf").path
        try Self.writePDF(
            to: pdfPath,
            pages: [
                "Overview of methods that determine mitochondrial function in human disease",
                "Reverse electron transport at complex I is discussed at length here.",
                "Figure 1. Mitochondrial function measured in PBMCs.",
            ]
        )

        // The page a model guesses at: the paper's front matter.
        let refused = #expect(throws: SourceImageCatalog.Failure.self) {
            try SourceImageCatalog.entries(sourceID: "p1", filePath: pdfPath, query: nil, page: 1)
        }
        #expect(refused == .pageWithoutPicture(
            requested: 1,
            available: ["Figure 1. Mitochondrial function measured in PBMCs. (page 3)"]
        ))
        #expect(refused?.message.contains("Figure 1.") == true)

        // The words are on page 2, the picture is not. Saying "no match" here
        // would have the tutor tell the learner the paper does not cover it.
        let prose = #expect(throws: SourceImageCatalog.Failure.self) {
            try SourceImageCatalog.entries(
                sourceID: "p1",
                filePath: pdfPath,
                query: "reverse electron transport",
                page: nil
            )
        }
        guard case .noPictureMatching(let query, _)? = prose else {
            Issue.record("Expected a no-picture failure, got \(String(describing: prose))")
            return
        }
        #expect(query == "reverse electron transport")
        #expect(prose?.message.contains("appears in this source") == true)

        // The figure page itself is still shown, by page and by query.
        let pinned = try SourceImageCatalog.entries(sourceID: "p1", filePath: pdfPath, query: nil, page: 3)
        #expect(pinned.map(\.reference.location) == [.page(3)])
        let found = try SourceImageCatalog.entries(sourceID: "p1", filePath: pdfPath, query: "Figure 1", page: nil)
        #expect(found.map(\.reference.location) == [.page(3)])
    }

    @Test("A picture with no caption still counts, by how much of the page it covers")
    func pdfUncaptionedPicture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceImageCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfPath = root.appendingPathComponent("chapter.pdf").path
        try Self.writeIllustratedPDF(
            to: pdfPath,
            pages: [
                // A cover: no caption anywhere, the picture is the page.
                (text: "Navigating Metabolism", pictureFraction: 0.9),
                // A masthead logo on a page of prose, the size of publisher chrome.
                (text: "Electron transport is the subject of this chapter.", pictureFraction: 0.1),
            ]
        )

        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let cover = document.page(at: 0), let prose = document.page(at: 1) else {
            Issue.record("The fixture PDF could not be read back")
            return
        }
        // 0.9 of each side is 0.81 of the page; 0.1 of each side is 0.01.
        #expect(abs(SourceImageCatalog.rasterImageCoverage(of: cover) - 0.81) < 0.02)
        #expect(SourceImageCatalog.rasterImageCoverage(of: prose) < 0.02)
        #expect(SourceImageCatalog.pageCarriesPicture(cover))
        #expect(!SourceImageCatalog.pageCarriesPicture(prose))

        let pinned = try SourceImageCatalog.entries(sourceID: "b1", filePath: pdfPath, query: nil, page: 1)
        #expect(pinned.map(\.reference.location) == [.page(1)])
        #expect(throws: SourceImageCatalog.Failure.pageWithoutPicture(requested: 2, available: [])) {
            try SourceImageCatalog.entries(sourceID: "b1", filePath: pdfPath, query: nil, page: 2)
        }
    }

    @Test("A source file kind that carries no pictures is refused by name")
    func unsupportedFormat() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceImageCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("transcript.ttml").path
        try "<tt/>".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: SourceImageCatalog.Failure.unsupportedFormat("ttml")) {
            try SourceImageCatalog.entries(sourceID: "s", filePath: path, query: nil, page: nil)
        }
        #expect(throws: SourceImageCatalog.Failure.fileUnavailable) {
            try SourceImageCatalog.entries(sourceID: "s", filePath: root.appendingPathComponent("missing.pdf").path, query: nil, page: nil)
        }
    }

    // MARK: - Fixtures

    private static func solidPNG(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// One US-letter page per string, drawn with CoreText so PDFKit can read
    /// the words back.
    private static func writePDF(to path: String, pages: [String]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 72, y: 400, width: 468, height: 300))
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 360)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Pages that draw a real image, so the coverage measure has something to
    /// measure. `pictureFraction` is the share of each side the picture takes:
    /// 0.9 is a cover, 0.1 is a publisher's logo.
    private static func writeIllustratedPDF(
        to path: String,
        pages: [(text: String, pictureFraction: Double)]
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let picture = try solidCGImage(width: 64, height: 64)
        for page in pages {
            context.beginPDFPage(nil)
            let width = mediaBox.width * page.pictureFraction
            let height = mediaBox.height * page.pictureFraction
            context.draw(picture, in: CGRect(x: 20, y: 20, width: width, height: height))
            let attributed = NSAttributedString(
                string: page.text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 760)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func solidCGImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}

/// A model that reads a video's slide block writes the frame's file path into
/// its reply (2026-09-10: `![…](Videos/src_…/Slides/slide_013_000450s.jpg)`,
/// drawn as a broken picture). These pin the three defences: the path is
/// recognised, it is rewritten to the portable reference the chat renders, and
/// the model is no longer handed the paths in the first place.
@Suite("Slide frame paths")
struct SlideFramePathTests {
    private typealias FramePath = SourceImageReference.SlideFramePath

    /// The block as the capture writes it, with a frame the vision pass marked.
    private static let videoContent = """
    [0:00] Welcome everyone.

    [7:15] Here is the pyruvate carrier result.

    ## Extracted video slide frames

    Representative slide screenshots extracted from this video's frames. Each bracketed range is a stretch of the video during which the slide is on screen. Image paths are relative to the ForeverLM content root.

    ### Slide frame 1 [0:00–0:40]
    Image: Videos/video-789/Slides/slide_001_000000s.jpg

    ### Slide frame 13 [7:15–8:02]
    Image: Videos/video-789/Slides/slide_013_000450s.jpg
    Recognized slide text:
    MPC expression decreases stem-cell function
    """

    @Test("A frame path is recognised relative, absolute, and as a file URL")
    func framePathParses() {
        let relative = FramePath(pathOrURL: "Videos/src_6268e6/Slides/slide_013_000450s.jpg")
        #expect(relative == FramePath(sourceID: "src_6268e6", fileName: "slide_013_000450s.jpg"))
        #expect(relative?.fileNameIndex == 13)
        // The second the frame was captured at, which a Doc captures again
        // when the deck's frames are on another Mac.
        #expect(relative?.fileNameSeconds == 450)
        let absolute = FramePath(pathOrURL: "/Users/m/Library/Mobile Documents/iCloud~com~foreverlm/Documents/Videos/src_6268e6/Slides/slide_002_000723s.jpg")
        #expect(absolute?.sourceID == "src_6268e6")
        #expect(absolute?.fileNameIndex == 2)
        let fileURL = FramePath(pathOrURL: "file:///Users/m/Library/Application%20Support/ForeverLM/Videos/src_6268e6/Slides/slide_004.jpg")
        #expect(fileURL == FramePath(sourceID: "src_6268e6", fileName: "slide_004.jpg"))
        #expect(fileURL?.fileNameIndex == 4)
        #expect(fileURL?.fileNameSeconds == nil)
        #expect(FramePath(pathOrURL: "foreverlm://image/src_6268e6/slide/13") == nil)
        #expect(FramePath(pathOrURL: "https://example.com/Videos/x/Slides/a.jpg")?.sourceID == "x")
        #expect(FramePath(pathOrURL: "Videos/src_6268e6/slide_013.jpg") == nil)
        #expect(FramePath(pathOrURL: "Papers/src_6268e6/Slides/slide_013.jpg") == nil)
        #expect(FramePath(pathOrURL: "") == nil)
        #expect(FramePath(sourceID: "s", fileName: "frame.jpg").fileNameIndex == nil)
        #expect(FramePath(sourceID: "s", fileName: "slide_001_000090s.jpg").fileNameSeconds == 90)
        #expect(FramePath(sourceID: "s", fileName: "slide_001_000090.jpg").fileNameSeconds == nil)
        #expect(FramePath(sourceID: "s", fileName: "frame_000090s.jpg").fileNameSeconds == nil)
    }

    @Test("The stored block names the frame's number; the file name is the fallback")
    func frameIndexFromBlock() {
        let named = FramePath(sourceID: "video-789", fileName: "slide_013_000450s.jpg")
        #expect(SourceImageCatalog.slideFrameIndex(for: named, in: Self.videoContent) == 13)
        // A file the block does not name — a re-extraction renamed it, say —
        // still resolves by the number in its name.
        let renamed = FramePath(sourceID: "video-789", fileName: "slide_007_000100s.jpg")
        #expect(SourceImageCatalog.slideFrameIndex(for: renamed, in: Self.videoContent) == 7)
        #expect(SourceImageCatalog.slideFrameIndex(for: renamed, in: "") == 7)
        let unnumbered = FramePath(sourceID: "video-789", fileName: "frame.jpg")
        #expect(SourceImageCatalog.slideFrameIndex(for: unnumbered, in: Self.videoContent) == nil)
    }

    @Test("A reply's frame-path images become portable slide references")
    func replyPathsAreRewritten() {
        let reply = """
        ### MPC expression decreases stem-cell function

        ![Rutter slide showing the MPC result](Videos/video-789/Slides/slide_013_000450s.jpg)

        Rutter forced intestinal stem cells to express more MPC. [Talk](foreverlm://source/video-789?t=435)
        ![Already portable](foreverlm://image/video-789/slide/1)
        ![Unknown file](Videos/video-789/Slides/frame.jpg)
        """
        #expect(SourceImageReference.slideFramePaths(in: reply) == [
            FramePath(sourceID: "video-789", fileName: "slide_013_000450s.jpg"),
            FramePath(sourceID: "video-789", fileName: "frame.jpg"),
        ])
        let rewritten = SourceImageReference.rewritingSlideFramePaths(in: reply) { path in
            SourceImageCatalog.slideFrameIndex(for: path, in: Self.videoContent)
        }
        #expect(rewritten.contains("![Rutter slide showing the MPC result](foreverlm://image/video-789/slide/13)"))
        #expect(!rewritten.contains("Slides/slide_013_000450s.jpg"))
        // Everything else is left exactly as written: the source link, the
        // reference that was already portable, and a file nothing can place.
        #expect(rewritten.contains("[Talk](foreverlm://source/video-789?t=435)"))
        #expect(rewritten.contains("![Already portable](foreverlm://image/video-789/slide/1)"))
        #expect(rewritten.contains("![Unknown file](Videos/video-789/Slides/frame.jpg)"))
        let untouched = "No pictures here. ![cat](https://example.com/cat.png)"
        #expect(SourceImageReference.rewritingSlideFramePaths(in: untouched) { _ in 1 } == untouched)
    }

    @Test("The model reads slide numbers and the tool to show them, never file paths")
    func assistantFacingContentHidesPaths() {
        let facing = SlideFrameExtraction.assistantFacingContent(Self.videoContent)
        #expect(!facing.contains("Image:"))
        #expect(!facing.contains("Slides/slide_013_000450s.jpg"))
        #expect(facing.contains("### Slide frame 13 [7:15–8:02]"))
        #expect(facing.contains("show_source_image with this source_id and slide 13"))
        #expect(facing.contains("show_source_image with this source_id and slide 1 "))
        #expect(!facing.contains("relative to the ForeverLM content root"))
        // The transcript above the block and the recognised text stay as they are.
        #expect(facing.contains("[7:15] Here is the pyruvate carrier result."))
        #expect(facing.contains("Recognized slide text:\nMPC expression decreases stem-cell function"))
        // The reader's parser still reads the same deck from the original.
        #expect(YouTubeSlideContentParser.parse(Self.videoContent).slides.map(\.index) == [1, 13])
        let plain = "[0:00] A transcript with no slides.\n\nImage: not a slide block"
        #expect(SlideFrameExtraction.assistantFacingContent(plain) == plain)
    }

    @Test("A crop takes the named part of a frame, clamped to it")
    func frameCropTakesTheNamedRegion() throws {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let frame = try #require(context.makeImage())
        let right = try #require(SourceImageCatalog.cropped(frame, to: PaperFigureRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        #expect(right.width == 100)
        #expect(right.height == 100)
        let corner = try #require(SourceImageCatalog.cropped(frame, to: PaperFigureRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)))
        #expect(corner.width == 20)
        #expect(corner.height == 10)
    }
}

/// A reply may show only a picture this device can show
/// (`ReviewSessionManager.unresolvedPictureAddresses`). 2026-09-28: a quiz
/// tutor that had not called the grader pasted a drawn picture's address
/// under an id no tool had given it, and the chat drew "picture unavailable
/// on this device" where question 6's picture belonged; later that day it
/// did so again for questions 11, 12 and 13.
@Suite("Picture addresses in a reply")
struct ChatPictureAddressTests {
    private static let made = "foreverlm://image/generated/8e4d5b2c-1f4a-4a3e-9c1d-6b2f8a7e5d41"
    private static let stored = "foreverlm://image/generated/a0cb4df9-6948-49cd-ba10-70494020fa1c"

    @Test("Only foreverlm://image targets of Markdown images are picture addresses, each once, in order")
    func addressesInAReply() {
        let reply = """
        Close — the number is 13.

        ![13 mtDNA-encoded OXPHOS subunits](\(Self.made))

        ![A web picture](https://example.com/a.png) and a frame file
        ![slide](Videos/video/Slides/slide_001_000000s.jpg), then
        ![Page 9](FOREVERLM://IMAGE/src_abc/page/9) and ![again](\(Self.made)).
        A link [not a picture](foreverlm://image/generated/0000aaaa) is prose.
        """
        #expect(SourceImageReference.pictureAddresses(in: reply) == [
            Self.made,
            "FOREVERLM://IMAGE/src_abc/page/9"
        ])
    }

    @Test("An address names a source, a drawn or kept picture, an attached one, or nothing")
    func whatAnAddressNames() {
        #expect(ChatPictureAddress(Self.stored) == .generated(id: "a0cb4df9-6948-49cd-ba10-70494020fa1c"))
        #expect(ChatPictureAddress("foreverlm://image/attached/0123abcd-ef45") == .attached(id: "0123abcd-ef45"))
        #expect(ChatPictureAddress("foreverlm://image/src_abc/at/232?crop=0.1,0.1,0.5,0.5") == .source(id: "src_abc"))
        #expect(ChatPictureAddress("foreverlm://image/src_abc/page/9") == .source(id: "src_abc"))
        // An id no store could hold, a missing location, a bare host.
        #expect(ChatPictureAddress("foreverlm://image/generated/not-a-uuid!") == .unreadable)
        #expect(ChatPictureAddress("foreverlm://image/src_abc") == .unreadable)
        #expect(ChatPictureAddress("foreverlm://image/") == .unreadable)
    }

    @Test("A drawn or attached picture this Mac does not hold is caught, whatever the chat says of it")
    func unheldStoredPictureIsCaught() {
        let attached = "foreverlm://image/attached/0123abcd-ef45"
        let heldHere = "foreverlm://image/generated/ffff0000-1111-2222-3333-444455556666"
        let targets = [Self.made, Self.stored, attached, heldHere, "foreverlm://image/src_abc/page/9"]
        let unheld = ChatPictureAddress.unheldStoredPictures(in: targets) { address in
            address == ChatPictureAddress(heldHere) || address == ChatPictureAddress(attached)
        }
        // The made-up id is caught, and so is `stored`, which a tool or an
        // earlier reply may have named but whose bytes are not here: the chat
        // would draw "picture unavailable on this device" for either. Until
        // 2026-09-28 a mention in the conversation let an id through, and a
        // made-up id an earlier reply had saved came back in a later one.
        // A source is judged by the library, not here.
        #expect(unheld == [Self.made, Self.stored])
    }

    @Test("A picture taken out of a reply takes its line with it")
    func picturesComeOut() {
        let reply = """
        Right — protease degradation handles one bad protein.

        ![quality control escalation](\(Self.made))

        [Rewatch 6:09](foreverlm://source/src_abc?t=369) and ![kept](https://example.com/a.png)

        **Question 12 of 20 · Recall**
        """
        #expect(SourceImageReference.removingPictures(from: reply) { $0 == Self.made } == """
        Right — protease degradation handles one bad protein.

        [Rewatch 6:09](foreverlm://source/src_abc?t=369) and ![kept](https://example.com/a.png)

        **Question 12 of 20 · Recall**
        """)
        // A web picture is not a picture address, so nothing picks it.
        #expect(SourceImageReference.removingPictures(from: reply) { _ in true }.contains("![kept](https://example.com/a.png)"))
        #expect(SourceImageReference.removingPictures(from: "No pictures.") { _ in true } == "No pictures.")
    }

    @Test("A store holds no picture under an id it could not have written")
    func storesDoNotHoldImpossibleIDs() {
        #expect(!GeneratedImageStore.holds(id: "../../etc/passwd"))
        #expect(!AttachedImageStore.holds(id: "NOT HEX"))
        #expect(!GeneratedImageStore.holds(id: "8e4d5b2c-1f4a-4a3e-9c1d-6b2f8a7e5d41"))
    }
}

/// A question's words against the words spoken over a talk's slides
/// (2026-09-29: "Helmholtz resonator drum eigen frequencies" found nothing in
/// an 86-slide talk, and the refusal named slides 1–12 as if they were all).
@Suite("Slide queries of several words")
struct SlideQueryWordsTests {
    /// Fourteen slides a minute each; slide 13 is on screen while "mutual
    /// inductance" and, later, "current loops" are said, never as one phrase.
    private static let longTalk: String = {
        var transcript: [String] = []
        var slides: [String] = []
        for index in 1...14 {
            let start = (index - 1) * 60
            let words: String
            switch index {
            case 13: words = "The loops on one face couple through mutual inductance, the rotors spinning together. These are current loops."
            case 12: words = "A current flows through the chain."
            default: words = "Slide number \(index) of the talk, about membranes."
            }
            transcript.append("[\(start / 60):00] \(words)")
            slides.append("""
            ### Slide frame \(index) [\(start / 60):00–\(start / 60):59]
            Image: Videos/long-talk/Slides/slide_\(String(format: "%03d", index))_\(String(format: "%06d", start))s.jpg
            """)
        }
        return transcript.joined(separator: "\n\n")
            + "\n\n## Extracted video slide frames\n\nRepresentative slide screenshots extracted from this video's frames.\n\n"
            + slides.joined(separator: "\n\n")
    }()

    @Test("Words said apart over one slide find it, most words first; one misheard word does not hide it")
    func wordsSaidApartFindTheSlide() throws {
        let entries = try SourceImageCatalog.slideEntries(
            sourceID: "long-talk",
            content: Self.longTalk,
            query: "mutual inductance current loops",
            slide: nil
        )
        #expect(entries.map(\.reference.location) == [.slide(13)])

        // "eigen" was never said; the other three words were.
        let misheard = try SourceImageCatalog.slideEntries(
            sourceID: "long-talk",
            content: Self.longTalk,
            query: "eigen mutual inductance loops",
            slide: nil
        )
        #expect(misheard.first?.reference.location == .slide(13))

        // A phrase said as one still finds exactly its slide.
        let phrase = try SourceImageCatalog.slideEntries(
            sourceID: "long-talk",
            content: Self.longTalk,
            query: "current loops",
            slide: nil
        )
        #expect(phrase.map(\.reference.location) == [.slide(13)])
    }

    @Test("Two words must both be there, and a word every slide shares claims none")
    func twoWordsNeedBoth() {
        #expect(throws: SourceImageCatalog.Failure.self) {
            try SourceImageCatalog.slideEntries(
                sourceID: "long-talk",
                content: Self.longTalk,
                query: "mutual klystron",
                slide: nil
            )
        }
        #expect(throws: SourceImageCatalog.Failure.self) {
            try SourceImageCatalog.slideEntries(
                sourceID: "long-talk",
                content: Self.longTalk,
                query: "the slide showing klystron",
                slide: nil
            )
        }
    }

    @Test("A refusal names the slides past the listing, so twelve are not read as the whole deck")
    func refusalNamesTheRest() {
        do {
            _ = try SourceImageCatalog.slideEntries(
                sourceID: "long-talk",
                content: Self.longTalk,
                query: "klystron",
                slide: nil
            )
            Issue.record("A word nobody said matched a slide")
        } catch let failure as SourceImageCatalog.Failure {
            guard case .noMatch(_, let available) = failure else {
                Issue.record("Unexpected failure \(failure)")
                return
            }
            #expect(available.count == 13)
            #expect(available.last == "and 2 more, slides 13–14: pass slide with a number to see one")
            #expect(failure.message.contains("slides 13–14"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
