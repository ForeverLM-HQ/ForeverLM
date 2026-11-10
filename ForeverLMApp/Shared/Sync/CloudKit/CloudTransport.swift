import CloudKit
import Foundation

/// The CloudKit operations the schema-v2 sync runs (docs/cloudkit-schema-design.md §2.3, §2.4,
/// §14.1), one transport per container: in the app only the library container
/// (`ForeverLMRuntimeIdentity.libraryContainerIdentifier`). The old container's lookup, catch-up and
/// late import (§2.4, §13.3, §13.6) take a transport too, which only their suites pass now: no build
/// is entitled to the old container, which stayed with the old Apple team. `ZoneBootstrap`, SpaceSync, BlobStore and the
/// replica audit run through it in the app. The private engine's own sends and fetches go through
/// `CKSyncEngine` there and through this protocol in tests, where `FakeCloudKit` implements it in
/// memory: one engine per database is all CloudKit allows (§2.3), and an engine cannot be pointed
/// at anything but a real database.
///
/// Everything crossing it is a value (records, ids, tokens, errors), so the fake needs no CloudKit
/// object and the replica stores what arrives as it arrives. The CloudKit implementation maps:
/// - `CloudRecord.systemFields` to and from `CKRecord.encodeSystemFields(with:)`, archived; a save
///   starts from `CKRecord(coder:)` over them, so `.ifServerRecordUnchanged` compares their tag;
/// - `CloudChangeToken.data` to and from an archived `CKServerChangeToken`;
/// - `CloudError` from `CKError`: its code, `retryAfterSeconds` and `serverRecord`;
/// - `CloudZoneDeletionReason` from `CKDatabase.DatabaseChange.Deletion.Reason`.
///
/// A call throws a `CloudError` for the operation as a whole (no account, a throttle, the network,
/// a request over CloudKit's limits, an expired database token, cancellation); what happened to each
/// record or zone it names is in its result instead.
protocol CloudTransport: AnyObject, Sendable {
    /// The container every call goes to.
    var containerIdentifier: String { get }

    /// The iCloud account's status for this container (`CKContainer.accountStatus()`).
    func accountStatus() async throws -> CKAccountStatus

    /// The signed-in user's record name (`CKContainer.userRecordID()`). It is container-scoped (§2.1)
    /// and names that user as the owner of the zones they share.
    func userRecordName() async throws -> String

    /// Every zone of `database` (`CKDatabase.allRecordZones()`): the account's own in the private
    /// database, the ones shared with it in the shared database.
    func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID]

    /// Creates and deletes zones (`CKModifyRecordZonesOperation`). Saving a zone that exists changes
    /// nothing; only the owner can do either, in the private database. Only `ZoneBootstrap` and
    /// `SpaceService` create a zone (§2.4 step 5).
    func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults

    /// Which zones changed or went since `token` (`CKFetchDatabaseChangesOperation`), with the reason
    /// for each deletion (§2.5). From a nil token: every zone, and no deletion. An expired token
    /// throws `changeTokenExpired`.
    func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges

    /// Each requested zone's changes since its token (`CKFetchRecordZoneChangesOperation`), one page
    /// per zone: records with only the desired keys, deletions with their record types, the records
    /// the server could not hand over (`CloudZoneChanges.failed`), the token to continue from and
    /// whether more is waiting. A zone that is gone, or whose token expired, fails alone with
    /// `zoneNotFound`, `userDeletedZone` or `changeTokenExpired`.
    func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>]

    /// Records by name (`CKFetchRecordsOperation`), with only `desiredKeys` (nil: every field; `[]`:
    /// the system fields, an existence check, §3.5.30 rule 4). A missing record is `unknownItem`.
    func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>]

    /// Saves and deletes records (`CKModifyRecordsOperation`). Under `.ifServerRecordUnchanged` a
    /// save without system fields is a create, and one with them an update of exactly that version;
    /// either fails with `serverRecordChanged`, carrying the server's record, when the server holds
    /// something else, and an update of a record deleted meanwhile fails with `unknownItem` (§6.2).
    /// Sends are never atomic in this design (§2.2); `atomically` exists so a test can show why.
    func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                       savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults
}

extension CloudTransport {
    /// One zone's changes since `token`.
    func zoneChanges(_ zoneID: CloudZoneID, in database: CloudDatabaseScope, since token: CloudChangeToken? = nil,
                     desiredKeys: [String]? = nil, resultsLimit: Int? = nil) async throws -> Result<CloudZoneChanges, CloudError> {
        let request = CloudZoneChangesRequest(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        let results = try await zoneChanges([request], in: database)
        return results[zoneID] ?? .failure(CloudError(.internalError, message: "no result for zone \(zoneID.zoneName)"))
    }

    /// One record by name.
    func record(_ id: CloudRecordID, in database: CloudDatabaseScope, desiredKeys: [String]? = nil) async throws -> Result<CloudRecord, CloudError> {
        let results = try await records([id], in: database, desiredKeys: desiredKeys)
        return results[id] ?? .failure(CloudError(.internalError, message: "no result for record \(id.recordName)"))
    }

    /// Saves and deletes as this design always does: compare-and-set, never atomic.
    func modifyRecords(saving: [CloudRecord] = [], deleting: [CloudRecordID] = [],
                       in database: CloudDatabaseScope) async throws -> CloudModifyResults {
        try await modifyRecords(saving: saving, deleting: deleting, in: database, savePolicy: .ifServerRecordUnchanged, atomically: false)
    }
}

/// A CloudKit database of a container. The public database is never used.
enum CloudDatabaseScope: String, Hashable, Sendable, CaseIterable {
    case `private`
    case shared
}

/// A zone (`CKRecordZone.ID`). A zone the signed-in user owns is named with
/// `CKCurrentUserDefaultName` in their private database; a zone shared with them carries its owner's
/// user record name, in their shared database.
struct CloudZoneID: Hashable, Sendable, CustomStringConvertible {
    static let currentUser = CKCurrentUserDefaultName

    var zoneName: String
    var ownerName: String

    init(_ zoneName: String, ownerName: String = CloudZoneID.currentUser) {
        self.zoneName = zoneName
        self.ownerName = ownerName
    }

    var description: String { ownerName == Self.currentUser ? zoneName : "\(zoneName)@\(ownerName)" }
}

/// A record's name in its zone (`CKRecord.ID`).
struct CloudRecordID: Hashable, Sendable, CustomStringConvertible {
    /// The record a zone-wide share is (`CKRecordNameZoneWideShare`), of type `cloudkit.share`.
    static let zoneShareRecordName = CKRecordNameZoneWideShare
    static let shareRecordType = CKRecord.SystemType.share

    var recordName: String
    var zoneID: CloudZoneID

    init(_ recordName: String, in zoneID: CloudZoneID) {
        self.recordName = recordName
        self.zoneID = zoneID
    }

    var description: String { "\(zoneID)/\(recordName)" }
}

/// A field's value. Schema-v2 records hold only `payload` (bytes) and, on `Content`, `data` (bytes)
/// and `asset` (§3.1); the other cases are the old container's.
enum CloudFieldValue: Hashable, Sendable {
    case bytes(Data)
    case string(String)
    case int64(Int64)
    case double(Double)
    case date(Date)
    case stringList([String])
    /// A file: the bytes a save uploads, or where a fetch put the downloaded bytes.
    case asset(URL)
}

/// One record as the server holds it, or as a client sends it.
struct CloudRecord: Hashable, Sendable {
    /// The one app field of every schema-v2 type: the encrypted envelope (§3.1, §3.2).
    static let payloadKey = "payload"
    /// `Content`'s inline body (encrypted) and one asset part (§3.5.30).
    static let dataKey = "data"
    static let assetKey = "asset"

    var id: CloudRecordID
    var recordType: String
    /// Fields in `encryptedValues`: `payload` and `data`, and the old container's encrypted fields.
    var encryptedFields: [String: CloudFieldValue]
    /// Plain fields: `asset` (an asset is encrypted at rest and never lives in `encryptedValues`),
    /// and the old container's asset fields. A schema-v2 record has no other plain field.
    var fields: [String: CloudFieldValue]
    /// The server's system fields, archived and opaque to everything but the transport that made
    /// them (the replica's `system_fields`). A save sends them back; nil on a create.
    var systemFields: Data?
    /// The server's change tag and dates as of this copy. Read only: a save ignores them.
    var changeTag: String?
    var creationDate: Date?
    var modificationDate: Date?
    /// A `cloudkit.share` record's roster, link and permissions, read only. Nothing sends a share
    /// back through `modifyRecords`: a share changes only through `CloudSharingTransport.saveShare`.
    var share: CloudShare?

    init(id: CloudRecordID, recordType: String, encryptedFields: [String: CloudFieldValue] = [:],
         fields: [String: CloudFieldValue] = [:], systemFields: Data? = nil) {
        self.id = id
        self.recordType = recordType
        self.encryptedFields = encryptedFields
        self.fields = fields
        self.systemFields = systemFields
    }

    /// `payload`'s bytes; nil when the record does not carry it (a fetch without the key).
    var payload: Data? {
        get {
            guard case .bytes(let data)? = encryptedFields[Self.payloadKey] else { return nil }
            return data
        }
        set { encryptedFields[Self.payloadKey] = newValue.map(CloudFieldValue.bytes) }
    }
}

/// An archived server change token for a database or a zone. Opaque, and stored as it is
/// (`ck_zones.change_token`).
struct CloudChangeToken: Hashable, Sendable {
    var data: Data
}

/// Why a zone left a database (§2.5).
enum CloudZoneDeletionReason: String, Hashable, Sendable {
    /// The app deleted it, on another device or here; for a joined space, the owner deleted it or
    /// this account lost access to it.
    case deleted
    /// The learner removed ForeverLM's data in iCloud settings. Until the zone is created again,
    /// every operation on it answers `userDeletedZone`.
    case purged
    /// The learner reset their encrypted data, so the zone and its encrypted fields are gone.
    case encryptedDataReset
}

struct CloudZoneDeletion: Hashable, Sendable {
    var zoneID: CloudZoneID
    var reason: CloudZoneDeletionReason
}

struct CloudDatabaseChanges: Hashable, Sendable {
    var modifiedZones: [CloudZoneID]
    var deletedZones: [CloudZoneDeletion]
    var changeToken: CloudChangeToken
    var moreComing: Bool
}

struct CloudZoneChangesRequest: Hashable, Sendable {
    var zoneID: CloudZoneID
    var since: CloudChangeToken?
    /// Nil fetches every field; `[]` only the system fields (the names-only audit walk, §2.3);
    /// `["payload"]` the light walk (§2.3).
    var desiredKeys: [String]?
    var resultsLimit: Int?
}

/// A record deleted since the token, with its type (`recordWithIDWasDeletedBlock`).
struct CloudRecordDeletion: Hashable, Sendable {
    var id: CloudRecordID
    var recordType: String
}

struct CloudZoneChanges: Hashable, Sendable {
    /// In the order the server delivered them, which need not be the order they were written (§5.7).
    var modified: [CloudRecord]
    /// From a nil token, always empty: a pass from nil never returns the deletions it missed, which
    /// is why the replica audit exists (§2.3, D30).
    var deleted: [CloudRecordDeletion]
    /// Records of this page the server could not hand over, each on its own
    /// (`modificationResultsByID`'s failures: an asset that would not download, a field that would
    /// not decrypt). The page's token moves past them all the same, so a caller fetches each by
    /// name (`records`), or keeps the previous token, before it stores this one; storing it
    /// without either loses those records until the replica audit finds them.
    var failed: [CloudRecordID: CloudError] = [:]
    var changeToken: CloudChangeToken
    var moreComing: Bool
}

enum CloudSavePolicy: Hashable, Sendable {
    /// Compare-and-set on the change tag (`.ifServerRecordUnchanged`), the policy of every send here.
    case ifServerRecordUnchanged
    /// Writes the fields the record carries over what the server holds, unchecked (`.changedKeys`).
    case changedKeys
    /// Replaces the whole record, unchecked (`.allKeys`).
    case allKeys
}

struct CloudModifyResults: Sendable {
    var saved: [CloudRecordID: Result<CloudRecord, CloudError>]
    var deleted: [CloudRecordID: Result<Void, CloudError>]

    /// The server's copy of a record this call saved, nil when that save failed.
    func savedRecord(_ id: CloudRecordID) -> CloudRecord? {
        guard case .success(let record)? = saved[id] else { return nil }
        return record
    }

    /// Why the save or delete of `id` failed, nil when it succeeded.
    func error(for id: CloudRecordID) -> CloudError? {
        if case .failure(let error)? = saved[id] { return error }
        if case .failure(let error)? = deleted[id] { return error }
        return nil
    }
}

struct CloudZoneModifyResults: Sendable {
    var saved: [CloudZoneID: Result<Void, CloudError>]
    var deleted: [CloudZoneID: Result<Void, CloudError>]
}

// MARK: - Sharing and subscriptions

/// What sharing a space takes beyond records (docs/cloudkit-schema-design.md §2.3, §9.2, §9.6): the
/// zone-wide CKShare of an owned space, accepting an invitation, and the shared database's
/// subscription. A participant leaves by deleting `cloudkit.zoneshare` from their shared database and
/// the owner stops sharing by deleting it from theirs, both through `modifyRecords`; a share is read
/// by name like any record, with its roster in `CloudRecord.share`.
protocol CloudSharingTransport: CloudTransport {
    /// Creates the zone-wide share of an owned zone in the private database, or changes the one it has
    /// (`CKShare(recordZoneID:)`, then a compare-and-set save). Returns the share as the server holds it.
    func saveShare(_ change: CloudShareChange, in zoneID: CloudZoneID) async throws -> CloudRecord

    /// Accepts invitations (`CKContainer.accept`): the space then appears in the shared database.
    func acceptShares(_ invitations: [CloudShareInvitation]) async throws -> [URL: Result<CloudShareAcceptance, CloudError>]

    /// Saves a database subscription that wakes the app silently (`CKDatabaseSubscription`,
    /// `shouldSendContentAvailable`); saving one that exists changes nothing.
    func saveDatabaseSubscription(_ subscriptionID: String, in database: CloudDatabaseScope) async throws
}

/// A zone-wide share as the transport reads it (`CKShare`).
struct CloudShare: Hashable, Sendable {
    enum Permission: String, Hashable, Sendable {
        case none
        case readOnly
        case readWrite
    }

    enum Role: String, Hashable, Sendable {
        case owner
        case privateUser
        case publicUser
        case unknown
    }

    enum Acceptance: String, Hashable, Sendable {
        case pending
        case accepted
        case removed
        case unknown
    }

    struct Participant: Hashable, Sendable {
        /// The CloudKit user record name, container-scoped (§2.1); nil until iCloud resolved them.
        var user: String?
        var name: String?
        var email: String?
        var permission: Permission
        var role: Role
        var acceptance: Acceptance
        var isCurrentUser: Bool
    }

    var url: URL?
    var title: String?
    var publicPermission: Permission
    /// Everyone on the share, the owner included.
    var participants: [Participant]

    var owner: Participant? { participants.first { $0.role == .owner } }
    var currentUser: Participant? { participants.first(where: \.isCurrentUser) }
}

/// Who an owner invites: iCloud resolves the lookup to a participant.
enum CloudShareLookup: Hashable, Sendable {
    case userRecordName(String)
    case email(String)
    case phoneNumber(String)
}

/// One save of a zone-wide share: what it changes. A field left nil keeps what the share holds.
struct CloudShareChange: Hashable, Sendable {
    var title: String?
    var publicPermission: CloudShare.Permission?
    var invite: [CloudShareLookup: CloudShare.Permission] = [:]
    /// Participants by user record name, their permission changed.
    var permissions: [String: CloudShare.Permission] = [:]
    /// Participants by user record name, removed from the share.
    var remove: Set<String> = []

    init(title: String? = nil, publicPermission: CloudShare.Permission? = nil) {
        self.title = title
        self.publicPermission = publicPermission
    }
}

/// An invitation to accept: the share's link, and on a device the system's own metadata for it when
/// the system handed it over (`userDidAcceptCloudKitShareWith`), which saves a lookup.
struct CloudShareInvitation: Hashable, @unchecked Sendable {
    var url: URL
    /// A `CKShare.Metadata`; opaque to everything but `CloudKitTransport`.
    var systemMetadata: AnyObject?

    init(url: URL, systemMetadata: AnyObject? = nil) {
        self.url = url
        self.systemMetadata = systemMetadata
    }

    static func == (lhs: CloudShareInvitation, rhs: CloudShareInvitation) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// An accepted share: the zone as this account's shared database names it, and the share.
struct CloudShareAcceptance: Hashable, Sendable {
    var zoneID: CloudZoneID
    var share: CloudShare
}

/// A CloudKit failure, for an operation or for one item of it.
struct CloudError: Error, Hashable, Sendable, CustomStringConvertible {
    var code: CKError.Code
    /// `CKErrorRetryAfterKey`: seconds the server asks the client to wait (`requestRateLimited`,
    /// `zoneBusy`, `serviceUnavailable`). `SyncPacer` obeys it for every stream (D43).
    var retryAfter: TimeInterval?
    /// `CKRecordChangedErrorServerRecordKey`: on `serverRecordChanged`, the record as the server
    /// holds it, every field included; the merge's S (§6.2).
    var serverRecord: CloudRecord?
    var message: String

    init(_ code: CKError.Code, retryAfter: TimeInterval? = nil, serverRecord: CloudRecord? = nil, message: String = "") {
        self.code = code
        self.retryAfter = retryAfter
        self.serverRecord = serverRecord
        self.message = message
    }

    var description: String {
        var text = "CloudKit error \(code.rawValue)"
        if !message.isEmpty { text += ": \(message)" }
        if let retryAfter { text += " (retry after \(retryAfter) s)" }
        return text
    }
}
