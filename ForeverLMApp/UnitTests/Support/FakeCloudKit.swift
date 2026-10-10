import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// An in-memory CloudKit for the schema-v2 sync's tests (docs/cloudkit-schema-design.md §14.2,
/// WP4b): one server holding every account's private database in each container, the zones those
/// accounts share with each other, change feeds with their tokens, and the failures the sync has to
/// survive. A test makes one server and asks it for a `Transport` per device. Two transports of one
/// account share its private database, as two Macs do; a transport of another account sees what was
/// shared with it in its shared database.
///
/// What it does as CloudKit does (`FakeCloudKitTests` pins each):
/// - Saves compare and set on change tags under `.ifServerRecordUnchanged`: a create that meets a
///   record, or an update of an older version, fails with `serverRecordChanged` carrying the
///   server's record; an update of a record deleted meanwhile, and the delete of a missing one, fail
///   with `unknownItem`.
/// - A missing zone is `zoneNotFound`; one the learner removed in iCloud settings is
///   `userDeletedZone` until it is created again; database changes give each zone deletion's reason.
/// - A zone's changes come in pages by change order, each with a token to go on from; a fetch from a
///   nil token returns the live records and no deletion; an expired token is `changeTokenExpired`;
///   records carry only their desired keys, in the order `deliveryOrder` gives within a page.
/// - An account's shared database shows the zones shared with it, under their owner's name; a
///   read-only participant's write is `permissionFailure`; a participant's write counts against the
///   owner's quota; deleting the zone-wide share leaves the zone.
/// - An owner saves a zone-wide share with a link, a title, a public permission and invitations
///   (`CloudSharingTransport`); an invitee, or anyone once the link is public, accepts it by its link;
///   a share read back carries its roster (`CloudRecord.share`). Database subscriptions are kept per
///   account and database.
/// - The server's clock dates every record it saves, and moves one tick per write.
/// - A throttle answers with `retryAfter` until its window has passed; injected failures stand in
///   for any other error; a save past the owner's quota is `quotaExceeded`; a request or record over
///   CloudKit's limits is `limitExceeded`.
/// - Every call is logged, so a test can show that a path made none (§13.3, a `fresh` activation).
///
/// Development's just-in-time schema is modelled only as far as a field keeping the kind and the
/// encryption of its first write. From a nil token, database changes come in one page.
final class FakeCloudKit: @unchecked Sendable {
    static let libraryContainer = SyncSchema.containerIdentifier
    /// The old Apple team's generation-1 container, which no build is entitled to: only the dormant
    /// cutover passes' suites still serve it from the fake, until WP30 deletes them.
    static let legacyContainer = "iCloud.com.foreverlm"

    /// CloudKit's limits on one request (§11.3).
    struct Limits: Sendable {
        /// Records saved and deleted, or fetched by name, in one request.
        var itemsPerRequest = 400
        /// Bytes of the records one save request carries, assets aside.
        var requestBytes = 2_000_000
        /// Bytes of one record, assets aside.
        var recordBytes = 1_000_000
        /// Changes in one page of a zone's feed when the request names no limit.
        var changesPageSize = 200
    }

    enum Permission: Sendable {
        case readOnly
        case readWrite
    }

    /// The order of the records within one page of a zone's changes. Pages always follow change order,
    /// so a token never skips anything, but CloudKit promises no order inside a page (§5.7).
    enum DeliveryOrder: Sendable, Equatable {
        case changeOrder
        case reversed
        case shuffled(seed: UInt64)
    }

    enum Operation: String, Sendable, CaseIterable {
        case accountStatus, userRecordName, allZones, modifyZones, databaseChanges, zoneChanges, records, modifyRecords
        case saveShare, acceptShares, saveSubscription
    }

    /// One call a transport made.
    struct Call: Equatable, Sendable {
        var device: String
        var user: String?
        var container: String
        var operation: Operation
        var database: CloudDatabaseScope?
        var zones: [String]
        var recordNames: [String]
        fileprivate var transport: Int
    }

    /// Where a throttle applies: everything one account asks of one container (`requestRateLimited`,
    /// `serviceUnavailable`: CloudKit throttles the client, D43), or one zone (`zoneBusy`, §2.2).
    enum ThrottleScope: Sendable, Equatable {
        case account(String, container: String = FakeCloudKit.libraryContainer)
        case zone(String, owner: String, container: String = FakeCloudKit.libraryContainer)
    }

    fileprivate struct ZoneKey: Hashable {
        var container: String
        var owner: String
        var name: String
    }

    fileprivate enum StoredValue: Equatable {
        case value(CloudFieldValue)
        case asset(Data)

        var byteCount: Int {
            switch self {
            case .value(let value): return FakeCloudKit.byteCount(value)
            case .asset(let data): return data.count
            }
        }
    }

    fileprivate struct StoredRecord {
        var recordType: String
        var encrypted: [String: StoredValue]
        var plain: [String: StoredValue]
        var changeTag = ""
        var created: Date
        var modified: Date
        var sequence: Int64 = 0

        /// What it costs its owner's quota, assets included.
        var byteCount: Int { (Array(encrypted.values) + Array(plain.values)).reduce(0) { $0 + $1.byteCount } }
    }

    fileprivate final class Zone {
        var exists = true
        var deletion: CloudZoneDeletionReason?
        /// Bumped when a deleted zone is created again: its old tokens name nothing.
        var incarnation = 1
        /// Bumped when the zone's tokens expire.
        var epoch = 0
        var sequence: Int64 = 0
        var records: [String: StoredRecord] = [:]
        var tombstones: [String: (recordType: String, sequence: Int64)] = [:]
        var participants: [String: Permission] = [:]
        /// The zone-wide share's link, title and public permission, and who was invited and has not
        /// accepted yet; participants who joined through the public link are `publicUsers`.
        var shareURL: URL?
        var shareTitle: String?
        var publicPermission: Permission?
        var invited: [String: Permission] = [:]
        var publicUsers: Set<String> = []
    }

    fileprivate struct LogKey: Hashable {
        var container: String
        var user: String
        var scope: CloudDatabaseScope
    }

    /// One account's view of one database: which zones changed or went, in order.
    fileprivate struct DatabaseLog {
        var epoch = 0
        var events: [(zone: ZoneKey, deletion: CloudZoneDeletionReason?)] = []
    }

    fileprivate struct Account {
        var user: String?
        var status: CKAccountStatus?
    }

    fileprivate struct Throttle {
        var scope: ThrottleScope
        var code: CKError.Code
        var until: Date
    }

    fileprivate struct Injection {
        var operation: Operation
        var container: String?
        var device: String?
        var remaining: Int
        var error: CloudError
    }

    fileprivate struct RecordInjection {
        var recordName: String
        var remaining: Int
        var error: CloudError
    }

    fileprivate struct ZoneToken: Codable {
        var container: String
        var owner: String
        var zone: String
        var incarnation: Int
        var epoch: Int
        var sequence: Int64
    }

    fileprivate struct DatabaseToken: Codable {
        var container: String
        var user: String
        var scope: String
        var epoch: Int
        var position: Int
    }

    fileprivate struct SystemFields: Codable {
        var container: String
        var owner: String
        var zone: String
        var record: String
        var tag: String
    }

    fileprivate struct FieldKind: Equatable {
        var kind: String
        var encrypted: Bool
    }

    /// A save or delete checked and waiting for the rest of its request.
    fileprivate enum Staged {
        case save(ZoneKey, CloudRecord, StoredRecord)
        case delete(ZoneKey, String)
        case leave(ZoneKey, String)
        case unshare(ZoneKey)

        var zone: ZoneKey {
            switch self {
            case .save(let key, _, _), .delete(let key, _), .leave(let key, _), .unshare(let key): return key
            }
        }
    }

    private let lock = NSLock()
    private var clock: Date
    private let tick: TimeInterval
    private var tagCounter = 0
    private var transportCounter = 0
    private var zones: [ZoneKey: Zone] = [:]
    private var logs: [LogKey: DatabaseLog] = [:]
    private var knownKinds: [String: FieldKind] = [:]
    private var quotas: [String: Int64] = [:]
    private var accounts: [Int: Account] = [:]
    private var throttles: [Throttle] = []
    private var injections: [Injection] = []
    private var recordInjections: [RecordInjection] = []
    private var callLog: [Call] = []
    private var shareLinks: [URL: ZoneKey] = [:]
    private var subscriptions: [LogKey: Set<String>] = [:]
    private var emails: [String: String] = [:]
    private var currentLimits = Limits()
    private var currentDeliveryOrder = DeliveryOrder.changeOrder
    private let downloads = FileManager.default.temporaryDirectory
        .appendingPathComponent("FakeCloudKit-\(UUID().uuidString)", isDirectory: true)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// A server whose clock starts at `start` and moves `tick` seconds with every write.
    init(start: Date = Date(timeIntervalSinceReferenceDate: 812_000_000), tick: TimeInterval = 0.001) {
        clock = start
        self.tick = tick
    }

    deinit {
        try? FileManager.default.removeItem(at: downloads)
    }

    // MARK: - Devices and accounts

    /// A device signed in to `user` (nil: signed out), talking to `container`.
    func transport(user: String?, container: String = FakeCloudKit.libraryContainer, device: String = "device") -> Transport {
        locked {
            transportCounter += 1
            accounts[transportCounter] = Account(user: user)
            return Transport(server: self, number: transportCounter, containerIdentifier: container, device: device)
        }
    }

    /// Signs `transport`'s device in to another account, or out with nil (an account change, §2.5).
    func signIn(_ transport: Transport, as user: String?) {
        locked { accounts[transport.number, default: Account()].user = user }
    }

    /// What `transport`'s `accountStatus()` answers; nil goes back to "available while signed in".
    func setAccountStatus(_ status: CKAccountStatus?, for transport: Transport) {
        locked { accounts[transport.number, default: Account()].status = status }
    }

    // MARK: - Clock, limits, delivery

    /// The server's time: every record a write saves is dated with it.
    var now: Date {
        get { locked { clock } }
        set { locked { clock = newValue } }
    }

    func advance(by seconds: TimeInterval) {
        locked { clock = clock.addingTimeInterval(seconds) }
    }

    var limits: Limits {
        get { locked { currentLimits } }
        set { locked { currentLimits = newValue } }
    }

    var deliveryOrder: DeliveryOrder {
        get { locked { currentDeliveryOrder } }
        set { locked { currentDeliveryOrder = newValue } }
    }

    // MARK: - The server's own view (no call is logged)

    /// The zones `owner` has in `container`.
    func zoneNames(owner: String, container: String = FakeCloudKit.libraryContainer) -> [String] {
        locked { zones.filter { $0.key.container == container && $0.key.owner == owner && $0.value.exists }.map(\.key.name).sorted() }
    }

    /// The names of the records a zone holds.
    func recordNames(zone: String, owner: String, container: String = FakeCloudKit.libraryContainer) -> [String] {
        locked {
            guard let stored = zones[ZoneKey(container: container, owner: owner, name: zone)], stored.exists else { return [] }
            return stored.records.keys.sorted()
        }
    }

    /// A record as the server holds it, every field included, as its owner reads it.
    func storedRecord(_ recordName: String, zone: String, owner: String, container: String = FakeCloudKit.libraryContainer) -> CloudRecord? {
        locked {
            let key = ZoneKey(container: container, owner: owner, name: zone)
            guard let stored = zones[key], stored.exists, let record = stored.records[recordName] else { return nil }
            return cloudRecord(record, named: recordName, in: key, as: CloudZoneID(zone), desiredKeys: nil)
        }
    }

    /// Writes records straight into `owner`'s zone, creating it if needed, as a client the test does
    /// not drive would (the old container's fixtures, another device's write). Each replaces what
    /// the server held under its name. Returns them as the server now holds them.
    @discardableResult
    func put(_ records: [CloudRecord], zone: String, owner: String, container: String = FakeCloudKit.libraryContainer) -> [CloudRecord] {
        locked {
            let key = ZoneKey(container: container, owner: owner, name: zone)
            createZone(key)
            let held = zones[key]!
            let written = records.compactMap { record -> CloudRecord? in
                // A record the fake refuses (an asset whose file is missing, a field both encrypted and plain) is a
                // failed test, never a trap that takes the whole test process down with it (T4).
                let fields: (encrypted: [String: StoredValue], plain: [String: StoredValue])
                do {
                    fields = try storedFields(of: record)
                } catch {
                    Issue.record("FakeCloudKit.put refused \(record.id): \(error)")
                    return nil
                }
                for (field, kind) in kinds(of: fields, type: record.recordType, container: container) {
                    knownKinds[field] = kind
                }
                let previous = held.records[record.id.recordName]
                let stored = StoredRecord(recordType: record.recordType, encrypted: fields.encrypted, plain: fields.plain,
                                          created: previous?.created ?? clock, modified: clock)
                let saved = commitSave(stored, named: record.id.recordName, in: key)
                return cloudRecord(saved, named: record.id.recordName, in: key, as: CloudZoneID(zone), desiredKeys: nil)
            }
            noteChanged(key)
            clock = clock.addingTimeInterval(tick)
            return written
        }
    }

    // MARK: - Zones going away

    /// Removes a zone as `reason` says: `.deleted` as another device of its owner would (§2.5),
    /// `.purged` as the learner does in iCloud settings, `.encryptedDataReset` as a reset does.
    func deleteZone(_ zone: String, owner: String, container: String = FakeCloudKit.libraryContainer, reason: CloudZoneDeletionReason = .deleted) {
        locked {
            removeZone(ZoneKey(container: container, owner: owner, name: zone), reason: reason)
            clock = clock.addingTimeInterval(tick)
        }
    }

    /// The learner resets their encrypted data: every zone they own in `container` goes.
    func resetEncryptedData(owner: String, container: String = FakeCloudKit.libraryContainer) {
        locked {
            for key in zones.keys where key.container == container && key.owner == owner {
                removeZone(key, reason: .encryptedDataReset)
            }
            clock = clock.addingTimeInterval(tick)
        }
    }

    // MARK: - Sharing

    /// Shares `owner`'s zone with `participant` through a zone-wide share (§2.2), which the zone holds
    /// as the record `cloudkit.zoneshare`; the participant's shared database lists the zone from now on.
    func share(zone: String, owner: String, container: String = FakeCloudKit.libraryContainer, with participant: String,
               permission: Permission = .readWrite) {
        locked {
            let key = ZoneKey(container: container, owner: owner, name: zone)
            guard let held = zones[key], held.exists else { preconditionFailure("share a zone that exists: \(zone)") }
            if held.records[CloudRecordID.zoneShareRecordName] == nil {
                saveShareRecord(in: key)
            }
            held.participants[participant] = permission
            held.invited[participant] = nil
            noteChanged(key)
            clock = clock.addingTimeInterval(tick)
        }
    }

    /// The owner removes `participant` from the share: the zone leaves their shared database.
    func removeParticipant(_ participant: String, zone: String, owner: String, container: String = FakeCloudKit.libraryContainer) {
        locked {
            let key = ZoneKey(container: container, owner: owner, name: zone)
            guard let held = zones[key], held.participants.removeValue(forKey: participant) != nil else { return }
            append(key, deletion: .deleted, to: LogKey(container: container, user: participant, scope: .shared))
            clock = clock.addingTimeInterval(tick)
        }
    }

    /// The account iCloud finds for an email address an owner invites.
    func register(email: String, user: String) {
        locked { emails[email] = user }
    }

    /// The database subscriptions `user` saved in `scope`.
    func subscriptionIDs(user: String, scope: CloudDatabaseScope, container: String = FakeCloudKit.libraryContainer) -> Set<String> {
        locked { subscriptions[LogKey(container: container, user: user, scope: scope)] ?? [] }
    }

    // MARK: - Tokens

    /// Every token issued for the zone so far expires, and the deletions it would have carried are
    /// gone: a client fetches from nil again and never hears of them (§2.3, D30).
    func expireZoneChangeTokens(zone: String, owner: String, container: String = FakeCloudKit.libraryContainer) {
        locked {
            guard let held = zones[ZoneKey(container: container, owner: owner, name: zone)] else { return }
            held.epoch += 1
            held.tombstones = [:]
        }
    }

    /// Every database token issued to `user` for `scope` so far expires.
    func expireDatabaseChangeTokens(user: String, scope: CloudDatabaseScope, container: String = FakeCloudKit.libraryContainer) {
        locked {
            let key = LogKey(container: container, user: user, scope: scope)
            logs[key, default: DatabaseLog()].epoch += 1
            logs[key]?.events = []
        }
    }

    // MARK: - Quota, throttles and injected failures

    /// The iCloud storage `user` has, across containers; nil is unlimited. Writes into a zone count
    /// against the zone's owner, whoever makes them (§2.5).
    func setQuota(_ bytes: Int64?, for user: String) {
        locked { quotas[user] = bytes }
    }

    func usedBytes(of user: String) -> Int64 {
        locked { usage(of: user) }
    }

    /// Refuses everything in `scope` with `code` for `seconds` of server time, each refusal carrying
    /// the time left as `retryAfter`.
    func throttle(_ code: CKError.Code = .requestRateLimited, for seconds: TimeInterval, scope: ThrottleScope) {
        locked { throttles.append(Throttle(scope: scope, code: code, until: clock.addingTimeInterval(seconds))) }
    }

    /// The next `times` calls of `operation` (from `device`, to `container`, when named) throw `error`.
    func failNext(_ operation: Operation, container: String? = nil, device: String? = nil, times: Int = 1, with error: CloudError) {
        locked { injections.append(Injection(operation: operation, container: container, device: device, remaining: times, error: error)) }
    }

    /// The next `times` saves, deletes or fetches of a record named `recordName` fail with `error`,
    /// alone in their request; a zone-change page that would deliver it reports it in `failed`
    /// instead, and its token still moves past it, as CloudKit's does.
    func failRecord(_ recordName: String, times: Int = 1, with error: CloudError) {
        locked { recordInjections.append(RecordInjection(recordName: recordName, remaining: times, error: error)) }
    }

    // MARK: - The call log

    /// Every call any transport made, in order.
    var calls: [Call] {
        locked { callLog }
    }

    func resetCalls() {
        locked { callLog = [] }
    }

    // MARK: - A device's transport

    final class Transport: CloudSharingTransport, @unchecked Sendable {
        let server: FakeCloudKit
        fileprivate let number: Int
        let containerIdentifier: String
        /// A name for the call log.
        let device: String

        fileprivate init(server: FakeCloudKit, number: Int, containerIdentifier: String, device: String) {
            self.server = server
            self.number = number
            self.containerIdentifier = containerIdentifier
            self.device = device
        }

        /// The calls this device made, in order.
        var calls: [Call] { server.calls.filter { $0.transport == number } }

        func accountStatus() async throws -> CKAccountStatus {
            try await server.perform(self, .accountStatus, requiresAccount: false) { account in
                account.status ?? (account.user == nil ? .noAccount : .available)
            }
        }

        func userRecordName() async throws -> String {
            try await server.perform(self, .userRecordName) { account in account.user ?? "" }
        }

        func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] {
            try await server.perform(self, .allZones, database: database) { account in
                server.visibleZones(of: account.user ?? "", container: containerIdentifier, scope: database)
            }
        }

        func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
            try await server.perform(self, .modifyZones, database: database, zones: saving + deleting, writes: true) { account in
                server.modifyZones(saving: saving, deleting: deleting, user: account.user ?? "", container: containerIdentifier, scope: database)
            }
        }

        func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
            try await server.perform(self, .databaseChanges, database: database) { account in
                try server.databaseChanges(user: account.user ?? "", container: containerIdentifier, scope: database,
                                           since: token, resultsLimit: resultsLimit)
            }
        }

        func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
            try await server.perform(self, .zoneChanges, database: database, zones: requests.map(\.zoneID)) { account in
                var results: [CloudZoneID: Result<CloudZoneChanges, CloudError>] = [:]
                for request in requests {
                    results[request.zoneID] = server.zoneChanges(request, user: account.user ?? "", container: containerIdentifier, scope: database)
                }
                return results
            }
        }

        func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
            try await server.perform(self, .records, database: database, zones: ids.map(\.zoneID), recordNames: ids.map(\.recordName)) { account in
                try server.fetch(ids, user: account.user ?? "", container: containerIdentifier, scope: database, desiredKeys: desiredKeys)
            }
        }

        func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                           savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
            let ids = saving.map(\.id) + deleting
            return try await server.perform(self, .modifyRecords, database: database, zones: ids.map(\.zoneID),
                                            recordNames: ids.map(\.recordName), writes: true) { account in
                try server.modify(saving: saving, deleting: deleting, user: account.user ?? "", container: containerIdentifier,
                                  scope: database, policy: savePolicy, atomically: atomically)
            }
        }

        func saveShare(_ change: CloudShareChange, in zoneID: CloudZoneID) async throws -> CloudRecord {
            try await server.perform(self, .saveShare, database: .private, zones: [zoneID],
                                     recordNames: [CloudRecordID.zoneShareRecordName], writes: true) { account in
                try server.saveShare(change, in: zoneID, user: account.user ?? "", container: containerIdentifier)
            }
        }

        func acceptShares(_ invitations: [CloudShareInvitation]) async throws -> [URL: Result<CloudShareAcceptance, CloudError>] {
            try await server.perform(self, .acceptShares, database: .shared, writes: true) { account in
                var results: [URL: Result<CloudShareAcceptance, CloudError>] = [:]
                for invitation in invitations {
                    results[invitation.url] = server.accept(invitation.url, user: account.user ?? "", container: containerIdentifier)
                }
                return results
            }
        }

        func saveDatabaseSubscription(_ subscriptionID: String, in database: CloudDatabaseScope) async throws {
            try await server.perform(self, .saveSubscription, database: database) { account in
                _ = server.subscriptions[LogKey(container: containerIdentifier, user: account.user ?? "", scope: database), default: []].insert(subscriptionID)
            }
        }
    }
}

// MARK: - The server (every method below runs with the lock held)

private extension FakeCloudKit {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Logs the call, then refuses it as CloudKit would before doing anything: cancelled, an injected
    /// failure, no account, or a throttle on the account. A write moves the clock one tick.
    func perform<T>(_ transport: Transport, _ operation: Operation, database: CloudDatabaseScope? = nil,
                    zones touched: [CloudZoneID] = [], recordNames: [String] = [], requiresAccount: Bool = true,
                    writes: Bool = false, _ body: (Account) throws -> T) async throws -> T {
        await Task.yield()
        let cancelled = Task.isCancelled
        return try locked {
            let account = accounts[transport.number] ?? Account()
            callLog.append(Call(device: transport.device, user: account.user, container: transport.containerIdentifier,
                                operation: operation, database: database, zones: touched.map(\.description),
                                recordNames: recordNames, transport: transport.number))
            if cancelled { throw CloudError(.operationCancelled, message: "the task was cancelled") }
            if let index = injections.firstIndex(where: { injection in
                injection.operation == operation && injection.remaining > 0
                    && (injection.container ?? transport.containerIdentifier) == transport.containerIdentifier
                    && (injection.device ?? transport.device) == transport.device
            }) {
                injections[index].remaining -= 1
                throw injections[index].error
            }
            if requiresAccount {
                guard let user = account.user else {
                    throw CloudError(.notAuthenticated, message: "\(transport.device) is not signed in to iCloud")
                }
                if let refusal = throttled(.account(user, container: transport.containerIdentifier)) { throw refusal }
            }
            let result = try body(account)
            if writes { clock = clock.addingTimeInterval(tick) }
            return result
        }
    }

    func throttled(_ scope: ThrottleScope) -> CloudError? {
        guard let throttle = throttles.last(where: { $0.scope == scope && $0.until > clock }) else { return nil }
        return CloudError(throttle.code, retryAfter: throttle.until.timeIntervalSince(clock), message: "throttled")
    }

    // MARK: Zones

    func visibleZones(of user: String, container: String, scope: CloudDatabaseScope) -> [CloudZoneID] {
        zones.filter { key, zone in
            guard key.container == container, zone.exists else { return false }
            switch scope {
            case .private: return key.owner == user
            case .shared: return zone.participants[user] != nil
            }
        }
        .map { zoneID(of: $0.key, scope: scope) }
        .sorted { ($0.ownerName, $0.zoneName) < ($1.ownerName, $1.zoneName) }
    }

    /// The zone id a client of `scope` knows `key` by: its own zones under the default owner name,
    /// shared ones under their owner's.
    func zoneID(of key: ZoneKey, scope: CloudDatabaseScope) -> CloudZoneID {
        scope == .private ? CloudZoneID(key.name) : CloudZoneID(key.name, ownerName: key.owner)
    }

    /// The zone `zoneID` names for `user` in `scope`, or why it cannot be reached (or written).
    func reach(_ zoneID: CloudZoneID, user: String, container: String, scope: CloudDatabaseScope,
               writing: Bool) -> Result<(ZoneKey, Zone), CloudError> {
        let key: ZoneKey
        switch scope {
        case .private:
            guard zoneID.ownerName == CloudZoneID.currentUser || zoneID.ownerName == user else {
                return .failure(CloudError(.invalidArguments, message: "\(zoneID) is not \(user)'s; a shared zone is in the shared database"))
            }
            key = ZoneKey(container: container, owner: user, name: zoneID.zoneName)
        case .shared:
            key = ZoneKey(container: container, owner: zoneID.ownerName, name: zoneID.zoneName)
            guard zoneID.ownerName != CloudZoneID.currentUser, zoneID.ownerName != user, let held = zones[key], held.exists,
                  let permission = held.participants[user] else {
                return .failure(CloudError(.zoneNotFound, message: "\(zoneID) is not shared with \(user)"))
            }
            if writing, permission == .readOnly {
                return .failure(CloudError(.permissionFailure, message: "\(user) may only read \(zoneID)"))
            }
        }
        guard let held = zones[key], held.exists else {
            if zones[key]?.deletion == .purged {
                return .failure(CloudError(.userDeletedZone, message: "\(zoneID) was removed in iCloud settings"))
            }
            return .failure(CloudError(.zoneNotFound, message: "no zone \(zoneID)"))
        }
        if let refusal = throttled(.zone(key.name, owner: key.owner, container: key.container)) { return .failure(refusal) }
        return .success((key, held))
    }

    func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], user: String, container: String,
                     scope: CloudDatabaseScope) -> CloudZoneModifyResults {
        var results = CloudZoneModifyResults(saved: [:], deleted: [:])
        let refused = CloudError(.permissionFailure, message: "only an owner creates or deletes a zone, in the private database")
        for zoneID in saving {
            guard scope == .private, zoneID.ownerName == CloudZoneID.currentUser || zoneID.ownerName == user else {
                results.saved[zoneID] = .failure(refused)
                continue
            }
            createZone(ZoneKey(container: container, owner: user, name: zoneID.zoneName))
            results.saved[zoneID] = .success(())
        }
        for zoneID in deleting {
            guard scope == .private, zoneID.ownerName == CloudZoneID.currentUser || zoneID.ownerName == user else {
                results.deleted[zoneID] = .failure(refused)
                continue
            }
            switch reach(zoneID, user: user, container: container, scope: scope, writing: true) {
            case .failure(let error): results.deleted[zoneID] = .failure(error)
            case .success(let (key, _)):
                removeZone(key, reason: .deleted)
                results.deleted[zoneID] = .success(())
            }
        }
        return results
    }

    /// Creates the zone, or creates a deleted one again under a new incarnation; one that exists
    /// is left alone.
    func createZone(_ key: ZoneKey) {
        if let held = zones[key] {
            guard !held.exists else { return }
            held.exists = true
            held.deletion = nil
            held.incarnation += 1
            held.epoch = 0
            held.sequence = 0
        } else {
            zones[key] = Zone()
        }
        noteChanged(key)
    }

    func removeZone(_ key: ZoneKey, reason: CloudZoneDeletionReason) {
        guard let held = zones[key], held.exists else { return }
        let participants = Array(held.participants.keys)
        held.exists = false
        held.deletion = reason
        held.records = [:]
        held.tombstones = [:]
        held.participants = [:]
        held.invited = [:]
        held.publicUsers = []
        if let url = held.shareURL { shareLinks[url] = nil }
        held.shareURL = nil
        append(key, deletion: reason, to: LogKey(container: key.container, user: key.owner, scope: .private))
        for participant in participants {
            append(key, deletion: .deleted, to: LogKey(container: key.container, user: participant, scope: .shared))
        }
    }

    /// A zone changed: its owner's private database and every participant's shared database say so.
    func noteChanged(_ key: ZoneKey) {
        append(key, deletion: nil, to: LogKey(container: key.container, user: key.owner, scope: .private))
        for participant in zones[key]?.participants.keys.sorted() ?? [] {
            append(key, deletion: nil, to: LogKey(container: key.container, user: participant, scope: .shared))
        }
    }

    func append(_ key: ZoneKey, deletion: CloudZoneDeletionReason?, to log: LogKey) {
        logs[log, default: DatabaseLog()].events.append((zone: key, deletion: deletion))
    }

    // MARK: Database changes

    func databaseChanges(user: String, container: String, scope: CloudDatabaseScope, since token: CloudChangeToken?,
                         resultsLimit: Int?) throws -> CloudDatabaseChanges {
        let logKey = LogKey(container: container, user: user, scope: scope)
        let log = logs[logKey] ?? DatabaseLog()
        guard let token else {
            return CloudDatabaseChanges(
                modifiedZones: visibleZones(of: user, container: container, scope: scope), deletedZones: [],
                changeToken: encode(DatabaseToken(container: container, user: user, scope: scope.rawValue, epoch: log.epoch,
                                                  position: log.events.count)),
                moreComing: false
            )
        }
        guard let decoded = try? JSONDecoder().decode(DatabaseToken.self, from: token.data), decoded.container == container,
              decoded.user == user, decoded.scope == scope.rawValue else {
            throw CloudError(.invalidArguments, message: "the token is not this account's \(scope.rawValue) database's")
        }
        guard decoded.epoch == log.epoch, decoded.position <= log.events.count else {
            throw CloudError(.changeTokenExpired, message: "the database token expired")
        }
        let pageSize = resultsLimit.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        var order: [ZoneKey] = []
        var latest: [ZoneKey: CloudZoneDeletionReason?] = [:]
        var position = decoded.position
        while position < log.events.count {
            let event = log.events[position]
            if !latest.keys.contains(event.zone) {
                if order.count == pageSize { break }
                order.append(event.zone)
            }
            latest[event.zone] = .some(event.deletion)
            position += 1
        }
        var modified: [CloudZoneID] = []
        var deleted: [CloudZoneDeletion] = []
        for key in order {
            if case .some(.some(let reason)) = latest[key] {
                deleted.append(CloudZoneDeletion(zoneID: zoneID(of: key, scope: scope), reason: reason))
            } else {
                modified.append(zoneID(of: key, scope: scope))
            }
        }
        return CloudDatabaseChanges(
            modifiedZones: modified, deletedZones: deleted,
            changeToken: encode(DatabaseToken(container: container, user: user, scope: scope.rawValue, epoch: log.epoch, position: position)),
            moreComing: position < log.events.count
        )
    }

    // MARK: Zone changes

    func zoneChanges(_ request: CloudZoneChangesRequest, user: String, container: String,
                     scope: CloudDatabaseScope) -> Result<CloudZoneChanges, CloudError> {
        let key: ZoneKey
        let held: Zone
        switch reach(request.zoneID, user: user, container: container, scope: scope, writing: false) {
        case .failure(let error): return .failure(error)
        case .success(let reached): (key, held) = reached
        }
        var since: Int64 = 0
        if let token = request.since {
            guard let decoded = try? JSONDecoder().decode(ZoneToken.self, from: token.data), decoded.container == key.container,
                  decoded.owner == key.owner, decoded.zone == key.name else {
                return .failure(CloudError(.invalidArguments, message: "the token is not \(request.zoneID)'s"))
            }
            guard decoded.incarnation == held.incarnation, decoded.epoch == held.epoch, decoded.sequence <= held.sequence else {
                return .failure(CloudError(.changeTokenExpired, message: "\(request.zoneID)'s token expired"))
            }
            since = decoded.sequence
        }
        // Every change after the token, in change order: live records and, unless the fetch starts from
        // nil, the deletions.
        var changes: [(sequence: Int64, name: String, deletedType: String?)] = held.records
            .filter { $0.value.sequence > since }
            .map { (sequence: $0.value.sequence, name: $0.key, deletedType: nil) }
        if request.since != nil {
            changes += held.tombstones.filter { $0.value.sequence > since }
                .map { (sequence: $0.value.sequence, name: $0.key, deletedType: $0.value.recordType) }
        }
        changes.sort { $0.sequence < $1.sequence }
        let pageSize = max(1, request.resultsLimit ?? currentLimits.changesPageSize)
        let page = changes.prefix(pageSize)
        let moreComing = changes.count > pageSize
        let shownAs = zoneID(of: key, scope: scope)
        var failed: [CloudRecordID: CloudError] = [:]
        let modified = page.compactMap { change -> CloudRecord? in
            guard change.deletedType == nil, let stored = held.records[change.name] else { return nil }
            if let error = injectedFailure(for: change.name) {
                failed[CloudRecordID(change.name, in: shownAs)] = error
                return nil
            }
            return cloudRecord(stored, named: change.name, in: key, as: shownAs, desiredKeys: request.desiredKeys, viewer: user)
        }
        let deleted = page.compactMap { change in
            change.deletedType.map { CloudRecordDeletion(id: CloudRecordID(change.name, in: shownAs), recordType: $0) }
        }
        let reached = moreComing ? page.last?.sequence ?? since : held.sequence
        return .success(CloudZoneChanges(
            modified: delivered(modified, page: since),
            deleted: deleted,
            failed: failed,
            changeToken: encode(ZoneToken(container: key.container, owner: key.owner, zone: key.name,
                                          incarnation: held.incarnation, epoch: held.epoch, sequence: reached)),
            moreComing: moreComing
        ))
    }

    /// Puts one page's records in the order `deliveryOrder` asks for.
    func delivered(_ records: [CloudRecord], page: Int64) -> [CloudRecord] {
        switch currentDeliveryOrder {
        case .changeOrder:
            return records
        case .reversed:
            return records.reversed()
        case .shuffled(let seed):
            var generator = SplitMix64(state: seed &+ UInt64(bitPattern: page))
            return records.shuffled(using: &generator)
        }
    }

    // MARK: Records

    func fetch(_ ids: [CloudRecordID], user: String, container: String, scope: CloudDatabaseScope,
               desiredKeys: [String]?) throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
        guard ids.count <= currentLimits.itemsPerRequest else {
            throw CloudError(.limitExceeded, message: "\(ids.count) records in one request; CloudKit takes \(currentLimits.itemsPerRequest)")
        }
        var results: [CloudRecordID: Result<CloudRecord, CloudError>] = [:]
        for id in ids {
            switch reach(id.zoneID, user: user, container: container, scope: scope, writing: false) {
            case .failure(let error):
                results[id] = .failure(error)
            case .success(let (key, held)):
                if let error = injectedFailure(for: id.recordName) {
                    results[id] = .failure(error)
                } else if let stored = held.records[id.recordName] {
                    results[id] = .success(cloudRecord(stored, named: id.recordName, in: key, as: zoneID(of: key, scope: scope),
                                                       desiredKeys: desiredKeys, viewer: user))
                } else {
                    results[id] = .failure(CloudError(.unknownItem, message: "no record \(id)"))
                }
            }
        }
        return results
    }

    func modify(saving: [CloudRecord], deleting: [CloudRecordID], user: String, container: String, scope: CloudDatabaseScope,
                policy: CloudSavePolicy, atomically: Bool) throws -> CloudModifyResults {
        let ids = saving.map(\.id) + deleting
        guard ids.count <= currentLimits.itemsPerRequest else {
            throw CloudError(.limitExceeded, message: "\(ids.count) records in one request; CloudKit takes \(currentLimits.itemsPerRequest)")
        }
        guard Set(ids).count == ids.count else {
            throw CloudError(.invalidArguments, message: "a record is named twice in one request")
        }
        let requestBytes = saving.reduce(0) { $0 + Self.byteCount(of: $1) }
        guard requestBytes <= currentLimits.requestBytes else {
            throw CloudError(.limitExceeded, message: "\(requestBytes) bytes in one request; CloudKit takes \(currentLimits.requestBytes)")
        }

        var usageChange: [String: Int64] = [:]
        var newKinds: [String: FieldKind] = [:]
        var outcomes: [(id: CloudRecordID, outcome: Result<Staged, CloudError>)] = []
        for record in saving {
            outcomes.append((record.id, stageSave(record, user: user, container: container, scope: scope, policy: policy,
                                                  usageChange: &usageChange, newKinds: &newKinds)))
        }
        for id in deleting {
            outcomes.append((id, stageDelete(id, user: user, container: container, scope: scope, usageChange: &usageChange)))
        }
        if atomically {
            // CloudKit's atomic saves hold per zone: one failure fails every other change to that zone.
            let failedZones = Set(outcomes.compactMap { item -> String? in
                guard case .failure = item.outcome else { return nil }
                return item.id.zoneID.description
            })
            outcomes = outcomes.map { item -> (id: CloudRecordID, outcome: Result<Staged, CloudError>) in
                guard case .success = item.outcome, failedZones.contains(item.id.zoneID.description) else { return item }
                return (item.id, .failure(CloudError(.batchRequestFailed, message: "another change to \(item.id.zoneID) failed")))
            }
        }

        var results = CloudModifyResults(saved: [:], deleted: [:])
        var touched: [ZoneKey] = []
        let savedIDs = Set(saving.map(\.id))
        for (id, outcome) in outcomes {
            switch outcome {
            case .failure(let error):
                if savedIDs.contains(id) { results.saved[id] = .failure(error) } else { results.deleted[id] = .failure(error) }
            case .success(let staged):
                if !touched.contains(staged.zone) { touched.append(staged.zone) }
                switch staged {
                case .save(let key, let sent, let stored):
                    for (field, kind) in kinds(of: (stored.encrypted, stored.plain), type: stored.recordType, container: key.container) {
                        knownKinds[field] = kind
                    }
                    let saved = commitSave(stored, named: id.recordName, in: key)
                    var returned = sent
                    returned.systemFields = systemFields(of: saved, named: id.recordName, in: key)
                    returned.changeTag = saved.changeTag
                    returned.creationDate = saved.created
                    returned.modificationDate = saved.modified
                    results.saved[id] = .success(returned)
                case .delete(let key, let name):
                    commitDelete(named: name, in: key)
                    results.deleted[id] = .success(())
                case .leave(let key, let participant):
                    zones[key]?.participants[participant] = nil
                    zones[key]?.publicUsers.remove(participant)
                    append(key, deletion: .deleted, to: LogKey(container: key.container, user: participant, scope: .shared))
                    results.deleted[id] = .success(())
                case .unshare(let key):
                    for participant in zones[key]?.participants.keys.sorted() ?? [] {
                        append(key, deletion: .deleted, to: LogKey(container: key.container, user: participant, scope: .shared))
                    }
                    zones[key]?.participants = [:]
                    zones[key]?.invited = [:]
                    zones[key]?.publicUsers = []
                    if let url = zones[key]?.shareURL { shareLinks[url] = nil }
                    zones[key]?.shareURL = nil
                    commitDelete(named: CloudRecordID.zoneShareRecordName, in: key)
                    results.deleted[id] = .success(())
                }
            }
        }
        for key in touched where zones[key]?.exists == true {
            noteChanged(key)
        }
        return results
    }

    func stageSave(_ record: CloudRecord, user: String, container: String, scope: CloudDatabaseScope, policy: CloudSavePolicy,
                   usageChange: inout [String: Int64], newKinds: inout [String: FieldKind]) -> Result<Staged, CloudError> {
        let key: ZoneKey
        let held: Zone
        switch reach(record.id.zoneID, user: user, container: container, scope: scope, writing: true) {
        case .failure(let error): return .failure(error)
        case .success(let reached): (key, held) = reached
        }
        if let error = injectedFailure(for: record.id.recordName) { return .failure(error) }
        let fields: (encrypted: [String: StoredValue], plain: [String: StoredValue])
        do {
            fields = try storedFields(of: record)
        } catch let error as CloudError {
            return .failure(error)
        } catch {
            return .failure(CloudError(.internalError, message: "\(error)"))
        }
        guard Self.byteCount(of: record) <= currentLimits.recordBytes else {
            return .failure(CloudError(.limitExceeded, message: "\(record.id) is over \(currentLimits.recordBytes) bytes"))
        }
        for (field, kind) in kinds(of: fields, type: record.recordType, container: container) {
            if let known = knownKinds[field] ?? newKinds[field], known != kind {
                return .failure(CloudError(.invalidArguments, message: "\(record.recordType).\(field.split(separator: "\u{1}").last ?? "") is \(known.kind)\(known.encrypted ? ", encrypted" : ""), not \(kind.kind)"))
            }
            newKinds[field] = kind
        }
        var basisTag: String?
        if let data = record.systemFields {
            guard let decoded = try? JSONDecoder().decode(SystemFields.self, from: data), decoded.container == key.container,
                  decoded.owner == key.owner, decoded.zone == key.name, decoded.record == record.id.recordName else {
                return .failure(CloudError(.invalidArguments, message: "the system fields are not \(record.id)'s"))
            }
            basisTag = decoded.tag
        }
        let existing = held.records[record.id.recordName]
        if let existing, existing.recordType != record.recordType {
            return .failure(CloudError(.invalidArguments, message: "\(record.id) is a \(existing.recordType), not a \(record.recordType)"))
        }
        var encrypted = fields.encrypted
        var plain = fields.plain
        switch policy {
        case .ifServerRecordUnchanged:
            if let existing {
                guard let basisTag, basisTag == existing.changeTag else {
                    let server = cloudRecord(existing, named: record.id.recordName, in: key, as: zoneID(of: key, scope: scope), desiredKeys: nil)
                    return .failure(CloudError(.serverRecordChanged, serverRecord: server,
                                               message: basisTag == nil ? "\(record.id) exists" : "\(record.id) changed since that version"))
                }
                encrypted = existing.encrypted.merging(encrypted) { $1 }
                plain = existing.plain.merging(plain) { $1 }
            } else if basisTag != nil {
                return .failure(CloudError(.unknownItem, message: "\(record.id) was deleted"))
            }
        case .changedKeys:
            if let existing {
                encrypted = existing.encrypted.merging(encrypted) { $1 }
                plain = existing.plain.merging(plain) { $1 }
            }
        case .allKeys:
            break
        }
        let stored = StoredRecord(recordType: record.recordType, encrypted: encrypted, plain: plain,
                                  created: existing?.created ?? clock, modified: clock)
        let growth = Int64(stored.byteCount - (existing?.byteCount ?? 0))
        if growth > 0, let quota = quotas[key.owner], usage(of: key.owner) + usageChange[key.owner, default: 0] + growth > quota {
            return .failure(CloudError(.quotaExceeded, message: "\(key.owner)'s iCloud storage is full"))
        }
        usageChange[key.owner, default: 0] += growth
        return .success(.save(key, record, stored))
    }

    func stageDelete(_ id: CloudRecordID, user: String, container: String, scope: CloudDatabaseScope,
                     usageChange: inout [String: Int64]) -> Result<Staged, CloudError> {
        // A participant may always leave, read-only or not, by deleting the zone-wide share.
        let leaving = scope == .shared && id.recordName == CloudRecordID.zoneShareRecordName
        let key: ZoneKey
        let held: Zone
        switch reach(id.zoneID, user: user, container: container, scope: scope, writing: !leaving) {
        case .failure(let error): return .failure(error)
        case .success(let reached): (key, held) = reached
        }
        if let error = injectedFailure(for: id.recordName) { return .failure(error) }
        if leaving { return .success(.leave(key, user)) }
        guard let existing = held.records[id.recordName] else {
            return .failure(CloudError(.unknownItem, message: "no record \(id)"))
        }
        if id.recordName == CloudRecordID.zoneShareRecordName { return .success(.unshare(key)) }
        usageChange[key.owner, default: 0] -= Int64(existing.byteCount)
        return .success(.delete(key, id.recordName))
    }

    /// Writes a record: a new change, a new tag, and no tombstone under its name.
    @discardableResult
    func commitSave(_ record: StoredRecord, named name: String, in key: ZoneKey) -> StoredRecord {
        guard let held = zones[key] else { preconditionFailure("commit into a zone that exists") }
        tagCounter += 1
        held.sequence += 1
        var saved = record
        saved.changeTag = "t" + String(tagCounter, radix: 36)
        saved.sequence = held.sequence
        held.records[name] = saved
        held.tombstones[name] = nil
        return saved
    }

    // MARK: Sharing

    /// Writes the zone-wide share record and gives the zone its link, once.
    func saveShareRecord(in key: ZoneKey) {
        guard let held = zones[key] else { return }
        let previous = held.records[CloudRecordID.zoneShareRecordName]
        commitSave(StoredRecord(recordType: CloudRecordID.shareRecordType, encrypted: [:], plain: [:],
                                created: previous?.created ?? clock, modified: clock),
                   named: CloudRecordID.zoneShareRecordName, in: key)
        if held.shareURL == nil {
            tagCounter += 1
            let url = URL(string: "https://www.icloud.com/share/fake\(tagCounter)#\(key.name)")!
            held.shareURL = url
            shareLinks[url] = key
        }
    }

    func saveShare(_ change: CloudShareChange, in zoneID: CloudZoneID, user: String, container: String) throws -> CloudRecord {
        let key: ZoneKey
        let held: Zone
        switch reach(zoneID, user: user, container: container, scope: .private, writing: true) {
        case .failure(let error): throw error
        case .success(let reached): (key, held) = reached
        }
        var invited: [String: Permission] = [:]
        for (lookup, permission) in change.invite {
            let invitee: String?
            switch lookup {
            case .userRecordName(let name): invitee = name
            case .email(let email): invitee = emails[email]
            case .phoneNumber: invitee = nil
            }
            guard let invitee else { throw CloudError(.unknownItem, message: "iCloud found no one for an invitation") }
            invited[invitee] = Self.permission(permission)
        }
        saveShareRecord(in: key)
        if let title = change.title { held.shareTitle = title }
        if let permission = change.publicPermission { held.publicPermission = Self.linkPermission(permission) }
        for (invitee, permission) in invited where held.participants[invitee] == nil && invitee != key.owner {
            held.invited[invitee] = permission
        }
        for (participant, permission) in change.permissions {
            if held.participants[participant] != nil { held.participants[participant] = Self.permission(permission) }
            if held.invited[participant] != nil { held.invited[participant] = Self.permission(permission) }
        }
        for participant in change.remove {
            held.invited[participant] = nil
            held.publicUsers.remove(participant)
            if held.participants.removeValue(forKey: participant) != nil {
                append(key, deletion: .deleted, to: LogKey(container: container, user: participant, scope: .shared))
            }
        }
        noteChanged(key)
        return cloudRecord(held.records[CloudRecordID.zoneShareRecordName]!, named: CloudRecordID.zoneShareRecordName, in: key,
                           as: CloudZoneID(key.name), desiredKeys: nil, viewer: user)
    }

    /// `user` accepts the share at `url`: an invitee with the permission they were invited with,
    /// anyone else only while the link is public.
    func accept(_ url: URL, user: String, container: String) -> Result<CloudShareAcceptance, CloudError> {
        guard let key = shareLinks[url], key.container == container, let held = zones[key], held.exists,
              held.records[CloudRecordID.zoneShareRecordName] != nil
        else { return .failure(CloudError(.unknownItem, message: "no share at \(url)")) }
        guard key.owner != user else { return .failure(CloudError(.invalidArguments, message: "the owner does not accept their own share")) }
        if held.participants[user] == nil {
            if let permission = held.invited.removeValue(forKey: user) {
                held.participants[user] = permission
            } else if let permission = held.publicPermission {
                held.participants[user] = permission
                held.publicUsers.insert(user)
            } else {
                return .failure(CloudError(.permissionFailure, message: "\(user) was not invited to \(key.name)"))
            }
            append(key, deletion: nil, to: LogKey(container: container, user: user, scope: .shared))
        }
        return .success(CloudShareAcceptance(zoneID: CloudZoneID(key.name, ownerName: key.owner), share: shareInfo(key, viewer: user)))
    }

    /// The share as `viewer` reads it: the owner, then participants and invitees by name.
    func shareInfo(_ key: ZoneKey, viewer: String) -> CloudShare {
        guard let held = zones[key] else { return CloudShare(url: nil, title: nil, publicPermission: .none, participants: []) }
        var participants = [CloudShare.Participant(user: key.owner, name: nil, email: nil, permission: .readWrite, role: .owner,
                                                   acceptance: .accepted, isCurrentUser: viewer == key.owner)]
        for (user, permission) in held.participants.sorted(by: { $0.key < $1.key }) {
            participants.append(CloudShare.Participant(
                user: user, name: nil, email: emails.first { $0.value == user }?.key, permission: Self.permission(permission),
                role: held.publicUsers.contains(user) ? .publicUser : .privateUser, acceptance: .accepted, isCurrentUser: viewer == user
            ))
        }
        for (user, permission) in held.invited.sorted(by: { $0.key < $1.key }) {
            participants.append(CloudShare.Participant(
                user: user, name: nil, email: emails.first { $0.value == user }?.key, permission: Self.permission(permission),
                role: .privateUser, acceptance: .pending, isCurrentUser: viewer == user
            ))
        }
        return CloudShare(url: held.shareURL, title: held.shareTitle, publicPermission: held.publicPermission.map(Self.permission) ?? .none,
                          participants: participants)
    }

    /// A link's permission: nil while only invitees may join.
    static func linkPermission(_ permission: CloudShare.Permission) -> Permission? {
        switch permission {
        case .none: return nil
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        }
    }

    static func permission(_ permission: CloudShare.Permission) -> Permission {
        permission == .readWrite ? .readWrite : .readOnly
    }

    static func permission(_ permission: Permission) -> CloudShare.Permission {
        permission == .readWrite ? .readWrite : .readOnly
    }

    func commitDelete(named name: String, in key: ZoneKey) {
        guard let held = zones[key], let existing = held.records.removeValue(forKey: name) else { return }
        held.sequence += 1
        held.tombstones[name] = (recordType: existing.recordType, sequence: held.sequence)
    }

    func injectedFailure(for recordName: String) -> CloudError? {
        guard let index = recordInjections.firstIndex(where: { $0.recordName == recordName && $0.remaining > 0 }) else { return nil }
        recordInjections[index].remaining -= 1
        return recordInjections[index].error
    }

    func usage(of owner: String) -> Int64 {
        zones.filter { $0.key.owner == owner }.values.reduce(0) { total, zone in
            total + zone.records.values.reduce(0) { $0 + Int64($1.byteCount) }
        }
    }

    // MARK: Values

    /// A record's fields as the server keeps them, an asset's file read now.
    func storedFields(of record: CloudRecord) throws -> (encrypted: [String: StoredValue], plain: [String: StoredValue]) {
        var encrypted: [String: StoredValue] = [:]
        var plain: [String: StoredValue] = [:]
        for (field, value) in record.encryptedFields {
            if case .asset = value {
                throw CloudError(.invalidArguments, message: "\(record.id): an asset is never in encryptedValues (\(field))")
            }
            encrypted[field] = .value(value)
        }
        for (field, value) in record.fields {
            guard encrypted[field] == nil else {
                throw CloudError(.invalidArguments, message: "\(record.id): \(field) is both encrypted and plain")
            }
            if case .asset(let url) = value {
                guard let data = try? Data(contentsOf: url) else {
                    throw CloudError(.assetFileNotFound, message: "\(record.id): no file at \(url.path) for \(field)")
                }
                plain[field] = .asset(data)
            } else {
                plain[field] = .value(value)
            }
        }
        return (encrypted, plain)
    }

    /// Each field's kind under its schema key (container, record type, field), as Development's
    /// just-in-time schema fixes it at the first write.
    func kinds(of fields: (encrypted: [String: StoredValue], plain: [String: StoredValue]), type: String,
                    container: String) -> [(String, FieldKind)] {
        let kind: (StoredValue) -> String = { value in
            switch value {
            case .asset: return "asset"
            case .value(let value):
                switch value {
                case .bytes: return "bytes"
                case .string: return "string"
                case .int64: return "int64"
                case .double: return "double"
                case .date: return "date"
                case .stringList: return "stringList"
                case .asset: return "asset"
                }
            }
        }
        return fields.encrypted.map { ("\(container)\u{1}\(type)\u{1}\($0.key)", FieldKind(kind: kind($0.value), encrypted: true)) }
            + fields.plain.map { ("\(container)\u{1}\(type)\u{1}\($0.key)", FieldKind(kind: kind($0.value), encrypted: false)) }
    }

    /// A stored record as a client reads it: only the desired keys, assets written to files.
    func cloudRecord(_ stored: StoredRecord, named name: String, in key: ZoneKey, as zoneID: CloudZoneID,
                     desiredKeys: [String]?, viewer: String? = nil) -> CloudRecord {
        let wanted: (String) -> Bool = { field in desiredKeys.map { $0.contains(field) } ?? true }
        var record = CloudRecord(id: CloudRecordID(name, in: zoneID), recordType: stored.recordType)
        for (field, value) in stored.encrypted where wanted(field) {
            record.encryptedFields[field] = materialized(value, field: field, record: name, tag: stored.changeTag, in: key)
        }
        for (field, value) in stored.plain where wanted(field) {
            record.fields[field] = materialized(value, field: field, record: name, tag: stored.changeTag, in: key)
        }
        record.systemFields = systemFields(of: stored, named: name, in: key)
        record.changeTag = stored.changeTag
        record.creationDate = stored.created
        record.modificationDate = stored.modified
        if stored.recordType == CloudRecordID.shareRecordType {
            record.share = shareInfo(key, viewer: viewer ?? key.owner)
        }
        return record
    }

    func materialized(_ value: StoredValue, field: String, record: String, tag: String, in key: ZoneKey) -> CloudFieldValue {
        switch value {
        case .value(let value):
            return value
        case .asset(let data):
            let safe: (String) -> String = { $0.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }
            let folder = downloads.appendingPathComponent([key.container, key.owner, key.name].map(safe).joined(separator: "/"), isDirectory: true)
            let file = folder.appendingPathComponent("\(safe(record))-\(safe(field))-\(tag)")
            if !FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: file)
            }
            return .asset(file)
        }
    }

    func systemFields(of stored: StoredRecord, named name: String, in key: ZoneKey) -> Data {
        (try? Self.encoder.encode(SystemFields(container: key.container, owner: key.owner, zone: key.name, record: name,
                                               tag: stored.changeTag))) ?? Data()
    }

    func encode<T: Encodable>(_ token: T) -> CloudChangeToken {
        CloudChangeToken(data: (try? Self.encoder.encode(token)) ?? Data())
    }

    /// A record's bytes as CloudKit's request and record limits count them: every field but assets.
    static func byteCount(of record: CloudRecord) -> Int {
        (Array(record.encryptedFields.values) + Array(record.fields.values)).reduce(0) { $0 + byteCount($1) }
    }

    static func byteCount(_ value: CloudFieldValue) -> Int {
        switch value {
        case .bytes(let data): return data.count
        case .string(let string): return string.utf8.count
        case .int64, .double, .date: return 8
        case .stringList(let list): return list.reduce(0) { $0 + $1.utf8.count }
        case .asset: return 0
        }
    }
}

/// A small seeded generator, so a shuffled delivery is the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
