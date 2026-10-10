import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// `CloudKitMapping`, the values the schema-v2 sync works on to and from CloudKit's objects
/// (docs/cloudkit-schema-design.md §14.1; WP4b's corrections for WP5). Nothing here talks to a
/// container: a `CKRecord` is made and read locally.
@Suite("CloudKit transport mapping")
struct CloudKitTransportMappingTests {
    private static let zone = CloudZoneID("Library")

    @Test("Every encrypted and plain key is read, not a fixed list, so an old record keeps fields such as userModificationDate")
    func readsEveryKey() throws {
        let ck = CKRecord(recordType: "Source", recordID: CKRecord.ID(recordName: "source-1", zoneID: Self.zone.ck))
        ck.encryptedValues["payload"] = Data("{}".utf8) as NSData
        ck.encryptedValues["title"] = "A paper" as NSString
        ck["userModificationDate"] = Date(timeIntervalSinceReferenceDate: 812_000_000) as NSDate
        ck["revision"] = NSNumber(value: 7)
        ck["score"] = NSNumber(value: 0.25)
        ck["tags"] = ["a", "b"] as NSArray

        let record = CloudKitMapping.record(ck)
        #expect(record.id == CloudRecordID("source-1", in: Self.zone))
        #expect(record.encryptedFields["payload"] == .bytes(Data("{}".utf8)))
        #expect(record.encryptedFields["title"] == .string("A paper"))
        #expect(record.fields["userModificationDate"] == .date(Date(timeIntervalSinceReferenceDate: 812_000_000)))
        #expect(record.fields["revision"] == .int64(7))
        #expect(record.fields["score"] == .double(0.25))
        #expect(record.fields["tags"] == .stringList(["a", "b"]))
        #expect(record.fields["title"] == nil, "an encrypted key is never read as a plain one")
        #expect(record.systemFields != nil)
    }

    @Test("A record saved from its system fields names the same record; without them it is a create")
    func systemFieldsRoundTrip() throws {
        let ck = CKRecord(recordType: "Notebook", recordID: CKRecord.ID(recordName: "nb_abc", zoneID: Self.zone.ck))
        var value = CloudKitMapping.record(ck)
        value.payload = Data("{\"env\":1}".utf8)
        let update = try CloudKitMapping.ckRecord(value)
        #expect(update.recordID == ck.recordID)
        #expect(update.recordType == "Notebook")
        #expect(update.encryptedValues["payload"] as? Data == Data("{\"env\":1}".utf8))

        var create = CloudRecord(id: CloudRecordID("nb_new", in: Self.zone), recordType: "Notebook")
        create.payload = Data([1])
        let created = try CloudKitMapping.ckRecord(create)
        #expect(created.recordChangeTag == nil)
        #expect(created.recordID.recordName == "nb_new")

        // System fields of another record are refused rather than saved under the wrong name.
        var mismatched = value
        mismatched.id = CloudRecordID("nb_other", in: Self.zone)
        #expect(throws: CloudError.self) { try CloudKitMapping.ckRecord(mismatched) }
    }

    @Test("A CKError keeps its code, its retryAfter and the server's record; a deletion reason maps one to one")
    func errorsAndReasons() throws {
        let server = CKRecord(recordType: "Notebook", recordID: CKRecord.ID(recordName: "nb_abc", zoneID: Self.zone.ck))
        server.encryptedValues["payload"] = Data([9]) as NSData
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server, CKErrorRetryAfterKey: NSNumber(value: 3.5)])
        let mapped = CloudKitMapping.error(error)
        #expect(mapped.code == .serverRecordChanged)
        #expect(mapped.retryAfter == 3.5)
        #expect(mapped.serverRecord?.payload == Data([9]))
        #expect(CloudKitMapping.error(CloudError(.zoneBusy)).code == .zoneBusy)
        #expect(CloudKitMapping.reason(.purged) == .purged)
        #expect(CloudKitMapping.reason(.encryptedDataReset) == .encryptedDataReset)
        #expect(CloudKitMapping.reason(.deleted) == .deleted)
    }
}
