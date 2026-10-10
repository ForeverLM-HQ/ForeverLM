import Foundation
import Testing
@testable import ForeverLM

/// Opening is a read (docs/cloudkit-schema-design.md P9, §3.5.18, WP12): opening a source, a notebook,
/// a course, a chat or a Doc in a generation-2 store with every registered trigger installed leaves
/// the outbox as it was, including a same-value full-row UPDATE of a `sources` row and a reader saving
/// the place it already has. The course, chat and Doc cases run against whatever projections the
/// registry holds; they assert more as WP9 to WP11 register theirs.
@Suite("Opening is a read")
struct OpeningIsAReadTests {
    typealias F = NotebookSyncFixture

    /// Every row of the outbox, as text: removals, field changes and pins.
    static func outbox(_ store: KnowledgeStore) throws -> [String] {
        var rows: [String] = []
        try store.query("SELECT source_table || '|' || local_key || '|' || op FROM ck_outbox ORDER BY 1", []) { rows.append($0.text(0) ?? "") }
        try store.query("SELECT source_table || '|' || local_key || '|' || column FROM ck_outbox_fields ORDER BY 1", []) { rows.append($0.text(0) ?? "") }
        return rows
    }

    @Test("Opening a source, a notebook, a course, a chat and a Doc writes nothing to send")
    func openingWritesNothing() throws {
        let (root, store) = try F.makeStore("open-read")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-1")
        try F.addSource(store, "src-2")
        try F.addNotebook(store, "nb-1")
        try F.file(store, "src-1", into: "nb-1")
        try store.execute("INSERT INTO courses (id, title) VALUES ('course-1', 'Bioenergetics')")
        try store.execute("""
            INSERT INTO global_artifacts (id, title, created_at, updated_at, kind) VALUES ('doc-1', 'Notes on Complex I', 1, 1, 'doc')
        """)
        try store.createReviewSession(id: "chat-1", topic: "Complex I", sourceIDs: ["src-1"])
        try store.updateSourceReadingPosition(sourceID: "src-1", page: 12)
        try store.updateSourceReadingLocator(sourceID: "src-2", locator: #"{"webScrollFraction":0.25}"#)
        try F.sendAll(store)
        // Whatever the sends left (a projection the registry does not hold yet keeps no rows).
        let before = try Self.outbox(store)

        // The source: the library list, the Reader's place, its walk and Understanding, the view.
        _ = try store.loadSources()
        _ = try store.loadSourceProgress(sourceID: "src-1")
        _ = try store.loadSourceReadingLocator(sourceID: "src-2")
        _ = try store.loadWalkthroughProgress("src-1")
        _ = try store.loadUnderstandingIndex(sourceID: "src-1")
        _ = try store.loadSourceReviewDepths(sourceIDs: ["src-1", "src-2"])
        _ = try F.count(store, "SELECT COUNT(*) FROM source_projection")
        // A reader restoring the place it already has, and one with none saving none.
        try store.updateSourceReadingPosition(sourceID: "src-1", page: 12)
        try store.updateSourceReadingLocator(sourceID: "src-2", locator: #"{"webScrollFraction":0.25}"#)
        try store.updateSourceReadingPosition(sourceID: "src-2", page: nil)
        try store.saveListenPosition(nil, sourceID: "src-1")
        // A same-value full-row UPDATE of the sources rows (a save of an unchanged model).
        try store.execute("""
            UPDATE sources SET date_added = date_added, state = state, error_message = error_message, source_type = source_type,
                status = status, archived_at = archived_at, public_url = public_url, is_consumed = is_consumed,
                reading_position_page = reading_position_page, reading_position_locator = reading_position_locator,
                read_at = read_at, review_depth = review_depth, connector_label = connector_label, team_id = team_id, wire_id = wire_id
        """)
        // The notebook, the course, the chat and the Doc.
        _ = try store.loadLearningGoals()
        _ = try store.loadCourseLectures()
        _ = try store.loadCourseLectureItems()
        _ = try store.loadReviewSessionLoadedSourceIDs(sessionID: "chat-1")
        _ = try store.loadArtifact("doc-1")

        #expect(try Self.outbox(store) == before)
        #expect(try F.count(store, "SELECT COUNT(*) FROM reading_states WHERE wire_id = 'src-2' AND position IS NOT NULL") == 0)
        #expect(try F.pending(store).isEmpty)
    }

    @Test("A source opened for the first time makes no reading state")
    func firstOpenMakesNoRecord() throws {
        let (root, store) = try F.makeStore("open-first")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-1")
        try F.sendAll(store)
        // What the send left: the row the Source and the Mark of its provenance both read waits for the next round
        // to find the Mark empty. Opening adds nothing to it.
        let before = try Self.outbox(store)
        try store.updateSourceReadingPosition(sourceID: "src-1", page: nil)
        try store.updateSourceReadingLocator(sourceID: "src-1", locator: nil)
        try store.updateSourceReadAt(sourceID: "src-1", readAt: nil)
        try store.setSourceReviewDepth(sourceID: "src-1", depth: nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM reading_states") == 0)
        #expect(try Self.outbox(store) == before)
        #expect(try F.pending(store).isEmpty, "nothing is left to send")
    }
}
