import CloudKit
import Foundation
import OSLog

/// One person on a space's roster, as members see them (§3.3 `Person`, §9.2).
struct SpaceMember: Equatable, Sendable {
    let person: SyncPerson
    let permission: CloudShare.Permission
    let role: CloudShare.Role
    let acceptance: CloudShare.Acceptance
    let isCurrentUser: Bool

    var isOwner: Bool { role == .owner }
}

/// A space's zone-wide share as the app shows it: its link, title, who may join by the link, and the
/// roster, the owner first.
struct SpaceShare: Equatable, Sendable {
    let url: URL?
    let title: String?
    let publicPermission: CloudShare.Permission
    let members: [SpaceMember]
}

enum ShareServiceError: Error, Equatable, Sendable {
    /// Only the owner shares a space, changes its share or stops sharing it.
    case notOwner
    /// The owner never leaves their own space; they stop sharing it or delete it.
    case ownerCannotLeave
    /// The space has no zone-wide share.
    case notShared
    case failed(CloudError)
}

/// The zone-wide CKShare of a space (docs/cloudkit-schema-design.md §2.2, §2.5, §9.1, §9.2, §9.6,
/// §9.7, D4): the owner shares, invites, removes and stops sharing; a member accepts and leaves; every
/// client reads the roster as `Person` values with permissions. What sharing changes locally is the
/// space's `ck_zones` row (role, permission, share), so SpaceSync walks a space from the moment it is
/// accepted and stops when it is left. A member's write over the owner's iCloud quota is reported in
/// the owner's name (§2.5, `quotaNotice`).
///
/// A space itself (its zone, and a root with a fresh salt saved by compare-and-set create) is made by
/// `SpaceService` with `spaceRoot`; this service shares it. Generation 2 only: generation 1's
/// team and Doc sharing keep the old container's own paths (D40).
struct ShareService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ShareService")

    let transport: CloudSharingTransport
    let store: PrivateSyncLocalStore
    let spaces: SpaceSync
    /// The name the learner goes by in the app, for their own row: CloudKit never names the signed-in
    /// account on its own roster.
    var accountName: String?

    // MARK: - A space's root

    /// The root `SpaceService` saves into a new `Space-<spaceID>` zone with a compare-and-set create
    /// (§2.4 Spaces, §3.5.1): its kind, a fresh salt and its id, the owner, and for a notebook or Doc
    /// space the record it was made for. `mint` stamps each field under its policy from the device's
    /// clock, as the bootstrap stamps the personal root.
    static func spaceRoot(kind: String, name: String, owner: SyncPerson, primaryID: String?, salt: Data,
                          at milliseconds: Int64, mint: (SyncPolicy, SyncStamp?) throws -> SyncStamp) throws -> SyncEnvelope {
        var envelope = SyncEnvelope.new(.zoneRoot, id: SyncSchema.rootRecordName, saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        patch.changes["kind"] = .value(.string(kind))
        patch.changes["salt"] = .value(.string(salt.base64EncodedString()))
        patch.changes["saltID"] = .value(.string(RecordNaming.saltID(salt)))
        patch.changes["name"] = .value(.string(name))
        patch.changes["owner"] = .value(owner.value)
        patch.changes["createdAt"] = .value(SyncJSON(milliseconds))
        patch.changes["editedAt"] = .value(SyncJSON(milliseconds))
        patch.changes["minClientRevision"] = .value(SyncJSON(1))
        if let primaryID { patch.changes["primaryID"] = .value(.string(primaryID)) }
        try envelope.apply(patch) { _, policy, seen in try mint(policy, seen) }
        return envelope
    }

    // MARK: - The owner

    /// Creates the space's zone-wide share, or changes it: its title (what an invitee sees before
    /// accepting), who may join by its link, invitations and permission changes.
    @discardableResult
    func share(_ zone: SpaceZone, title: String? = nil, publicPermission: CloudShare.Permission? = nil,
               invite: [CloudShareLookup: CloudShare.Permission] = [:], permissions: [String: CloudShare.Permission] = [:]) async throws -> SpaceShare {
        guard zone.isOwned else { throw ShareServiceError.notOwner }
        var change = CloudShareChange(title: title, publicPermission: publicPermission)
        change.invite = invite
        change.permissions = permissions
        let record = try await save(change, in: zone)
        try await store.perform { state in
            guard var row = try state.replica.zone(key: zone.zoneKey) else { return }
            row.shareRecordName = CloudRecordID.zoneShareRecordName
            row.role = "owner"
            row.permission = CloudShare.Permission.readWrite.rawValue
            try state.replica.upsertZone(row)
        }
        return try await roster(record.share)
    }

    /// Takes `user` (a user record name) off the share; the space leaves their shared database.
    @discardableResult
    func removeParticipant(_ user: String, from zone: SpaceZone) async throws -> SpaceShare {
        guard zone.isOwned else { throw ShareServiceError.notOwner }
        var change = CloudShareChange()
        change.remove = [user]
        return try await roster(try await save(change, in: zone).share)
    }

    /// Stop sharing (§9.6): the share goes, the zone stays an owned space with no participants.
    func stopSharing(_ zone: SpaceZone) async throws {
        guard zone.isOwned else { throw ShareServiceError.notOwner }
        let shareID = CloudRecordID(CloudRecordID.zoneShareRecordName, in: zone.zoneID)
        let results = try await transport.modifyRecords(deleting: [shareID], in: .private)
        if let error = results.error(for: shareID), error.code != .unknownItem { throw ShareServiceError.failed(error) }
        try await store.perform { state in
            guard var row = try state.replica.zone(key: zone.zoneKey) else { return }
            row.shareRecordName = nil
            try state.replica.upsertZone(row)
        }
    }

    private func save(_ change: CloudShareChange, in zone: SpaceZone) async throws -> CloudRecord {
        do {
            return try await transport.saveShare(change, in: zone.zoneID)
        } catch let error as CloudError {
            throw ShareServiceError.failed(error)
        }
    }

    // MARK: - Members

    /// Accepts an invitation; the space joins this device's spaces at once, with the permission the
    /// share gives, and the next SpaceSync round walks it.
    func accept(_ invitation: CloudShareInvitation) async throws -> SpaceZone {
        let results: [URL: Result<CloudShareAcceptance, CloudError>]
        do {
            results = try await transport.acceptShares([invitation])
        } catch let error as CloudError {
            throw ShareServiceError.failed(error)
        }
        let accepted: CloudShareAcceptance
        switch results[invitation.url] {
        case .success(let acceptance)?: accepted = acceptance
        case .failure(let error)?: throw ShareServiceError.failed(error)
        case nil: throw ShareServiceError.failed(CloudError(.unknownItem, message: "no answer for the invitation"))
        }
        let zone = SpaceZone(accepted.zoneID, in: .shared)
        guard SyncZoneName(zone.zoneID.zoneName)?.isSpace == true else {
            throw ShareServiceError.failed(CloudError(.invalidArguments, message: "the share is not a ForeverLM space"))
        }
        let permission = accepted.share.currentUser?.permission
        try await store.perform { state in
            let replica = state.replica
            try replica.setEngineState(SpaceSync.StateScope.gone(zone.zoneKey), nil)
            var row = try replica.zone(key: zone.zoneKey) ?? ReplicaZone(
                zoneKey: zone.zoneKey, database: .shared, zoneName: zone.zoneID.zoneName, ownerRecordName: zone.zoneID.ownerName,
                kind: SyncZone.space.rawValue.lowercased()
            )
            row.role = "member"
            row.permission = permission?.rawValue
            row.shareRecordName = CloudRecordID.zoneShareRecordName
            try replica.upsertZone(row)
        }
        Self.logger.info("Joined a space")
        return zone
    }

    /// Leave (§9.6): this member deletes the share from their shared database, and the space goes
    /// from this device as a space that went does (its local rows wait for the space packages).
    func leave(_ zone: SpaceZone) async throws {
        guard !zone.isOwned else { throw ShareServiceError.ownerCannotLeave }
        let shareID = CloudRecordID(CloudRecordID.zoneShareRecordName, in: zone.zoneID)
        let results = try await transport.modifyRecords(deleting: [shareID], in: .shared)
        if let error = results.error(for: shareID), ![.unknownItem, .zoneNotFound].contains(error.code) {
            throw ShareServiceError.failed(error)
        }
        try await spaces.spaceGone(zone, reason: "left")
    }

    // MARK: - The roster

    /// The space's share as the server holds it now; a member's own permission is kept in `ck_zones`,
    /// which SpaceSync's write guard reads.
    func roster(of zone: SpaceZone) async throws -> SpaceShare {
        let shareID = CloudRecordID(CloudRecordID.zoneShareRecordName, in: zone.zoneID)
        let fetched: Result<CloudRecord, CloudError>
        do {
            fetched = try await transport.record(shareID, in: zone.database, desiredKeys: nil)
        } catch let error as CloudError {
            throw ShareServiceError.failed(error)
        }
        switch fetched {
        case .success(let record):
            guard let share = record.share else { throw ShareServiceError.notShared }
            let me = zone.isOwned ? nil : share.currentUser
            let root = try await store.perform { state -> SyncEnvelope? in
                if let me, var row = try state.replica.zone(key: zone.zoneKey) {
                    row.permission = me.permission.rawValue
                    try state.replica.upsertZone(row)
                }
                return try state.replica.record(zoneKey: zone.zoneKey, recordName: SyncSchema.rootRecordName)
                    .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            }
            return try await roster(share, ownerName: SpaceSync.ownerName(root, zone: zone))
        case .failure(let error) where error.code == .unknownItem:
            throw ShareServiceError.notShared
        case .failure(let error):
            throw ShareServiceError.failed(error)
        }
    }

    /// The roster as `Person` values: each participant's user record name and the name members see.
    /// The owner's own share names them by a placeholder, which is this account's record name. A
    /// member who sees no name for the owner takes the one the space's root gives (`ownerName`).
    private func roster(_ share: CloudShare?, ownerName: String? = nil) async throws -> SpaceShare {
        guard let share else { throw ShareServiceError.notShared }
        var me: String?
        if share.participants.contains(where: { $0.isCurrentUser || $0.user == CKCurrentUserDefaultName }) {
            do {
                me = try await transport.userRecordName()
            } catch {
                Self.logger.error("Reading this account's record name failed: \(String(describing: error), privacy: .public)")
            }
        }
        let members = share.participants.map { participant -> SpaceMember in
            let user = participant.user == CKCurrentUserDefaultName ? me ?? "" : participant.user ?? ""
            let isCurrentUser = participant.isCurrentUser || (me != nil && user == me)
            return SpaceMember(
                person: SyncPerson(user: user, name: Self.displayName(participant, isCurrentUser: isCurrentUser, accountName: accountName,
                                                                      ownerName: participant.role == .owner ? ownerName : nil)),
                permission: participant.permission, role: participant.role, acceptance: participant.acceptance, isCurrentUser: isCurrentUser
            )
        }.sorted { lhs, rhs in
            if lhs.isOwner != rhs.isOwner { return lhs.isOwner }
            return lhs.person.name ?? "" < rhs.person.name ?? ""
        }
        return SpaceShare(url: share.url, title: share.title, publicPermission: share.publicPermission, members: members)
    }

    /// CloudKit names only participants it resolved from an invitation, never the signed-in account:
    /// the shared name, else the account's own name for this account (the root's owner name for the
    /// owner), else the email, else a word.
    static func displayName(_ participant: CloudShare.Participant, isCurrentUser: Bool, accountName: String?, ownerName: String? = nil) -> String {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if isCurrentUser, let account = accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty { return account }
        if let owner = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty, owner != participant.user { return owner }
        if let email = participant.email, !email.isEmpty { return email }
        return isCurrentUser ? "You" : "Member"
    }

    // MARK: - Quota

    /// What Settings › iCloud says when iCloud storage refused a write (§2.5): in someone else's
    /// space it is the owner's storage, since members' writes count against the owner.
    static func quotaNotice(owner: String?) -> String {
        guard let owner, !owner.isEmpty else {
            return "Your iCloud storage is full, so ForeverLM can't save your changes to iCloud. Free up space in iCloud to keep syncing."
        }
        return "\(owner)'s iCloud storage is full, so changes to their shared space can't be saved until they free up space."
    }
}
