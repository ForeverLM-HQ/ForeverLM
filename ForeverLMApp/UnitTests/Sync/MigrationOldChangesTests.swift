import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Reading the old container's change feed (docs/cloudkit-schema-design.md §13.6): the feed is in change
/// order, so what a page says last about a record name stands, however the pages split the story.
@Suite("Migration old changes")
struct MigrationOldChangesTests {
    /// A transport whose zone feed is a script: the pages it hands out, in order. Everything else is refused.
    private final class ScriptedFeed: CloudTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [CloudZoneChanges]

        init(_ pages: [CloudZoneChanges]) { self.pages = pages }

        var containerIdentifier: String { "scripted" }
        func accountStatus() async throws -> CKAccountStatus { .available }
        func userRecordName() async throws -> String { "_learner" }
        func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] { [] }
        func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
            throw CloudError(.notAuthenticated, message: "read only")
        }
        func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
            throw CloudError(.notAuthenticated, message: "read only")
        }
        func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
            let page = lock.withLock { pages.removeFirst() }
            return Dictionary(uniqueKeysWithValues: requests.map { ($0.zoneID, .success(page)) })
        }
        func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
            throw CloudError(.notAuthenticated, message: "read only")
        }
        func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope, savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
            throw CloudError(.notAuthenticated, message: "read only")
        }
    }

    private static let zone = CloudZoneID(CloudKitZoneHome.knowledgeZoneName)

    private static func record(_ name: String) -> CloudRecord {
        CloudRecord(id: CloudRecordID(name, in: zone), recordType: CloudKitSyncEntity.artifact.recordType)
    }

    private static func deletion(_ name: String) -> CloudRecordDeletion {
        CloudRecordDeletion(id: CloudRecordID(name, in: zone), recordType: CloudKitSyncEntity.artifact.recordType)
    }

    private static func page(modified: [String] = [], deleted: [String] = [], more: Bool, token: String) -> CloudZoneChanges {
        CloudZoneChanges(modified: modified.map(record), deleted: deleted.map(deletion), changeToken: CloudChangeToken(data: Data(token.utf8)), moreComing: more)
    }

    @Test("A record deleted on one page and saved again on a later one is a record; saved and then deleted is a deletion (F32)")
    func lastWordOfTheFeedStands() async throws {
        let feed = ScriptedFeed([
            Self.page(modified: ["a", "b"], deleted: ["c"], more: true, token: "t1"),
            Self.page(modified: ["c"], deleted: ["b"], more: true, token: "t2"),
            Self.page(deleted: ["d"], more: false, token: "t3"),
        ])
        let zone = try #require(MigrationOldZone(name: CloudKitZoneHome.knowledgeZoneName))
        let fetched = try await MigrationOldChangeFetcher(transport: feed).fetch(zone, since: CloudChangeToken(data: Data("t0".utf8)))
        #expect(fetched.modified.map(\.id.recordName).sorted() == ["a", "c"], "c was saved again after its deletion")
        #expect(fetched.deleted == ["b", "d"], "b was deleted after it was saved")
        #expect(fetched.tokenText == Data("t3".utf8).base64EncodedString())
    }
}
