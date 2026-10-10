import Foundation
import Testing
@testable import ForeverLM

/// A generation-1 release cut between WP4 and T0, then the first generation-2 launch (D40, D49,
/// docs/cloudkit-schema-design.md §13.1 "Generation-1 releases before T0", §13.3 step 1 and step 3c,
/// WP16a): the store a release leaves, at 150, 153 or 156, is copied exactly as it is before the flip's
/// migrations, and the activation derives every v2 table from whatever generation 1 wrote since,
/// local edits and inbound records alike.
@Suite("Generation 1 release, then T0")
struct Generation1ReleaseThenT0Tests {
    private typealias Fixture = OutboxTestProjections

    private static func activate(_ store: KnowledgeStore, derivations: [ActivationDerivation] = KnowledgeStore.activationDerivations) async throws -> ActivationJournal {
        try store.executeScript(Fixture.tablesSQL)
        var environment = ActivationEnvironment()
        environment.oldContainerTransport = nil
        environment.derivations = derivations
        environment.registry = Fixture.registry
        environment.status = ActivationStatus()
        return try await GenerationActivationRunner(access: DirectStoreAccess(store: store), environment: environment).run()
    }

    @Test("The copy is at the store's own version, whichever generation-1 build left it",
          arguments: [150 as Int32, 153, 156])
    func copyIsAtTheStoresOwnVersion(version: Int32) async throws {
        let root = try Schema154Fixture.temporaryRoot("t0-copy-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: version, generation: .one)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)

        let journal = try await Self.activate(store, derivations: [])
        #expect(Schema154Fixture.scalar(at: root, "PRAGMA user_version", file: "knowledge.pre-v2.db") == String(version), "the copy is exactly what the last generation-1 build left")
        #expect(journal.clonePath == "knowledge.pre-v2.db" && journal.cloneUserVersion == version)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion), "the store itself migrated after the copy")
    }

    @Test("Generation-1 writes since the last migration are derived at the flip: a review chat, a voice chat with no kind, a new notebook and a reading position")
    func generation1WritesAreDerived() async throws {
        let root = try Schema154Fixture.temporaryRoot("t0-writes")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID: String
        let notebookID: String
        do {
            let library = try Schema154Fixture.makeLibrary(at: root, version: 153, generation: .one)
            sourceID = try #require(library.sourceIDs.first)
            // The release's own launch migrates the store; its writes then follow, as generation 1 makes them.
            let release = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
            try release.createReviewSession(id: "gen1-review", topic: "A review", sourceIDs: [])
            try release.addReviewExchange(sessionID: "gen1-review", question: "Why?", answer: "Because", evaluation: "Right", score: 0.9, knowledgeNote: nil, sourceRefs: [])
            try release.execForTesting("""
                INSERT INTO review_sessions (id, topic, started_at, status, source_ids) VALUES ('ios-live-1', 'Spoken', 1, 'completed', '[]')
            """)
            notebookID = try release.createCompanionGoal(
                title: "New notebook", topic: "New notebook", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: []
            ).id
            try release.execForTesting("UPDATE sources SET reading_position_page = 4 WHERE id = '\(sourceID)'")
        }
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)

        let journal = try await Self.activate(store)
        #expect(journal.activatedAt != nil && journal.mode == .fresh)
        func encoded(_ type: SyncRecordType, _ id: String) throws -> [String: SyncJSON]? {
            try KnowledgeStore.projectionRegistry.projection(for: type)?.encode(
                ProjectionRecordRef(zoneKey: PrivateSyncZones.libraryKey, zone: .library, type: type, wireID: id, localID: id), connection: store
            )
        }
        #expect(try encoded(.chat, "gen1-review")?["kind"] == .string("review"), "a graded chat is a review")
        #expect(try encoded(.chat, "ios-live-1")?["kind"] == .string("voice"), "a NULL-kind spoken chat is a voice chat")
        #expect(try encoded(.notebook, notebookID)?["title"] == .string("New notebook"), "the new notebook is a Notebook")
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM reading_states WHERE wire_id = '\(sourceID)'") == 1, "the position is a ReadingState")
    }
}
