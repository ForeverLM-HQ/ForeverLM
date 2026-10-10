import CloudKit
import Foundation
import OSLog

// MARK: - Reading the old zones' changes from a token (docs/cloudkit-schema-design.md §13.6)

/// A zone of the old container as the base and the snapshot name it: `Knowledge`, or a `Team-<id>` the
/// learner owns, or `Team-<id>@<owner>` for one shared with them (`OldContainerZoneKey.snapshotZone`).
struct MigrationOldZone: Hashable, Sendable {
    let name: String
    let zoneID: CloudZoneID
    let database: CloudDatabaseScope

    init?(name: String) {
        guard !name.isEmpty else { return nil }
        self.name = name
        if let at = name.firstIndex(of: "@") {
            zoneID = CloudZoneID(String(name[..<at]), ownerName: String(name[name.index(after: at)...]))
            database = .shared
        } else {
            zoneID = CloudZoneID(name)
            database = .private
        }
    }

    var isKnowledge: Bool { zoneID.zoneName == CloudKitZoneHome.knowledgeZoneName }
}

/// What the old zone gave since the token.
struct MigrationFetchedZone: Sendable {
    let zone: MigrationOldZone
    /// Every record changed since the token (every record the zone holds after a walk from nil).
    var modified: [CloudRecord] = []
    /// The names of records deleted since the token. After a walk from nil, which never reports deletions,
    /// the caller names them by diffing against the base (`fullWalk`).
    var deleted: [String] = []
    /// The token to continue from; nil when the zone is gone.
    var token: CloudChangeToken?
    /// The token was nil or expired, so `modified` is the whole zone and `deleted` must be diffed (§13.6).
    var fullWalk = false
    /// `zoneNotFound` or `userDeletedZone`: the zone is gone, which ends its import and deletes nothing.
    var isMissing = false
}

/// Reads the old container's change feed from a stored token, and records by name. Reads only; the old
/// engine never starts (§13.4 step 0).
struct MigrationOldChangeFetcher {
    let transport: any CloudTransport
    /// Names fetched in one call (CloudKit's own limit is 400).
    var namesPerRequest = 100
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationImport")

    func fetch(_ zone: MigrationOldZone, since token: CloudChangeToken?) async throws -> MigrationFetchedZone {
        var result = MigrationFetchedZone(zone: zone)
        var cursor = token
        var fullWalk = token == nil
        var records: [String: CloudRecord] = [:]
        var order: [String] = []
        var deleted: Set<String> = []
        while true {
            let page: CloudZoneChanges
            switch try await transport.zoneChanges(zone.zoneID, in: zone.database, since: cursor, desiredKeys: OldContainerWalk.desiredKeys) {
            case .success(let changes):
                page = changes
            case .failure(let error) where error.code == .changeTokenExpired:
                // An expired token is a payload walk from nil, diffed against the base.
                cursor = nil
                fullWalk = true
                records = [:]
                order = []
                deleted = []
                continue
            case .failure(let error) where OldContainerWalk.isMissingZone(error):
                result.isMissing = true
                Self.logger.notice("An old zone is gone: \(zone.name, privacy: .public)")
                return result
            case .failure(let error):
                throw error
            }
            // The feed is in change order: what a page says last about a name stands, so a record deleted on one
            // page and saved again on a later one is a record, and the other way round is a deletion (F32).
            for record in page.modified where record.recordType != CloudRecordID.shareRecordType {
                deleted.remove(record.id.recordName)
                if records.updateValue(record, forKey: record.id.recordName) == nil { order.append(record.id.recordName) }
            }
            for gone in page.deleted where gone.recordType != CloudRecordID.shareRecordType {
                deleted.insert(gone.id.recordName)
                records[gone.id.recordName] = nil
                order.removeAll { $0 == gone.id.recordName }
            }
            // A record the page could not hand over is fetched by name before its token is trusted.
            if !page.failed.isEmpty {
                let ids = page.failed.keys.sorted { $0.recordName < $1.recordName }
                let fetched = try await transport.records(ids, in: zone.database, desiredKeys: OldContainerWalk.desiredKeys)
                for id in ids {
                    guard case .success(let record)? = fetched[id] else { throw OldContainerWalkError.recordUnreadable(id.recordName) }
                    deleted.remove(id.recordName)
                    if records.updateValue(record, forKey: id.recordName) == nil { order.append(id.recordName) }
                }
            }
            cursor = page.changeToken
            if !page.moreComing {
                result.token = page.changeToken
                break
            }
        }
        result.modified = order.compactMap { records[$0] }
        result.deleted = deleted.sorted()
        result.fullWalk = fullWalk
        return result
    }

    /// Records by name: those the zone still holds, and the names it no longer does (a listing that shows
    /// a waiting record deleted, §13.6).
    func fetch(names: [String], in zone: MigrationOldZone) async throws -> (found: [CloudRecord], missing: [String]) {
        var found: [CloudRecord] = []
        var missing: [String] = []
        for start in stride(from: 0, to: names.count, by: namesPerRequest) {
            let ids = names[start..<min(start + namesPerRequest, names.count)].map { CloudRecordID($0, in: zone.zoneID) }
            let fetched = try await transport.records(ids, in: zone.database, desiredKeys: OldContainerWalk.desiredKeys)
            for id in ids {
                switch fetched[id] {
                case .success(let record)?:
                    found.append(record)
                case .failure(let error)? where error.code == .unknownItem || OldContainerWalk.isMissingZone(error):
                    missing.append(id.recordName)
                case .failure(let error)?:
                    throw error
                case nil:
                    missing.append(id.recordName)
                }
            }
        }
        return (found, missing)
    }
}

extension MigrationFetchedZone {
    /// A token as the watermark keeps it: base64.
    var tokenText: String? { token.map { $0.data.base64EncodedString() } }
}

extension CloudChangeToken {
    init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }
}
