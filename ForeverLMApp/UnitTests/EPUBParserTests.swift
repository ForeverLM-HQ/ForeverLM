import Testing
import Foundation
@testable import ForeverLM

private func makeChapter(title: String, textContent: String, order: Int) -> EPUBChapter {
    EPUBChapter(
        title: title,
        textContent: textContent,
        htmlContent: "<h1>\(title)</h1><p>\(textContent)</p>",
        order: order
    )
}

// MARK: - HTML Stripping

@Suite("EPUBParser.stripHTML")
struct StripHTMLTests {

    @Test("Strips basic HTML tags")
    func basicTags() {
        let html = "<p>Hello <b>world</b></p>"
        let result = EPUBParser.stripHTML(html)
        #expect(result.contains("Hello"))
        #expect(result.contains("world"))
        #expect(!result.contains("<p>"))
        #expect(!result.contains("<b>"))
    }

    @Test("Converts block elements to newlines")
    func blockElements() {
        let html = "<p>First paragraph</p><p>Second paragraph</p>"
        let result = EPUBParser.stripHTML(html)
        #expect(result.contains("First paragraph"))
        #expect(result.contains("Second paragraph"))
        #expect(result.contains("\n"))
    }

    @Test("Removes script and style blocks")
    func scriptsAndStyles() {
        let html = """
        <p>Content</p>
        <script>var x = 1;</script>
        <style>.foo { color: red; }</style>
        <p>More content</p>
        """
        let result = EPUBParser.stripHTML(html)
        #expect(result.contains("Content"))
        #expect(result.contains("More content"))
        #expect(!result.contains("var x"))
        #expect(!result.contains("color: red"))
    }

    @Test("Decodes HTML entities")
    func htmlEntities() {
        let html = "Tom &amp; Jerry &lt;3 &gt; &quot;fun&quot; &apos;s &#9726;"
        let result = EPUBParser.stripHTML(html)
        #expect(result.contains("Tom & Jerry"))
        #expect(result.contains("<3"))
        #expect(result.contains(">"))
        #expect(result.contains("\"fun\""))
        #expect(result.contains("◾"))
    }

    @Test("Handles non-breaking spaces")
    func nonBreakingSpaces() {
        let html = "Hello&nbsp;world&#160;test"
        let result = EPUBParser.stripHTML(html)
        #expect(result.contains("Hello world test"))
    }

    @Test("Collapses excessive newlines")
    func collapsesNewlines() {
        let html = "<p>A</p><p></p><p></p><p></p><p></p><p>B</p>"
        let result = EPUBParser.stripHTML(html)
        // Should not have more than 2 consecutive newlines
        #expect(!result.contains("\n\n\n"))
    }

    @Test("Returns empty string for empty input")
    func emptyInput() {
        #expect(EPUBParser.stripHTML("") == "")
    }

    @Test("Handles self-closing br tags")
    func brTags() {
        let html = "Line 1<br/>Line 2<br />Line 3<br>Line 4"
        let result = EPUBParser.stripHTML(html)
        #expect(result.contains("Line 1"))
        #expect(result.contains("Line 2"))
    }
}

// MARK: - Heading Extraction

@Suite("EPUBParser.extractHeadingFromHTML")
struct ExtractHeadingTests {

    @Test("Extracts h1 heading")
    func h1() {
        let html = "<html><body><h1>Chapter 1: Introduction</h1><p>Text...</p></body></html>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == "Chapter 1: Introduction")
    }

    @Test("Extracts h2 when no h1")
    func h2Fallback() {
        let html = "<html><body><h2>Section Title</h2><p>Text...</p></body></html>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == "Section Title")
    }

    @Test("Prefers h1 over h2")
    func h1Priority() {
        let html = "<html><body><h1>Main Title</h1><h2>Subtitle</h2></body></html>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == "Main Title")
    }

    @Test("Preserves first explicit heading")
    func preservesFirstExplicitHeading() {
        let html = "<html><body><h1>CHAPTER 1</h1><h1>Desperately Seeking Patterns</h1></body></html>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == "CHAPTER 1")
    }

    @Test("Strips inline tags from heading")
    func inlineTags() {
        let html = "<h1>Chapter <em>1</em>: <b>Bold</b> Title</h1>"
        let result = EPUBParser.extractHeadingFromHTML(html)
        #expect(result?.contains("Chapter") == true)
        #expect(result?.contains("Bold") == true)
        #expect(result?.contains("<em>") != true)
    }

    @Test("Returns nil for no headings")
    func noHeadings() {
        let html = "<html><body><p>Just a paragraph.</p></body></html>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == nil)
    }

    @Test("Returns nil for empty heading")
    func emptyHeading() {
        let html = "<h1></h1><p>Content</p>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == nil)
    }

    @Test("Handles heading with attributes")
    func headingWithAttributes() {
        let html = "<h1 class=\"title\" id=\"ch1\">My Chapter</h1>"
        #expect(EPUBParser.extractHeadingFromHTML(html) == "My Chapter")
    }

    @Test("Does not infer headings from publisher classes")
    func ignoresClassBasedHeading() {
        let html = """
        <html><body>
        <div class="B_header">1</div>
        <div class="A_header1">Introduction</div>
        <p>Chapter text.</p>
        </body></html>
        """
        #expect(EPUBParser.extractHeadingFromHTML(html) == nil)
    }

    @Test("Preserves explicit publisher heading text")
    func preservesExplicitPublisherHeading() {
        let html = """
        <html><body>
        <h1>McFa_9780307986832_epub_c02_r1</h1>
        <div class="A_header1">What is Life?</div>
        <p>Chapter text.</p>
        </body></html>
        """
        #expect(EPUBParser.extractHeadingFromHTML(html) == "McFa_9780307986832_epub_c02_r1")
    }
}

// MARK: - EPUB Image Data URI Normalization

@Suite("EPUBParser.normalizeImageDataURIs")
struct EPUBImageDataURINormalizationTests {

    @Test("Normalizes malformed jpg image data URI")
    func normalizesMalformedJPGDataURI() {
        let html = #"<img src="data:image/.jpg;base64,abcd"/>"#
        let result = EPUBParser.normalizeImageDataURIs(in: html)
        #expect(result == #"<img src="data:image/jpeg;base64,abcd"/>"#)
    }

    @Test("Normalizes image jpg alias")
    func normalizesJPGAlias() {
        let html = #"<img src="data:image/jpg;base64,abcd"/>"#
        let result = EPUBParser.normalizeImageDataURIs(in: html)
        #expect(result == #"<img src="data:image/jpeg;base64,abcd"/>"#)
    }
}

// MARK: - EPUB Chapter Image Resolution

@Suite("EPUBParser.firstImagePath")
struct EPUBChapterImagePathTests {

    @Test("Resolves first local img src relative to chapter")
    func resolvesRelativeImage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-image-test-\(UUID().uuidString)", isDirectory: true)
        let chapterDir = root.appendingPathComponent("Text", isDirectory: true)
        let imageDir = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = imageDir.appendingPathComponent("chapter art.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: imageURL)
        let chapterURL = chapterDir.appendingPathComponent("chapter.xhtml")
        try """
        <html><body><p>Text</p><img src="../Images/chapter%20art.jpg"/></body></html>
        """.write(to: chapterURL, atomically: true, encoding: .utf8)

        #expect(EPUBParser.firstImagePath(inXHTMLAt: chapterURL.path) == imageURL.path)
    }

    @Test("Ignores remote and data images")
    func ignoresNonLocalImages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-image-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chapterURL = root.appendingPathComponent("chapter.xhtml")
        try """
        <html><body>
        <img src="https://example.com/image.jpg"/>
        <img src="data:image/png;base64,abc"/>
        </body></html>
        """.write(to: chapterURL, atomically: true, encoding: .utf8)

        #expect(EPUBParser.firstImagePath(inXHTMLAt: chapterURL.path) == nil)
    }
}

// MARK: - EPUB Structure Extraction

@Suite("EPUBParser.extractStructure")
struct EPUBStructureExtractionTests {

    @Test("Extracts semantic chapters from the Coacervate page-spread EPUB fixture")
    func extractsCoacervateFixture() throws {
        guard let epubPath = ProcessInfo.processInfo.environment["FOREVERLM_COACERVATE_EPUB"],
              FileManager.default.fileExists(atPath: epubPath) else {
            return
        }

        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coacervate-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let chapters = try EPUBParser.extractStructure(from: epubPath, to: outputDir.path)
        let titles = chapters.map(\.title)
        #expect(!titles.contains(where: EPUBParser.isGenericChapterLabel))
        #expect(titles.contains("INTRODUCTION"))
        #expect(titles.contains("4.4. Main principles of Ling's AIH"))
        #expect(!titles.contains(where: { $0.hasPrefix("1. Lengthening of NMR") }))

        let photographedPassageChapter = try #require(chapters.first(where: { chapter in
            let html = try? String(contentsOfFile: chapter.xhtmlPath, encoding: .utf8)
            return html?.contains("fundamental problem posed by Schrödinger") == true
        }))
        #expect(photographedPassageChapter.title == "PART 2. THE COHERENCE OF LIFE")
    }

    @Test("Uses a real contents page instead of page-range navigation labels")
    func replacesPageRangeNavigationWithSemanticChapters() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-page-range-toc-test-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let metaInf = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let ops = packageRoot.appendingPathComponent("OPS", isDirectory: true)
        let textDir = ops.appendingPathComponent("Text", isDirectory: true)
        let outputDir = root.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let fileNames = ["title", "spread-1", "spread-2", "spread-3", "spread-4", "spread-5", "spread-6"]
        let manifest = fileNames.map {
            "<item id=\"\($0)\" href=\"Text/\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = fileNames.map { "<itemref idref=\"\($0)\"/>" }.joined(separator: "\n")
        try """
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifest)
          </manifest>
          <spine>\(spine)</spine>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="Text/title.xhtml">Title page</a></li>
            <li><a href="Text/spread-1.xhtml">Pages 1–2</a></li>
            <li><a href="Text/spread-2.xhtml">Pages 3–4</a></li>
            <li><a href="Text/spread-3.xhtml">Pages 5–6</a></li>
            <li><a href="Text/spread-4.xhtml">Pages 7–8</a></li>
            <li><a href="Text/spread-5.xhtml">Page 9</a></li>
            <li><a href="Text/spread-6.xhtml">Pages 10–11</a></li>
          </ol></nav>
        </body></html>
        """.write(to: ops.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let documents = [
            "<html><body><h1>Title page</h1></body></html>",
            "<html><body><h2>CONTENTS</h2><h2>INTRODUCTION</h2><h2>1. A Real Chapter</h2></body></html>",
            "<html><body><p>Copyright and publication details.</p></body></html>",
            "<html><body><h2>Introduction</h2><p>Opening.</p></body></html>",
            "<html><body><h2>1. An incidental numbered list item</h2><p>Continuation.</p></body></html>",
            "<html><body><h2>1. A REAL CHAPTER</h2><p>Chapter opening.</p></body></html>",
            "<html><body><p>Chapter continuation.</p></body></html>",
        ]
        for (fileName, document) in zip(fileNames, documents) {
            try document.write(
                to: textDir.appendingPathComponent("\(fileName).xhtml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let epubURL = root.appendingPathComponent("book.epub")
        try zipDirectory(packageRoot, to: epubURL)

        let chapters = try EPUBParser.extractStructure(from: epubURL.path, to: outputDir.path)
        #expect(chapters.map(\.title) == ["Title page", "CONTENTS", "INTRODUCTION", "1. A Real Chapter"])

        let introductionHTML = try String(contentsOfFile: chapters[2].xhtmlPath, encoding: .utf8)
        #expect(introductionHTML.contains("Opening."))
        #expect(introductionHTML.contains("Continuation."))
        #expect(!chapters.map(\.title).contains("1. An incidental numbered list item"))
    }

    @Test("Extracts Life on the Edge main chapters and figure assets from real EPUB fixture")
    func extractsLifeOnTheEdgeFixture() throws {
        guard let epubPath = ProcessInfo.processInfo.environment["FOREVERLM_LIFE_ON_EDGE_EPUB"],
              FileManager.default.fileExists(atPath: epubPath) else {
            return
        }

        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("life-on-edge-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let chapters = try EPUBParser.extractStructure(from: epubPath, to: outputDir.path)
        #expect(chapters.map(\.title) == [
            "1) Introduction",
            "2) What is life?",
            "3) The engines of life",
            "4) The quantum beat",
            "5) Finding Nemo’s home",
            "6) The butterfly, the fruit fly and the quantum robin",
            "7) Quantum genes",
            "8) Mind",
            "9) How life began",
            "10) Quantum biology: life on the edge of a storm",
        ])

        let firstChapter = try #require(chapters.first)
        let firstChapterHTML = try String(contentsOfFile: firstChapter.xhtmlPath, encoding: .utf8)
        #expect(firstChapterHTML.contains("Figure 1.1:"))
        #expect(firstChapterHTML.contains("McFa_9780307986832_epub_001_r1.jpg"))

        let figurePath = try #require(EPUBParser.firstImagePath(inXHTMLAt: firstChapter.xhtmlPath))
        #expect(figurePath.hasSuffix("OEBPS/images/McFa_9780307986832_epub_001_r1.jpg"))
        #expect(FileManager.default.fileExists(atPath: figurePath))
    }

    @Test("Combines TOC chapter spine ranges so figures in later files are included")
    func combinesTOCChapterSpineRangeWithFigures() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-structure-test-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let metaInf = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let ops = packageRoot.appendingPathComponent("OPS", isDirectory: true)
        let textDir = ops.appendingPathComponent("Text", isDirectory: true)
        let imageDir = ops.appendingPathComponent("Images", isDirectory: true)
        let outputDir = root.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ch1a" href="Text/ch1a.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1b" href="Text/ch1b.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="fig1" href="Images/fig1.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="ch1a"/>
            <itemref idref="ch1b"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="Text/ch1a.xhtml">Chapter 1</a></li>
                <li><a href="Text/ch2.xhtml">Chapter 2</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """.write(to: ops.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        try "<html><body><h1>Chapter 1</h1><p>Opening text.</p></body></html>"
            .write(to: textDir.appendingPathComponent("ch1a.xhtml"), atomically: true, encoding: .utf8)
        try """
        <html><body>
          <figure><img src="../Images/fig1.png"/><figcaption>Figure 1. A living system.</figcaption></figure>
        </body></html>
        """.write(to: textDir.appendingPathComponent("ch1b.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Chapter 2</h1><p>Next chapter.</p></body></html>"
            .write(to: textDir.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageDir.appendingPathComponent("fig1.png"))

        let epubURL = root.appendingPathComponent("book.epub")
        try zipDirectory(packageRoot, to: epubURL)

        let chapters = try EPUBParser.extractStructure(from: epubURL.path, to: outputDir.path)
        #expect(chapters.count == 2)

        let firstHTML = try String(contentsOfFile: chapters[0].xhtmlPath, encoding: .utf8)
        #expect(firstHTML.contains("Opening text."))
        #expect(firstHTML.contains("Figure 1. A living system."))
        #expect(firstHTML.contains("<img"))
        #expect(!firstHTML.lowercased().contains("<!doctype html>"))
        #expect((try? XMLDocument(data: Data(firstHTML.utf8), options: [])) != nil)
        #expect(EPUBParser.firstImagePath(inXHTMLAt: chapters[0].xhtmlPath) == outputDir.appendingPathComponent("OPS/Images/fig1.png").path)
    }

    @Test("Combined chapter files use descriptive filenames and inject headings when missing")
    func combinedChapterFilesUseDescriptiveFilenamesAndInjectHeadings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-combined-filename-test-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let metaInf = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let ops = packageRoot.appendingPathComponent("OPS", isDirectory: true)
        let textDir = ops.appendingPathComponent("Text", isDirectory: true)
        let outputDir = root.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="intro-a" href="Text/intro-a.xhtml" media-type="application/xhtml+xml"/>
            <item id="intro-b" href="Text/intro-b.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1-a" href="Text/ch1-a.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1-b" href="Text/ch1-b.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="intro-a"/>
            <itemref idref="intro-b"/>
            <itemref idref="ch1-a"/>
            <itemref idref="ch1-b"/>
          </spine>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="Text/intro-a.xhtml">Introduction</a></li>
                <li><a href="Text/ch1-a.xhtml">1. The Current Situation</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """.write(to: ops.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        try "<html><body><p>Intro part one.</p></body></html>"
            .write(to: textDir.appendingPathComponent("intro-a.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><p>Intro part two.</p></body></html>"
            .write(to: textDir.appendingPathComponent("intro-b.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><p>Chapter part one.</p></body></html>"
            .write(to: textDir.appendingPathComponent("ch1-a.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><p>Chapter part two.</p></body></html>"
            .write(to: textDir.appendingPathComponent("ch1-b.xhtml"), atomically: true, encoding: .utf8)

        let epubURL = root.appendingPathComponent("book.epub")
        try zipDirectory(packageRoot, to: epubURL)

        let chapters = try EPUBParser.extractStructure(from: epubURL.path, to: outputDir.path)
        #expect(chapters.map(\.title) == ["Introduction", "1. The Current Situation"])

        let combinedDir = outputDir.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
        let introPath = combinedDir.appendingPathComponent("01 Introduction.xhtml")
        let chapterPath = combinedDir.appendingPathComponent("02 1. The Current Situation.xhtml")
        #expect(chapters.map(\.xhtmlPath) == [introPath.path, chapterPath.path])
        #expect(FileManager.default.fileExists(atPath: introPath.path))
        #expect(FileManager.default.fileExists(atPath: chapterPath.path))

        let introHTML = try String(contentsOf: introPath, encoding: .utf8)
        let chapterHTML = try String(contentsOf: chapterPath, encoding: .utf8)
        #expect(introHTML.contains("<h1>Introduction</h1>"))
        #expect(chapterHTML.contains("<h1>1. The Current Situation</h1>"))
        #expect(introHTML.contains("Intro part one."))
        #expect(chapterHTML.contains("Chapter part two."))
    }

    @Test("Strips legacy HTML5 doctype from combined chapter files on disk")
    func stripsLegacyHTML5DoctypeFromCombinedChapterFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-repair-doctype-\(UUID().uuidString)", isDirectory: true)
        let chaptersDir = root.appendingPathComponent("Chapters", isDirectory: true)
        let combinedDir = chaptersDir.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: combinedDir, withIntermediateDirectories: true)
        let chapterURL = combinedDir.appendingPathComponent("02 Chapter.xhtml")
        try """
        <!doctype html>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Chapter text.</p></body></html>
        """.write(to: chapterURL, atomically: true, encoding: .utf8)

        EPUBParser.repairLegacyCombinedChapterDoctype(in: chaptersDir.path)

        let repaired = try String(contentsOf: chapterURL, encoding: .utf8)
        #expect(!repaired.lowercased().contains("<!doctype html>"))
        #expect(repaired.contains("Chapter text."))
        #expect((try? XMLDocument(data: Data(repaired.utf8), options: [])) != nil)
    }

    @Test("Uses NCX chapter classes without merging back matter into final chapter")
    func usesNCXChapterClassesAsImportRowsAndOtherEntriesAsBoundaries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-ncx-class-test-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let metaInf = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = packageRoot.appendingPathComponent("OEBPS", isDirectory: true)
        let outputDir = root.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="book.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        try """
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item href="book.ncx" id="ncx" media-type="application/x-dtbncx+xml"/>
            <item href="OEBPS/front.htm" id="front" media-type="application/xhtml+xml"/>
            <item href="OEBPS/c01.htm" id="c01" media-type="application/xhtml+xml"/>
            <item href="OEBPS/c02.htm" id="c02" media-type="application/xhtml+xml"/>
            <item href="OEBPS/notes.htm" id="notes" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="front"/>
            <itemref idref="c01"/>
            <itemref idref="c02"/>
            <itemref idref="notes"/>
          </spine>
        </package>
        """.write(to: packageRoot.appendingPathComponent("book.opf"), atomically: true, encoding: .utf8)

        try """
        <ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint class="other" id="np1"><navLabel><text>Front Matter</text></navLabel><content src="OEBPS/front.htm"/></navPoint>
            <navPoint class="chapter" id="np2"><navLabel><text>1 Introduction</text></navLabel><content src="OEBPS/c01.htm"/></navPoint>
            <navPoint class="chapter" id="np3"><navLabel><text>2 What is life?</text></navLabel><content src="OEBPS/c02.htm"/></navPoint>
            <navPoint class="other" id="np4"><navLabel><text>Notes</text></navLabel><content src="OEBPS/notes.htm"/></navPoint>
          </navMap>
        </ncx>
        """.write(to: packageRoot.appendingPathComponent("book.ncx"), atomically: true, encoding: .utf8)

        try "<html><body><p>Front matter.</p></body></html>"
            .write(to: oebps.appendingPathComponent("front.htm"), atomically: true, encoding: .utf8)
        try "<html><body><div class=\"A_header1\">Introduction</div><p>Chapter one.</p></body></html>"
            .write(to: oebps.appendingPathComponent("c01.htm"), atomically: true, encoding: .utf8)
        try "<html><body><div class=\"A_header1\">What is life?</div><p>Chapter two.</p></body></html>"
            .write(to: oebps.appendingPathComponent("c02.htm"), atomically: true, encoding: .utf8)
        try "<html><body><p>Back matter notes should not be merged.</p></body></html>"
            .write(to: oebps.appendingPathComponent("notes.htm"), atomically: true, encoding: .utf8)

        let epubURL = root.appendingPathComponent("book.epub")
        try zipDirectory(packageRoot, to: epubURL)

        let chapters = try EPUBParser.extractStructure(from: epubURL.path, to: outputDir.path)
        #expect(chapters.map(\.title) == ["1 Introduction", "2 What is life?"])

        let finalHTML = try String(contentsOfFile: chapters[1].xhtmlPath, encoding: .utf8)
        #expect(finalHTML.contains("Chapter two."))
        #expect(!finalHTML.contains("Back matter notes should not be merged."))
    }

    @Test("Accepts an unpacked .epub folder the way Apple Books stores its library")
    func extractsUnpackedEPUBFolder() throws {
        // Apple Books keeps every iCloud book as a bare `.epub` directory, not a ZIP.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unpacked-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let epubDir = root.appendingPathComponent("The Song of the Cell.epub", isDirectory: true)
        let metaInf = epubDir.appendingPathComponent("META-INF", isDirectory: true)
        let content = epubDir.appendingPathComponent("e9781982117375", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)

        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="9781982117375.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata>
            <dc:title>The Song of the Cell</dc:title>
            <dc:creator>Siddhartha Mukherjee</dc:creator>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="ch1" href="e9781982117375/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="e9781982117375/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.write(to: epubDir.appendingPathComponent("9781982117375.opf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1" playOrder="1"><navLabel><text>The Original Cell</text></navLabel><content src="e9781982117375/ch1.xhtml"/></navPoint>
            <navPoint id="n2" playOrder="2"><navLabel><text>The Visible Cell</text></navLabel><content src="e9781982117375/ch2.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """.write(to: epubDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        try "<html><body><h1>The Original Cell</h1><p>Every cell comes from a cell.</p></body></html>"
            .write(to: content.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><h1>The Visible Cell</h1><p>Leeuwenhoek looks.</p></body></html>"
            .write(to: content.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        #expect(EPUBParser.isDirectoryEPUB(at: epubDir.path))

        let outputDir = root.appendingPathComponent("Chapters", isDirectory: true)
        let chapters = try EPUBParser.extractStructure(from: epubDir.path, to: outputDir.path)
        #expect(chapters.count == 2)
        #expect(chapters.first?.title == "The Original Cell")
        let firstHTML = try String(contentsOfFile: chapters[0].xhtmlPath, encoding: .utf8)
        #expect(firstHTML.contains("Every cell comes from a cell."))

        let metadata = EPUBParser.extractMetadata(from: epubDir.path)
        #expect(metadata.title == "The Song of the Cell")
        #expect(metadata.author == "Siddhartha Mukherjee")

        // The source folder must be left exactly where it was — copied, never moved.
        #expect(FileManager.default.fileExists(atPath: epubDir.appendingPathComponent("mimetype").path))
    }

    @Test("Says a broken download is damaged instead of blaming container.xml")
    func reportsDamagedArchive() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damaged-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let metaInf = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try "application/epub+zip".write(to: packageRoot.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try "<package><manifest/><spine/></package>"
            .write(to: packageRoot.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let epubURL = root.appendingPathComponent("book.epub")
        try zipDirectory(packageRoot, to: epubURL)
        #expect(EPUBParser.damagedZIPEntries(at: epubURL)?.unreadable == 0)

        // Zero the first entry's local header, as a download that broke part-way leaves it.
        var bytes = try Data(contentsOf: epubURL)
        bytes.replaceSubrange(0..<30, with: Data(count: 30))
        try bytes.write(to: epubURL)

        let damage = try #require(EPUBParser.damagedZIPEntries(at: epubURL))
        #expect(damage.unreadable == 1)
        #expect(damage.total == 4)
        let outputDir = root.appendingPathComponent("out", isDirectory: true)
        #expect {
            try EPUBParser.extractStructure(from: epubURL.path, to: outputDir.path)
        } throws: { error in
            guard case EPUBParser.EPUBError.damagedArchive(1, 4) = error else { return false }
            return true
        }
    }

    private func zipDirectory(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-qry", destination.path, "."]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "EPUBStructureExtractionTests", code: Int(process.terminationStatus))
        }
    }
}

// MARK: - Chapter Title Normalization

@Suite("EPUBParser.normalizeChapterTitle")
struct EPUBChapterTitleNormalizationTests {

    @Test("Decodes entities without rewriting chapter meaning")
    func decodesEntitiesLosslessly() {
        let result = EPUBParser.normalizeChapterTitle("Chapter 1 &#9726; The Insulin-Glucose Circuit")
        #expect(result == "Chapter 1 ◾ The Insulin-Glucose Circuit")
    }

    @Test("Formats split heading title")
    func formatsSplitHeadingTitle() {
        let result = EPUBParser.normalizeChapterTitle("CHAPTER 1 the Insulin-Glucose Circuit")
        #expect(result == "CHAPTER 1 the Insulin-Glucose Circuit")
    }

    @Test("Formats fractional chapter number")
    func formatsFractionalChapterNumber() {
        let result = EPUBParser.normalizeChapterTitle("Chapter 2.5 ◾ Three Laws of Physiology")
        #expect(result == "Chapter 2.5 ◾ Three Laws of Physiology")
    }

    @Test("Leaves non-chapter title alone")
    func leavesNonChapterTitleAlone() {
        #expect(EPUBParser.normalizeChapterTitle("About Math and Biological Terms") == "About Math and Biological Terms")
    }
}

// MARK: - Chapter Title Cleaning

@Suite("StudioViewModel.cleanChapterTitle")
@MainActor
struct ChapterTitleCleaningTests {

    @Test("Preserves filename stem")
    func preservesFilenameStem() {
        let result = StudioViewModel.chapterTitle("01 Chapter 3: Genetics.txt")
        #expect(result == "01 Chapter 3: Genetics")
    }

    @Test("Preserves meaningful title")
    func preservesMeaningfulTitle() {
        let result = StudioViewModel.chapterTitle("05 Introduction to Systems Biology.txt")
        #expect(result.contains("Introduction"))
        #expect(result.contains("Systems Biology"))
    }

    @Test("Preserves underscores")
    func preservesUnderscores() {
        let result = StudioViewModel.chapterTitle("03_My_Chapter.txt")
        #expect(result == "03_My_Chapter")
    }

    @Test("Preserves leading zeros")
    func preservesLeadingZeros() {
        let result = StudioViewModel.chapterTitle("03 Chapter 05 Content.txt")
        #expect(result == "03 Chapter 05 Content")
    }

    @Test("Preserves imported chapter titles")
    func preservesImportedChapterTitle() {
        #expect(
            StudioViewModel.importedBookChapterTitle(
                "Introduction to Probability – 2) Discrete Random Variables",
                bookTitle: "Introduction to Probability"
            ) == "Introduction to Probability – 2) Discrete Random Variables"
        )
        #expect(
            StudioViewModel.importedBookChapterTitle(
                "Build a Large Language Model (From Scratch) - Chapter 3: Coding Attention Mechanisms",
                bookTitle: "Build a Large Language Model (From Scratch)"
            ) == "Build a Large Language Model (From Scratch) - Chapter 3: Coding Attention Mechanisms"
        )
        #expect(
            StudioViewModel.importedBookChapterTitle(
                "How Life Works: Chapter 6 Cells",
                bookTitle: "How Life Works"
            ) == "How Life Works: Chapter 6 Cells"
        )
    }

    @Test("A title that runs into the table of contents is cut back to its own heading")
    func trimsTableOfContentsRuns() {
        // The three chapters of Molecular Biology of the Cell that were cited
        // under a run of contents lines (2026-09-09).
        #expect(
            StudioViewModel.importedBookChapterTitle(
                "11) Small-Molecule Transport and Electrical Properties of Membranes Chapter 12 Intracellular Organization and Protein Sorting Chapter 13 Intracellular Membrane Traffic Chapter 14 Energy Conversion and",
                bookTitle: "Molecular Biology of the Cell"
            ) == "Small-Molecule Transport and Electrical Properties of Membranes"
        )
        #expect(
            StudioViewModel.importedBookChapterTitle(
                "21) Development of Multicellular Organisms Chapter 22 Stem Cells in Tissue Homeostasis and Regeneration Chapter 23 Pathogens",
                bookTitle: "Molecular Biology of the Cell"
            ) == "Development of Multicellular Organisms"
        )
        #expect(
            StudioViewModel.importedBookChapterTitle(
                "8) Analyzing Cells, Molecules, and Systems Chapter 9 Visualizing Cells and Their Molecules PART IV INTERNAL ORGANIZATION OF THE CELL",
                bookTitle: "Molecular Biology of the Cell"
            ) == "Analyzing Cells, Molecules, and Systems"
        )
        // One further label after a leading number that is not the next chapter's
        // is a title's own words, as is a label with no number at all.
        #expect(
            StudioViewModel.importedBookChapterTitle("3) Notes on Part II Methods", bookTitle: "B")
                == "3) Notes on Part II Methods"
        )
        #expect(
            StudioViewModel.importedBookChapterTitle("The Part I Played", bookTitle: "B") == "The Part I Played"
        )
        #expect(
            StudioViewModel.importedBookChapterTitle("Chapter 6 Cells", bookTitle: "B") == "Chapter 6 Cells"
        )
    }
}

// MARK: - AI Chapter Selection Validation

@Suite("StudioViewModel book chapter AI selection validation")
@MainActor
struct BookChapterAISelectionValidationTests {

    @Test("Does not second-guess the chapter-splitting AI semantically")
    func doesNotSecondGuessSelection() {
        let issue = StudioViewModel.bookChapterSelectionIssue(
            chapters: [(title: "Epilogue: quantum life", pageIndex: 284)],
            pageCount: 300
        )

        #expect(issue == nil)
    }

    @Test("Allows PDF chapter selection that starts after front matter")
    func allowsPDFSelectionAfterFrontMatter() {
        let issue = StudioViewModel.bookChapterSelectionIssue(
            chapters: [
                (title: "1) What Is Life?", pageIndex: 18),
                (title: "2) The Quantum Cell", pageIndex: 54)
            ],
            pageCount: 300
        )

        #expect(issue == nil)
    }
}

// MARK: - Chapter Sort Key

@Suite("StudioViewModel.chapterSortKey")
@MainActor
struct ChapterSortKeyTests {

    @Test("Numeric prefix gives correct key")
    func numericPrefix() {
        #expect(StudioViewModel.chapterSortKey("03 Genetics.txt") == 3)
        #expect(StudioViewModel.chapterSortKey("12 Advanced Topics.pdf") == 12)
        #expect(StudioViewModel.chapterSortKey("01 Introduction.txt") == 1)
    }

    @Test("Chapters sort in correct order")
    func sortOrder() {
        let files = [
            "03 Third.txt",
            "01 First.txt",
            "10 Tenth.txt",
            "02 Second.txt",
        ]
        let sorted = files.sorted { StudioViewModel.chapterSortKey($0) < StudioViewModel.chapterSortKey($1) }
        #expect(sorted[0] == "01 First.txt")
        #expect(sorted[1] == "02 Second.txt")
        #expect(sorted[2] == "03 Third.txt")
        #expect(sorted[3] == "10 Tenth.txt")
    }
}

// MARK: - Illustrated Reader Documents

@Suite("EPUBParser.readerDocument")
struct ReaderDocumentTests {

    /// PNG magic plus filler: small enough to travel verbatim, so these tests
    /// exercise the inlining transformation without depending on ImageIO output.
    private static let pngBytes =
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x21, count: 24)

    private func makeChapterDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBReaderDocument_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeImage(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pngBytes.write(to: url)
        return url
    }

    @Test("Inlines a chapter's local image as a data URI")
    func inlinesLocalImage() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeImage(named: "images/plate1.png", in: directory)

        let document = EPUBParser.readerDocument(
            fromHTML: """
            <html><body><p>Before</p>
            <img src="images/plate1.png" alt="Plate 1"/>
            <p>After</p></body></html>
            """,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(document.inlinedImageCount == 1)
        #expect(document.omittedImageCount == 0)
        #expect(document.html.contains("data:image/png;base64,\(Self.pngBytes.base64EncodedString())"))
        // The reference is gone: nothing in the document points at a file the
        // phone does not have.
        #expect(!document.html.contains("images/plate1.png"))
        #expect(document.html.contains("alt=\"Plate 1\""))
    }

    @Test("Inlines an SVG image referenced through xlink:href")
    func inlinesSVGReference() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\" height=\"4\"/></svg>"
        try Data(svg.utf8).write(to: directory.appendingPathComponent("figure.svg"))

        let document = EPUBParser.readerDocument(
            fromHTML: """
            <body><svg viewBox="0 0 4 4"><image xlink:href="figure.svg"/></svg></body>
            """,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(document.inlinedImageCount == 1)
        #expect(document.html.contains("data:image/svg+xml;base64,"))
    }

    @Test("Leaves a visible note where an image cannot be resolved")
    func notesUnresolvableImage() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = EPUBParser.readerDocument(
            fromHTML: #"<body><p>Text</p><img src="images/missing.png"/></body>"#,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(document.inlinedImageCount == 0)
        #expect(document.omittedImageCount == 1)
        #expect(document.html.contains("flm-image-omitted"))
        #expect(!document.html.contains("<img"))
    }

    @Test("Drops a remote image rather than letting the reader fetch it")
    func dropsRemoteImage() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = EPUBParser.readerDocument(
            fromHTML: #"<body><img src="https://tracker.example.com/pixel.png"/></body>"#,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(document.omittedImageCount == 1)
        #expect(!document.html.contains("tracker.example.com"))
    }

    @Test("Removes script, embeds and inline event handlers")
    func removesActiveMarkup() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = EPUBParser.readerDocument(
            fromHTML: """
            <html><head><link rel="stylesheet" href="style.css"></head>
            <body><script>fetch('https://example.com')</script>
            <iframe src="https://example.com"></iframe>
            <p onclick="alert(1)">Chapter One</p>
            <img src="x.png" srcset="https://example.com/2x.png 2x"/>
            </body></html>
            """,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(!document.html.lowercased().contains("<script"))
        #expect(!document.html.lowercased().contains("<iframe"))
        #expect(!document.html.lowercased().contains("<link"))
        #expect(!document.html.lowercased().contains("onclick"))
        #expect(!document.html.lowercased().contains("srcset"))
        #expect(document.html.contains("Chapter One"))
    }

    @Test("Keeps the formatting the plain-text reader used to throw away")
    func keepsFormattingMarkup() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = EPUBParser.readerDocument(
            fromHTML: """
            <body><h2>Chapter Two</h2><p>An <em>emphasized</em> word and a
            <blockquote>quotation</blockquote></p>
            <figure><img src="none.png"/><figcaption>Figure 2.1</figcaption></figure></body>
            """,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(document.html.contains("<h2>Chapter Two</h2>"))
        #expect(document.html.contains("<em>emphasized</em>"))
        #expect(document.html.contains("<blockquote>quotation</blockquote>"))
        #expect(document.html.contains("<figcaption>Figure 2.1</figcaption>"))
    }

    @Test("Stops inlining once the document byte budget is spent")
    func honorsByteBudget() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeImage(named: "a.png", in: directory)
        _ = try writeImage(named: "b.png", in: directory)

        let document = EPUBParser.readerDocument(
            fromHTML: #"<body><img src="a.png"/><img src="b.png"/></body>"#,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path,
            maximumBytes: 0
        )

        // No silent truncation: every image the budget refused says so on the page.
        #expect(document.inlinedImageCount == 0)
        #expect(document.omittedImageCount == 2)
    }

    @Test("A budget that fits one image keeps the earlier one")
    func budgetFollowsReadingOrder() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeImage(named: "first.png", in: directory)
        _ = try writeImage(named: "second.png", in: directory)
        let body = #"<body><img src="first.png"/><img src="second.png"/></body>"#
        let oneImage = "data:image/png;base64,\(Self.pngBytes.base64EncodedString())".utf8.count

        let document = EPUBParser.readerDocument(
            fromHTML: body,
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path,
            maximumBytes: body.utf8.count + oneImage
        )

        #expect(document.inlinedImageCount == 1)
        #expect(document.omittedImageCount == 1)
        // Reading order decides: the reader meets the surviving figure first.
        let inlinedAt = try #require(document.html.range(of: "data:image/png"))
        let notedAt = try #require(document.html.range(of: "flm-image-omitted"))
        #expect(inlinedAt.lowerBound < notedAt.lowerBound)
    }

    @Test("Already-inlined data URIs are left alone")
    func keepsExistingDataURIs() throws {
        let directory = try makeChapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = "data:image/png;base64,\(Self.pngBytes.base64EncodedString())"

        let document = EPUBParser.readerDocument(
            fromHTML: "<body><img src=\"\(existing)\"/></body>",
            chapterPath: directory.appendingPathComponent("chapter1.xhtml").path
        )

        #expect(document.inlinedImageCount == 1)
        #expect(document.omittedImageCount == 0)
        #expect(document.html.contains(existing))
    }

    @Test("Only markup chapters have a reader document")
    func rejectsNonMarkupChapters() {
        #expect(EPUBParser.isMarkupChapter("/Books/Title/Chapters/c1.xhtml"))
        #expect(EPUBParser.isMarkupChapter("/Books/Title/Chapters/c1.html"))
        #expect(!EPUBParser.isMarkupChapter("/Books/Title/Chapters/c1.pdf"))
        #expect(EPUBParser.readerDocument(forChapterAt: "/Books/Title/Chapters/c1.pdf") == nil)
    }
}
