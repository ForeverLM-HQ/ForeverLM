import CloudKit
import XCTest
@testable import ForeverLM

/// The catalog sync reads a record's payload from the inline field or, for a
/// record that outgrew it, from the `payloadAsset` file. On 2026-09-10 a
/// ReviewSession in the second form stopped every iPhone sync with "CloudKit
/// returned … without its catalog payload" because only the inline field was
/// read.
final class MobileCloudRecordPayloadTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "Knowledge")

    func testInlinePayloadWinsOverAsset() throws {
        let record = CKRecord(recordType: "ReviewSession", recordID: CKRecord.ID(recordName: "r1", zoneID: zone))
        record.encryptedValues["payload"] = Data("inline".utf8) as NSData
        record["payloadAsset"] = CKAsset(fileURL: try writeTemp("asset"))

        let data = MobileCloudRecordPayload.data(from: record, payloadField: "payload", assetField: "payloadAsset")
        XCTAssertEqual(data, Data("inline".utf8))
    }

    func testOversizedPayloadIsReadFromTheAsset() throws {
        let record = CKRecord(recordType: "ReviewSession", recordID: CKRecord.ID(recordName: "r2", zoneID: zone))
        record["payloadAsset"] = CKAsset(fileURL: try writeTemp("{\"id\":\"big\"}"))

        let data = MobileCloudRecordPayload.data(from: record, payloadField: "payload", assetField: "payloadAsset")
        XCTAssertEqual(data, Data("{\"id\":\"big\"}".utf8))
    }

    func testRecordWithNeitherFormHasNoPayload() {
        let record = CKRecord(recordType: "ReviewSession", recordID: CKRecord.ID(recordName: "r3", zoneID: zone))
        XCTAssertNil(MobileCloudRecordPayload.data(from: record, payloadField: "payload", assetField: "payloadAsset"))
    }

    func testEmptyAssetFileCountsAsNoPayload() throws {
        let record = CKRecord(recordType: "ReviewSession", recordID: CKRecord.ID(recordName: "r4", zoneID: zone))
        record["payloadAsset"] = CKAsset(fileURL: try writeTemp(""))
        XCTAssertNil(MobileCloudRecordPayload.data(from: record, payloadField: "payload", assetField: "payloadAsset"))
    }

    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileCloudRecordPayloadTests-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
