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
        #expect(KnowledgeStore.schemaVersion == 171)
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
