import Foundation
import Testing
@testable import ForeverLM

/// Deleting inside a space (docs/cloudkit-schema-design.md §9.2, WP15): the space's owner deletes
/// anything in it; a member deletes a Notebook, Artifact, Course or Chat only when its `createdBy` names
/// them, and archives otherwise; a read-only member deletes nothing; personal rows are always the
/// learner's. A client rule, checked before anything is written; generation 1 never checks it.
@Suite("Space delete permission", .serialized)
struct SpaceDeletePermissionTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture

    /// Bob's Mac holding Alice's space with two notebooks: one Bob made, one Alice made.
    static func member(_ name: String, permission: String = "readWrite") throws -> (URL, KnowledgeStore, String) {
        let (root, store) = try F.makeStore(name)
        try F.prepareReplica(store)
        let zone = try S.holdSpace(store, spaceID: "s1", owner: "_alice", permission: permission)
        try F.apply(store, [
            try S.record(.notebook, "nb-bobs", ["title": .string("Bob's"), "status": .string("active"),
                                                 "createdBy": SyncPerson(user: "_bob", name: "Bob").value], zoneKey: zone),
            try S.record(.notebook, "nb-alices", ["title": .string("Alice's"), "status": .string("active"),
                                                   "createdBy": SyncPerson(user: "_alice", name: "Alice").value], zoneKey: zone),
        ])
        try store.replica.setEngineState(ReplicaStore.EngineScope.account, Data("_bob".utf8))
        return (root, store, zone)
    }

    @Test("A member deletes the notebook they made, not the owner's; the owner deletes both")
    func memberAndOwner() throws {
        let (root, store, _) = try Self.member("delete-member")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try SpaceRows.mayDelete(type: .notebook, localID: "nb-bobs", user: "_bob", connection: store))
        #expect(try !SpaceRows.mayDelete(type: .notebook, localID: "nb-alices", user: "_bob", connection: store))
        #expect(throws: KnowledgeStoreError.self) { try store.requireSpaceDeletion(.notebook, "nb-alices") }
        try store.requireSpaceDeletion(.notebook, "nb-bobs")

        let (ownerRoot, owner) = try F.makeStore("delete-owner")
        defer { try? FileManager.default.removeItem(at: ownerRoot) }
        try F.prepareReplica(owner)
        let zone = try S.holdSpace(owner, spaceID: "s1")
        try F.apply(owner, [try S.record(.notebook, "nb-bobs", ["title": .string("Bob's"), "status": .string("active"),
                                                                 "createdBy": SyncPerson(user: "_bob", name: "Bob").value], zoneKey: zone)])
        #expect(try SpaceRows.mayDelete(type: .notebook, localID: "nb-bobs", user: "_alice", connection: owner), "the owner deletes anything")
    }

    @Test("A read-only member deletes nothing; a personal row and a record not sent yet are the learner's")
    func readOnlyAndPersonal() throws {
        let (root, store, _) = try Self.member("delete-readonly", permission: "readOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try !SpaceRows.mayDelete(type: .notebook, localID: "nb-bobs", user: "_bob", connection: store))
        try F.addNotebook(store, "nb-mine")
        #expect(try SpaceRows.mayDelete(type: .notebook, localID: "nb-mine", user: "_bob", connection: store))
        let (writableRoot, writable, _) = try Self.member("delete-unsent")
        defer { try? FileManager.default.removeItem(at: writableRoot) }
        try writable.recordIdentity(zoneKey: "shared/_alice/Space-s1", recordType: "Chat", wireID: "chat-new", localID: "chat-new")
        #expect(try SpaceRows.mayDelete(type: .chat, localID: "chat-new", user: "_bob", connection: writable), "made here and not sent")
        #expect(try SpaceRows.mayDelete(type: .task, localID: "task-1", user: "_bob", connection: writable), "a type the rule does not name")
    }
}
