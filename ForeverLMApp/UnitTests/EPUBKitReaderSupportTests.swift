import Foundation
import Testing
@testable import ForeverLM

@Suite("EPUBKitReaderSupport")
struct EPUBKitReaderSupportTests {
    @Test("Uses document headings when EPUB navigation only names page ranges")
    func replacesPageRangeTitlesWithHeadings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-reader-page-range-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let metaInf = chapters.appendingPathComponent("META-INF", isDirectory: true)
        let ops = chapters.appendingPathComponent("OPS", isDirectory: true)
        let textDir = ops.appendingPathComponent("Text", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try """
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
            <item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
          <navPoint id="one"><navLabel><text>Pages 22-23</text></navLabel><content src="Text/one.xhtml"/></navPoint>
          <navPoint id="two"><navLabel><text>Page 24</text></navLabel><content src="Text/two.xhtml"/></navPoint>
        </navMap></ncx>
        """.write(to: ops.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let one = textDir.appendingPathComponent("one.xhtml")
        let two = textDir.appendingPathComponent("two.xhtml")
        try "<html><body><h1>Introduction</h1></body></html>"
            .write(to: one, atomically: true, encoding: .utf8)
        try "<html><body><h1>1. Early History</h1></body></html>"
            .write(to: two, atomically: true, encoding: .utf8)

        let navigation = try #require(EPUBKitReaderSupport.navigation(containing: two.path))
        #expect(navigation.items.map(\.title) == ["Introduction", "1. Early History"])
        #expect(navigation.currentIndex == 1)
        #expect(navigation.positionLabel == "2 of 2")
    }

    @Test("Builds reader navigation from EPUBKit spine and TOC")
    func buildsReaderNavigationFromSpineAndTOC() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-reader-support-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let metaInf = chapters.appendingPathComponent("META-INF", isDirectory: true)
        let ops = chapters.appendingPathComponent("OPS", isDirectory: true)
        let textDir = ops.appendingPathComponent("Text", isDirectory: true)
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
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Reader Test</dc:title>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <docTitle><text>Reader Test</text></docTitle>
          <navMap>
            <navPoint id="nav1" playOrder="1">
              <navLabel><text>Opening</text></navLabel>
              <content src="Text/ch1.xhtml"/>
            </navPoint>
            <navPoint id="nav2" playOrder="2">
              <navLabel><text>Second Chapter</text></navLabel>
              <content src="Text/ch2.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """.write(to: ops.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let ch1 = textDir.appendingPathComponent("ch1.xhtml")
        let ch2 = textDir.appendingPathComponent("ch2.xhtml")
        try "<html><body><h1>Fallback One</h1><p>One.</p></body></html>"
            .write(to: ch1, atomically: true, encoding: .utf8)
        try "<html><body><h1>Fallback Two</h1><p>Two.</p></body></html>"
            .write(to: ch2, atomically: true, encoding: .utf8)

        let navigation = try #require(EPUBKitReaderSupport.navigation(containing: ch2.path))
        #expect(navigation.items.map(\.title) == ["Opening", "Second Chapter"])
        #expect(navigation.currentIndex == 1)
        #expect(navigation.previousItem?.path == ch1.path)
        #expect(navigation.nextItem == nil)
        #expect(navigation.positionLabel == "2 of 2")
    }

    @Test("Contents follows ingested sources: drops non-source spine files and flags archived")
    func filtersNavigationToIngestedChapterSources() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-reader-filter-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let metaInf = chapters.appendingPathComponent("META-INF", isDirectory: true)
        let ops = chapters.appendingPathComponent("OPS", isDirectory: true)
        let textDir = ops.appendingPathComponent("Text", isDirectory: true)
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
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Reader Test</dc:title>
          </metadata>
          <manifest>
            <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="cover"/>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let cover = textDir.appendingPathComponent("cover.xhtml")
        let ch1 = textDir.appendingPathComponent("ch1.xhtml")
        let ch2 = textDir.appendingPathComponent("ch2.xhtml")
        try "<html><body><h1>Cover</h1></body></html>".write(to: cover, atomically: true, encoding: .utf8)
        try "<html><body><h1>One</h1></body></html>".write(to: ch1, atomically: true, encoding: .utf8)
        try "<html><body><h1>Two</h1></body></html>".write(to: ch2, atomically: true, encoding: .utf8)

        // cover.xhtml was never ingested as a source; ch1 is archived, ch2 is active.
        let sourceChapterPaths = ["OPS/Text/ch1.xhtml": true, "OPS/Text/ch2.xhtml": false]
        let navigation = try #require(
            EPUBKitReaderSupport.navigation(containing: ch2.path, sourceChapterPaths: sourceChapterPaths)
        )

        #expect(navigation.items.map(\.path) == [ch1.path, ch2.path])
        #expect(navigation.items.first(where: { $0.path == ch1.path })?.isArchived == true)
        #expect(navigation.items.first(where: { $0.path == ch2.path })?.isArchived == false)
        #expect(navigation.positionLabel == "2 of 2")
    }

    @Test("Contents falls back to imported combined chapters when source paths do not match raw spine")
    func filtersNavigationToCombinedChapterSources() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-reader-combined-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let metaInf = chapters.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = chapters.appendingPathComponent("OEBPS", isDirectory: true)
        let textDir = oebps.appendingPathComponent("xhtml", isDirectory: true)
        let combinedDir = chapters.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: combinedDir, withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="raw1" href="xhtml/xhtml-0-5.xhtml" media-type="application/xhtml+xml"/>
            <item id="raw2" href="xhtml/xhtml-0-6.xhtml" media-type="application/xhtml+xml"/>
            <item id="raw3" href="xhtml/xhtml-0-7.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="raw1"/>
            <itemref idref="raw2"/>
            <itemref idref="raw3"/>
          </spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try "<html><body><h1>Introduction</h1></body></html>"
            .write(to: textDir.appendingPathComponent("xhtml-0-5.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><p>Continuation.</p></body></html>"
            .write(to: textDir.appendingPathComponent("xhtml-0-6.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><h1>1. The Current Situation</h1></body></html>"
            .write(to: textDir.appendingPathComponent("xhtml-0-7.xhtml"), atomically: true, encoding: .utf8)

        let combinedIntro = combinedDir.appendingPathComponent("01 Introduction.xhtml")
        let combinedCurrent = combinedDir.appendingPathComponent("02 The Current Situation.xhtml")
        try "<html><body><h1>Introduction</h1><p>Combined intro.</p></body></html>"
            .write(to: combinedIntro, atomically: true, encoding: .utf8)
        try "<html><body><h1>1. The Current Situation</h1><p>Combined chapter.</p></body></html>"
            .write(to: combinedCurrent, atomically: true, encoding: .utf8)

        let sourceChapterPaths = [
            "ForeverLMCombinedChapters/01 Introduction.xhtml": false,
            "ForeverLMCombinedChapters/02 The Current Situation.xhtml": false
        ]
        let navigation = try #require(
            EPUBKitReaderSupport.navigation(containing: combinedIntro.path, sourceChapterPaths: sourceChapterPaths)
        )

        #expect(navigation.items.map(\.path) == [combinedIntro.path, combinedCurrent.path])
        #expect(navigation.items.map(\.title) == ["Introduction", "1. The Current Situation"])
        #expect(navigation.currentIndex == 0)
    }

    @Test("Strips import sort prefix from combined chapter filenames without headings")
    func stripsImportSortPrefixFromCombinedChapterFilenames() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-reader-double-number-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let combinedDir = chapters.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: combinedDir, withIntermediateDirectories: true)

        let combinedIntro = combinedDir.appendingPathComponent("01 Introduction.xhtml")
        let combinedCurrent = combinedDir.appendingPathComponent("02 1) The Current Situation.xhtml")
        try "<html><head><title>Introduction</title></head><body><p>Intro body.</p></body></html>"
            .write(to: combinedIntro, atomically: true, encoding: .utf8)
        try "<html><head><title>1) The Current Situation</title></head><body><p>Chapter body.</p></body></html>"
            .write(to: combinedCurrent, atomically: true, encoding: .utf8)

        let sourceChapterPaths = [
            "ForeverLMCombinedChapters/01 Introduction.xhtml": false,
            "ForeverLMCombinedChapters/02 1) The Current Situation.xhtml": false
        ]
        let navigation = try #require(
            EPUBKitReaderSupport.navigation(containing: combinedCurrent.path, sourceChapterPaths: sourceChapterPaths)
        )

        #expect(navigation.items.map(\.title) == ["Introduction", "1) The Current Situation"])
        #expect(navigation.currentIndex == 1)
        #expect(navigation.positionLabel == "2 of 2")
    }

    @Test("Uses injected headings from newly imported combined chapter files")
    func usesInjectedHeadingsFromNewCombinedChapterFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-reader-new-combined-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let combinedDir = chapters.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: combinedDir, withIntermediateDirectories: true)

        let combinedIntro = combinedDir.appendingPathComponent("01 Introduction.xhtml")
        let combinedCurrent = combinedDir.appendingPathComponent("02 The Current Situation.xhtml")
        try "<html><body><h1>Introduction</h1><p>Intro body.</p></body></html>"
            .write(to: combinedIntro, atomically: true, encoding: .utf8)
        try "<html><body><h1>1) The Current Situation</h1><p>Chapter body.</p></body></html>"
            .write(to: combinedCurrent, atomically: true, encoding: .utf8)

        let sourceChapterPaths = [
            "ForeverLMCombinedChapters/01 Introduction.xhtml": false,
            "ForeverLMCombinedChapters/02 The Current Situation.xhtml": false
        ]
        let navigation = try #require(
            EPUBKitReaderSupport.navigation(containing: combinedCurrent.path, sourceChapterPaths: sourceChapterPaths)
        )

        #expect(navigation.items.map(\.title) == ["Introduction", "1) The Current Situation"])
    }

    @Test("Combined chapter assets resolve from chapter directory, not Chapters root")
    func combinedChapterAssetsResolveFromChapterDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-html-base-\(UUID().uuidString)", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let combinedDir = chapters.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
        let imageDir = chapters.appendingPathComponent("OEBPS/image", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: combinedDir, withIntermediateDirectories: true)

        let imageURL = imageDir.appendingPathComponent("figure.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: imageURL)
        let chapterURL = combinedDir.appendingPathComponent("02 Chapter.xhtml")
        try """
        <!doctype html>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../OEBPS/image/figure.jpg"/></body></html>
        """.write(to: chapterURL, atomically: true, encoding: .utf8)

        let imageReference = "../OEBPS/image/figure.jpg"
        let chapterBase = EPUBKitReaderSupport.htmlDocumentBaseURL(for: chapterURL.path)
        let resolvedFromChapter = URL(string: imageReference, relativeTo: chapterBase)!.standardizedFileURL.path
        let resolvedFromChaptersRoot = URL(string: imageReference, relativeTo: chapters)!.standardizedFileURL.path

        #expect(resolvedFromChapter == imageURL.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: resolvedFromChaptersRoot))
    }

    @Test("Strips legacy HTML5 doctype from combined chapter XHTML")
    func stripsLegacyHTML5DoctypeFromCombinedChapterXHTML() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-normalize-xhtml-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let chapter = root.appendingPathComponent("04 Dead Ends.xhtml")
        try """
        <!doctype html>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Dead ends.</p></body></html>
        """.write(to: chapter, atomically: true, encoding: .utf8)

        let normalized = try #require(EPUBKitReaderSupport.normalizedXHTMLContent(for: chapter.path))
        #expect(!normalized.lowercased().contains("<!doctype html>"))
        #expect(normalized.contains("Dead ends."))
        #expect((try? XMLDocument(data: Data(normalized.utf8), options: [])) != nil)
        #expect(EPUBKitReaderSupport.normalizedXHTMLContent(for: (root.appendingPathComponent("missing.xhtml")).path) == nil)
    }
}
