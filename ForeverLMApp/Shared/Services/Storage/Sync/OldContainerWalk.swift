import CloudKit
import Foundation
import OSLog

// MARK: - The bounded walk of the old zones (docs/cloudkit-schema-design.md §13.4 step 0)

/// One zone of the old container as the walk found it: every record it holds now, with its payload and
/// `userModificationDate` only (no asset field), and the token to continue from.
struct OldContainerWalkedZone: Sendable {
    let zoneID: CloudZoneID
    let database: CloudDatabaseScope
    var records: [CloudRecord]
    var token: CloudChangeToken

    /// Where its records live, in generation 1's terms.
    var home: CloudKitZoneHome {
        CloudKitZoneHome(
            scope: database == .private ? .privateScope : .shared, zoneName: zoneID.zoneName,
            ownerRecordName: zoneID.ownerName == CloudZoneID.currentUser ? nil : zoneID.ownerName
        )
    }

    var isKnowledge: Bool { zoneID.zoneName == CloudKitZoneHome.knowledgeZoneName }

    /// The key a zone's token is kept under (`ck_engine_state`), and its snapshot rows' `old_zone`.
    var stateKey: String { OldContainerZoneKey.stateKey(database: database, zoneID: zoneID) }
}

/// Names a zone of the old container in the replica's own tables.
enum OldContainerZoneKey {
    /// `ck_legacy_snapshot.old_zone`: `Knowledge`, or `Team-<id>`; a team zone another account owns also
    /// carries its owner, since two accounts' teams may share an id's shape but never a zone.
    static func snapshotZone(database: CloudDatabaseScope, zoneID: CloudZoneID) -> String {
        zoneID.ownerName == CloudZoneID.currentUser ? zoneID.zoneName : "\(zoneID.zoneName)@\(zoneID.ownerName)"
    }

    /// `ck_engine_state.scope` of a zone's change token.
    static func stateKey(database: CloudDatabaseScope, zoneID: CloudZoneID) -> String {
        "migration.token.\(database.rawValue).\(snapshotZone(database: database, zoneID: zoneID))"
    }
}

/// Everything one walk of the old container returned. Nothing is applied until it is complete (§13.3).
struct OldContainerWalkResult: Sendable {
    /// When the walk started: the activation's `catch_up_at`, and the time a migrated value with no time
    /// of its own takes (§13.4 step 4).
    var startedAt: Date
    /// The old container's user record name.
    var account: String?
    /// `Knowledge` is not there (never created, or `zoneNotFound` / `userDeletedZone`): no old world at
    /// all (§13.3 step 3, R4-m4).
    var knowledgeMissing = false
    var zones: [OldContainerWalkedZone] = []
    /// Folder holding the payload assets fetched by name, removed with `discard()`.
    var assetFolder: URL?

    func records(in zone: OldContainerWalkedZone) -> [CloudRecord] { zone.records }

    var recordCount: Int { zones.reduce(0) { $0 + $1.records.count } }

    func discard() {
        if let assetFolder { try? FileManager.default.removeItem(at: assetFolder) }
    }
}

enum OldContainerWalkError: Error, LocalizedError, Equatable {
    /// A record the server could not hand over, even by name: applying a walk without it could delete
    /// it locally, so the walk stops.
    case recordUnreadable(String)
    case assetMissing(String)

    var errorDescription: String? {
        switch self {
        case .recordUnreadable(let name): return "iCloud did not hand over the old record \(name)."
        case .assetMissing(let name): return "The old record \(name) came without its payload."
        }
    }
}

/// The walk (§13.4 step 0): `CKFetchRecordZoneChangesOperation` from a nil token over the old
/// `Knowledge` zone and every `Team-*` zone of both databases, then `payloadAsset` by name for the
/// records that carry their payload there. It reads only; the first-generation engine never starts. Reused by the
/// full catch-up (WP16a), the deferred catch-up and the refresh (WP16b), which apply what it returns.
struct OldContainerWalk {
    let transport: any CloudTransport
    var now: () -> Date = Date.init
    /// Records fetched by name in one call (CloudKit's own limit is 400).
    var namesPerRequest = 100
    var assetsRoot: URL = FileManager.default.temporaryDirectory

    static let desiredKeys = [CKRecord.FieldKey.payload, CKRecord.FieldKey.userModificationDate]
    static let payloadAssetKeys = [CKRecord.FieldKey.payloadAsset]
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")

    /// The zones that hold the learner's library, a zone's records and the token to continue from.
    func fetchZones() async throws -> OldContainerWalkResult {
        var walk = OldContainerWalkResult(startedAt: now())
        let privateZones = try await transport.allZones(in: .private)
        let sharedZones = try await transport.allZones(in: .shared)
        walk.account = try? await transport.userRecordName()
        var targets: [(CloudZoneID, CloudDatabaseScope)] = []
        if privateZones.contains(where: { $0.zoneName == CloudKitZoneHome.knowledgeZoneName }) {
            targets.append((CloudZoneID(CloudKitZoneHome.knowledgeZoneName), .private))
        } else {
            walk.knowledgeMissing = true
        }
        targets += privateZones.filter { TeamRecord.teamID(fromZoneName: $0.zoneName) != nil }.map { ($0, .private) }
        targets += sharedZones.filter { TeamRecord.teamID(fromZoneName: $0.zoneName) != nil }.map { ($0, .shared) }

        for (zoneID, database) in targets {
            do {
                walk.zones.append(try await fetchZone(zoneID, in: database))
            } catch let error as CloudError where Self.isMissingZone(error) {
                // The learner's zone going away between the lookup and the fetch is no old world; a team's
                // means the team is gone, which this walk leaves alone (it deletes nothing for a team).
                if zoneID.zoneName == CloudKitZoneHome.knowledgeZoneName { walk.knowledgeMissing = true }
                Self.logger.notice("An old zone is gone: \(zoneID.zoneName, privacy: .public)")
            }
        }
        return walk
    }

    static func isMissingZone(_ error: CloudError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    private func fetchZone(_ zoneID: CloudZoneID, in database: CloudDatabaseScope) async throws -> OldContainerWalkedZone {
        var records: [CloudRecord] = []
        var token: CloudChangeToken?
        var finalToken: CloudChangeToken?
        repeat {
            let page: CloudZoneChanges
            switch try await transport.zoneChanges(zoneID, in: database, since: token, desiredKeys: Self.desiredKeys) {
            case .success(let changes): page = changes
            case .failure(let error): throw error
            }
            records += page.modified.filter { $0.recordType != CloudRecordID.shareRecordType }
            // A record the page could not hand over is fetched by name before its token is trusted.
            if !page.failed.isEmpty {
                let ids = page.failed.keys.sorted { $0.recordName < $1.recordName }
                let fetched = try await transport.records(ids, in: database, desiredKeys: Self.desiredKeys)
                for id in ids {
                    guard case .success(let record)? = fetched[id] else { throw OldContainerWalkError.recordUnreadable(id.recordName) }
                    records.append(record)
                }
            }
            token = page.changeToken
            finalToken = page.changeToken
            if !page.moreComing { break }
        } while true
        guard let finalToken else { throw CloudError(.internalError, message: "no token for \(zoneID.zoneName)") }
        // A record can appear on two pages when it changed during the walk; the last copy is the newest.
        var latest: [String: CloudRecord] = [:]
        var order: [String] = []
        for record in records {
            if latest.updateValue(record, forKey: record.id.recordName) == nil { order.append(record.id.recordName) }
        }
        return OldContainerWalkedZone(zoneID: zoneID, database: database, records: order.compactMap { latest[$0] }, token: finalToken)
    }

    // MARK: payloadAsset is payload

    /// Fetches `payloadAsset` by name for `names` of each zone and puts it in the walk's record: a
    /// ReviewSession's whole JSON (a chat over 512 KiB, `payload` cleared) or an Artifact's body package.
    /// The asset's bytes are copied into the walk's own folder, since CloudKit's download is temporary.
    func fetchPayloadAssets(_ names: [CloudZoneID: Set<String>], into walk: inout OldContainerWalkResult) async throws {
        guard names.values.contains(where: { !$0.isEmpty }) else { return }
        let folder = assetsRoot.appendingPathComponent("OldContainerWalkResult-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        walk.assetFolder = folder
        for index in walk.zones.indices {
            let zone = walk.zones[index]
            guard let wanted = names[zone.zoneID], !wanted.isEmpty else { continue }
            let ids = wanted.sorted().map { CloudRecordID($0, in: zone.zoneID) }
            var byName: [String: URL] = [:]
            for chunk in stride(from: 0, to: ids.count, by: namesPerRequest).map({ Array(ids[$0 ..< min($0 + namesPerRequest, ids.count)]) }) {
                let fetched = try await transport.records(chunk, in: zone.database, desiredKeys: Self.payloadAssetKeys)
                for id in chunk {
                    guard case .success(let record)? = fetched[id] else { throw OldContainerWalkError.recordUnreadable(id.recordName) }
                    // A record with no asset carries its payload inline: nothing to add.
                    guard case .asset(let url)? = record.fields[CKRecord.FieldKey.payloadAsset] else { continue }
                    let copy = folder.appendingPathComponent(UUID().uuidString + ".asset")
                    try FileManager.default.copyItem(at: url, to: copy)
                    byName[id.recordName] = copy
                }
            }
            for position in walk.zones[index].records.indices {
                let name = walk.zones[index].records[position].id.recordName
                if let url = byName[name] { walk.zones[index].records[position].fields[CKRecord.FieldKey.payloadAsset] = .asset(url) }
            }
        }
    }

    /// A walk record as the CloudKit object today's decoders read, with its asset field attached.
    static func ckRecord(_ record: CloudRecord) -> CKRecord {
        let ck = CKRecord(recordType: record.recordType, recordID: record.id.ck)
        for (key, value) in record.encryptedFields { if let object = CloudKitMapping.encrypted(value) { ck.encryptedValues[key] = object } }
        for (key, value) in record.fields { if let object = CloudKitMapping.plain(value) { ck[key] = object } }
        return ck
    }
}

extension CloudRecord {
    /// Whether the record carries no payload of its own: a ReviewSession whose JSON passed 512 KiB
    /// travels whole in `payloadAsset` with `payload` cleared (§13.4 step 0).
    var hasEmptyPayload: Bool {
        guard case .bytes(let data)? = encryptedFields[CKRecord.FieldKey.payload] else { return true }
        return data.isEmpty
    }

    /// The server's `userModificationDate` of an old record: the encrypted field its writers set, else
    /// the server's own modification date (`CloudKitRecordMapper.descriptor`'s order).
    var oldModifiedAt: Date {
        if case .date(let date)? = encryptedFields[CKRecord.FieldKey.userModificationDate] { return date }
        return modificationDate ?? Date(timeIntervalSince1970: 0)
    }
}
