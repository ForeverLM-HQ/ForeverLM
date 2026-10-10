import Foundation
import Testing
@testable import ForeverLM

/// A source named by id, as its rows read it: in the library, archived, or
/// gone. On 2026-09-19 three archived journal-club prep papers read as "no
/// longer in the library", because the rows only asked the active list, which
/// cannot tell the two apart. See `LibrarySourcePresence`.
@Suite("Library source presence")
struct LibrarySourcePresenceTests {

    private func article(_ url: String, title: String) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .paper)
        article.normalizedURL = URLNormalizer.normalize(url)
        return article
    }

    @Test("In the library, archived, and gone are three different answers")
    func threeStates() {
        let archivedRow = SourceRowSummary(id: "a", title: "Archived paper", status: .archived, type: .paper)
        let activeRow = SourceRowSummary(id: "b", title: "Stored title", status: .active, type: .paper)

        #expect(LibrarySourcePresence.resolve(activeTitle: "Loaded title", row: nil) == .inLibrary(title: "Loaded title"))
        #expect(LibrarySourcePresence.resolve(activeTitle: nil, row: archivedRow) == .archived(title: "Archived paper"))
        #expect(LibrarySourcePresence.resolve(activeTitle: nil, row: nil) == .gone)

        // The loaded library's title wins when both answer; a row storage
        // knows as active but the library has not loaded yet is not gone.
        #expect(LibrarySourcePresence.resolve(activeTitle: "Loaded title", row: archivedRow) == .inLibrary(title: "Loaded title"))
        #expect(LibrarySourcePresence.resolve(activeTitle: nil, row: activeRow) == .inLibrary(title: "Stored title"))
    }

    @Test("Each answer says what its row shows and allows")
    func presentation() {
        let inLibrary = LibrarySourcePresence.inLibrary(title: "Read me")
        #expect(inLibrary.label == "Read me")
        #expect(inLibrary.menuLabel == "Read me")
        #expect(inLibrary.title == "Read me")
        #expect(!inLibrary.isArchived)
        #expect(inLibrary.canOpen)

        let archived = LibrarySourcePresence.archived(title: "Read me")
        #expect(archived.label == "Read me")
        #expect(archived.menuLabel == "Read me (Archived)")
        #expect(archived.title == "Read me")
        #expect(archived.isArchived)
        #expect(archived.canOpen)

        let gone = LibrarySourcePresence.gone
        #expect(gone.label == "Source no longer in the library")
        #expect(gone.menuLabel == "Source no longer in the library")
        #expect(gone.title == nil)
        #expect(!gone.isArchived)
        #expect(!gone.canOpen)
    }

    @Test("Storage answers for archived rows by title and leaves deleted ids out")
    func storageRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        var active = article("https://example.com/active", title: "Active paper")
        var archived = article("https://example.com/archived", title: "Archived paper")
        try store.insertSourceIfNew(&active)
        try store.insertSourceIfNew(&archived)
        try store.archiveSource(archived.id)

        let rows = try store.sourceRowSummaries(for: [active.id, archived.id, "missing-id"])
        #expect(rows[active.id] == SourceRowSummary(id: active.id, title: "Active paper", status: .active, type: .paper))
        #expect(rows[archived.id] == SourceRowSummary(id: archived.id, title: "Archived paper", status: .archived, type: .paper))
        #expect(rows["missing-id"] == nil)
        #expect(try store.sourceRowSummaries(for: [String]()).isEmpty)

        // The active list still leaves the archived paper out — which is why
        // the rows could not tell it from a deleted one — and the two answers
        // together give each id its state.
        let loaded = Dictionary(uniqueKeysWithValues: try store.loadActiveSources().map { ($0.id, $0.title) })
        #expect(loaded.keys.sorted() == [active.id])
        #expect(LibrarySourcePresence.resolve(activeTitle: loaded[active.id], row: rows[active.id]) == .inLibrary(title: "Active paper"))
        #expect(LibrarySourcePresence.resolve(activeTitle: loaded[archived.id], row: rows[archived.id]) == .archived(title: "Archived paper"))
        #expect(LibrarySourcePresence.resolve(activeTitle: loaded["missing-id"], row: rows["missing-id"]) == .gone)
    }

    @Test("Unarchiving from a row restores the source as the MCP tool does, and reports a missing row")
    func unarchiveRestoring() throws {
        let store = try KnowledgeStore(inMemory: true)
        var archived = article("https://example.com/archived", title: "Archived paper")
        try store.insertSourceIfNew(&archived)
        try store.archiveSource(archived.id)
        #expect(try store.sourceRowSummaries(for: [archived.id])[archived.id]?.status == .archived)

        let outcome = try store.unarchiveSourceRestoringContent(archived.id)
        #expect(outcome == SourceUnarchiveOutcome(title: "Archived paper", rebuiltContent: false))
        #expect(try store.sourceRowSummaries(for: [archived.id])[archived.id]?.status == .active)
        #expect(try store.loadActiveSources().map(\.id) == [archived.id])

        #expect(try store.unarchiveSourceRestoringContent("missing-id") == nil)
    }

}
