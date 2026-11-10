import Foundation
import Testing
@testable import ForeverLM

/// Record names (§3.4) and the deterministic ids of §4.1: no title, URL or user text ever reaches a
/// name CloudKit shows in clear, and two devices that make one thing make one record.
@Suite("Record naming")
struct RecordNamingTests {
    @Test("The naming vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("naming")
    }

    @Test("Every type's name is its prefix and 26 base32 characters, at most 30 in all; ZoneRoot is root")
    func shape() {
        let salt = Data(repeating: 7, count: 32)
        for type in SyncRecordType.allCases {
            let name = RecordNaming.recordName(type: type, id: String(repeating: "x", count: 500), salt: salt)
            #expect(name.count <= SyncSchema.recordNameMaxLength)
            if type == .zoneRoot {
                #expect(name == "root")
            } else {
                #expect(name.range(of: "^\(type.spec.prefix!)_[a-z2-7]{26}$", options: .regularExpression) != nil)
            }
            #expect(RecordNaming.recordType(ofRecordName: name) == type)
        }
        #expect(RecordNaming.recordType(ofRecordName: "zzz_abc") == nil)
    }

    @Test("One id names two records in two zones, and ids compare exactly")
    func saltsAndCase() {
        let personal = Data(repeating: 1, count: 32)
        let space = Data(repeating: 2, count: 32)
        let id = "6f1c0e8a-0b8d-4d5c-9f5e-3f0e1c2b9a77"
        #expect(RecordNaming.recordName(type: .notebook, id: id, salt: personal) != RecordNaming.recordName(type: .notebook, id: id, salt: space))
        #expect(RecordNaming.recordName(type: .notebook, id: id, salt: personal) != RecordNaming.recordName(type: .notebook, id: id.uppercased(), salt: personal))
        #expect(RecordNaming.recordName(type: .notebook, id: id, salt: personal) != RecordNaming.recordName(type: .goal, id: id, salt: personal))
    }

    @Test("base32 is RFC 4648 lowercase with no padding")
    func base32() {
        #expect(RecordNaming.base32(Data()) == "")
        #expect(RecordNaming.base32(Data("f".utf8)) == "my")
        #expect(RecordNaming.base32(Data("foobar".utf8)) == "mzxw6ytboi")
    }

    @Test("Deterministic ids: sources, files, collections, migrated history, edges and per-member records")
    func identities() {
        #expect(SyncIdentity.sourceID(normalizedURL: "example.com/path") == "src_c074fe3957be94f706105a3fb3e1fe61d23fd5e3299f29b2d07dddcc339d7973")
        #expect(SyncIdentity.sourceFileID(sha256Hex: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            == "src_28379fe3885ed21e0b7da43f8b6c6673fb2c70cfce09c2dd0a7dbd5a2a99ea53")
        #expect(SyncIdentity.migratedSittingID("session:7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d") == "sit:legacy:01e8315ed124fad35f53e18b")
        #expect(SyncIdentity.entryID(containerID: "nb1", itemKind: "source", itemID: "src_2cd9") == "en:nb1:source:src_2cd9")
        #expect(SyncIdentity.entryID(containerID: "les1", itemKind: "source", itemID: "src_2cd9", span: 2) == "en:les1:source:src_2cd9#2")
        #expect(SyncIdentity.markID(kind: "hidden", target: "src:src_2cd9") == "mk:hidden:src:src_2cd9")
        #expect(SyncIdentity.activityLogID(day: "2026-10-02", deviceID: SyncIdentity.migratedHistoryDeviceID) == "al:2026-10-02:legacy22")
        #expect(SyncIdentity.contentID(owner: "src_1", role: "pdf", partHash32: "0123") == "ct:src_1:pdf:0123")
        #expect(SyncIdentity.collectionID(kind: "podcastShow", externalKey: "example.com/feed.xml").hasPrefix("col_"))
    }

    @Test("A new device id is 8 base32 characters and never legacy22")
    func deviceIDs() {
        for _ in 0..<200 {
            let id = SyncIdentity.newDeviceID()
            #expect(SyncStamp.isValidDeviceID(id))
            #expect(id != SyncIdentity.migratedHistoryDeviceID)
        }
        #expect(SyncStamp.isValidDeviceID(SyncIdentity.migratedHistoryDeviceID), "legacy22 is base32, so it must be refused explicitly")
    }
}
