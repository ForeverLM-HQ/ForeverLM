import Foundation
import Testing
@testable import ForeverLM

/// Generation 1 behaves as build 178 did (D40): schema 154 dropped the per-member tables' cascades, so
/// the two statements that delete `sources` rows (`deleteSourceRows`, `deleteLocalDuplicateRows`) and
/// the notebook delete remove those rows themselves, and leave exactly what the cascade left; and no
/// generation-1 write ever reaches an outbox. WP8 and WP12 add their accessors' cases to their own
/// migration suites.
@Suite("Generation 1 invariants")
struct Generation1InvariantTests {
    @Test("deleteLocalDuplicate removes the duplicate's per-member rows, as the cascade did")
    func duplicateDeleteMatchesTheCascade() throws {
        let root = try Schema154Fixture.temporaryRoot("g1-duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: nil)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        let original = try #require(try store.loadSourceWithoutContent(library.sourceIDs[2]))
        try store.execForTesting("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('dup-1', 1, 'ready', 'article', 'active');
            INSERT INTO articles (source_id, url, normalized_url, title, domain)
            SELECT 'dup-1', url, normalized_url, title, domain FROM articles WHERE source_id = '\(original.id)';
        """)
        try Schema154Fixture.addPerMemberRows(store, sourceID: "dup-1")
        let before = Schema154Fixture.perMemberRows(at: root).filter { !$0.contains("dup-1") }
        try store.deleteLocalDuplicate(of: original)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources WHERE id = 'dup-1'") == 0)
        #expect(Schema154Fixture.perMemberRows(at: root) == before, "the duplicate's rows went and nothing else")
    }

    @Test("The notebook delete removes the notebook's files, as the cascade did")
    func notebookDeleteRemovesItsFiles() throws {
        let root = try Schema154Fixture.temporaryRoot("g1-notebook")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: nil)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        try store.deleteLearningGoal(library.notebookID)
        #expect(try store.loadLearningGoal(library.notebookID) == nil)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM notebook_files") == 0)
    }

    @Test("Generation-1 writes leave no ck_outbox row and install no trigger")
    func noOutboxUnderGeneration1() throws {
        let root = try Schema154Fixture.temporaryRoot("g1-outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: 153)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        var added = StudioArticle(url: "https://example.org/schema154/new", title: "New paper", sourceType: .article)
        try store.insertSourceIfNew(&added)
        try store.addSourceToGoal(sourceID: added.id, goalID: library.notebookID, plannedAt: Date())
        try store.writeSourceHidden(added.id, hidden: true)
        try store.deleteSource(library.sourceIDs[1])
        try store.deleteLearningGoal(library.notebookID)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_outbox") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_records") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources WHERE wire_id IS NOT NULL") == 0)
        #expect(try !store.pendingSyncChanges().isEmpty, "generation 1 still records its own sync bookkeeping")
    }
}
