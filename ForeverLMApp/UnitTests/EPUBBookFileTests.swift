import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// An EPUB book kept as one file (schema 170): a chapter keeps its address under the book's
/// `Chapters` folder, which names the entry inside the book's `.epub` once the folder is gone.
enum EPUBBookFileFixture {
    static let chapterOne = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title>
    <link rel="stylesheet" href="../Styles/book.css"/></head>
    <body><h1>Water</h1><p>Water is a polar molecule.</p><img src="../Images/drop.png"/></body></html>
    """
    static let chapterTwo = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head>
    <body><h1>Ions</h1><p>Ions carry charge.</p></body></html>
    """
    static let picture = Data((0..<2_000).map { UInt8($0 % 251) })

    /// `Books/Foo` in a fresh directory, with the book unpacked in its `Chapters` folder the way
    /// builds before 170 left it, and the reader's assembled page written beside the chapters.
    static func unpackedBook(_ name: String) throws -> (folder: URL, chapters: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-book-\(name)-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Books/Foo", isDirectory: true)
        let chapters = folder.appendingPathComponent("Chapters", isDirectory: true)
        let files: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("<package/>".utf8),
            "OEBPS/Text/one.xhtml": Data(chapterOne.utf8),
            "OEBPS/Text/two.xhtml": Data(chapterTwo.utf8),
            "OEBPS/Styles/book.css": Data("p { margin: 0 }".utf8),
            "OEBPS/Images/drop.png": picture,
            EPUBBookDocument.fileName: Data("<html>the reader's page</html>".utf8),
        ]
        for (name, data) in files {
            let url = chapters.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return (folder, chapters)
    }

    /// The book's own file as it was imported: an EPUB holding an entry the folder lacks.
    static func originalFile(in folder: URL) throws -> URL {
        let scratch = folder.deletingLastPathComponent().appendingPathComponent("original-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: scratch.appendingPathComponent("mimetype"))
        try Data("only in the original".utf8).write(to: scratch.appendingPathComponent("OEBPS/notes.txt"))
        let file = folder.appendingPathComponent("Foo.epub")
        try EPUBBookFiles.pack(scratch, original: nil, to: file)
        return file
    }

    static func removeRoot(of folder: URL) {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent())
    }
}

@Suite("An EPUB book is one file")
struct EPUBBookFileTests {
    private typealias Fixture = EPUBBookFileFixture

    @Test("Packing keeps every file of the folder and every entry of the book's file, mimetype first and stored")
    func packsEverything() throws {
        let (folder, chapters) = try Fixture.unpackedBook("pack")
        defer { Fixture.removeRoot(of: folder) }
        let file = try Fixture.originalFile(in: folder)

        try EPUBBookFiles.pack(chapters, original: file, to: file, skipping: [EPUBBookDocument.fileName])

        let names = try #require(EPUBBookFiles.entryNames(inBook: file.path))
        #expect(names.first == "mimetype")
        #expect(Set(names) == [
            "mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/Text/one.xhtml", "OEBPS/Text/two.xhtml",
            "OEBPS/Styles/book.css", "OEBPS/Images/drop.png", "OEBPS/notes.txt",
        ], "the reader's page is not the book's")
        let data = try Data(contentsOf: file)
        let mimetype = try #require(EPUBParser.zipCentralDirectory(data)?.first)
        #expect(mimetype.method == 0, "EPUB requires the mimetype stored")
        #expect(EPUBBookFiles.entry("OEBPS/notes.txt", inBook: file.path) == Data("only in the original".utf8))
        #expect(EPUBBookFiles.entry("OEBPS/Images/drop.png", inBook: file.path) == Fixture.picture)
    }

    @Test("Packing drops what the book no longer holds, from the folder and from the book's file alike")
    func packDrops() throws {
        let (folder, chapters) = try Fixture.unpackedBook("drop")
        defer { Fixture.removeRoot(of: folder) }
        let file = try Fixture.originalFile(in: folder)

        try EPUBBookFiles.pack(
            chapters,
            original: file,
            to: file,
            skipping: [EPUBBookDocument.fileName],
            dropping: ["OEBPS/notes.txt", "OEBPS/Text/two.xhtml"]
        )

        let names = Set(try #require(EPUBBookFiles.entryNames(inBook: file.path)))
        #expect(!names.contains("OEBPS/notes.txt"), "an entry only the book's file held")
        #expect(!names.contains("OEBPS/Text/two.xhtml"), "a file of the folder")
        #expect(names.contains("OEBPS/Text/one.xhtml") && names.contains("OEBPS/Images/drop.png"))
    }

    @Test("A book added again over a different file keeps the documents this app wrote into the old one")
    func appEntriesCarryOver() throws {
        let (folder, chapters) = try Fixture.unpackedBook("carry")
        defer { Fixture.removeRoot(of: folder) }
        let joined = Data("<html><body><h1>Water and Ions</h1></body></html>".utf8)
        let whole = Data("<html><body>the whole book</body></html>".utf8)
        for (name, data) in [("ForeverLMCombinedChapters/01 Water and Ions.xhtml", joined), (EPUBParser.wholeBookEntry, whole)] {
            let url = chapters.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let old = folder.appendingPathComponent("Old.epub")
        try EPUBBookFiles.pack(chapters, original: nil, to: old, skipping: [EPUBBookDocument.fileName])
        let carried = EPUBBookFiles.appEntries(inBook: old.path)
        #expect(Set(carried.map(\.name)) == ["ForeverLMCombinedChapters/01 Water and Ions.xhtml", EPUBParser.wholeBookEntry])

        // The learner's own copy, which holds none of them.
        let fresh = try Fixture.originalFile(in: folder)
        #expect(EPUBBookFiles.appEntries(inBook: fresh.path).isEmpty)
        try EPUBBookFiles.addEntries(carried, toBook: fresh)
        #expect(EPUBBookFiles.entry(EPUBParser.wholeBookEntry, inBook: fresh.path) == whole)
        #expect(EPUBBookFiles.entry("ForeverLMCombinedChapters/01 Water and Ions.xhtml", inBook: fresh.path) == joined)
        #expect(EPUBBookFiles.entry("OEBPS/notes.txt", inBook: fresh.path) == Data("only in the original".utf8))
        #expect(EPUBBookFiles.entryNames(inBook: fresh.path)?.first == "mimetype")
        #expect(EPUBBookFiles.appEntries(inBook: folder.appendingPathComponent("missing.epub").path).isEmpty)
    }

    @Test("A chapter's address reads its file while the book is unpacked, and its entry once the folder is gone")
    func readsByAddress() throws {
        let (folder, chapters) = try Fixture.unpackedBook("address")
        defer { Fixture.removeRoot(of: folder) }
        let file = try Fixture.originalFile(in: folder)
        let one = chapters.appendingPathComponent("OEBPS/Text/one.xhtml").path
        let picture = chapters.appendingPathComponent("OEBPS/Images/drop.png").path

        #expect(EPUBBookFiles.location(ofPath: one) == nil, "still unpacked: the file on disk is the chapter")
        #expect(EPUBBookFiles.text(atPath: one) == Fixture.chapterOne)

        try EPUBBookFiles.pack(chapters, original: file, to: file, skipping: [EPUBBookDocument.fileName])
        try FileManager.default.removeItem(at: chapters)

        #expect(EPUBBookFiles.location(ofPath: one) == .init(book: file.path, entry: "OEBPS/Text/one.xhtml"))
        #expect(EPUBBookFiles.text(atPath: one) == Fixture.chapterOne)
        #expect(EPUBBookFiles.contents(atPath: picture) == Fixture.picture)
        #expect(EPUBBookFiles.exists(atPath: one))
        #expect(EPUBBookFiles.exists(atPath: chapters.appendingPathComponent("OEBPS/Text/../Text/two.xhtml").path))
        #expect(!EPUBBookFiles.exists(atPath: chapters.appendingPathComponent("OEBPS/Text/three.xhtml").path))
        #expect(!EPUBBookFiles.exists(atPath: chapters.appendingPathComponent(EPUBBookDocument.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: chapters.path), "nothing unpacked is left beside the book")
        // The text every reader of a chapter goes through.
        #expect(EPUBParser.stripHTML(EPUBBookFiles.text(atPath: one) ?? "").contains("polar molecule"))
    }

    @Test("Where a folder's book is packed: the file named for it, else its only EPUB, else a new one")
    func packingTarget() throws {
        let (folder, chapters) = try Fixture.unpackedBook("target")
        defer { Fixture.removeRoot(of: folder) }

        let none = EPUBBookFiles.packingTarget(inFolder: folder.path)
        #expect(none.destination.path == folder.appendingPathComponent("Foo.epub").path)
        #expect(none.original == nil)

        let other = folder.appendingPathComponent("Imported Title.epub")
        try Data("not read".utf8).write(to: other)
        #expect(EPUBBookFiles.packingTarget(inFolder: folder.path).destination.path == other.path)
        #expect(EPUBBookFiles.packingTarget(inFolder: folder.path).original?.path == other.path)
        try FileManager.default.removeItem(at: other)

        // An EPUB an older build unpacked under the book file's own name is replaced by the file.
        let unpackedFile = folder.appendingPathComponent("Foo.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackedFile, withIntermediateDirectories: true)
        let target = EPUBBookFiles.packingTarget(inFolder: folder.path)
        #expect(target.destination.path == unpackedFile.path)
        #expect(target.original == nil)
        try EPUBBookFiles.pack(chapters, original: target.original, to: target.destination)
        var isDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: unpackedFile.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        #expect(EPUBBookFiles.bookFile(inFolder: folder.path) == unpackedFile.path)
    }

    @Test("A path under no Chapters folder, or a folder with no book file, names no entry")
    func noLocation() throws {
        #expect(EPUBBookFiles.location(ofPath: "/tmp/elsewhere/one.xhtml") == nil)
        #expect(EPUBBookFiles.location(ofPath: "/tmp/no-book-\(UUID().uuidString)/Chapters/one.xhtml") == nil)
        #expect(EPUBBookFiles.split("/a/Books/Foo/Chapters/OEBPS/Text/one.xhtml")?.chapters == "/a/Books/Foo/Chapters")
        #expect(EPUBBookFiles.split("/a/Books/Foo/Chapters/OEBPS/Text/one.xhtml")?.entry == "OEBPS/Text/one.xhtml")
        #expect(EPUBBookFiles.split("/a/Books/Foo/Chapters/") == nil)
    }

    @Test("The reader's scheme serves a packed book's entries and the pages it was given, and nothing else")
    func scheme() throws {
        let (folder, chapters) = try Fixture.unpackedBook("scheme")
        defer { Fixture.removeRoot(of: folder) }
        let file = try Fixture.originalFile(in: folder)
        try EPUBBookFiles.pack(chapters, original: file, to: file, skipping: [EPUBBookDocument.fileName])
        try FileManager.default.removeItem(at: chapters)

        let one = chapters.appendingPathComponent("OEBPS/Text/one.xhtml").path
        let url = try #require(EPUBBookScheme.url(forPath: one))
        #expect(url.scheme == EPUBBookScheme.name)
        #expect(EPUBBookScheme.path(of: url) == one)
        #expect(EPUBBookScheme.isLocalDocument(url))
        #expect(EPUBBookScheme.isLocalDocument(URL(fileURLWithPath: one)))
        #expect(!EPUBBookScheme.isLocalDocument(URL(string: "https://example.com/one.xhtml")))
        // A relative link resolves against the chapter's address as it did on disk.
        let css = try #require(URL(string: "../Styles/book.css", relativeTo: url)?.absoluteURL)
        #expect(EPUBBookScheme.path(of: css) == chapters.appendingPathComponent("OEBPS/Styles/book.css").path)

        let chapter = try #require(EPUBBookScheme.response(forPath: one))
        #expect(chapter.data == Data(Fixture.chapterOne.utf8))
        #expect(chapter.mimeType == "application/xhtml+xml")
        #expect(EPUBBookScheme.response(forPath: chapters.appendingPathComponent("OEBPS/Images/drop.png").path)?.mimeType == "image/png")

        let page = chapters.appendingPathComponent(EPUBBookDocument.fileName).path
        #expect(EPUBBookScheme.response(forPath: page) == nil)
        EPUBBookScheme.register(page: "<html>the book</html>", atPath: page)
        #expect(EPUBBookScheme.response(forPath: page)?.data == Data("<html>the book</html>".utf8))
        #expect(EPUBBookScheme.response(forPath: page)?.mimeType == "text/html")

        // A file on disk outside a book's file is never served.
        #expect(EPUBBookScheme.response(forPath: file.path) == nil)
        #expect(EPUBBookScheme.response(forPath: "/etc/hosts") == nil)
    }
}

@Suite("An EPUB book kept as one file in the Reader")
struct EPUBBookFileReaderTests {
    private typealias Fixture = EPUBBookFileFixture

    @Test("The book's page is assembled from its file and served from memory; nothing is written beside it")
    func assemblesFromTheFile() throws {
        let (folder, chapters) = try Fixture.unpackedBook("reader")
        defer { Fixture.removeRoot(of: folder) }
        let file = try Fixture.originalFile(in: folder)
        try EPUBBookFiles.pack(chapters, original: file, to: file, skipping: [EPUBBookDocument.fileName])
        try FileManager.default.removeItem(at: chapters)

        let inputs = [
            EPUBBookDocument.Input(sourceID: "src-one", title: "Water", path: chapters.appendingPathComponent("OEBPS/Text/one.xhtml").path),
            EPUBBookDocument.Input(sourceID: "src-two", title: "Ions", path: chapters.appendingPathComponent("OEBPS/Text/two.xhtml").path),
        ]
        let book = try #require(EPUBBookDocument.assemble(inputs)).writingFile()

        #expect(book.chapters.map(\.sourceID) == ["src-one", "src-two"])
        #expect(book.html.contains("polar molecule") && book.html.contains("Ions carry charge"))
        #expect(book.baseURL.scheme == EPUBBookScheme.name)
        let page = try #require(book.fileURL)
        #expect(page.scheme == EPUBBookScheme.name)
        #expect(book.documentURL == page)
        #expect(EPUBBookScheme.response(forPath: try #require(EPUBBookScheme.path(of: page)))?.data == Data(book.html.utf8))
        // The chapter's picture, as the page names it, is served from the book's file.
        let picture = try #require(URL(string: "OEBPS/Images/drop.png", relativeTo: book.baseURL)?.absoluteURL)
        #expect(EPUBBookScheme.response(forPath: try #require(EPUBBookScheme.path(of: picture)))?.data == Fixture.picture)
        #expect(!FileManager.default.fileExists(atPath: chapters.path))
    }
}

/// An EPUB reads the moment it is added (docs-site/books.md): its spine is written into its file as
/// one document, read as a book of one chapter until the chapter model has grouped its documents,
/// and what the learner marks or reaches meanwhile moves to the chapter holding it.
@Suite("An EPUB reads whole until its chapters are made")
struct EPUBWholeBookTests {
    private typealias Fixture = EPUBBookFileFixture

    @Test("The whole book, written into the book's file, reads in the Reader as a book of one chapter")
    func wholeBookReads() throws {
        let (folder, chapters) = try Fixture.unpackedBook("whole-reader")
        defer { Fixture.removeRoot(of: folder) }
        let file = try Fixture.originalFile(in: folder)
        try EPUBBookFiles.pack(chapters, original: file, to: file, skipping: [EPUBBookDocument.fileName])
        try FileManager.default.removeItem(at: chapters)

        let staging = folder.appendingPathComponent("Chapters.incoming", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let inventory = try EPUBParser.extractInventory(from: file.path, to: staging.path)
        #expect(inventory.documents.map(\.file) == ["OEBPS/Text/one.xhtml", "OEBPS/Text/two.xhtml"])
        let entry = try EPUBParser.writeWholeBook(from: inventory, title: "Foo")
        try EPUBBookFiles.pack(staging, original: file, to: file)

        let whole = chapters.appendingPathComponent(entry).path
        let book = try #require(EPUBBookDocument.assemble([
            EPUBBookDocument.Input(sourceID: "whole", title: "Foo", path: whole),
        ])).writingFile()
        #expect(book.chapters.map(\.sourceID) == ["whole"])
        #expect(book.html.contains("polar molecule") && book.html.contains("Ions carry charge"))
        // Its picture, named from the Chapters root as every chapter's is, comes from the book's file.
        #expect(book.html.contains("OEBPS/Images/drop.png"))
        let picture = try #require(URL(string: "OEBPS/Images/drop.png", relativeTo: book.baseURL)?.absoluteURL)
        let picturePath = try #require(EPUBBookScheme.path(of: picture))
        #expect(EPUBBookScheme.response(forPath: picturePath)?.data == Fixture.picture)
        #expect(!FileManager.default.fileExists(atPath: chapters.path), "nothing unpacked is left beside the book")
    }

    /// Four documents in reading order — a cover, two chapters, notes — and the inventory the
    /// chapter model is shown, with word counts chosen so places are easy to count.
    private static func book(_ name: String) throws -> (root: URL, inventory: EPUBParser.Inventory) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-whole-\(name)-\(UUID().uuidString)", isDirectory: true)
        let documents: [(file: String, html: String, words: Int)] = [
            ("OEBPS/cover.xhtml", "<html><body><p>Cover of the book.</p></body></html>", 10),
            ("OEBPS/one.xhtml", "<html><body><h1>Water</h1><p>Water is a polar molecule. The membrane holds a charge.</p><img src=\"Images/drop.png\"/></body></html>", 40),
            ("OEBPS/two.xhtml", "<html><body><h1>Ions</h1><p>Ions carry charge across the membrane.</p></body></html>", 40),
            ("OEBPS/notes.xhtml", "<html><body><p>Notes on sources.</p></body></html>", 10),
        ]
        var inventoryDocuments: [EPUBParser.Inventory.Document] = []
        for (index, document) in documents.enumerated() {
            let url = root.appendingPathComponent(document.file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try document.html.write(to: url, atomically: true, encoding: .utf8)
            inventoryDocuments.append(EPUBParser.Inventory.Document(
                index: index, path: url.path, file: document.file, inSpine: true,
                headings: [], opening: "", wordCount: document.words
            ))
        }
        let inventory = EPUBParser.Inventory(
            rootDir: root.path, documents: inventoryDocuments, tableOfContents: [], missingFiles: [], unreadableEntryCount: 0
        )
        return (root, inventory)
    }

    private static let made = Date(timeIntervalSince1970: 1_700_000_000)

    private static func mark(_ id: String, _ anchor: ReaderTextAnchor, pictures: [ReaderImageAnchor] = []) -> SourceHighlight {
        SourceHighlight(
            id: id, sourceID: "whole", quote: anchor.exact, note: "Why?", color: .default,
            anchor: anchor, imageAnchors: pictures, createdAt: made, updatedAt: made
        )
    }

    /// The model's grouping, which leaves out the cover and the notes.
    private static let grouping = [
        EPUBParser.ChapterSpan(title: "Water", firstDocument: 1, lastDocument: 1),
        EPUBParser.ChapterSpan(title: "Ions", firstDocument: 2, lastDocument: 2),
    ]

    @Test("Each mark goes to the chapter its passage is in, found as the Reader finds it, and the place reached keeps its depth")
    func planMovesMarksAndPlace() throws {
        let (root, inventory) = try Self.book("plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let ions = Self.mark("ions", ReaderTextAnchor(exact: "Ions carry charge", offset: 90))
        // "membrane" is in both chapters; its context says the second, though its offset is the first's.
        let membrane = Self.mark("membrane", ReaderTextAnchor(exact: "membrane", prefix: "charge across the ", suffix: ".", offset: 50))
        // In the notes, which the grouping left out.
        let notes = Self.mark("notes", ReaderTextAnchor(exact: "Notes on sources"))
        // A mark on the first chapter's picture, which has no words.
        let picture = Self.mark("picture", ReaderTextAnchor(exact: ""), pictures: [
            ReaderImageAnchor(src: "foreverlm-book://book/Foo/Chapters/OEBPS/Images/drop.png", alt: "A drop"),
        ])
        let state = StudioViewModel.WholeEPUBBookState(highlights: [ions, membrane, notes, picture], fractionReached: 0.05)

        let plan = StudioViewModel.planWholeEPUBBook(state, chapters: Self.grouping, in: inventory)

        // The cover holds the place and the notes a mark: the chapters stretch over both.
        #expect(plan.spans == [
            EPUBParser.ChapterSpan(title: "Water", firstDocument: 0, lastDocument: 1),
            EPUBParser.ChapterSpan(title: "Ions", firstDocument: 2, lastDocument: 3),
        ])
        let moves = Dictionary(uniqueKeysWithValues: plan.highlights.map { ($0.highlight.id, $0) })
        #expect(moves["ions"]?.chapter == 1)
        #expect(moves["membrane"]?.chapter == 1)
        #expect(moves["notes"]?.chapter == 1)
        #expect(moves["picture"]?.chapter == 0)
        #expect(moves["picture"]?.anchor == picture.anchor, "a picture has no words to count")

        // Each anchor now counts from its chapter's first word, its words and context unchanged.
        let second = EPUBParser.documentText(atPath: inventory.documents[2].path)
            + "\n\n" + EPUBParser.documentText(atPath: inventory.documents[3].path)
        let ionsAnchor = try #require(moves["ions"]?.anchor)
        #expect(ionsAnchor.exact == ions.anchor.exact && ionsAnchor.prefix == ions.anchor.prefix)
        let ionsRange = try #require(second.range(of: "Ions carry charge"))
        #expect(ionsAnchor.offset == ReaderTextAnchor(text: second, range: ionsRange).offset, "as a mark made there counts it")
        let membraneAnchor = try #require(moves["membrane"]).anchor
        let membraneRange = try #require(membraneAnchor.resolve(in: second))
        #expect(second[membraneRange] == "membrane")
        #expect(String(second[..<membraneRange.lowerBound]).hasSuffix("charge across the "))

        // 0.05 of the book's 100 words is halfway through the cover's 10, which is
        // 5 of the first chapter's 50 now.
        let place = try #require(plan.place)
        #expect(place.index == 0)
        #expect(abs(place.fraction - 0.1) < 0.000_1)
    }

    @Test("A book nobody has marked or read keeps the model's chapters as they are")
    func planWithoutState() throws {
        let (root, inventory) = try Self.book("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = StudioViewModel.planWholeEPUBBook(.init(), chapters: Self.grouping, in: inventory)
        #expect(plan.spans == Self.grouping)
        #expect(plan.highlights.isEmpty && plan.place == nil)

        // A mark whose passage is in no document stays on the first chapter, as it was.
        let lost = Self.mark("lost", ReaderTextAnchor(exact: "words this book never had"))
        let kept = StudioViewModel.planWholeEPUBBook(.init(highlights: [lost]), chapters: Self.grouping, in: inventory)
        #expect(kept.spans == Self.grouping)
        #expect(kept.highlights.first?.chapter == 0 && kept.highlights.first?.anchor == lost.anchor)
    }

    @Test("The chapters stretch to hold a document that was marked or reached, and only that")
    func spansStretch() {
        let spans = [
            EPUBParser.ChapterSpan(title: "A", firstDocument: 2, lastDocument: 3),
            EPUBParser.ChapterSpan(title: "B", firstDocument: 5, lastDocument: 6),
            EPUBParser.ChapterSpan(title: "C", firstDocument: 8, lastDocument: 8),
        ]
        #expect(StudioViewModel.epubChapterSpans(spans, holdingDocuments: [2, 6, 8]) == spans)
        let stretched = StudioViewModel.epubChapterSpans(spans, holdingDocuments: [0, 4, 7, 9, 5, -1])
        #expect(stretched.map(\.firstDocument) == [0, 5, 8])
        #expect(stretched.map(\.lastDocument) == [4, 7, 9])
        #expect(stretched.map(\.title) == ["A", "B", "C"])
        #expect(StudioViewModel.epubChapterSpans([], holdingDocuments: [1]).isEmpty)
    }

    @Test("A place through the whole book is a place through one document, counted in words")
    func placeAmongDocuments() throws {
        let words: [(document: Int, words: Int)] = [(0, 10), (1, 0), (2, 40), (3, 50)]
        #expect(StudioViewModel.epubDocumentPlace(atFraction: 0, words: words) == StudioViewModel.EPUBPlace(index: 0, fraction: 0))
        // A document with no words, a picture page, holds no place.
        #expect(StudioViewModel.epubDocumentPlace(atFraction: 0.1, words: words) == StudioViewModel.EPUBPlace(index: 2, fraction: 0))
        let late = try #require(StudioViewModel.epubDocumentPlace(atFraction: 0.55, words: words))
        #expect(late.index == 3 && abs(late.fraction - 0.1) < 0.000_1)
        #expect(StudioViewModel.epubDocumentPlace(atFraction: 1, words: words) == StudioViewModel.EPUBPlace(index: 3, fraction: 1))
        #expect(StudioViewModel.epubDocumentPlace(atFraction: 0.5, words: []) == nil)

        let span = EPUBParser.ChapterSpan(title: "B", firstDocument: 2, lastDocument: 3)
        let fraction = StudioViewModel.epubChapterFraction(of: .init(index: 3, fraction: 0.5), in: span, words: [2: 40, 3: 40])
        #expect(abs(fraction - 0.75) < 0.000_1)
    }

    @Test("A mark moved to its chapter is the same mark, its offset counted from the chapter's start")
    func markMoves() throws {
        let reading = StudioViewModel.EPUBReadingText([
            (index: 0, text: "Cover words."),
            (index: 1, text: "Water\nThe membrane   holds a charge."),
            (index: 2, text: "Ions\nIons cross the membrane."),
        ])
        #expect(reading.text.hasPrefix("Cover words.\n\nWater"))
        #expect(reading.starts.map(\.document) == [0, 1, 2])
        let mark = Self.mark("mark", ReaderTextAnchor(exact: "membrane", prefix: "cross the ", suffix: ".", offset: 60))
        let found = try #require(reading.place(of: mark) { _ in nil })
        #expect(found.document == 2)
        // As a mark made on chapter 2's own text, "Ions\nIons cross the membrane.", counts it.
        let chapter = "Ions\nIons cross the membrane."
        let inChapter = try #require(chapter.range(of: "membrane"))
        let expected = ReaderTextAnchor(text: chapter, range: inChapter).offset
        let offset = try #require(found.offset)
        #expect(reading.countedOffset(offset, fromStartOf: 2) == expected)
        #expect(reading.countedOffset(offset, fromStartOf: 7) == nil)
        // A chapter that starts a document earlier counts from there, whitespace collapsed.
        let fromWater = try #require(reading.countedOffset(offset, fromStartOf: 1))
        #expect(fromWater == ReaderTextAnchor.normalize("Water\nThe membrane   holds a charge.\n\nIons\nIons cross the ").text.count)
        let unwritten = reading.place(of: Self.mark("none", ReaderTextAnchor(exact: "never written"))) { _ in nil }
        #expect(unwritten == nil)

        var counted = mark.anchor
        counted.offset = expected
        let moved = StudioViewModel.highlight(mark, movedTo: "chapter-2", anchor: counted)
        #expect(moved.id == "mark" && moved.sourceID == "chapter-2" && moved.anchor == counted)
        #expect(moved.quote == mark.quote && moved.note == mark.note && moved.pdfAnchor == nil)
        #expect(moved.createdAt == Self.made && moved.updatedAt > Self.made)
    }
}

/// The schema-170 step from 169: every book with a chapter addressed in an unpacked EPUB folder
/// joins the merge queue by id; a PDF book and a book already one file do not.
@Suite("Schema 170 migration", .serialized)
struct EPUBBookFileMigrationTests {
    @Test("Queues each unpacked EPUB book once, a team's copy included, reads no file, publishes nothing")
    func queuesUnpackedBooks() throws {
        let root = try Schema154Fixture.temporaryRoot("epub-book-files-169")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        try store.execForTesting("""
            INSERT INTO books (id, title) VALUES ('epub', 'Epub'), ('team-epub', 'Team'), ('pdf', 'Pdf'), ('gone', 'Gone');
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES
                ('epub-1', 0, 'ready', 'book', 'active'), ('epub-2', 0, 'ready', 'book', 'active'),
                ('team-1', 0, 'ready', 'book', 'active'), ('pdf-1', 0, 'ready', 'book', 'active'),
                ('gone-1', 0, 'ready', 'book', 'archived');
            UPDATE sources SET team_id = 'team' WHERE id = 'team-1';
            INSERT INTO book_sources (source_id, url, local_file_path, title) VALUES
                ('epub-1', 'Books/Epub/Chapters/OEBPS/one.xhtml', 'Books/Epub/Chapters/OEBPS/one.xhtml', 'One'),
                ('epub-2', 'Books/Epub/Chapters/OEBPS/two.html', 'Books/Epub/Chapters/OEBPS/two.html', 'Two'),
                ('team-1', 'Books/Team/Chapters/part1.XHTML', 'Books/Team/Chapters/part1.XHTML', 'Part'),
                ('pdf-1', 'Books/Pdf/Chapters/01 One.pdf', 'Books/Pdf/Chapters/01 One.pdf', 'One'),
                ('gone-1', 'Books/Gone/Chapters/one.xhtml', 'Books/Gone/Chapters/one.xhtml', 'One');
            INSERT INTO group_members (source_id, group_id, sort_index) VALUES
                ('epub-1', 'epub', 0), ('epub-2', 'epub', 1), ('team-1', 'team-epub', 0), ('pdf-1', 'pdf', 0), ('gone-1', 'gone', 0);
        """)
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("DELETE FROM book_file_merge_queue; PRAGMA user_version = 169;")

        Schema154Fixture.newLaunch(root)
        let migrated = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(KnowledgeStore.schemaVersion == 172)
        #expect(Set(try migrated.dueBookFileMerges(limit: 10)) == ["epub", "team-epub"])
        #expect(try migrated.bookChapterPaths(bookID: "epub") == [
            "Books/Epub/Chapters/OEBPS/one.xhtml", "Books/Epub/Chapters/OEBPS/two.html",
        ])
        #expect(try migrated.pendingSyncChanges().isEmpty)
        #expect(StudioViewModel.isUnpackedEPUBChapterPath("Books/Epub/Chapters/OEBPS/one.xhtml"))
        #expect(!StudioViewModel.isUnpackedEPUBChapterPath("Books/Pdf/Chapters/01 One.pdf"))
        #expect(!StudioViewModel.isUnpackedEPUBChapterPath("Books/Pdf/Pdf.pdf#page=3"))
    }
}
