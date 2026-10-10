import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Under generation 2 the learner's own state outlives the content it is about (D18, §5.7): since schema
/// 154 no per-member table has a foreign key to content, so neither a local delete nor an inbound one
/// takes a highlight, a hidden mark, a visible override or an Understanding row with its source.
/// WP7, WP8, WP10, WP12 and WP12b add their projections' cases to their own suites.
@Suite("Source delete keeps personal state")
struct SourceDeleteKeepsPersonalStateTests {
    private static let kinds = Schema154Fixture.releasedPerMemberTables.map(\.name).filter { $0 != "notebook_files" }

    private static func rows(_ store: KnowledgeStore, of sourceID: String) throws -> [String: Int] {
        var rows: [String: Int] = [:]
        for table in kinds {
            rows[table] = try Schema154Fixture.count(store, "SELECT COUNT(*) FROM \(table) WHERE source_id = '\(sourceID)'")
        }
        return rows
    }

    private static func everyKind(_ count: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: kinds.map { ($0, count) })
    }

    private static func generation2Library(_ name: String) throws -> (root: URL, store: KnowledgeStore, library: Schema154Fixture.Library) {
        let root = try Schema154Fixture.temporaryRoot(name)
        let library = try Schema154Fixture.makeLibrary(at: root, version: nil, generation: .two)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        return (root, store, library)
    }

    @Test("A local source delete keeps its highlight, hidden, visible and Understanding rows")
    func localDeleteKeepsRows() throws {
        let (root, store, library) = try Self.generation2Library("local")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = library.sourceIDs[0]
        #expect(try Self.rows(store, of: sourceID) == Self.everyKind(1))
        try store.deleteSource(sourceID)
        #expect(try store.loadSourceWithoutContent(sourceID) == nil, "the source is gone")
        #expect(try Self.rows(store, of: sourceID) == Self.everyKind(1), "the learner's own rows stay")
        #expect(try store.pendingSyncChanges().filter { $0.entity == .sourceHighlight || $0.entity == .hiddenSource }.isEmpty,
                "nothing tombstones the rows that stayed")
    }

    @Test("An inbound delete through the apply keeps them too")
    func inboundDeleteKeepsRows() throws {
        let (root, store, library) = try Self.generation2Library("inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = library.sourceIDs[1]
        try store.replica.apply { _ in
            // A test closure standing in for the Source projection's applyDeletion (WP7).
            try store.deleteSourceRows(sourceID)
        }
        #expect(try store.loadSourceWithoutContent(sourceID) == nil)
        #expect(try Self.rows(store, of: sourceID) == Self.everyKind(1))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_apply_guard") == 0)
    }

    @Test("A local duplicate's delete keeps the duplicate's rows")
    func duplicateDeleteKeepsRows() throws {
        let (root, store, library) = try Self.generation2Library("duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(try store.loadSourceWithoutContent(library.sourceIDs[2]))
        try store.execForTesting("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('dup-1', 1, 'ready', 'article', 'active');
            INSERT INTO articles (source_id, url, normalized_url, title, domain)
            SELECT 'dup-1', url, normalized_url, title, domain FROM articles WHERE source_id = '\(original.id)';
        """)
        try Schema154Fixture.addPerMemberRows(store, sourceID: "dup-1")
        try store.deleteLocalDuplicate(of: original)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources WHERE id = 'dup-1'") == 0)
        #expect(try Self.rows(store, of: "dup-1") == Self.everyKind(1))
    }

    @Test("A notebook delete leaves its files unfiled")
    func notebookDeleteUnfilesItsFiles() throws {
        let (root, store, library) = try Self.generation2Library("notebook")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.deleteLearningGoal(library.notebookID)
        #expect(try store.loadLearningGoal(library.notebookID) == nil)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM notebook_files WHERE id = 'file-1' AND notebook_id IS NULL") == 1)
    }
}
