import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The share sheet's notebook choice (docs/notebooks-design.md, "iPhone"):
/// the queued item carries the notebook it was filed into, a queue an older
/// build made still drains, the app writes the notebooks in Home's order for
/// the extension to read, the sheet opens on the notebook last shared into,
/// and a drain files each item into a notebook that is still there.
@Suite("Share sheet notebooks")
struct MobileShareSheetTests {

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileShareSheetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func notebook(_ id: String, title: String, updatedAt: Date) -> MobileCloudNotebook {
        MobileCloudNotebook(id: id, title: title, instructions: nil, sourceIDs: [], isArchived: false, updatedAt: updatedAt)
    }

    // MARK: - The queued item

    @Test("A queued item carries the notebook it was filed into, and none when it was filed into none")
    func queuedItemCarriesNotebook() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = MobileShareInbox(databaseURL: directory.appendingPathComponent("inbox.sqlite"))
        let link = try #require(URL(string: "https://www.nature.com/articles/s41586-024-0001"))
        try await inbox.enqueueURL(link, title: "  Mitochondria  ", notebookID: "nb-1")
        try await inbox.enqueueURL(try #require(URL(string: "https://example.com/a")), title: nil)
        try await inbox.enqueueStashedFile(path: directory.appendingPathComponent("x/Paper.pdf").path, title: "Paper", notebookID: " ")

        let pending = try await inbox.pending()
        #expect(pending.count == 3)
        let filed = try #require(pending.first { $0.url == link.absoluteString })
        #expect(filed.notebookID == "nb-1")
        #expect(filed.title == "Mitochondria")
        #expect(filed.sourceType == "unclassified")
        #expect(pending.first { $0.url == "https://example.com/a" }?.notebookID == nil, "the library only")
        let file = try #require(pending.first { $0.filePath != nil })
        #expect(file.notebookID == nil, "a blank id is no notebook")
        #expect(file.sourceType == "file")

        try await inbox.remove(filed)
        #expect(try await inbox.pending().count == 2)
    }

    @Test("A queue an older build made gains the notebook column, its items filed into no notebook")
    func olderQueueStillDrains() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("inbox.sqlite")

        // The table and row exactly as the build before the notebook choice
        // wrote them.
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        let oldSchema = """
            CREATE TABLE inbox (
                id TEXT PRIMARY KEY,
                url TEXT,
                file_path TEXT,
                title TEXT,
                source_type TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT INTO inbox (id, url, file_path, title, source_type, created_at)
            VALUES ('old-1', 'https://example.com/old', NULL, 'Old share', 'unclassified', 100);
            """
        #expect(sqlite3_exec(database, oldSchema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let inbox = MobileShareInbox(databaseURL: databaseURL)
        let pending = try await inbox.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.id == "old-1")
        #expect(pending.first?.title == "Old share")
        #expect(pending.first?.notebookID == nil)

        try await inbox.enqueueURL(try #require(URL(string: "https://example.com/new")), title: nil, notebookID: "nb-2")
        let both = try await inbox.pending()
        #expect(both.map(\.id).first == "old-1", "oldest first")
        #expect(both.last?.notebookID == "nb-2")
        // A second open finds the column and adds nothing.
        #expect(try await MobileShareInbox(databaseURL: databaseURL).pending().count == 2)
    }

    // MARK: - The notebook list

    @Test("The notebook list keeps its order through the app group, ids and titles only")
    func notebookListRoundTrip() throws {
        let notebooks = [
            MobileShareNotebook(id: "b", title: " Bioelectricity "),
            MobileShareNotebook(id: "", title: "No id"),
            MobileShareNotebook(id: "a", title: "Aging"),
            MobileShareNotebook(id: "b", title: "Repeated"),
            MobileShareNotebook(id: "c", title: ""),
        ]
        let data = try #require(MobileShareNotebookList.encode(notebooks))
        let decoded = try #require(MobileShareNotebookList.decode(data))
        #expect(decoded == [
            MobileShareNotebook(id: "b", title: "Bioelectricity"),
            MobileShareNotebook(id: "a", title: "Aging"),
            MobileShareNotebook(id: "c", title: ""),
        ])
        #expect(MobileShareNotebookList.displayTitle(of: decoded[2]) == "Untitled")
        #expect(MobileShareNotebookList.decode(Data("not a list".utf8)) == nil)

        // Each entry is its id and title, nothing else.
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]])
        #expect(plist.allSatisfy { Set($0.keys) == ["id", "title"] })
    }

    @Test("The app writes Home's order, and only when it changed")
    func storeWritesOnlyChanges() throws {
        let suiteName = "MobileShareSheetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileShareNotebookStore(defaults: defaults)
        #expect(store.notebooks.isEmpty)
        #expect(store.save([]) == false, "nothing to write for no notebooks")

        let old = Date(timeIntervalSinceReferenceDate: 1_000)
        let new = Date(timeIntervalSinceReferenceDate: 2_000)
        let notebooks = [
            notebook("p1", title: "Aging", updatedAt: old),
            notebook("p2", title: "Bioelectricity", updatedAt: old),
            notebook("p3", title: "Cancer", updatedAt: new),
        ]
        let list = MobileAudioReviewViewModel.shareNotebooks(notebooks, lastChatAt: ["p2": new.addingTimeInterval(60)])
        #expect(list.map(\.id) == ["p2", "p3", "p1"], "Home's order: a chat moves its notebook up")
        #expect(list.first?.title == "Bioelectricity")

        #expect(store.save(list))
        #expect(store.notebooks == list)
        #expect(store.save(list) == false, "the same list is not written again")
        #expect(store.save(Array(list.reversed())))
        #expect(store.notebooks.map(\.id) == ["p1", "p3", "p2"])
    }

    @Test("The sheet opens on the notebook last shared into while it is still listed")
    func lastUsedPreselection() throws {
        let suiteName = "MobileShareSheetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileShareNotebookStore(defaults: defaults)
        let notebooks = [MobileShareNotebook(id: "a", title: "Aging"), MobileShareNotebook(id: "b", title: "Bio")]

        #expect(MobileShareNotebookList.preselected(lastUsed: store.lastUsedNotebookID, in: notebooks) == nil, "first share: Not in a notebook")
        store.rememberLastUsed("b")
        #expect(store.lastUsedNotebookID == "b")
        #expect(MobileShareNotebookList.preselected(lastUsed: store.lastUsedNotebookID, in: notebooks) == "b")
        #expect(MobileShareNotebookList.preselected(lastUsed: "b", in: [notebooks[0]]) == nil, "a notebook gone since: none")
        store.rememberLastUsed(nil)
        #expect(store.lastUsedNotebookID == nil, "Not in a notebook is remembered too")
        #expect(defaults.object(forKey: MobileShareNotebookStore.lastUsedKey) == nil)
    }

    // MARK: - What the sheet shows

    @Test("The sheet shows the title the sending app gave and the link's site, without fetching")
    func preview() throws {
        #expect(MobileSharePreview.title(itemTitle: nil, contentText: "The Page\nselected words") == "The Page")
        #expect(MobileSharePreview.title(itemTitle: "  Given  ", contentText: "Other") == "Given")
        #expect(MobileSharePreview.title(itemTitle: nil, contentText: "https://example.com/a") == nil, "an address is no title")
        #expect(MobileSharePreview.title(itemTitle: "", contentText: "  \n ") == nil)

        let link = try #require(URL(string: "https://www.nature.com/articles/x"))
        #expect(MobileSharePreview.site(of: link) == "nature.com")
        #expect(MobileSharePreview.site(of: try #require(URL(string: "https://arxiv.org/abs/1"))) == "arxiv.org")

        #expect(MobileSharePreview.webAddress(in: " https://example.com/a?b=1 ")?.absoluteString == "https://example.com/a?b=1")
        #expect(MobileSharePreview.webAddress(in: "Read this: https://example.com/post and tell me")?.absoluteString == "https://example.com/post")
        #expect(MobileSharePreview.webAddress(in: "hello") == nil, "text with no web address is not queued")
        #expect(MobileSharePreview.webAddress(in: "ftp://example.com/file") == nil)
        #expect(MobileSharePreview.isWebAddress(try #require(URL(string: "file:///tmp/a.pdf"))) == false)
    }
}
