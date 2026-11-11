import Foundation
import Testing
@testable import ForeverLM

@Suite("EPUBKitReaderSupport")
struct EPUBKitReaderSupportTests {
    @Test("A chapter's path is named from inside its book's Chapters folder")
    func relativeChapterPathStartsInsideTheChaptersFolder() {
        #expect(
            EPUBKitReaderSupport.relativeChapterPath(
                for: "/Library/Books/Field Guide/Chapters/ForeverLMCombinedChapters/02 Chapter.xhtml"
            ) == "ForeverLMCombinedChapters/02 Chapter.xhtml"
        )
        #expect(
            EPUBKitReaderSupport.relativeChapterPath(
                for: "/Library/Books/Field_Guide_Chapters/OEBPS/../OEBPS/xhtml/one.xhtml"
            ) == "OEBPS/xhtml/one.xhtml"
        )
        #expect(EPUBKitReaderSupport.relativeChapterPath(for: "/Library/Articles/article.html") == nil)
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

    @Test("Strips the HTML5 doctype from combined chapter XHTML")
    func stripsHTML5DoctypeFromCombinedChapterXHTML() throws {
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
