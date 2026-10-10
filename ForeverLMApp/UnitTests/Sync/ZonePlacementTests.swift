import Foundation
import Testing
@testable import ForeverLM

/// `zoneFor` (§4.4) from each type's `home` in the schema: records land in the zone of their resolved
/// home, so a device that knows of a merge or a move writes new children into the right place.
@Suite("Zone placement")
struct ZonePlacementTests {
    typealias Replica = SyncVectorRunner.VectorReplica

    @Test("The placement vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("placement")
    }

    @Test("Every type's home is data the schema gives, and it never names a zone the type cannot use")
    func homesAreSchemaData() {
        for type in SyncRecordType.allCases {
            let spec = type.spec
            #expect((spec.home.rule == .library) == spec.isPrivateOnly, Comment(rawValue: type.rawValue))
            let placed = ZonePlacement.zone(for: type, id: "x", fields: type == .chat ? ["kind": "chat"] : [:], writtenIn: .space("s1"),
                                            replica: Replica(records: [:]))
            #expect(spec.zones.contains(placed.kind), Comment(rawValue: "\(type.rawValue) placed in \(placed.name)"))
        }
    }

    @Test("A child of a merged notebook goes to the survivor; of a moved one, to the space; of a moving one, to Library until the copy arrives")
    func resolvedHomes() {
        let entry: [String: SyncJSON] = ["containerKind": "notebook", "containerID": "nbA", "itemKind": "source", "itemID": "src_1"]
        func zone(_ records: [String: SyncJSON]) -> String {
            ZonePlacement.zone(for: .entry, id: "en:nbA:source:src_1", fields: entry, writtenIn: .library, replica: Replica(records: records)).name
        }
        #expect(zone(["Library": ["Notebook": ["nbA": ["mergedInto": "nbB"], "nbB": [:]]]]) == "Library")
        #expect(zone(["Library": ["Notebook": ["nbA": ["movedTo": "s1"]]], "Space-s1": ["Notebook": ["nbA": [:]]]]) == "Space-s1")
        #expect(zone(["Library": ["Notebook": ["nbA": ["movingTo": "s1"]]]]) == "Library")
        #expect(zone(["Library": ["Notebook": ["nbA": ["movingTo": "s1"]]], "Space-s1": ["Notebook": ["nbA": [:]]]]) == "Space-s1")
        #expect(zone(["Library": ["Notebook": ["nbA": ["mergedInto": "nbB"], "nbB": ["movedTo": "s2"]]], "Space-s2": ["Notebook": ["nbB": [:]]]]) == "Space-s2")
    }

    @Test("A private chat stays in Library and a shared one follows its notebook into the space")
    func chats() {
        let replica = Replica(records: ["Space-t1": ["Notebook": ["nb7": [:]]]])
        #expect(ZonePlacement.zone(for: .chat, id: "c1", fields: ["kind": "chat", "notebookID": "nb7"], writtenIn: .library, replica: replica) == .space("t1"))
        for kind in ChatKind.allCases where kind.isPrivate {
            #expect(ZonePlacement.zone(for: .chat, id: "c1", fields: ["kind": .string(kind.rawValue), "notebookID": "nb7"], writtenIn: .library,
                                       replica: replica) == .library)
        }
    }

    @Test("Satellites go where their owner is, except personal ones, which are always private")
    func satellites() {
        let replica = Replica(records: ["Catalog": ["Source": ["src_1": [:]]], "Space-s1": ["Source": ["src_1": [:]], "Artifact": ["art1": [:]]]])
        func zone(_ fields: [String: SyncJSON], _ library: SyncZoneName) -> SyncZoneName {
            ZonePlacement.zone(for: .content, id: "ct:x", fields: fields, writtenIn: library, replica: replica)
        }
        #expect(zone(["ownerType": "Source", "ownerID": "src_1", "role": "pdf"], .library) == .content)
        #expect(zone(["ownerType": "Source", "ownerID": "src_1", "role": "pdf"], .space("s1")) == .space("s1"))
        #expect(zone(["ownerType": "Artifact", "ownerID": "art1", "role": "body"], .library) == .space("s1"))
        #expect(zone(["ownerType": "Artifact", "ownerID": "art1", "role": "draftBase"], .space("s1")) == .content)
    }

    @Test("Zone names read and print as CloudKit names them")
    func zoneNames() {
        #expect(SyncZoneName("Library") == .library)
        #expect(SyncZoneName("Space-6f1c0e8a")?.name == "Space-6f1c0e8a")
        #expect(SyncZoneName("Space-") == nil)
        #expect(SyncZoneName("Archive") == nil)
    }
}
