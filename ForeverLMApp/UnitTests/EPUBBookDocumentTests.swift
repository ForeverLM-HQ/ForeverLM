import Foundation
import Testing
@testable import ForeverLM

@Suite("EPUB book read as one document")
struct EPUBBookDocumentTests {
    /// A book folder the way an EPUB import leaves it: `Chapters/OEBPS/…`
    /// with a stylesheet and a picture, plus a combined chapter in
    /// `ForeverLMCombinedChapters` that points back up into `OEBPS`.
    private struct Fixture {
        let root: URL
        let chapters: URL
        let one: URL
        let two: URL
        let combined: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("epub-book-document-\(UUID().uuidString)", isDirectory: true)
            chapters = root.appendingPathComponent("Book/Chapters", isDirectory: true)
            let oebps = chapters.appendingPathComponent("OEBPS", isDirectory: true)
            let combinedDir = chapters.appendingPathComponent("ForeverLMCombinedChapters", isDirectory: true)
            try FileManager.default.createDirectory(at: oebps.appendingPathComponent("css"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: oebps.appendingPathComponent("image"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: combinedDir, withIntermediateDirectories: true)
            try "p { color: black; }".write(to: oebps.appendingPathComponent("css/book.css"), atomically: true, encoding: .utf8)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: oebps.appendingPathComponent("image/plate.png"))

            one = oebps.appendingPathComponent("one.xhtml")
            two = oebps.appendingPathComponent("two.xhtml")
            combined = combinedDir.appendingPathComponent("03 Photos.xhtml")
            try """
            <?xml version='1.0' encoding='UTF-8'?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="nl-NL">
            <head>
            <title>One</title>
            <link href="css/book.css" rel="stylesheet" type="text/css"/>
            <style>@font-face { font-family: Book; src: url(fonts/book.otf); }</style>
            </head>
            <body id="chapter-one" class="frontmatter">
            <h2><a id="anchor-one"/>Over de auteur</h2>
            <p>See <a href="two.xhtml#note-1">the note</a>.</p>
            <script>alert('no')</script>
            </body>
            </html>
            """.write(to: one, atomically: true, encoding: .utf8)
            try """
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><link href="css/book.css" rel="stylesheet" type="text/css"/></head>
            <body><h1>Proloog</h1><p id="note-1">A note.</p><img src="image/plate.png" alt=""/></body>
            </html>
            """.write(to: two, atomically: true, encoding: .utf8)
            try """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Photos</title></head>
            <body><h1>Photos</h1><img src="../OEBPS/image/plate.png" alt=""/></body></html>
            """.write(to: combined, atomically: true, encoding: .utf8)
        }

        var inputs: [EPUBBookDocument.Input] {
            [
                .init(sourceID: "src-one", title: "Over de auteur", path: one.path),
                .init(sourceID: "src-two", title: "Proloog", path: two.path),
                .init(sourceID: "src-photos", title: "Photos", path: combined.path),
            ]
        }
    }

    @Test("Every chapter is one section, in reading order, named by its source")
    func chaptersBecomeSections() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let book = try #require(EPUBBookDocument.assemble(fixture.inputs))
        #expect(book.chapters.map(\.sourceID) == ["src-one", "src-two", "src-photos"])
        #expect(book.baseURL.standardizedFileURL.path == fixture.chapters.standardizedFileURL.path)

        let html = book.html
        let one = try #require(html.range(of: #"data-flm-chapter="src-one""#))
        let two = try #require(html.range(of: #"data-flm-chapter="src-two""#))
        let photos = try #require(html.range(of: #"data-flm-chapter="src-photos""#))
        #expect(one.lowerBound < two.lowerBound && two.lowerBound < photos.lowerBound)
        // The body's own id and class stay on its section, where the
        // publisher's CSS and links look for them.
        #expect(html.contains(#"<section class="flm-book-chapter frontmatter" id="chapter-one" data-flm-chapter="src-one" data-flm-chapter-path="OEBPS/one.xhtml">"#))
        #expect(html.contains(#"<html lang="nl-NL">"#))
        #expect(!html.contains("alert("))
    }

    @Test("References resolve from the Chapters folder, and each stylesheet is linked once")
    func referencesAreRebasedToTheChaptersFolder() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let html = try #require(EPUBBookDocument.assemble(fixture.inputs)).html
        #expect(html.components(separatedBy: #"href="OEBPS/css/book.css""#).count == 2)
        #expect(html.contains(#"url("OEBPS/fonts/book.otf")"#))
        #expect(html.contains(#"href="OEBPS/two.xhtml#note-1""#))
        // A chapter picture, and the combined chapter's `../OEBPS/…` one.
        #expect(html.components(separatedBy: #"src="OEBPS/image/plate.png""#).count == 3)
        #expect(!html.contains("../OEBPS"))
    }

    @Test("An XHTML empty element stays empty when the book is parsed as HTML")
    func selfClosingElementsAreExpanded() {
        #expect(EPUBBookDocument.expandingSelfClosingTags(in: #"<h2><a id="x"/>Title</h2>"#)
            == #"<h2><a id="x"></a>Title</h2>"#)
        #expect(EPUBBookDocument.expandingSelfClosingTags(in: #"<p class="gap"/><div/>"#)
            == #"<p class="gap"></p><div></div>"#)
        // Void elements are left alone.
        #expect(EPUBBookDocument.expandingSelfClosingTags(in: #"<br/><img src="a.png"/><hr />"#)
            == #"<br/><img src="a.png"/><hr />"#)
    }

    @Test("A chapter whose file is missing, or filed in another book's folder, is left out")
    func unreadableChaptersAreSkipped() throws {
        let fixture = try Fixture()
        let elsewhere = try Fixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: elsewhere.root)
        }

        var inputs = fixture.inputs
        inputs.insert(.init(sourceID: "src-missing", title: "Gone", path: fixture.chapters.appendingPathComponent("OEBPS/gone.xhtml").path), at: 1)
        inputs.append(.init(sourceID: "src-other", title: "Other", path: elsewhere.one.path))
        let book = try #require(EPUBBookDocument.assemble(inputs, anchoredAt: fixture.two.path))
        #expect(book.chapters.map(\.sourceID) == ["src-one", "src-two", "src-photos"])

        // The book is the opened chapter's folder, whichever chapter is first.
        let other = try #require(EPUBBookDocument.assemble(inputs, anchoredAt: elsewhere.one.path))
        #expect(other.chapters.map(\.sourceID) == ["src-other"])
    }

    @Test("The page is written into the Chapters folder once, and again only when it changes")
    func writesTheDocumentFile() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let book = try #require(EPUBBookDocument.assemble(fixture.inputs)).writingFile()
        let fileURL = try #require(book.fileURL)
        #expect(fileURL.deletingLastPathComponent().standardizedFileURL.path == fixture.chapters.standardizedFileURL.path)
        #expect(fileURL.lastPathComponent.hasPrefix("."))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == book.html)
        #expect(book.documentURL == fileURL)

        let written = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        _ = try #require(EPUBBookDocument.assemble(fixture.inputs)).writingFile()
        let rewritten = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        #expect(written == rewritten)
    }

    @Test("A position report names its chapter and the chapters read past")
    func parsesPositionReports() throws {
        let report = try #require(EPUBBookPositionReport(body: [
            "chapter": "src-two",
            "fraction": NSNumber(value: 1.4),
            "passed": ["src-one", "", "src-two"],
            "userInitiated": NSNumber(value: true),
        ] as [String: Any]))
        #expect(report.position == EPUBBookPosition(sourceID: "src-two", fraction: 1))
        #expect(report.passedSourceIDs == ["src-one"])
        #expect(report.userInitiated)
        #expect(EPUBBookPositionReport(body: ["fraction": 0.5]) == nil)
        #expect(EPUBBookPositionReport(body: "src-two") == nil)
    }
}
