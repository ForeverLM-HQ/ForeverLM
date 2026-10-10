import Foundation
import Testing
@testable import ForeverLM

/// Stores, rows and records for WP10's suites (docs/cloudkit-schema-design.md §3.5.13, §3.5.14,
/// §3.5.19, D50): a generation-2 store with the real registry's triggers (`NotebookSyncFixture`),
/// chats written through the app's own writers, a space zone a notebook lives in, and what the feeder
/// would send. It reads nothing but the store, the replica and the feeder, so the suites built on it
/// also run standalone over the real sources.
enum ChatSyncFixture {
    typealias N = NotebookSyncFixture

    static let spaceSalt = Data(repeating: 7, count: 32)
    static let spaceZoneKey = "private/Space-s1"

    /// A chat as the app creates one, with its kind written as a generation-2 creation site writes it.
    static func addChat(
        _ store: KnowledgeStore, _ id: String, kind: ChatKind? = .chat, sourceIDs: [String] = [], cardIDs: [String] = [],
        goalID: String? = nil, briefing: String? = nil, startedAt: Double = 10_000
    ) throws {
        try store.createReviewSession(
            id: id, topic: "Chat \(id)", sourceIDs: sourceIDs, cardIDs: cardIDs, startedAt: Date(timeIntervalSinceReferenceDate: startedAt),
            modelProvider: "openrouter", modelID: "vendor/model", modelEffort: "high", goalID: goalID, briefing: briefing, chatKind: kind
        )
    }

    /// One complete exchange: a question, the learner's answer and the tutor's reply.
    @discardableResult
    static func addExchange(_ store: KnowledgeStore, chat: String, question: String = "What does Complex I pump?", score: Double? = nil) throws -> String {
        let sequence = try store.addReviewExchange(
            sessionID: chat, question: question, answer: "Protons", evaluation: "Right: four per NADH.", score: score,
            knowledgeNote: nil, sourceRefs: ["src-a"], answeredAt: Date(timeIntervalSinceReferenceDate: 20_000)
        )
        return try exchangeID(store, chat: chat, sequence: sequence)
    }

    static func exchangeID(_ store: KnowledgeStore, chat: String, sequence: Int) throws -> String {
        try N.text(store, "SELECT id FROM review_exchanges WHERE session_id = ? AND sequence_number = ?", [.text(chat), .integer(Int64(sequence))]) ?? ""
    }

    /// The space `Space-s1` as the replica holds it once SpaceSync walked it: its zone, its root with
    /// the salt, and notebook `notebookID` in it.
    static func holdSpaceNotebook(_ store: KnowledgeStore, _ notebookID: String) throws {
        let saltID = RecordNaming.saltID(spaceSalt)
        try store.replica.upsertZone(ReplicaZone(zoneKey: spaceZoneKey, database: .private, zoneName: "Space-s1", kind: "space", saltID: saltID))
        var root = SyncEnvelope.new(.zoneRoot, id: "root", saltID: saltID)
        try root.apply(RecordPatch(.zoneRoot, id: "root", changes: [
            "kind": .value("team"), "salt": .value(.string(spaceSalt.base64EncodedString())), "saltID": .value(.string(saltID)),
        ])) { _, policy, _ in SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: 0, deviceID: "otheraaa") }
        try store.replica.upsertRecord(ReplicaRecord(
            zoneKey: spaceZoneKey, recordName: SyncSchema.rootRecordName, recordType: SyncRecordType.zoneRoot.rawValue, wireID: "root",
            systemFields: Data([1]), payload: try root.storedPayload(), seenPass: nil
        ))
        var notebook = SyncEnvelope.new(.notebook, id: notebookID, saltID: saltID)
        try notebook.apply(RecordPatch(.notebook, id: notebookID, changes: ["title": .value("Team notebook"), "status": .value("active")])) { _, policy, _ in
            SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: 0, deviceID: "otheraaa")
        }
        try store.replica.upsertRecord(ReplicaRecord(
            zoneKey: spaceZoneKey, recordName: RecordNaming.recordName(type: .notebook, id: notebookID, salt: spaceSalt),
            recordType: SyncRecordType.notebook.rawValue, wireID: notebookID, systemFields: Data([1]), payload: try notebook.storedPayload(),
            seenPass: nil
        ))
    }

    /// Sends every due change as the engine and SpaceSync would: a space's through the write guard
    /// (a refused field left out), each acknowledged by the server with what was sent. Returns what
    /// went, by `<type>:<wire id>`.
    @discardableResult
    static func sendAll(_ store: KnowledgeStore) throws -> [String: OutboxChange] {
        let feeder = OutboxFeeder(connection: store, registry: N.registry)
        let writer = SpaceWriteGuard.Writer(user: "alice", permission: .readWrite, isOwner: true)
        var sent: [String: OutboxChange] = [:]
        for change in try feeder.nextBatch(now: Date().addingTimeInterval(60)) {
            var outgoing = change
            if change.zone.isSpace {
                let held = try store.replica.record(zoneKey: change.zoneKey, recordType: change.recordType.rawValue, wireID: change.wireID)
                    .map { try SyncEnvelope(storedPayload: $0.payload) }
                switch SpaceSync.guarded(change, held: held, writer: writer) {
                case .send(let guarded): outgoing = guarded
                case .nothingLeft, .refuse:
                    try feeder.discard(change)
                    continue
                }
            }
            sent["\(change.recordType.rawValue):\(change.wireID)"] = outgoing
            switch outgoing.action {
            case .save: try feeder.acknowledgeSave(outgoing, serverRecord: try OutboxTestProjections.serverRecord(for: outgoing))
            case .delete: try feeder.acknowledgeDelete(outgoing)
            }
        }
        return sent
    }

    /// A record built from the fields a change sent, as another Mac receives it.
    static func received(_ change: OutboxChange?, zoneKey: String = N.libraryZoneKey) throws -> ReplicaRecord {
        let change = try #require(change)
        let fields = try #require(N.savedFields(change))
        return try N.record(change.recordType, change.wireID, fields, zoneKey: zoneKey)
    }

    /// The decoded text of a satellite laid out from `text`, as the satellite reader hands it over.
    static func satelliteBody(_ stored: Data) throws -> Data {
        try SyncGzip.decompress(stored, maxBytes: 64 << 20)
    }
}
