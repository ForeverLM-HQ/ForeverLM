import CoreGraphics
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

@Suite("Reference Library Import")
struct ReferenceLibraryImportServiceTests {
    @Test("BibTeX preserves structured metadata and resolves a linked PDF")
    func parsesBibTeXWithAttachment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("papers/study.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: pdf)

        let text = #"""
        @article{smith2024,
          title = {{A Structured} Study of Learning},
          author = {Smith, Jane and Vale, Robin},
          journal = {Journal of Useful Results},
          year = {2024},
          doi = {10.1234/example.7},
          file = {Full Text:papers/study.pdf:application/pdf}
        }
        """#

        let entries = ReferenceLibraryImportService.parseBibTeX(text, baseDirectory: directory)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.recordID == "smith2024")
        #expect(entry.title == "A Structured Study of Learning")
        #expect(entry.authors == "Smith, Jane; Vale, Robin")
        #expect(entry.journal == "Journal of Useful Results")
        #expect(entry.year == "2024")
        #expect(entry.doi == "10.1234/example.7")
        #expect(entry.pdfPath == pdf.path)
        #expect(entry.stableCatalogURL == "https://doi.org/10.1234/example.7")
    }

    @Test("RIS collects repeated authors and relative attachment paths")
    func parsesRISWithAttachment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("paper.pdf")
        try Data("pdf".utf8).write(to: pdf)

        let text = """
        TY  - JOUR
        ID  - ris-42
        TI  - A Paper from Paperpile
        AU  - Ada Lovelace
        AU  - Grace Hopper
        JO  - Computing Letters
        PY  - 2025/02/03
        DO  - 10.5555/paperpile
        L1  - paper.pdf
        ER  -
        """

        let entries = ReferenceLibraryImportService.parseRIS(text, baseDirectory: directory)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.recordID == "ris-42")
        #expect(entry.authors == "Ada Lovelace; Grace Hopper")
        #expect(entry.journal == "Computing Letters")
        #expect(entry.year == "2025")
        #expect(entry.pdfPath == pdf.path)
    }

    @Test("Zotero database import reads metadata and stored attachment without writing")
    func readsZoteroDatabase() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("zotero.sqlite")
        let attachmentDirectory = directory.appendingPathComponent("storage/ATTACH01")
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        let pdf = attachmentDirectory.appendingPathComponent("paper.pdf")
        try Data("pdf".utf8).write(to: pdf)

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        let db = try #require(database)
        defer { sqlite3_close(db) }
        try createZoteroFixture(db)

        let entries = try ReferenceLibraryImportService.loadZoteroDatabase(databaseURL, dataDirectory: directory)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.recordID == "PAPER001")
        #expect(entry.title == "A Zotero Paper")
        #expect(entry.authors == "Katherine Johnson")
        #expect(entry.journal == "Zotero Journal")
        #expect(entry.year == "2023")
        #expect(entry.doi == "10.1000/zotero")
        #expect(entry.pdfPath == pdf.path)
        // A Zotero older than 6 has no annotations table, and no marks.
        #expect(entry.marks.isEmpty)
    }

    @Test("Zotero reader highlights and notes come with their paper; file, image and trashed marks do not")
    func readsZoteroAnnotations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("zotero.sqlite")
        let attachmentDirectory = directory.appendingPathComponent("storage/ATTACH01")
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: attachmentDirectory.appendingPathComponent("paper.pdf"))

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        let db = try #require(database)
        defer { sqlite3_close(db) }
        try createZoteroFixture(db)
        // Zotero 7's table, with the columns it declares.
        try exec(db, """
            CREATE TABLE itemAnnotations (
                itemID INTEGER PRIMARY KEY, parentItemID INT NOT NULL, type INTEGER NOT NULL,
                authorName TEXT, text TEXT, comment TEXT, color TEXT, pageLabel TEXT,
                sortIndex TEXT NOT NULL, position TEXT NOT NULL, isExternal INT NOT NULL
            );
            INSERT INTO itemTypes VALUES (3, 'annotation');
            INSERT INTO items VALUES
                (20, 3, 'ANNOT001', '2023-05-01 09:00:00'),
                (21, 3, 'ANNOT002', '2023-05-01 09:05:00'),
                (22, 3, 'ANNOT003', '2023-05-01 09:06:00'),
                (23, 3, 'ANNOT004', '2023-05-01 09:07:00'),
                (24, 3, 'ANNOT005', '2023-05-01 09:08:00'),
                (25, 3, 'ANNOT006', '2023-05-01 09:09:00');
            INSERT INTO itemAnnotations VALUES
                (21, 11, 2, NULL, NULL, 'Check the method', '#ff6666', '2', '00001|000400|00100',
                 '{"pageIndex":1,"rects":[[10,400,32,422]]}', 0),
                (20, 11, 1, NULL, ' Retrieval beats rereading. ', 'The core claim', '#2ea8e5', '1', '00000|000100|00200',
                 '{"pageIndex":0,"rects":[[36,500,300,518],[36,480,120,498]]}', 0),
                (22, 11, 1, NULL, 'Saved in the file', '', '#ffd400', '1', '00000|000200|00300',
                 '{"pageIndex":0,"rects":[[36,460,300,478]]}', 1),
                (23, 11, 3, NULL, NULL, 'A figure', '#ffd400', '1', '00000|000300|00400',
                 '{"pageIndex":0,"rects":[[36,100,300,300]]}', 0),
                (24, 11, 1, NULL, 'In the trash', '', '#ffd400', '1', '00000|000400|00500',
                 '{"pageIndex":0,"rects":[[36,440,300,458]]}', 0),
                (25, 11, 2, NULL, NULL, '', '#ffd400', '1', '00000|000500|00600',
                 '{"pageIndex":0,"rects":[[10,420,32,442]]}', 0);
            INSERT INTO deletedItems VALUES (24);
            """)

        let entries = try ReferenceLibraryImportService.loadZoteroDatabase(databaseURL, dataDirectory: directory)
        let marks = try #require(entries.first).marks
        #expect(marks.count == 2)

        let highlight = try #require(marks.first)
        #expect(highlight.kind == .passage)
        #expect(highlight.pageIndex == 0)
        #expect(highlight.rects == [
            CGRect(x: 36, y: 500, width: 264, height: 18),
            CGRect(x: 36, y: 480, width: 84, height: 18),
        ])
        #expect(highlight.text == "Retrieval beats rereading.")
        #expect(highlight.comment == "The core claim")
        #expect(highlight.color == .blue)
        #expect(highlight.originKey == "zotero:ANNOT001")
        #expect(highlight.createdAt == Date(timeIntervalSince1970: 1_682_931_600))

        let note = try #require(marks.last)
        #expect(note.kind == .pinnedNote)
        #expect(note.pageIndex == 1)
        #expect(note.text == nil)
        #expect(note.comment == "Check the method")
        #expect(note.color == .pink)
    }

    @Test("Another app's marker colors map to the nearest ForeverLM marker by hue")
    func mapsForeignMarkerColors() {
        // Zotero's palette.
        #expect(SourceHighlightColor(hex: "#ffd400") == .yellow)
        #expect(SourceHighlightColor(hex: "#ff6666") == .pink)
        #expect(SourceHighlightColor(hex: "#5fb236") == .green)
        #expect(SourceHighlightColor(hex: "#2ea8e5") == .blue)
        #expect(SourceHighlightColor(hex: "#a28ae5") == .purple)
        #expect(SourceHighlightColor(hex: "#e56eee") == .pink)
        #expect(SourceHighlightColor(hex: "#f19837") == .yellow)
        #expect(SourceHighlightColor(hex: "#aaaaaa") == .default)
        #expect(SourceHighlightColor(hex: "yellow") == nil)
        #expect(SourceHighlightColor(hex: nil) == nil)
        // ForeverLM's own markers survive the trip.
        for color in SourceHighlightColor.allCases {
            let rgb = color.components
            #expect(SourceHighlightColor(nearestTo: rgb.red, green: rgb.green, blue: rgb.blue) == color)
        }
    }

    @Test("BibTeX file fields resolve Mendeley, JabRef, escaped and bare paths")
    func resolvesManagerFileFields() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mendeley = directory.appendingPathComponent("Mendeley Desktop/Smith_2019.pdf")
        let jabref = directory.appendingPathComponent("jabref.pdf")
        let colon = directory.appendingPathComponent("Notes: A Study.pdf")
        let bare = directory.appendingPathComponent("All Papers/S/Smith 2020.pdf")
        for pdf in [mendeley, jabref, colon, bare] {
            try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("pdf".utf8).write(to: pdf)
        }
        // Mendeley Desktop drops the leading slash of an absolute path.
        let mendeleyField = ":" + String(mendeley.path.dropFirst()).replacingOccurrences(of: "_", with: "\\_") + ":pdf"
        let colonField = "Main:" + colon.path.replacingOccurrences(of: ":", with: "\\:") + ":PDF"
        let text = """
        @article{mendeley, title = {Mendeley Paper}, file = {\(mendeleyField)}}
        @article{jabref, title = {JabRef Paper}, file = {:jabref.pdf:PDF}}
        @article{colon, title = {Colon Paper}, file = {\(colonField)}}
        @article{bare, title = {Bare Paper}, file = {All Papers/S/Smith 2020.pdf}}
        @article{missing, title = {Missing Paper}, file = {:nowhere.pdf:PDF;Other:jabref.txt:text}}
        """

        let entries = ReferenceLibraryImportService.parseBibTeX(text, baseDirectory: directory)
        let paths = Dictionary(uniqueKeysWithValues: entries.map { ($0.recordID, $0.pdfPath) })
        #expect(paths["mendeley"] == mendeley.path)
        #expect(paths["jabref"] == jabref.path)
        #expect(paths["colon"] == colon.path)
        #expect(paths["bare"] == bare.path)
        #expect(paths["missing"] == .some(nil))
    }

    @Test("A Zotero database locked by a running Zotero is read from a snapshot")
    func readsLockedZoteroDatabase() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("zotero.sqlite")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("storage/ATTACH01"),
            withIntermediateDirectories: true
        )
        try Data("pdf".utf8).write(to: directory.appendingPathComponent("storage/ATTACH01/paper.pdf"))

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        let db = try #require(database)
        defer { sqlite3_close(db) }
        try createZoteroFixture(db)
        // Zotero keeps its database under an exclusive lock while it runs.
        try exec(db, "PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE items SET key = key; COMMIT;")

        let entries = try ReferenceLibraryImportService.loadZoteroDatabase(databaseURL, dataDirectory: directory)
        #expect(entries.map(\.title) == ["A Zotero Paper"])
        #expect(entries.first?.pdfPath != nil)
    }

    private func createZoteroFixture(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE itemTypes (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
            CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INTEGER, key TEXT, dateAdded TEXT);
            CREATE TABLE deletedItems (itemID INTEGER PRIMARY KEY);
            CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
            CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE itemData (itemID INTEGER, fieldID INTEGER, valueID INTEGER);
            CREATE TABLE creatorTypes (creatorTypeID INTEGER PRIMARY KEY, creatorType TEXT);
            CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INTEGER);
            CREATE TABLE itemCreators (itemID INTEGER, creatorID INTEGER, creatorTypeID INTEGER, orderIndex INTEGER);
            CREATE TABLE itemAttachments (itemID INTEGER, parentItemID INTEGER, contentType TEXT, path TEXT);

            INSERT INTO itemTypes VALUES (1, 'journalArticle'), (2, 'attachment');
            INSERT INTO items VALUES
                (10, 1, 'PAPER001', '2023-04-05 12:00:00'),
                (11, 2, 'ATTACH01', '2023-04-05 12:00:01');
            INSERT INTO fields VALUES
                (1, 'title'), (2, 'publicationTitle'), (3, 'date'), (4, 'DOI'), (5, 'url');
            INSERT INTO itemDataValues VALUES
                (1, 'A Zotero Paper'), (2, 'Zotero Journal'), (3, '2023-04'),
                (4, '10.1000/zotero'), (5, 'https://example.com/paper');
            INSERT INTO itemData VALUES (10, 1, 1), (10, 2, 2), (10, 3, 3), (10, 4, 4), (10, 5, 5);
            INSERT INTO creatorTypes VALUES (1, 'author');
            INSERT INTO creators VALUES (1, 'Katherine', 'Johnson', 0);
            INSERT INTO itemCreators VALUES (10, 1, 1, 0);
            INSERT INTO itemAttachments VALUES (11, 10, 'application/pdf', 'storage:paper.pdf');
            """)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exec(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "ReferenceLibraryImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
