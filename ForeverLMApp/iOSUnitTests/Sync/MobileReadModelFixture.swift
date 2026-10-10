import Foundation
@testable import ForeverLM

/// Records for the read-model suites (docs/cloudkit-schema-design.md §14.2 WP19b), as other devices wrote
/// them, applied to an in-memory replica the way inbound records are.
enum MobileReadModelFixture {
    static let library = "private/Library"
    static let catalog = "private/Catalog"
    static let space = "private/Space-s1"

    static func replica(spaceName: String? = "Acme Lab") async throws -> MobileReplica {
        let replica = try MobileReplica(path: ":memory:")
        if let spaceName {
            try await MobileSyncFixture.holdSpace(replica, zoneKey: space, zoneName: "Space-s1", owned: true, name: spaceName)
        }
        return replica
    }

    static func notebook(_ id: String, _ title: String, edited: Int64, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = ["title": .string(title), "status": .string("active"), "createdAt": SyncJSON(edited), "editedAt": SyncJSON(edited)]
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.notebook, id, fields)
    }

    static func entry(_ container: String, _ kind: String, _ item: String, order: String, containerKind: String = "notebook",
                      at milliseconds: Int64 = MobileSyncFixture.stampMilliseconds, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = [
            "containerKind": .string(containerKind), "containerID": .string(container), "itemKind": .string(kind), "itemID": .string(item),
            "state": .string("active"), "orderKey": .string(order), "origin": .string("added"), "addedAt": SyncJSON(1_000),
        ]
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.entry, "en:\(container):\(kind):\(item)", fields, at: milliseconds)
    }

    static func source(_ id: String, _ title: String, added: Int64, type: String = "paper", _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = [
            "primaryKey": .string("native:\(id)"), "type": .string(type), "title": .string(title), "status": .string("active"), "addedAt": SyncJSON(added),
        ]
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.source, id, fields)
    }

    static func chat(_ id: String, notebook: String?, kind: String = "chat", title: String? = nil, edited: Int64, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = [
            "kind": .string(kind), "title": .string(title ?? id), "status": .string("active"), "contextMode": .string("notebook"),
            "createdAt": SyncJSON(edited), "editedAt": SyncJSON(edited),
        ]
        if let notebook { fields["notebookID"] = .string(notebook) }
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.chat, id, fields)
    }

    static func exchange(_ id: String, chat: String, seq: Int, question: String, answer: String? = nil, reply: String? = nil) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = ["chatID": .string(chat), "seq": SyncJSON(seq), "createdAt": SyncJSON(Int64(seq)), "question": .string(question)]
        if let answer { fields["userAnswer"] = .string(answer) }
        if let reply { fields["evaluation"] = .string(reply) }
        return try MobileSyncFixture.envelope(.exchange, id, fields)
    }

    static func mark(_ kind: String, _ target: String, on: Bool = true) throws -> SyncEnvelope {
        try MobileSyncFixture.envelope(.mark, "mk:\(kind):\(target)", ["kind": .string(kind), "target": .string(target), "on": .bool(on), "at": SyncJSON(1)])
    }

    /// The value an untick of `entry` stores (§5.6): its `state` and `approval` stamps.
    static func stampPair(_ entry: SyncEnvelope) throws -> String {
        guard let parsed = SyncNotebookChatContext.Entry(entry) else { throw CocoaError(.coderValueNotFound) }
        return SyncNotebookChatContext.stampPair(parsed)
    }

    /// A set field's value: each member present.
    static func set(_ members: [String]) -> SyncJSON {
        .object(Dictionary(uniqueKeysWithValues: members.map { ($0, SyncJSON.bool(true)) }))
    }
}
