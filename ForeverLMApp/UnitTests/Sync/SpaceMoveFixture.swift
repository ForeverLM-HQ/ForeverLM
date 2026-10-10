import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Macs, a space and a notebook for WP15b's suites (docs/cloudkit-schema-design.md §4.4, §5.2, §5.3, §9.2,
/// D51): Alice's Macs on FakeCloudKit, each with the app's projections and triggers, its private engine,
/// SpaceSync, BlobStore and WP15's SpaceService, and a notebook her iPhone wrote with everything a move
/// carries and everything it leaves (private chats). A suite moves it with `SpaceMoveJob`.
enum SpaceMoveFixture {
    static let user = "alice"
    static let personalSalt = Data(repeating: 1, count: 32)
    static let spaceID = "s1"
    static let spaceKey = "private/Space-s1"
    static let libraryKey = "private/Library"
    static let catalogKey = "private/Catalog"
    static let owner = SyncPerson(user: "alice", name: "Alice")

    static let notebook = "nb-cells"
    /// Approved, pending and rejected: the third travels as its Entry alone (§5.3 step 4).
    static let sources = ["src-a", "src-b", "src-c"]
    static let chat = "cht-open"
    static let exchanges = ["exc-1", "exc-2"]
    /// Chats that stay in `Library` whole (D19, D20, R5-m1).
    static let privateChats = ["cht-voice", "cht-walk", "cht-quiz", "cht-review", "cht-overall", "cht-scored"]
    static let doc = "doc-1"
    static let comment = "cmt-1"
    static let task = "tsk-1"
    static let base: Int64 = 1_759_400_000_000

    // MARK: A Mac of Alice's

    final class Mac {
        let device: EngineTestDevice
        let spaces: SpaceSync
        let blobs: BlobStore
        let shares: ShareService
        let service: SpaceService

        init(_ server: FakeCloudKit, name: String, deviceID: String) async throws {
            device = try EngineTestDevice(server, name: name, deviceID: deviceID, user: SpaceMoveFixture.user, registry: KnowledgeStore.projectionRegistry)
            var pacing = SyncPacerState.Configuration()
            pacing.capacity = 1_000_000
            pacing.refillPerSecond = 1_000_000
            let pacer = SyncPacer(configuration: pacing)
            let clock: @Sendable () -> Date = { Date().addingTimeInterval(EngineTestDevice.ahead) }
            spaces = SpaceSync(transport: device.transport, store: device.local, moveMaps: device.engine.moveMaps, deviceID: deviceID,
                               pacer: { _ in pacer }, clock: clock)
            blobs = BlobStore(transport: device.transport, store: device.local, deviceID: deviceID, pacer: { _ in pacer }, clock: clock)
            shares = ShareService(transport: device.transport, store: device.local, spaces: spaces, accountName: "Alice")
            var service = SpaceService(transport: device.transport, store: device.local, spaces: spaces, shares: shares, deviceID: deviceID)
            service.now = clock
            self.service = service
            try await device.bootstrap(.macHoldingLibrary, salt: 1)
        }

        var store: KnowledgeStore { device.store }
        var server: FakeCloudKit { device.server }

        /// A move job as the app makes one: this Mac's engine fetches `Library` and `Catalog`, its
        /// SpaceSync walks a space, and the moves it lists are the engine's and SpaceSync's.
        func job(deviceID: String? = nil) -> SpaceMoveJob {
            let engine = device.engine
            let sync = spaces
            let local = device.local
            let server = device.server
            return SpaceMoveJob(transport: device.transport, store: device.local, blobs: blobs, moveMaps: engine.moveMaps, spaces: service,
                                deviceID: deviceID ?? device.deviceID, clock: { Date().addingTimeInterval(EngineTestDevice.ahead) }) { zoneKey in
                EngineTestDriver.follow(server)
                if let row = try await local.perform({ try $0.replica.zone(key: zoneKey) }), let zone = SpaceZone(row) {
                    try await sync.walk(zone)
                } else {
                    try await engine.fetchChanges()
                }
            }
        }

        /// A round: the private engine, then every space.
        func sync() async throws {
            EngineTestDriver.follow(server)
            try await device.engine.sync()
            try await spaces.sync()
        }

        /// The space `Space-s1` made for the notebook, as WP15's SpaceService makes one, not shared yet.
        @discardableResult
        func makeSpace(kind: String = "notebook", primaryID: String? = SpaceMoveFixture.notebook, id: String = SpaceMoveFixture.spaceID) async throws -> SpaceSummary {
            EngineTestDriver.follow(server)
            return try await service.create(kind: kind, name: "Cells", owner: SpaceMoveFixture.owner, primaryID: primaryID, spaceID: id, share: false)
        }
    }

    // MARK: Records as Alice's iPhone writes them

    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], zone: String = "Library", salt: Data = personalSalt,
                       ms: Int64 = base, device: String = "iphoneaa") throws -> CloudRecord {
        var envelope = SyncEnvelope.new(type, id: id, saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields {
            if let kind = type.spec.field(field)?.kind, kind != .scalar, let elements = value.objectValue {
                patch.changes[field] = .elements(elements)
            } else {
                patch.changes[field] = .value(value)
            }
        }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: ms, counter: counter, deviceID: device)
        }
        return CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: type, id: id, salt: salt), in: CloudZoneID(zone)), recordType: type.rawValue,
                           encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())])
    }

    static func entry(_ notebookID: String, _ sourceID: String, approval: String, order: String) throws -> CloudRecord {
        try record(.entry, SyncIdentity.entryID(containerID: notebookID, itemKind: "source", itemID: sourceID), [
            "containerKind": "notebook", "containerID": .string(notebookID), "itemKind": "source", "itemID": .string(sourceID),
            "state": "active", "approval": .string(approval), "orderKey": .string(order), "origin": "added", "addedAt": SyncJSON(base),
        ])
    }

    static func chatRecord(_ id: String, kind: String, extra: [String: SyncJSON] = [:]) throws -> CloudRecord {
        var fields: [String: SyncJSON] = [
            "kind": .string(kind), "notebookID": .string(notebook), "title": .string("Chat \(id)"), "status": "active",
            "contextMode": "notebook", "createdAt": SyncJSON(base), "editedAt": SyncJSON(base),
        ]
        fields.merge(extra) { _, new in new }
        return try record(.chat, id, fields)
    }

    static func exchangeRecord(_ id: String, chat: String, seq: Int, extra: [String: SyncJSON] = [:], ms: Int64 = base) throws -> CloudRecord {
        var fields: [String: SyncJSON] = [
            "chatID": .string(chat), "seq": SyncJSON(Int64(seq)), "createdAt": SyncJSON(ms), "question": .string("Question \(seq)?"),
            "evaluation": .string("Answer \(seq)."),
        ]
        fields.merge(extra) { _, new in new }
        return try record(.exchange, id, fields, ms: ms)
    }

    static func sourceRecord(_ id: String) throws -> CloudRecord {
        try record(.source, id, [
            "type": "article", "title": .string("Article \(id)"), "url": .string("https://example.org/\(id)"), "status": "active",
            "ingest": .object(["ord": .array([0, 1]), "state": "queued"]), "addedAt": SyncJSON(base),
            "primaryKey": .string("url:example.org/\(id)"), "workKeys": .object(["url:example.org/\(id)": .bool(true)]),
        ], zone: "Catalog")
    }

    /// The notebook and everything filed in it, written into Alice's library by her iPhone; her Mac then
    /// fetches it, so its projections lay down the local rows.
    static func seed(_ mac: Mac) async throws {
        let server = mac.server
        server.put(try sources.map(sourceRecord), zone: "Catalog", owner: user)
        var library: [CloudRecord] = [
            try record(.notebook, notebook, ["title": "🧬 Cells", "status": "active", "createdAt": SyncJSON(base), "instructions": "Read slowly"]),
            try entry(notebook, "src-a", approval: "approved", order: "a0"),
            try entry(notebook, "src-b", approval: "pending", order: "a1"),
            try entry(notebook, "src-c", approval: "rejected", order: "a2"),
            try chatRecord(chat, kind: "chat"),
            try exchangeRecord(exchanges[0], chat: chat, seq: 1),
            try exchangeRecord(exchanges[1], chat: chat, seq: 2),
            try chatRecord("cht-voice", kind: "voice"),
            try chatRecord("cht-walk", kind: "walkthrough"),
            try chatRecord("cht-quiz", kind: "quizSitting"),
            try chatRecord("cht-review", kind: "review", extra: ["overallScore": SyncJSON(4.0)]),
            try exchangeRecord("exc-review", chat: "cht-review", seq: 1, extra: ["score": SyncJSON(4.0)]),
            // A review misfiled as a chat: its score keeps it, and its Exchanges, in Library whole.
            try chatRecord("cht-overall", kind: "chat", extra: ["overallScore": SyncJSON(3.0)]),
            try exchangeRecord("exc-overall", chat: "cht-overall", seq: 1),
            try chatRecord("cht-scored", kind: "chat"),
            try exchangeRecord("exc-scored-1", chat: "cht-scored", seq: 1),
            try exchangeRecord("exc-scored-2", chat: "cht-scored", seq: 2, extra: ["score": SyncJSON(2.0)]),
            try record(.artifact, doc, ["kind": "doc", "title": "Cell notes", "notebookID": .string(notebook), "status": "active", "createdAt": SyncJSON(base)]),
            try record(.comment, comment, ["artifactID": .string(doc), "body": "Check the figure", "author": owner.value, "createdAt": SyncJSON(base),
                                           "editedAt": SyncJSON(base)]),
            try record(.task, task, ["kind": "todo", "notebookID": .string(notebook), "title": "Read src-a", "status": "todo", "createdAt": SyncJSON(base),
                                     "editedAt": SyncJSON(base)]),
        ]
        library.sort { $0.id.recordName < $1.id.recordName }
        server.put(library, zone: "Library", owner: user)
        EngineTestDriver.follow(server)
        try await mac.device.fetch()
    }

    // MARK: Reading what happened

    static func spaceSalt(_ mac: Mac, key: String = spaceKey) throws -> Data {
        let root = try #require(try mac.store.replica.record(zoneKey: key, recordName: SyncSchema.rootRecordName))
        return try #require(try SyncEnvelope(storedPayload: root.payload).fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:)))
    }

    /// A record as the server holds it, decoded; nil when it has none.
    static func server(_ mac: Mac, _ type: SyncRecordType, _ id: String, zone: String) throws -> SyncEnvelope? {
        let salt = zone.hasPrefix(SyncSchema.spaceZonePrefix) ? try spaceSalt(mac, key: "private/\(zone)") : personalSalt
        let name = type == .zoneRoot ? SyncSchema.rootRecordName : RecordNaming.recordName(type: type, id: id, salt: salt)
        guard let payload = mac.server.storedRecord(name, zone: zone, owner: user)?.payload else { return nil }
        return try SyncEnvelope(storedPayload: payload)
    }

    static func inSpace(_ mac: Mac, _ type: SyncRecordType, _ id: String, zone: String = "Space-s1") throws -> SyncEnvelope? {
        try server(mac, type, id, zone: zone)
    }

    static func inLibrary(_ mac: Mac, _ type: SyncRecordType, _ id: String) throws -> SyncEnvelope? {
        try server(mac, type, id, zone: type == .source || type == .collection ? "Catalog" : "Library")
    }

    /// Every move the personal root's `moveMaps` entries list, read back as any device reads them.
    static func listedMoves(_ mac: Mac) async throws -> [MoveMapMove] {
        let root = try #require(try server(mac, .zoneRoot, "root", zone: "Library"))
        let fetch = MoveMapIndex.transportFetch(mac.device.transport, salt: personalSalt)
        var moves: [MoveMapMove] = []
        for entry in MoveMapIndex.entries(of: root) {
            moves += try MoveMapIndex.decodeList(try await fetch(entry.file))
        }
        return moves
    }

    static func count(_ mac: Mac, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
        try mac.store.scalarInteger(sql, parameters) ?? -1
    }

    static func text(_ mac: Mac, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        try mac.store.scalarText(sql, parameters)
    }

    /// What every finished move of the notebook into `Space-s1` leaves, whichever way it got there.
    static func expectMoved(_ mac: Mac, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // The space holds the notebook (no redirect, made by its owner), its Entries, the sources the live
        // ones name, the ordinary chat and its Exchanges, the Doc and its Comment, the task.
        let copy = try #require(try inSpace(mac, .notebook, notebook), sourceLocation: sourceLocation)
        #expect(copy.fields["title"] == .string("🧬 Cells"), sourceLocation: sourceLocation)
        #expect((copy.fields["movingTo"] ?? .null) == .null && copy.fields["movedTo"] == nil, sourceLocation: sourceLocation)
        #expect(copy.fields["createdBy"].flatMap(SyncPerson.init(json:))?.user == user, sourceLocation: sourceLocation)
        for source in sources {
            #expect(try inSpace(mac, .entry, SyncIdentity.entryID(containerID: notebook, itemKind: "source", itemID: source)) != nil, sourceLocation: sourceLocation)
            #expect(try inLibrary(mac, .entry, SyncIdentity.entryID(containerID: notebook, itemKind: "source", itemID: source)) == nil, sourceLocation: sourceLocation)
            #expect(try inLibrary(mac, .source, source) != nil, "the library keeps its own sources", sourceLocation: sourceLocation)
        }
        #expect(try inSpace(mac, .source, "src-a")?.fields["copiedFrom"]?["zone"] == .string("personal"), sourceLocation: sourceLocation)
        #expect(try inSpace(mac, .source, "src-b") != nil, sourceLocation: sourceLocation)
        #expect(try inSpace(mac, .source, "src-c") == nil, "a rejected suggestion travels as its Entry alone", sourceLocation: sourceLocation)
        for (type, id) in [(SyncRecordType.chat, chat), (.exchange, exchanges[0]), (.exchange, exchanges[1]), (.artifact, doc), (.comment, comment), (.task, task)] {
            #expect(try inSpace(mac, type, id) != nil, "\(type.rawValue) \(id) is in the space", sourceLocation: sourceLocation)
            #expect(try inLibrary(mac, type, id) == nil, "\(type.rawValue) \(id) left Library", sourceLocation: sourceLocation)
        }
        #expect(try inSpace(mac, .chat, chat)?.fields["createdBy"].flatMap(SyncPerson.init(json:))?.user == user, sourceLocation: sourceLocation)
        // Private chats stay in Library whole, with their Exchanges, filed by notebookID (§5.3 step 7, R5-m1).
        for id in privateChats {
            #expect(try inLibrary(mac, .chat, id)?.fields["notebookID"] == .string(notebook), "\(id) stays", sourceLocation: sourceLocation)
            #expect(try inSpace(mac, .chat, id) == nil, "\(id) never reaches the space", sourceLocation: sourceLocation)
        }
        for id in ["exc-review", "exc-overall", "exc-scored-1", "exc-scored-2"] {
            #expect(try inLibrary(mac, .exchange, id) != nil && inSpace(mac, .exchange, id) == nil, "\(id) stays with its chat", sourceLocation: sourceLocation)
        }
        // The original is the permanent stub.
        let stub = try #require(try inLibrary(mac, .notebook, notebook), sourceLocation: sourceLocation)
        #expect(stub.fields["status"] == .string("moved") && stub.fields["movedTo"] == .string(spaceID), sourceLocation: sourceLocation)
        // The moves are listed before any original went, and every moved record is listed.
        let listed = Set(try await listedMoves(mac).map { "\($0.type):\($0.id):\($0.from)>\($0.to)" })
        for id in [notebook, chat, doc, comment, task] + exchanges {
            #expect(listed.contains { $0.contains(":\(id):Library>Space-s1") }, "\(id) is listed", sourceLocation: sourceLocation)
        }
        #expect(!listed.contains { $0.contains("cht-voice") }, sourceLocation: sourceLocation)
        // The Mac's own rows: the notebook kept its row, now the space's; its pool names the space's sources.
        #expect(try count(mac, "SELECT COUNT(*) FROM learning_goals WHERE wire_key = ?", [.text(notebook)]) == 1, sourceLocation: sourceLocation)
        #expect(try text(mac, "SELECT team_id FROM learning_goals WHERE id = ?", [.text(notebook)]) == spaceID, sourceLocation: sourceLocation)
        // The approved and the pending source name the space's copies; the rejected one, which has no copy
        // there, keeps the learner's own (its Entry still moved).
        #expect(try count(mac, """
            SELECT COUNT(*) FROM learning_goal_items i JOIN sources s ON s.id = i.source_id WHERE i.goal_id = ? AND s.team_id = ?
        """, [.text(notebook), .text(spaceID)]) == 2, sourceLocation: sourceLocation)
        #expect(try count(mac, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = ?", [.text(notebook)]) == 3, "no duplicate pool rows", sourceLocation: sourceLocation)
        #expect(try text(mac, "SELECT resolved_zone FROM notebook_resolution WHERE id = ?", [.text(notebook)]) == "Space-s1", sourceLocation: sourceLocation)
    }
}
