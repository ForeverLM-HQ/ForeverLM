import Foundation
import Testing
@testable import ForeverLM

/// What may be written into a space (§9.2): nothing per member reaches a shared record (D18, bug b2),
/// a private chat kind stays private (D19), and scores and grading stay off shared chats (D20).
@Suite("Space write guard")
struct SpaceWriteGuardTests {
    static let member = SpaceWriteGuard.Writer(user: "_member", permission: .readWrite, isOwner: false)
    static let owner = SpaceWriteGuard.Writer(user: "_owner", permission: .readWrite, isOwner: true)
    static let reader = SpaceWriteGuard.Writer(user: "_reader", permission: .readOnly, isOwner: false)

    @Test("Every priv-only type is refused in a space, and every shareable one is let in")
    func privateOnlyTypes() {
        for type in SyncRecordType.allCases {
            let refusals = SpaceWriteGuard.refusals(writing: type.rawValue, fields: type == .chat ? ["kind": "chat"] : [:], by: Self.member)
            #expect(refusals.contains(.privateOnlyType(type.rawValue)) == type.spec.isPrivateOnly, Comment(rawValue: type.rawValue))
            if !type.spec.isPrivateOnly { #expect(refusals.isEmpty, Comment(rawValue: type.rawValue)) }
        }
    }

    @Test("A member-local field is refused, even on a type the generator lets into spaces")
    func memberLocalFields() throws {
        // The generator never puts a member-local field on a shareable type; the guard refuses one anyway.
        let notebook = SyncRecordType.notebook.spec
        let leaked = SyncTypeSpec(.notebook, prefix: notebook.prefix, zones: notebook.zones, home: notebook.home, isPrivateOnly: false,
                                  idForms: notebook.idForms, idDeterminism: notebook.idDeterminism, cloudKitFields: notebook.cloudKitFields,
                                  fields: notebook.fields + [SyncFieldSpec("courseOrder", json: "orderKey", kind: .map, policy: .lastWriter, isMemberLocal: true)])
        let refusals = SpaceWriteGuard.refusals(writing: "Notebook", fields: ["title": "Shared", "courseOrder": ["crs1": "a0"]], by: Self.member, spec: leaked)
        #expect(refusals == [.memberLocalField(type: "Notebook", field: "courseOrder")])
        // The schema's own member-local fields sit on priv-only types, so their records never get in at all.
        for type in SyncRecordType.allCases {
            for field in type.spec.fields where field.isMemberLocal { #expect(type.spec.isPrivateOnly, Comment(rawValue: "\(type.rawValue).\(field.name)")) }
        }
        #expect(SpaceWriteGuard.refusals(writing: "NotebookState", fields: ["courseOrder": ["crs1": "a0"]], by: Self.member)
            .contains(.privateOnlyType("NotebookState")))
    }

    @Test("Private chat kinds stay in Library; chat and transcript are shareable")
    func chatKinds() {
        for kind in ChatKind.allCases {
            let refused = !SpaceWriteGuard.refusals(writing: "Chat", fields: ["kind": .string(kind.rawValue)], by: Self.member).isEmpty
            #expect(refused == kind.isPrivate, Comment(rawValue: kind.rawValue))
        }
        #expect(SpaceWriteGuard.refusals(writing: "Chat", fields: [:], by: Self.member) == [.privateKind(type: "Chat", field: "kind", value: "")])
    }

    @Test("Scores and grading never reach a space: every privateKindsOnly field is refused, even on a shareable chat")
    func privateKindsOnlyFields() throws {
        let flagged = SyncRecordType.allCases.flatMap { type in
            type.spec.fields.filter(\.isPrivateKindsOnly).map { "\(type.rawValue).\($0.name)" }
        }
        #expect(flagged.sorted() == ["Chat.overallScore", "Exchange.grading", "Exchange.score"])

        #expect(SpaceWriteGuard.refusals(writing: "Exchange", fields: ["question": "Why?", "grading": ["questionVerdict": "right"]], by: Self.member)
            == [.privateKindsOnlyField(type: "Exchange", field: "grading")])
        #expect(SpaceWriteGuard.refusals(writing: "Exchange", fields: ["question": "Why?", "score": 0.8], by: Self.owner)
            == [.privateKindsOnlyField(type: "Exchange", field: "score")])
        // A review misfiled as a chat passes the kind rule, and its score is still refused.
        #expect(SpaceWriteGuard.refusals(writing: "Chat", fields: ["kind": "chat", "overallScore": 72], by: Self.member)
            == [.privateKindsOnlyField(type: "Chat", field: "overallScore")])
        // Cleared (null) or absent, nothing is carried, so nothing is refused.
        #expect(SpaceWriteGuard.refusals(writing: "Exchange", fields: ["question": "Why?", "grading": .null, "score": .null], by: Self.member).isEmpty)
        #expect(SpaceWriteGuard.refusals(writing: "Chat", fields: ["kind": "chat", "overallScore": .null], by: Self.member).isEmpty)

        // A patch that adds a score to a shared chat is refused before anything is queued.
        let held = SyncEnvelope(type: "Chat", id: "cht1", saltID: "00000000", fields: ["kind": "chat", "title": "Shared"], stamps: [:])
        #expect(throws: SpaceWriteGuard.Refusal.privateKindsOnlyField(type: "Chat", field: "overallScore")) {
            try SpaceWriteGuard.check(RecordPatch(.chat, id: "cht1", changes: ["overallScore": .value(64)]), onto: held, by: Self.member)
        }
        try SpaceWriteGuard.check(RecordPatch(.chat, id: "cht1", changes: ["title": .value("Renamed")]), onto: held, by: Self.member)
    }

    @Test("Personal satellites are refused, by field and by role")
    func personalSatellites() {
        let learnerModel: SyncJSON = ["owner": "root", "role": "learnerModel", "hash": .string(String(repeating: "a", count: 64)),
                                      "parts": [.string(String(repeating: "b", count: 32))]]
        #expect(SpaceWriteGuard.refusals(writing: "ZoneRoot", fields: ["kind": "team", "learnerModel": learnerModel], by: Self.owner)
            == [.personalSatellite(type: "ZoneRoot", field: "learnerModel")])
        let draftBase: SyncJSON = ["owner": "art1", "role": "draftBase", "hash": .string(String(repeating: "a", count: 64)),
                                   "parts": [.string(String(repeating: "b", count: 32))]]
        #expect(SpaceWriteGuard.refusals(writing: "Artifact", fields: ["kind": "doc", "files": ["base": draftBase]], by: Self.member)
            == [.personalSatellite(type: "Artifact", field: "files")])
        #expect(SpaceWriteGuard.refusals(writing: "Content", fields: ["role": "understanding"], by: Self.member)
            == [.personalSatellite(type: "Content", field: "role")])
        #expect(SpaceWriteGuard.refusals(writing: "Content", fields: ["role": "pdf", "personal": false], by: Self.member).isEmpty)
    }

    @Test("A read-only participant writes and deletes nothing")
    func readOnly() {
        #expect(SpaceWriteGuard.refusals(writing: "Notebook", fields: ["title": "x"], by: Self.reader) == [.readOnlyParticipant])
        #expect(SpaceWriteGuard.refusals(deleting: "Task", fields: [:], by: Self.reader) == [.readOnlyParticipant])
    }

    @Test("A notebook, Doc, course or chat is deleted only by the space owner or whoever made it")
    func deletes() {
        let mine: [String: SyncJSON] = ["createdBy": SyncPerson(user: "_member", name: "Me").value]
        let theirs: [String: SyncJSON] = ["createdBy": SyncPerson(user: "_other", name: "Them").value]
        for type in ["Notebook", "Artifact", "Chat"] {
            #expect(SpaceWriteGuard.refusals(deleting: type, fields: mine, by: Self.member).isEmpty)
            #expect(SpaceWriteGuard.refusals(deleting: type, fields: theirs, by: Self.member) == [.deleteNotAllowed(type: type)])
            #expect(SpaceWriteGuard.refusals(deleting: type, fields: theirs, by: Self.owner).isEmpty)
        }
        // Course has no createdBy (§3.5.9): only the owner deletes a space's course.
        #expect(SpaceWriteGuard.refusals(deleting: "Course", fields: [:], by: Self.member) == [.deleteNotAllowed(type: "Course")])
        #expect(SpaceWriteGuard.refusals(deleting: "Entry", fields: [:], by: Self.member).isEmpty)
    }

    @Test("A patch is checked against the record it produces")
    func patches() throws {
        let held = SyncEnvelope(type: "Chat", id: "cht1", saltID: "00000000", fields: ["kind": "review"], stamps: [:])
        #expect(throws: SpaceWriteGuard.Refusal.self) {
            try SpaceWriteGuard.check(RecordPatch(.chat, id: "cht1", changes: ["title": .value("Renamed")]), onto: held, by: Self.member)
        }
        try SpaceWriteGuard.check(RecordPatch(.chat, id: "cht2", changes: ["kind": .value("chat"), "title": .value("New")]), onto: nil, by: Self.member)
        #expect(SpaceWriteGuard.refusals(writing: "FutureType", fields: [:], by: Self.member) == [.unknownType("FutureType")])
    }
}

/// Security audit, 2026-11-12: CloudKit lets any read-write member save a space's root, and every
/// device took the root it fetched, so a member could rotate the salt (every device drops the
/// space) or raise `minClientRevision` (every device stops writing).
@Suite("Space root policy")
struct SpaceRootPolicyTests {
    @Test("A joined space takes a root only its owner saved")
    func joinedSpaceTakesOnlyTheOwnersRoot() {
        #expect(SpaceRootPolicy.acceptsRoot(modifiedBy: "_owner", zoneOwner: "_owner", isOwned: false, me: "_member"))
        #expect(!SpaceRootPolicy.acceptsRoot(modifiedBy: "_other_member", zoneOwner: "_owner", isOwned: false, me: "_member"))
        // A member's own save of the root reads back as the current user, and is still not the owner's.
        #expect(!SpaceRootPolicy.acceptsRoot(modifiedBy: CloudZoneID.currentUser, zoneOwner: "_owner", isOwned: false, me: "_member"))
        #expect(!SpaceRootPolicy.acceptsRoot(modifiedBy: "_member", zoneOwner: "_owner", isOwned: false, me: "_member"))
        // A root whose saver is not named is nobody's to trust.
        #expect(!SpaceRootPolicy.acceptsRoot(modifiedBy: nil, zoneOwner: "_owner", isOwned: false, me: "_member"))
        #expect(!SpaceRootPolicy.acceptsRoot(modifiedBy: nil, zoneOwner: CloudZoneID.currentUser, isOwned: true, me: "_owner"))
    }

    @Test("An owned space takes its own saves and no member's")
    func ownedSpaceTakesOnlyItsOwn() {
        let zoneOwner = CloudZoneID.currentUser
        #expect(SpaceRootPolicy.acceptsRoot(modifiedBy: CloudZoneID.currentUser, zoneOwner: zoneOwner, isOwned: true, me: "_owner"))
        #expect(SpaceRootPolicy.acceptsRoot(modifiedBy: "_owner", zoneOwner: zoneOwner, isOwned: true, me: "_owner"))
        #expect(!SpaceRootPolicy.acceptsRoot(modifiedBy: "_member", zoneOwner: zoneOwner, isOwned: true, me: "_owner"))
    }

    @Test("minClientRevision holds writes back only within a real revision's reach")
    func minClientRevisionIsCapped() {
        #expect(!SpaceRootPolicy.requiresNewerBuild(nil, revision: 1))
        #expect(!SpaceRootPolicy.requiresNewerBuild(1, revision: 1))
        #expect(SpaceRootPolicy.requiresNewerBuild(2, revision: 1))
        #expect(SpaceRootPolicy.requiresNewerBuild(1 + SpaceRootPolicy.maxRevisionLead, revision: 1))
        #expect(!SpaceRootPolicy.requiresNewerBuild(2 + SpaceRootPolicy.maxRevisionLead, revision: 1))
        #expect(!SpaceRootPolicy.requiresNewerBuild(Int.max, revision: 1))
    }

    @Test("An owner's invitation link reads unless the owner chose editing")
    func invitationLinkDefaultsToReadOnly() {
        #expect(StorageService.defaultInvitationLinkPermission == .readOnly)
    }
}
