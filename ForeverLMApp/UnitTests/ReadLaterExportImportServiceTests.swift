import Foundation
import Testing
@testable import ForeverLM

@Suite("Read-Later Export Import")
struct ReadLaterExportImportServiceTests {
    @Test("A Pocket CSV carries title, date and archive state")
    func parsesPocketCSV() {
        let text = """
        title,url,time_added,tags,status
        "A Title, With a Comma",https://example.com/a,1700000000,,unread
        https://example.com/b,https://example.com/b,1700000100,tech,archive
        """
        let entries = ReadLaterExportImportService.parseCSV(text)
        #expect(entries.map(\.url) == ["https://example.com/a", "https://example.com/b"])
        #expect(entries[0].title == "A Title, With a Comma")
        #expect(entries[0].dateAdded == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entries[0].isRead == false)
        #expect(entries[1].title == nil)
        #expect(entries[1].isRead)
    }

    @Test("A Readwise Reader CSV skips feed items and reads its archive location")
    func parsesReadwiseCSV() {
        let text = """
        Title,URL,ID,Document tags,Saved date,Reading progress,Location,Seen
        Saved,https://example.com/saved,1,,2023-06-15 14:23:45+00:00,0,later,false
        Done,https://example.com/done,2,,2023-06-16 09:00:00+00:00,1,archive,true
        From a feed,https://example.com/feed,3,,2023-06-17 09:00:00+00:00,0,feed,false
        """
        let entries = ReadLaterExportImportService.parseCSV(text)
        #expect(entries.map(\.title) == ["Saved", "Done"])
        #expect(entries[0].dateAdded != nil)
        #expect(entries[1].isRead)
    }

    @Test("An Instapaper CSV and quoted multi-line fields")
    func parsesInstapaperCSV() {
        let text = "URL,Title,Selection,Folder,Timestamp\r\n"
            + "https://example.com/i,Insta,\"line one\r\nline \"\"two\"\"\",Archive,1690000000\r\n"
            + "https://example.com/j,Unread,,Unread,1690000001\r\n"
        let entries = ReadLaterExportImportService.parseCSV(text)
        #expect(entries.map(\.url) == ["https://example.com/i", "https://example.com/j"])
        #expect(entries[0].isRead)
        #expect(entries[1].isRead == false)
    }

    @Test("A CSV whose URL column has an unfamiliar header is still read")
    func findsUnnamedURLColumn() {
        let text = """
        Headline,Address
        Something,https://example.com/x
        """
        let entries = ReadLaterExportImportService.parseCSV(text)
        #expect(entries.map(\.url) == ["https://example.com/x"])
    }

    @Test("Bookmarks HTML reads links, dates and a Read Archive heading")
    func parsesBookmarksHTML() {
        let text = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <h1>Unread</h1>
        <ul>
        <li><a href="https://example.com/one" time_added="1600000000" tags="">One &amp; Only</a></li>
        </ul>
        <h1>Read Archive</h1>
        <ul>
        <li><A HREF="https://example.com/two" ADD_DATE="1600000100">Two</A></li>
        <li><a href="javascript:void(0)">Not a page</a></li>
        </ul>
        """
        let entries = ReadLaterExportImportService.parseBookmarksHTML(text)
        #expect(entries.map(\.url) == ["https://example.com/one", "https://example.com/two"])
        #expect(entries[0].title == "One & Only")
        #expect(entries[0].isRead == false)
        #expect(entries[1].isRead)
        #expect(entries[1].dateAdded == Date(timeIntervalSince1970: 1_600_000_100))
    }

    @Test("JSON exports find URL records at any depth")
    func parsesJSON() throws {
        let json = """
        {"items": [
          {"id": "1", "url": "https://example.com/j1", "title": "J1", "savedAt": "2024-01-02T03:04:05.000Z", "state": "Archived"},
          {"id": "2", "originalUrl": "https://example.com/j2", "title": "J2", "isArchived": false}
        ]}
        """
        let entries = ReadLaterExportImportService.parseJSON(Data(json.utf8))
        #expect(entries.map(\.url) == ["https://example.com/j1", "https://example.com/j2"])
        #expect(entries[0].isRead)
        #expect(entries[0].dateAdded != nil)
        #expect(entries[1].isRead == false)
    }

    @Test("A folder of exports is read whole and one URL lands once")
    func deduplicatesAcrossFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "url,title\nhttps://example.com/same,\n".write(
            to: directory.appendingPathComponent("part_000000.csv"), atomically: true, encoding: .utf8)
        try "https://example.com/same\nhttps://example.com/other\n".write(
            to: directory.appendingPathComponent("links.txt"), atomically: true, encoding: .utf8)

        let inventory = try ReadLaterExportImportService.inventory(from: [directory])
        #expect(inventory.entries.map(\.url) == ["https://example.com/same", "https://example.com/other"])
    }

    @Test("An export with no links is reported, not imported as nothing")
    func reportsEmptyExport() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).csv")
        try "title,notes\nA,B\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: ReadLaterExportImportService.ImportError.self) {
            try ReadLaterExportImportService.inventory(from: [file])
        }
    }
}
