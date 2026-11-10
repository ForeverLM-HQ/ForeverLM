import CloudKit
import Foundation

/// `CloudTransport` over a real `CKContainer` (docs/cloudkit-schema-design.md §2.3, §14.1): the
/// values the schema-v2 sync works on, mapped to and from CloudKit's own async API. ZoneBootstrap,
/// the replica audit, SpaceSync and BlobStore talk to CloudKit through it; the private engine's own
/// sends and fetches go through `CKSyncEngine`, whose records cross into the sync as values through
/// `CloudKitMapping` too.
final class CloudKitTransport: CloudTransport, @unchecked Sendable {
    let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    /// The transport for a container this build is entitled to. `CKContainer(identifier:)` traps on
    /// any other, so the caller passes an identifier from `ForeverLMRuntimeIdentity`, never a guess.
    convenience init(containerIdentifier: String) {
        self.init(container: CKContainer(identifier: containerIdentifier))
    }

    var containerIdentifier: String { container.containerIdentifier ?? "" }

    private func database(_ scope: CloudDatabaseScope) -> CKDatabase {
        scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    func accountStatus() async throws -> CKAccountStatus {
        do { return try await container.accountStatus() } catch { throw CloudKitMapping.error(error) }
    }

    func userRecordName() async throws -> String {
        do { return try await container.userRecordID().recordName } catch { throw CloudKitMapping.error(error) }
    }

    func allZones(in scope: CloudDatabaseScope) async throws -> [CloudZoneID] {
        do {
            return try await database(scope).allRecordZones().map { CloudZoneID($0.zoneID) }
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in scope: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
        do {
            let (saved, deleted) = try await database(scope).modifyRecordZones(
                saving: saving.map { CKRecordZone(zoneID: $0.ck) }, deleting: deleting.map(\.ck)
            )
            return CloudZoneModifyResults(
                saved: Dictionary(saved.map { (CloudZoneID($0.key), $0.value.map { _ in () }.mapError(CloudKitMapping.error)) }, uniquingKeysWith: { first, _ in first }),
                deleted: Dictionary(deleted.map { (CloudZoneID($0.key), $0.value.mapError(CloudKitMapping.error)) }, uniquingKeysWith: { first, _ in first })
            )
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    func databaseChanges(in scope: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
        do {
            let changes = try await database(scope).databaseChanges(since: try CloudKitMapping.serverToken(token), resultsLimit: resultsLimit)
            return CloudDatabaseChanges(
                modifiedZones: changes.modifications.map { CloudZoneID($0.zoneID) },
                deletedZones: changes.deletions.map { CloudZoneDeletion(zoneID: CloudZoneID($0.zoneID), reason: CloudKitMapping.reason($0.reason)) },
                changeToken: try CloudKitMapping.token(changes.changeToken),
                moreComing: changes.moreComing
            )
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    func zoneChanges(_ requests: [CloudZoneChangesRequest], in scope: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
        var results: [CloudZoneID: Result<CloudZoneChanges, CloudError>] = [:]
        for request in requests {
            do {
                let changes = try await database(scope).recordZoneChanges(
                    inZoneWith: request.zoneID.ck, since: try CloudKitMapping.serverToken(request.since),
                    desiredKeys: request.desiredKeys, resultsLimit: request.resultsLimit
                )
                // A record can fail on its own while the page's token moves past it: it is kept in
                // `failed`, so the caller fetches it by name before it stores the token.
                var modified: [CloudRecord] = []
                var failed: [CloudRecordID: CloudError] = [:]
                for (id, result) in changes.modificationResultsByID {
                    switch result {
                    case .success(let modification): modified.append(CloudKitMapping.record(modification.record))
                    case .failure(let error): failed[CloudRecordID(id)] = CloudKitMapping.error(error)
                    }
                }
                results[request.zoneID] = .success(CloudZoneChanges(
                    modified: modified,
                    deleted: changes.deletions.map { CloudRecordDeletion(id: CloudRecordID($0.recordID), recordType: $0.recordType) },
                    failed: failed,
                    changeToken: try CloudKitMapping.token(changes.changeToken),
                    moreComing: changes.moreComing
                ))
            } catch let error as CKError where Self.failsTheCall(error) {
                throw CloudKitMapping.error(error)
            } catch {
                results[request.zoneID] = .failure(CloudKitMapping.error(error))
            }
        }
        return results
    }

    func records(_ ids: [CloudRecordID], in scope: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
        do {
            let fetched = try await database(scope).records(for: ids.map(\.ck), desiredKeys: desiredKeys)
            return Dictionary(fetched.map { (CloudRecordID($0.key), $0.value.map(CloudKitMapping.record).mapError(CloudKitMapping.error)) },
                              uniquingKeysWith: { first, _ in first })
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in scope: CloudDatabaseScope,
                       savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
        do {
            let records = try saving.map(CloudKitMapping.ckRecord)
            let (saved, deleted) = try await database(scope).modifyRecords(
                saving: records, deleting: deleting.map(\.ck), savePolicy: CloudKitMapping.policy(savePolicy), atomically: atomically
            )
            return CloudModifyResults(
                saved: Dictionary(saved.map { (CloudRecordID($0.key), $0.value.map(CloudKitMapping.record).mapError(CloudKitMapping.error)) },
                                  uniquingKeysWith: { first, _ in first }),
                deleted: Dictionary(deleted.map { (CloudRecordID($0.key), $0.value.mapError(CloudKitMapping.error)) },
                                    uniquingKeysWith: { first, _ in first })
            )
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    /// A per-zone fetch error that is the account's or the network's, not the zone's: it fails the
    /// whole call, as `CloudTransport` says, so the pacer sees one throttle instead of one per zone.
    private static func failsTheCall(_ error: CKError) -> Bool {
        switch error.code {
        case .requestRateLimited, .serviceUnavailable, .networkUnavailable, .networkFailure, .notAuthenticated,
             .operationCancelled, .quotaExceeded, .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Sharing and subscriptions

extension CloudKitTransport: CloudSharingTransport {
    func saveShare(_ change: CloudShareChange, in zoneID: CloudZoneID) async throws -> CloudRecord {
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID.ck)
        do {
            var share = CKShare(recordZoneID: zoneID.ck)
            do {
                if let held = try await database.record(for: shareID) as? CKShare { share = held }
            } catch let error as CKError where error.code == .unknownItem {
                // No share yet: the new one is created by the save below.
            }
            if let title = change.title { share[CKShare.SystemFieldKey.title] = title as CKRecordValue }
            if let permission = change.publicPermission { share.publicPermission = CloudKitMapping.permission(permission) }
            for participant in share.participants where participant.role != .owner {
                guard let user = participant.userIdentity.userRecordID?.recordName else { continue }
                if change.remove.contains(user) {
                    share.removeParticipant(participant)
                } else if let permission = change.permissions[user] {
                    participant.permission = CloudKitMapping.permission(permission)
                }
            }
            if !change.invite.isEmpty {
                for (lookup, participant) in try await shareParticipants(Array(change.invite.keys)) {
                    participant.permission = CloudKitMapping.permission(change.invite[lookup] ?? .readOnly)
                    share.addParticipant(participant)
                }
            }
            let (saved, _) = try await database.modifyRecords(saving: [share], deleting: [])
            guard let result = saved[share.recordID] else { throw CloudError(.internalError, message: "no result for the share") }
            return CloudKitMapping.record(try result.get())
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    func acceptShares(_ invitations: [CloudShareInvitation]) async throws -> [URL: Result<CloudShareAcceptance, CloudError>] {
        var metadata: [URL: Result<CKShare.Metadata, CloudError>] = [:]
        var unknown: [URL] = []
        for invitation in invitations {
            if let held = invitation.systemMetadata as? CKShare.Metadata {
                metadata[invitation.url] = .success(held)
            } else {
                unknown.append(invitation.url)
            }
        }
        if !unknown.isEmpty {
            metadata.merge(try await shareMetadata(unknown)) { held, _ in held }
        }
        var results: [URL: Result<CloudShareAcceptance, CloudError>] = [:]
        for invitation in invitations {
            switch metadata[invitation.url] ?? .failure(CloudError(.unknownItem, message: "no share at the link")) {
            case .failure(let error):
                results[invitation.url] = .failure(error)
            case .success(let held):
                do {
                    let share = try await container.accept(held)
                    results[invitation.url] = .success(CloudShareAcceptance(zoneID: CloudZoneID(share.recordID.zoneID), share: CloudKitMapping.share(share)))
                } catch let error as CKError where Self.failsTheCall(error) {
                    throw CloudKitMapping.error(error)
                } catch {
                    results[invitation.url] = .failure(CloudKitMapping.error(error))
                }
            }
        }
        return results
    }

    func saveDatabaseSubscription(_ subscriptionID: String, in scope: CloudDatabaseScope) async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification
        do {
            let (saved, _) = try await database(scope).modifySubscriptions(saving: [subscription], deleting: [])
            if case .failure(let error)? = saved[subscriptionID] { throw error }
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    /// iCloud's participant for each lookup (`CKFetchShareParticipantsOperation`); a lookup it cannot
    /// resolve fails the save, so nobody is invited by half.
    private func shareParticipants(_ lookups: [CloudShareLookup]) async throws -> [CloudShareLookup: CKShare.Participant] {
        let infos = lookups.map { lookup -> CKUserIdentity.LookupInfo in
            switch lookup {
            case .userRecordName(let name): return CKUserIdentity.LookupInfo(userRecordID: CKRecord.ID(recordName: name))
            case .email(let email): return CKUserIdentity.LookupInfo(emailAddress: email)
            case .phoneNumber(let number): return CKUserIdentity.LookupInfo(phoneNumber: number)
            }
        }
        let found: [CKUserIdentity.LookupInfo: CKShare.Participant] = try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var participants: [CKUserIdentity.LookupInfo: CKShare.Participant] = [:]
            var failure: Error?
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: infos)
            operation.perShareParticipantResultBlock = { info, result in
                lock.withLock {
                    switch result {
                    case .success(let participant): participants[info] = participant
                    case .failure(let error): failure = failure ?? error
                    }
                }
            }
            operation.fetchShareParticipantsResultBlock = { result in
                lock.withLock {
                    if case .failure(let error) = result { failure = failure ?? error }
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: participants) }
                }
            }
            container.add(operation)
        }
        var byLookup: [CloudShareLookup: CKShare.Participant] = [:]
        for (lookup, info) in zip(lookups, infos) {
            guard let participant = found[info] else { throw CloudError(.unknownItem, message: "iCloud found no one for an invitation") }
            byLookup[lookup] = participant
        }
        return byLookup
    }

    /// Each link's share metadata (`CKFetchShareMetadataOperation`).
    private func shareMetadata(_ urls: [URL]) async throws -> [URL: Result<CKShare.Metadata, CloudError>] {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var results: [URL: Result<CKShare.Metadata, CloudError>] = [:]
            let operation = CKFetchShareMetadataOperation(shareURLs: urls)
            operation.perShareMetadataResultBlock = { url, result in
                lock.withLock { results[url] = result.mapError(CloudKitMapping.error) }
            }
            operation.fetchShareMetadataResultBlock = { result in
                lock.withLock {
                    switch result {
                    case .success: continuation.resume(returning: results)
                    case .failure(let error) where results.isEmpty: continuation.resume(throwing: CloudKitMapping.error(error))
                    case .failure: continuation.resume(returning: results)
                    }
                }
            }
            container.add(operation)
        }
    }
}

// MARK: - Values to and from CloudKit

extension CloudZoneID {
    init(_ id: CKRecordZone.ID) { self.init(id.zoneName, ownerName: id.ownerName) }
    var ck: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
}

extension CloudRecordID {
    init(_ id: CKRecord.ID) { self.init(id.recordName, in: CloudZoneID(id.zoneID)) }
    var ck: CKRecord.ID { CKRecord.ID(recordName: recordName, zoneID: zoneID.ck) }
}

/// The mapping between CloudKit's objects and the transport's values, shared by `CloudKitTransport`
/// and the private engine's `CKSyncEngine` adapter.
enum CloudKitMapping {
    /// A record's system fields, archived (`ck_records.system_fields`): a later save starts from them,
    /// so `.ifServerRecordUnchanged` compares their change tag.
    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// A `CKRecord` to save: its system fields when it has them (an update), else a new record (a
    /// create), with every field the value carries.
    static func ckRecord(_ record: CloudRecord) throws -> CKRecord {
        let ck: CKRecord
        if let data = record.systemFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
            decoder.requiresSecureCoding = true
            defer { decoder.finishDecoding() }
            guard let decoded = CKRecord(coder: decoder), decoded.recordID == record.id.ck else {
                throw CloudError(.invalidArguments, message: "system fields that do not name \(record.id)")
            }
            ck = decoded
        } else {
            ck = CKRecord(recordType: record.recordType, recordID: record.id.ck)
        }
        for (key, value) in record.encryptedFields {
            ck.encryptedValues[key] = encrypted(value)
        }
        for (key, value) in record.fields {
            ck[key] = plain(value)
        }
        return ck
    }

    /// A fetched or saved record as a value: every encrypted key (`encryptedValues.allKeys()`) and
    /// every plain one, never a fixed list, so the old container's records keep fields such as
    /// `userModificationDate`.
    static func record(_ ck: CKRecord) -> CloudRecord {
        var record = CloudRecord(id: CloudRecordID(ck.recordID), recordType: ck.recordType, systemFields: systemFields(of: ck))
        record.changeTag = ck.recordChangeTag
        record.creationDate = ck.creationDate
        record.modificationDate = ck.modificationDate
        let encryptedKeys = ck.encryptedValues.allKeys()
        for key in encryptedKeys {
            if let object = ck.encryptedValues[key], let value = value(object) { record.encryptedFields[key] = value }
        }
        for key in ck.allKeys() where !encryptedKeys.contains(key) {
            if let object = ck[key], let value = value(object) { record.fields[key] = value }
        }
        if let share = ck as? CKShare { record.share = Self.share(share) }
        return record
    }

    /// The database a CloudKit push came from: a database subscription's (`flm-shared-db`,
    /// CKSyncEngine's own) or a zone subscription's; nil for the public database or another kind.
    static func database(of notification: CKNotification) -> CloudDatabaseScope? {
        let scope = (notification as? CKDatabaseNotification)?.databaseScope ?? (notification as? CKRecordZoneNotification)?.databaseScope
        switch scope {
        case .private?: return .private
        case .shared?: return .shared
        default: return nil
        }
    }

    /// A share's link, title, public permission and roster.
    static func share(_ share: CKShare) -> CloudShare {
        let formatter = PersonNameComponentsFormatter()
        return CloudShare(
            url: share.url,
            title: share[CKShare.SystemFieldKey.title] as? String,
            publicPermission: permission(share.publicPermission),
            participants: share.participants.map { participant in
                let identity = participant.userIdentity
                let name = identity.nameComponents.map { formatter.string(from: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
                return CloudShare.Participant(
                    user: identity.userRecordID?.recordName,
                    name: name?.isEmpty == false ? name : nil,
                    email: identity.lookupInfo?.emailAddress,
                    permission: permission(participant.permission),
                    role: role(participant.role),
                    acceptance: acceptance(participant.acceptanceStatus),
                    isCurrentUser: participant == share.currentUserParticipant
                )
            }
        )
    }

    static func permission(_ permission: CKShare.ParticipantPermission) -> CloudShare.Permission {
        switch permission {
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        case .none, .unknown: return .none
        @unknown default: return .none
        }
    }

    static func permission(_ permission: CloudShare.Permission) -> CKShare.ParticipantPermission {
        switch permission {
        case .none: return .none
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        }
    }

    static func role(_ role: CKShare.ParticipantRole) -> CloudShare.Role {
        switch role {
        case .owner: return .owner
        case .privateUser: return .privateUser
        case .publicUser: return .publicUser
        default: return .unknown
        }
    }

    static func acceptance(_ status: CKShare.ParticipantAcceptanceStatus) -> CloudShare.Acceptance {
        switch status {
        case .pending: return .pending
        case .accepted: return .accepted
        case .removed: return .removed
        default: return .unknown
        }
    }

    static func encrypted(_ value: CloudFieldValue) -> (any __CKRecordObjCValue)? {
        switch value {
        case .bytes(let data): return data as NSData
        case .string(let string): return string as NSString
        case .int64(let int): return NSNumber(value: int)
        case .double(let double): return NSNumber(value: double)
        case .date(let date): return date as NSDate
        case .stringList(let list): return list as NSArray
        case .asset: return nil
        }
    }

    static func plain(_ value: CloudFieldValue) -> (any __CKRecordObjCValue)? {
        if case .asset(let url) = value { return CKAsset(fileURL: url) }
        return encrypted(value)
    }

    static func value(_ object: Any) -> CloudFieldValue? {
        switch object {
        case let asset as CKAsset: return asset.fileURL.map(CloudFieldValue.asset)
        case let data as Data: return .bytes(data)
        case let string as String: return .string(string)
        case let date as Date: return .date(date)
        case let list as [String]: return .stringList(list)
        case let number as NSNumber:
            return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int64(number.int64Value)
        default: return nil
        }
    }

    static func token(_ token: CKServerChangeToken) throws -> CloudChangeToken {
        CloudChangeToken(data: try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true))
    }

    static func serverToken(_ token: CloudChangeToken?) throws -> CKServerChangeToken? {
        guard let token else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token.data)
    }

    static func error(_ error: Error) -> CloudError {
        if let cloud = error as? CloudError { return cloud }
        guard let ck = error as? CKError else { return CloudError(.internalError, message: "\(error)") }
        return CloudError(ck.code, retryAfter: ck.retryAfterSeconds, serverRecord: ck.serverRecord.map(record),
                          message: ck.localizedDescription)
    }

    static func reason(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) -> CloudZoneDeletionReason {
        switch reason {
        case .deleted: return .deleted
        case .purged: return .purged
        case .encryptedDataReset: return .encryptedDataReset
        @unknown default: return .deleted
        }
    }

    static func policy(_ policy: CloudSavePolicy) -> CKModifyRecordsOperation.RecordSavePolicy {
        switch policy {
        case .ifServerRecordUnchanged: return .ifServerRecordUnchanged
        case .changedKeys: return .changedKeys
        case .allKeys: return .allKeys
        }
    }
}
